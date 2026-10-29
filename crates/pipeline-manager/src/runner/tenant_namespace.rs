//! Namespaces, quotas and limits the platform gives a tenant.
//!
//! A tenant's pipelines share the platform namespace until an operator gives
//! the tenant one of its own. Giving it one is what makes a quota possible:
//! a `ResourceQuota` counts what is in a namespace, so with every tenant's
//! pipelines in one namespace a quota can only be the whole platform's. With
//! one namespace per tenant, the chart's `tenantNamespaces` entry carries the
//! quota, and the API server keeps the namespace in step with it.
//!
//! Three things are kept in step:
//!
//! * the namespace itself, created when the tenant is given one and deleted
//!   when the tenant is;
//! * a `ResourceQuota` that caps the totals of what the namespace's pipelines
//!   may claim, which is what turns "the cluster is full" into a per-tenant
//!   limit;
//! * a `LimitRange` that gives a pipeline pod defaults, so a pipeline that
//!   names no CPU request still counts against the quota at a known size
//!   instead of being rejected or admitted as free.
//!
//! What this module does not do is reap: a deployment that stops naming a
//! tenant's namespace leaves the namespace behind, with the pipelines in it.
//! Removing it silently would stop those pipelines, so the operator does that
//! after seeing the warning the API server logs at start-up.

use crate::config::KubernetesRunnerConfig;
use crate::error::ManagerError;
use crate::runner::error::RunnerError;
use k8s_openapi::api::core::v1::{
    LimitRange, LimitRangeItem, LimitRangeSpec, Namespace, ResourceQuota, ResourceQuotaSpec,
};
use k8s_openapi::api::rbac::v1::{
    RoleBinding, RoleRef, Subject,
};
use k8s_openapi::apimachinery::pkg::api::resource::Quantity;
use kube::api::{Api, DeleteParams, Patch, PatchParams, PostParams};
use kube::Client;
use std::collections::BTreeMap;
use tracing::{error, info, warn};

/// A label the platform puts on every namespace it manages.
///
/// It is what tells a namespace the platform created from one an operator
/// created by hand: only the former is deleted when the tenant goes.
pub const MANAGED_LABEL: &str = "feldera.com/managed-by";

/// Value of [`MANAGED_LABEL`] on a namespace the platform created.
pub const MANAGED_BY: &str = "feldera-manager";

/// Label recording the tenant a managed namespace belongs to.
pub const TENANT_ID_LABEL: &str = "feldera.com/tenant-id";

/// Name of the `RoleBinding` the platform writes into a tenant namespace.
///
/// Fixed rather than derived from the namespace: one binding per namespace, the
/// same name everywhere, so an operator looking for "what did the platform grant
/// here" has one place to look.
pub const RUNNER_BINDING_NAME: &str = "feldera-pipeline-runner";

/// One tenant's namespace and the quota it carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TenantNamespacePlan {
    /// Tenant the namespace belongs to.
    pub tenant_id: uuid::Uuid,
    /// Name of the namespace.
    pub namespace: String,
    /// Quota the namespace gets, or `None` when it gets none.
    pub quota: QuotaSpec,
    /// LimitRange defaults a pipeline pod inherits.
    pub limits: LimitSpec,
}

/// The totals a tenant's namespace may claim.
///
/// Every field is a Kubernetes quantity string (`8`, `500m`, `32000Mi`), which
/// is the form the chart's `tenantNamespaces` entry carries and the form the
/// quota takes. Strings rather than numbers keep the platform from having to
/// know which unit an operator meant: `500m` and `0.5` are both CPU requests,
/// and converting between them here would only lose information.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct QuotaSpec {
    /// Sum of `requests.cpu` over the namespace's pods.
    pub requests_cpu: Option<String>,
    /// Sum of `requests.memory`.
    pub requests_memory: Option<String>,
    /// Sum of `limits.cpu`.
    pub limits_cpu: Option<String>,
    /// Sum of `limits.memory`.
    pub limits_memory: Option<String>,
    /// Number of persistent volume claims, counted rather than sized.
    pub persistent_volume_claims: Option<String>,
    /// Sum of requested storage over those claims.
    pub requests_storage: Option<String>,
}

impl QuotaSpec {
    /// Whether the quota caps anything at all.
    ///
    /// An empty quota is not `Some` with no fields: the Kubernetes API server
    /// rejects a `ResourceQuota` with an empty `hard` map, so a plan with no
    /// caps carries no quota object.
    pub fn is_empty(&self) -> bool {
        self.hard().is_empty()
    }

    /// The `hard` map of the quota object.
    pub fn hard(&self) -> BTreeMap<String, Quantity> {
        let mut hard = BTreeMap::new();
        for (key, value) in [
            ("requests.cpu", &self.requests_cpu),
            ("requests.memory", &self.requests_memory),
            ("limits.cpu", &self.limits_cpu),
            ("limits.memory", &self.limits_memory),
            ("persistentvolumeclaims", &self.persistent_volume_claims),
            ("requests.storage", &self.requests_storage),
        ] {
            if let Some(value) = value.as_ref().filter(|value| !value.is_empty()) {
                hard.insert(key.to_string(), Quantity(value.clone()));
            }
        }
        hard
    }
}

/// Defaults and bounds a pod in the namespace inherits.
///
/// The quota only counts what a pod declares, so a pod that declares nothing
/// slips through. The `LimitRange` closes that: with a default request set, a
/// pod that names none inherits it and is counted.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LimitSpec {
    /// CPU request given to a container that names none.
    pub default_cpu_request: Option<String>,
    /// Memory request given to a container that names none.
    pub default_memory_request: Option<String>,
    /// CPU limit given to a container that names none.
    pub default_cpu_limit: Option<String>,
    /// Memory limit given to a container that names none.
    pub default_memory_limit: Option<String>,
    /// Largest CPU limit a container may name. Exceeding it fails admission
    /// rather than being clamped, which turns a typo into an error.
    pub max_cpu: Option<String>,
    /// Largest memory limit a container may name.
    pub max_memory: Option<String>,
}

impl LimitSpec {
    /// Whether the limits change anything.
    pub fn is_empty(&self) -> bool {
        self.defaults().is_empty() && self.maximum().is_empty()
    }

    fn defaults(&self) -> BTreeMap<String, Quantity> {
        quantities([
            ("cpu", &self.default_cpu_request),
            ("memory", &self.default_memory_request),
        ])
    }

    fn default_limits(&self) -> BTreeMap<String, Quantity> {
        quantities([
            ("cpu", &self.default_cpu_limit),
            ("memory", &self.default_memory_limit),
        ])
    }

    fn maximum(&self) -> BTreeMap<String, Quantity> {
        quantities([("cpu", &self.max_cpu), ("memory", &self.max_memory)])
    }
}

/// Builds a quantity map from the fields that are set.
fn quantities<const N: usize>(
    fields: [(&'static str, &Option<String>); N],
) -> BTreeMap<String, Quantity> {
    fields
        .into_iter()
        .filter_map(|(key, value)| {
            value
                .as_ref()
                .filter(|value| !value.is_empty())
                .map(|value| (key.to_string(), Quantity(value.clone())))
        })
        .collect()
}

/// Why a tenant's namespace could not be found, created or annotated.
#[derive(Debug)]
pub enum NamespaceError {
    /// The tenant's namespace does not exist and the platform may not create
    /// it: the manager's role is namespaced, so creating one needs a
    /// cluster-scoped grant the chart gives only when asked.
    Missing {
        namespace: String,
        tenant: uuid::Uuid,
    },
    /// The API server refused the call.
    Api(String),
}

impl std::fmt::Display for NamespaceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NamespaceError::Missing { namespace, tenant } => write!(
                f,
                "tenant {tenant} is mapped to the namespace '{namespace}', which does not exist \
                 and was not created by the platform: create it with the quota in \
                 --kubernetes-runner-tenant-quotas, or turn on \
                 --kubernetes-runner-tenant-namespace-automation to let the platform create it"
            ),
            NamespaceError::Api(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for NamespaceError {}

/// Builds the namespace, quota and limit range of one tenant.
pub fn namespace_object(plan: &TenantNamespacePlan) -> Namespace {
    let mut labels = BTreeMap::new();
    labels.insert(MANAGED_LABEL.to_string(), MANAGED_BY.to_string());
    labels.insert(TENANT_ID_LABEL.to_string(), plan.tenant_id.to_string());
    Namespace {
        metadata: k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta {
            name: Some(plan.namespace.clone()),
            labels: Some(labels),
            ..Default::default()
        },
        ..Default::default()
    }
}

/// Builds the quota object of one tenant's namespace, or `None` when the plan
/// caps nothing.
pub fn quota_object(plan: &TenantNamespacePlan) -> Option<ResourceQuota> {
    if plan.quota.is_empty() {
        return None;
    }
    Some(ResourceQuota {
        metadata: k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta {
            name: Some(quota_name(&plan.namespace)),
            namespace: Some(plan.namespace.clone()),
            ..Default::default()
        },
        spec: Some(ResourceQuotaSpec {
            hard: Some(plan.quota.hard()),
            ..Default::default()
        }),
        status: None,
    })
}

/// Builds the limit range of one tenant's namespace, or `None` when the plan
/// sets no default and no maximum.
pub fn limit_range_object(plan: &TenantNamespacePlan) -> Option<LimitRange> {
    if plan.limits.is_empty() {
        return None;
    }
    let item = LimitRangeItem {
        type_: "Container".to_string(),
        default: Some(plan.limits.default_limits()).filter(|map| !map.is_empty()),
        default_request: Some(plan.limits.defaults()).filter(|map| !map.is_empty()),
        max: Some(plan.limits.maximum()).filter(|map| !map.is_empty()),
        ..Default::default()
    };
    Some(LimitRange {
        metadata: k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta {
            name: Some(limit_range_name(&plan.namespace)),
            namespace: Some(plan.namespace.clone()),
            ..Default::default()
        },
        spec: Some(LimitRangeSpec { limits: vec![item] }),
    })
}

/// Name of the quota in a namespace.
pub fn quota_name(namespace: &str) -> String {
    format!("{namespace}-tenant-quota")
}

/// Name of the limit range in a namespace.
pub fn limit_range_name(namespace: &str) -> String {
    format!("{namespace}-tenant-limits")
}

/// Parses the chart's tenant map into plans.
///
/// The map's key is the tenant, either as a UUID or as a name that is resolved
/// through `resolve` (the database lookup). A key that is neither is skipped
/// with a warning: one typo must not keep every other tenant from having a
/// quota. A namespace that appears twice is a configuration mistake that would
/// have two tenants share a quota, so the later entry is skipped.
pub fn plans_from_config(
    config: &KubernetesRunnerConfig,
    resolve: impl Fn(&str) -> Option<uuid::Uuid>,
) -> Vec<TenantNamespacePlan> {
    let mut plans: Vec<TenantNamespacePlan> = Vec::new();
    for entry in &config.kubernetes_runner_tenant_quotas {
        let Some((key, value)) = entry.split_once(':') else {
            warn!(
                entry,
                "ignoring a tenant quota that is not of the form <tenant>:<namespace>:<quota>"
            );
            continue;
        };
        let key = key.trim().strip_prefix("tenant=").unwrap_or(key.trim());
        let tenant_id = match uuid::Uuid::parse_str(key) {
            Ok(uuid) => uuid,
            Err(_) => match resolve(key) {
                Some(id) => id,
                None => {
                    warn!(
                        entry,
                        "ignoring a tenant quota whose tenant is neither a UUID nor a known \
                         tenant name"
                    );
                    continue;
                }
            },
        };
        let mut parts = value.split(':');
        let Some(namespace) = parts.next().map(str::trim).filter(|ns| !ns.is_empty()) else {
            warn!(entry, "ignoring a tenant quota with an empty namespace");
            continue;
        };
        let Some(spec) = parts.next() else {
            warn!(
                entry,
                "ignoring a tenant quota with no quota spec: an entry with a namespace and no \
                 quota turns automation on for the tenant without capping anything"
            );
            continue;
        };
        if plans
            .iter()
            .any(|plan| plan.namespace == namespace || plan.tenant_id == tenant_id)
        {
            warn!(
                entry,
                "ignoring a tenant quota that repeats a tenant or a namespace"
            );
            continue;
        }
        match parse_quota_spec(spec) {
            Ok((quota, limits)) => plans.push(TenantNamespacePlan {
                tenant_id,
                namespace: namespace.to_string(),
                quota,
                limits,
            }),
            Err(error) => warn!(entry, %error, "ignoring a tenant quota that does not parse"),
        }
    }
    plans
}

/// Parses the quota part of a `tenant=<id>:<namespace>:<quota>` entry.
///
/// The spec is a comma-separated list of `key=value` pairs. Keys are the
/// `ResourceQuota` resource names (`requests.cpu`, `limits.memory`,
/// `persistentvolumeclaims`, `requests.storage`) plus the `LimitRange` keys
/// (`default.cpu`, `default.memory`, `defaultRequest.cpu`,
/// `defaultRequest.memory`, `max.cpu`, `max.memory`). An unknown key is an
/// error rather than a warning: silently dropping `limits.memroy` would cap
/// nothing while reading as if it did.
pub fn parse_quota_spec(spec: &str) -> Result<(QuotaSpec, LimitSpec), String> {
    let mut quota = QuotaSpec::default();
    let mut limits = LimitSpec::default();
    for pair in spec.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let Some((key, value)) = pair.split_once('=') else {
            return Err(format!("'{pair}' is not of the form key=value"));
        };
        let value = value.trim().to_string();
        if value.is_empty() {
            return Err(format!("'{pair}' has an empty value"));
        }
        match key.trim() {
            "requests.cpu" => quota.requests_cpu = Some(value),
            "requests.memory" => quota.requests_memory = Some(value),
            "limits.cpu" => quota.limits_cpu = Some(value),
            "limits.memory" => quota.limits_memory = Some(value),
            "persistentvolumeclaims" => quota.persistent_volume_claims = Some(value),
            "requests.storage" => quota.requests_storage = Some(value),
            "default.cpu" => limits.default_cpu_limit = Some(value),
            "default.memory" => limits.default_memory_limit = Some(value),
            "defaultRequest.cpu" => limits.default_cpu_request = Some(value),
            "defaultRequest.memory" => limits.default_memory_request = Some(value),
            "max.cpu" => limits.max_cpu = Some(value),
            "max.memory" => limits.max_memory = Some(value),
            other => {
                return Err(format!(
                    "'{other}' is not a quota key: use requests.cpu, requests.memory, \
                     limits.cpu, limits.memory, persistentvolumeclaims, requests.storage, \
                     default.cpu, default.memory, defaultRequest.cpu, defaultRequest.memory, \
                     max.cpu or max.memory"
                ));
            }
        }
    }
    Ok((quota, limits))
}

/// The namespace names the quota map mentions, for the start-up check.
pub fn configured_namespaces(config: &KubernetesRunnerConfig) -> Vec<String> {
    let mut namespaces: Vec<String> = config
        .kubernetes_runner_tenant_quotas
        .iter()
        .filter_map(|entry| entry.split_once(':').map(|(_, rest)| rest))
        .filter_map(|rest| rest.split(':').next())
        .map(|namespace| namespace.trim().to_string())
        .filter(|namespace| !namespace.is_empty())
        .collect();
    namespaces.sort();
    namespaces.dedup();
    namespaces
}

/// The tenant a namespace is the quota namespace of, when it parses as a UUID.
///
/// Only a UUID is answered: a tenant named in the map is resolved through the
/// database, which the runner does not consult, so a named tenant's pipelines
/// stay in the runner-wide namespace until the operator writes the id. The
/// warning at start-up says which entries those are.
pub fn tenant_of(config: &KubernetesRunnerConfig, namespace: &str) -> Option<uuid::Uuid> {
    for entry in &config.kubernetes_runner_tenant_quotas {
        let Some((key, rest)) = entry.split_once(':') else {
            continue;
        };
        let Some(entry_namespace) = rest.split(':').next().map(str::trim) else {
            continue;
        };
        if entry_namespace != namespace {
            continue;
        }
        let key = key.trim().strip_prefix("tenant=").unwrap_or(key.trim());
        return uuid::Uuid::parse_str(key).ok();
    }
    None
}

/// Keeps the cluster's tenant namespaces in step with the tenants, for the API
/// server to hold while it runs.
///
/// The plans are read once at start-up, because the configuration does not
/// change while the process runs, and because a tenant named by name can only
/// be resolved against the database that exists at that moment.
pub struct TenantNamespaces {
    plans: Vec<TenantNamespacePlan>,
    automate: bool,
    client: Client,
    /// Who the manager is, and what to grant it in a tenant namespace.
    binding: Option<OwnedRunnerBinding>,
}

/// [`RunnerBinding`] with owned strings, kept on the service rather than passed
/// down from every caller.
#[derive(Debug, Clone)]
struct OwnedRunnerBinding {
    subject_namespace: String,
    service_account: String,
    cluster_role: String,
}

impl OwnedRunnerBinding {
    fn as_binding(&self) -> RunnerBinding<'_> {
        RunnerBinding {
            subject_namespace: &self.subject_namespace,
            service_account: &self.service_account,
            cluster_role: &self.cluster_role,
        }
    }
}

impl TenantNamespaces {
    /// Reads the plans named by `config`, resolving tenant names through
    /// `resolve`.
    ///
    /// Returns `None` when the configuration names no tenant namespace: the
    /// API server then has nothing to keep in step, and asking it to reach a
    /// cluster it does not use would make every tenant operation depend on the
    /// cluster being reachable.
    pub async fn from_config(
        config: &KubernetesRunnerConfig,
        resolve: impl Fn(&str) -> Option<uuid::Uuid>,
    ) -> Result<Option<Self>, ManagerError> {
        if config.kubernetes_runner_tenant_quotas.is_empty() {
            return Ok(None);
        }
        let plans = plans_from_config(config, resolve);
        if plans.is_empty() {
            // Every entry was skipped, so there is again nothing to keep in
            // step. The warnings that were logged say why.
            return Ok(None);
        }
        let client = crate::runner::kubernetes_runner::build_kubernetes_client(config).await?;
        // The binding is only needed when the platform creates namespaces: a
        // namespace an operator created is theirs to grant permissions in, and
        // that operator was told to bind the ClusterRole.
        let binding = match (
            &config.kubernetes_runner_manager_service_account,
            &config.kubernetes_runner_tenant_cluster_role,
        ) {
            (Some(service_account), Some(cluster_role)) => Some(OwnedRunnerBinding {
                subject_namespace: config
                    .kubernetes_runner_manager_namespace
                    .clone()
                    .unwrap_or_else(|| config.kubernetes_runner_namespace.clone()),
                service_account: service_account.clone(),
                cluster_role: cluster_role.clone(),
            }),
            (None, _) => {
                warn!(
                    "--kubernetes-runner-manager-service-account is unset: the platform cannot \
                     bind its own permissions in the tenant namespaces it creates, so a pipeline \
                     in one of them will be refused when the manager tries to provision it"
                );
                None
            }
            (_, None) => {
                warn!(
                    "--kubernetes-runner-tenant-cluster-role is unset: the platform cannot bind \
                     its permissions in the tenant namespaces it creates, so a pipeline in one of \
                     them will be refused when the manager tries to provision it"
                );
                None
            }
        };
        Ok(Some(Self {
            plans,
            automate: config.kubernetes_runner_tenant_namespace_automation,
            client,
            binding,
        }))
    }

    /// The plan for `tenant`, if it has one.
    pub fn plan(&self, tenant: uuid::Uuid) -> Option<&TenantNamespacePlan> {
        self.plans.iter().find(|plan| plan.tenant_id == tenant)
    }

    /// Creates or updates the tenant's namespace and quota, or reports that it
    /// is missing.
    ///
    /// Called once a tenant exists in the database, so that a namespace this
    /// creates always has a tenant to belong to.
    pub async fn admit(&self, tenant: uuid::Uuid) -> Result<(), ManagerError> {
        let Some(plan) = self.plan(tenant) else {
            return Ok(());
        };
        self.sync(plan).await
    }

    /// Deletes the tenant's namespace when automation is on.
    ///
    /// Called once the tenant is gone from the database. The namespace holds
    /// the tenant's pipelines' claims, so its deletion is what reclaims their
    /// storage; with automation off the namespace stays for the operator.
    pub async fn release(&self, tenant: uuid::Uuid) -> Result<(), ManagerError> {
        let Some(plan) = self.plan(tenant) else {
            return Ok(());
        };
        if !self.automate {
            info!(
                namespace = plan.namespace,
                "leaving the deleted tenant's namespace in place: tenant namespace \
                 automation is off"
            );
            return Ok(());
        }
        teardown(&self.client, plan).await.map(|_| ()).map_err(|error| {
            ManagerError::from(RunnerError::RunnerStopError {
                error: error.to_string(),
            })
        })
    }

    /// Checks at start-up that every namespace the map names exists, so that a
    /// missing one is reported once rather than at the first tenant creation.
    pub async fn verify_at_startup(&self) {
        for plan in &self.plans {
            if self.automate {
                if let Err(error) = self.sync(plan).await {
                    error!(
                        namespace = plan.namespace,
                        tenant = %plan.tenant_id,
                        "unable to create the tenant's namespace: {error}"
                    );
                }
                continue;
            }
            match namespace_exists(&self.client, &plan.namespace).await {
                Ok(true) => {}
                Ok(false) => warn!(
                    namespace = plan.namespace,
                    tenant = %plan.tenant_id,
                    "the tenant's namespace does not exist and tenant namespace automation is \
                     off: create it, or turn the automation on, before creating the tenant"
                ),
                Err(error) => {
                    warn!(
                        namespace = plan.namespace,
                        "unable to check that the tenant's namespace exists: {error}"
                    );
                }
            }
        }
    }

    async fn sync(&self, plan: &TenantNamespacePlan) -> Result<(), ManagerError> {
        let binding = self.binding.as_ref().map(|owned| owned.as_binding());
        apply(&self.client, plan, self.automate, binding)
            .await
            .map_err(|error| {
                ManagerError::from(RunnerError::RunnerProvisionError {
                    error: error.to_string(),
                })
            })
    }
}

/// Whether `namespace` exists.
async fn namespace_exists(client: &Client, namespace: &str) -> Result<bool, ManagerError> {
    let namespaces: Api<Namespace> = Api::all(client.clone());
    namespaces
        .get_opt(namespace)
        .await
        .map(|found| found.is_some())
        .map_err(|error| {
            ManagerError::from(RunnerError::RunnerCheckError {
                error: format!("unable to read the namespace '{namespace}': {error}"),
            })
        })
}

/// Builds the `RoleBinding` that grants the manager its permission in a tenant
/// namespace, or `None` when the manager does not know what to bind.
///
/// The chart grants the runner's rights through an aggregated `ClusterRole`
/// bound in the release namespace. A tenant namespace is created at runtime,
/// so nobody is bound there and the manager's first attempt to create the
/// tenant's StatefulSet is refused with `secrets is forbidden`. Binding the
/// `ClusterRole` in the new namespace is what closes that gap.
///
/// Both the subject and the `ClusterRole` come from configuration because the
/// manager cannot read them from the cluster: its own identity is a service
/// account, and the API server does not expose which one.
pub fn runner_binding_object(
    plan: &TenantNamespacePlan,
    subject_namespace: &str,
    subject_service_account: &str,
    cluster_role: &str,
) -> RoleBinding {
    RoleBinding {
        metadata: kube::core::ObjectMeta {
            name: Some(RUNNER_BINDING_NAME.to_string()),
            namespace: Some(plan.namespace.clone()),
            labels: Some(BTreeMap::from([(
                MANAGED_LABEL.to_string(),
                MANAGED_BY.to_string(),
            )])),
            ..Default::default()
        },
        role_ref: RoleRef {
            api_group: "rbac.authorization.k8s.io".to_string(),
            kind: "ClusterRole".to_string(),
            name: cluster_role.to_string(),
        },
        subjects: Some(vec![Subject {
            kind: "ServiceAccount".to_string(),
            name: subject_service_account.to_string(),
            namespace: Some(subject_namespace.to_string()),
            api_group: None,
        }]),
    }
}

/// Creates, patches or reports one tenant's namespace and its quota.
///
/// Called when the tenant is given a namespace. When automation is off the
/// namespace must already exist: the caller maps the tenant to it and the
/// runner's `can_provision` then reports a missing one. When automation is on
/// the platform creates the namespace, labelled as its own, and applies the
/// quota and the limit range to it.
///
/// Patching rather than creating blindly makes a second call (a manager
/// restart, two API servers) idempotent, and it is what changes a quota when
/// the operator edits the chart value and restarts.
pub async fn apply(
    client: &Client,
    plan: &TenantNamespacePlan,
    automation: bool,
    runner_binding: Option<RunnerBinding<'_>>,
) -> Result<(), NamespaceError> {
    let namespaces: Api<Namespace> = Api::all(client.clone());
    let existing = namespaces
        .get_opt(&plan.namespace)
        .await
        .map_err(|error| NamespaceError::Api(format!("unable to read '{}': {error}", plan.namespace)))?;

    match existing {
        None if !automation => {
            return Err(NamespaceError::Missing {
                namespace: plan.namespace.clone(),
                tenant: plan.tenant_id,
            });
        }
        None => {
            namespaces
                .create(&PostParams::default(), &namespace_object(plan))
                .await
                .map_err(|error| {
                    NamespaceError::Api(format!(
                        "unable to create the namespace '{}' for tenant {}: {error}",
                        plan.namespace, plan.tenant_id
                    ))
                })?;
            info!(
                namespace = %plan.namespace,
                tenant = %plan.tenant_id,
                "created a tenant namespace"
            );
        }
        Some(existing) => {
            // A namespace the platform did not create is adopted only by
            // recording the tenancy: the platform never deletes a namespace it
            // did not create, so an operator who pointed a tenant at an
            // existing namespace keeps it when the tenant goes.
            let managed = existing
                .metadata
                .labels
                .as_ref()
                .and_then(|labels| labels.get(MANAGED_LABEL))
                .is_some_and(|value| value == MANAGED_BY);
            if !managed {
                info!(
                    namespace = %plan.namespace,
                    tenant = %plan.tenant_id,
                    "using an existing namespace for a tenant; the platform will not delete it"
                );
            }
            let mut labels = BTreeMap::new();
            labels.insert(
                TENANT_ID_LABEL.to_string(),
                serde_json::Value::String(plan.tenant_id.to_string()),
            );
            if automation && !managed {
                labels.insert(
                    MANAGED_LABEL.to_string(),
                    serde_json::Value::String(MANAGED_BY.to_string()),
                );
            }
            let patch = serde_json::json!({ "metadata": { "labels": labels } });
            namespaces
                .patch(
                    &plan.namespace,
                    &PatchParams::default(),
                    &Patch::Merge(patch),
                )
                .await
                .map_err(|error| {
                    NamespaceError::Api(format!(
                        "unable to label the namespace '{}': {error}",
                        plan.namespace
                    ))
                })?;
        }
    }

    // The quota goes on after the namespace exists; a quota that cannot be
    // applied is reported to the caller, which decides whether that fails the
    // request. It is a server-side apply so that removing a cap from the chart
    // removes it from the cluster rather than leaving the old one behind.
    let quotas: Api<ResourceQuota> = Api::namespaced(client.clone(), &plan.namespace);
    let quota_name = quota_name(&plan.namespace);
    match quota_object(plan) {
        Some(quota) => {
            let patch = serde_json::json!({
                "apiVersion": "v1",
                "kind": "ResourceQuota",
                "metadata": { "name": quota_name, "namespace": plan.namespace },
                "spec": quota.spec,
            });
            quotas
                .patch(
                    &quota_name,
                    &PatchParams::apply("feldera-manager").force(),
                    &Patch::Apply(patch),
                )
                .await
                .map_err(|error| {
                    NamespaceError::Api(format!(
                        "unable to apply the quota '{quota_name}' in '{}': {error}",
                        plan.namespace
                    ))
                })?;
        }
        None => {
            // No cap configured: drop the one an earlier configuration left, so
            // an operator who removes a quota from the chart gets it removed.
            match quotas.delete(&quota_name, &DeleteParams::default()).await {
                Ok(_) => info!(namespace = %plan.namespace, "removed the tenant quota"),
                Err(kube::Error::Api(response)) if response.code == 404 => {}
                Err(error) => {
                    return Err(NamespaceError::Api(format!(
                        "unable to remove the quota '{quota_name}' in '{}': {error}",
                        plan.namespace
                    )));
                }
            }
        }
    }

    let limit_ranges: Api<LimitRange> = Api::namespaced(client.clone(), &plan.namespace);
    let limits_name = limit_range_name(&plan.namespace);
    match limit_range_object(plan) {
        Some(limits) => {
            let patch = serde_json::json!({
                "apiVersion": "v1",
                "kind": "LimitRange",
                "metadata": { "name": limits_name, "namespace": plan.namespace },
                "spec": limits.spec,
            });
            limit_ranges
                .patch(
                    &limits_name,
                    &PatchParams::apply("feldera-manager").force(),
                    &Patch::Apply(patch),
                )
                .await
                .map_err(|error| {
                    NamespaceError::Api(format!(
                        "unable to apply the limit range '{limits_name}' in '{}': {error}",
                        plan.namespace
                    ))
                })?;
        }
        None => match limit_ranges.delete(&limits_name, &DeleteParams::default()).await {
            Ok(_) => info!(namespace = %plan.namespace, "removed the tenant limit range"),
            Err(kube::Error::Api(response)) if response.code == 404 => {}
            Err(error) => {
                return Err(NamespaceError::Api(format!(
                    "unable to remove the limit range '{limits_name}' in '{}': {error}",
                    plan.namespace
                )));
            }
        },
    }

    // The manager's own permission in this namespace. Written after the
    // namespace exists and before anything is provisioned in it: without the
    // binding the manager cannot create the pipeline's Secret, and a pipeline
    // started before it lands fails with a 403 that reads like a platform bug.
    match runner_binding {
        Some(binding) => {
            let bindings: Api<RoleBinding> = Api::namespaced(client.clone(), &plan.namespace);
            // Server-side apply so that a manager that learns a corrected
            // `ClusterRole` name replaces the binding rather than failing on it.
            let patch = serde_json::json!({
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "RoleBinding",
                "metadata": {
                    "name": RUNNER_BINDING_NAME,
                    "namespace": plan.namespace,
                    "labels": {
                        MANAGED_LABEL: MANAGED_BY,
                    },
                },
                "roleRef": {
                    "apiGroup": "rbac.authorization.k8s.io",
                    "kind": "ClusterRole",
                    "name": binding.cluster_role,
                },
                "subjects": [{
                    "kind": "ServiceAccount",
                    "name": binding.service_account,
                    "namespace": binding.subject_namespace,
                }],
            });
            bindings
                .patch(
                    RUNNER_BINDING_NAME,
                    &PatchParams::apply("feldera-manager").force(),
                    &Patch::Apply(patch),
                )
                .await
                .map_err(|error| {
                    NamespaceError::Api(format!(
                        "unable to bind the runner's permissions in the namespace '{}': {error}",
                        plan.namespace
                    ))
                })?;
        }
        None => {
            warn!(
                namespace = %plan.namespace,
                tenant = %plan.tenant_id,
                "the manager does not know its own service account or the runner ClusterRole, \
                 so it cannot bind its permissions in this namespace: set \
                 --kubernetes-runner-manager-service-account and \
                 --kubernetes-runner-tenant-cluster-role, or bind the ClusterRole in the \
                 namespace yourself. Until then the pipelines in this namespace cannot be \
                 provisioned"
            );
        }
    }

    Ok(())
}

/// Who the manager runs as, and which `ClusterRole` grants what a pipeline needs.
///
/// Both are configuration because the manager cannot read them from the cluster:
/// see [`runner_binding_object`].
#[derive(Debug, Clone, Copy)]
pub struct RunnerBinding<'a> {
    /// Namespace the manager's service account lives in.
    pub subject_namespace: &'a str,
    /// Name of the manager's service account.
    pub service_account: &'a str,
    /// `ClusterRole` to bind in the tenant namespace.
    pub cluster_role: &'a str,
}

/// Deletes a tenant's namespace, if the platform created it.
///
/// Only a namespace labelled [`MANAGED_LABEL`] is deleted: a tenant mapped to a
/// namespace an operator created keeps that namespace, and the warning below
/// says so, because deleting it would delete whatever else lives there.
///
/// Deleting the namespace deletes the pipelines in it, which is the cascade the
/// tenant delete asks for. Their database rows are gone by the time this runs,
/// so the pipeline objects go with the namespace rather than one by one.
pub async fn teardown(
    client: &Client,
    plan: &TenantNamespacePlan,
) -> Result<bool, NamespaceError> {
    let namespaces: Api<Namespace> = Api::all(client.clone());
    let existing = namespaces
        .get_opt(&plan.namespace)
        .await
        .map_err(|error| NamespaceError::Api(format!("unable to read '{}': {error}", plan.namespace)))?;
    let Some(existing) = existing else {
        return Ok(false);
    };
    let managed = existing
        .metadata
        .labels
        .as_ref()
        .and_then(|labels| labels.get(MANAGED_LABEL))
        .is_some_and(|value| value == MANAGED_BY);
    if !managed {
        warn!(
            namespace = %plan.namespace,
            tenant = %plan.tenant_id,
            "the tenant is gone but its namespace was not created by the platform: leaving it in \
             place, delete it by hand once nothing else uses it"
        );
        return Ok(false);
    }
    namespaces
        .delete(&plan.namespace, &DeleteParams::default())
        .await
        .map_err(|error| {
            NamespaceError::Api(format!(
                "unable to delete the namespace '{}' of tenant {}: {error}",
                plan.namespace, plan.tenant_id
            ))
        })?;
    info!(
        namespace = %plan.namespace,
        tenant = %plan.tenant_id,
        "deleted a tenant namespace"
    );
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    fn config_with(entries: &[&str]) -> KubernetesRunnerConfig {
        let mut config = KubernetesRunnerConfig::parse_from(["test"]);
        config.kubernetes_runner_tenant_quotas =
            entries.iter().map(|entry| entry.to_string()).collect();
        config
    }

    /// Two entries joined with ';' are two tenants, and the comma inside one
    /// entry keeps separating its own keys.
    #[test]
    fn a_joined_list_of_entries_is_several_tenants() {
        let config = KubernetesRunnerConfig::parse_from([
            "test",
            "--kubernetes-runner-tenant-quotas",
            "tenant=11111111-1111-1111-1111-111111111111:ns-a: requests.cpu=16,requests.memory=32Gi;tenant=22222222-2222-2222-2222-222222222222:ns-b: limits.cpu=4",
        ]);
        assert_eq!(config.kubernetes_runner_tenant_quotas.len(), 2);
        let plans = plans_from_config(&config, |_| None);
        assert_eq!(plans.len(), 2);
        assert!(plans[0].quota.requests_memory.is_some());
        assert!(plans[1].quota.limits_cpu.is_some());
    }

    /// The chart's entry parses into a quota and the limit range it names.
    #[test]
    fn a_configured_quota_parses_into_a_plan() {
        let tenant = uuid::Uuid::now_v7();
        let config = config_with(&[&format!(
            "tenant={tenant}:acme:requests.cpu=8,requests.memory=16Gi,limits.memory=32Gi,\
             persistentvolumeclaims=20,requests.storage=500Gi,defaultRequest.cpu=1,\
             defaultRequest.memory=2Gi,max.cpu=4"
        )]);
        let plans = plans_from_config(&config, |_| None);
        assert_eq!(plans.len(), 1);
        let plan = &plans[0];
        assert_eq!(plan.tenant_id, tenant);
        assert_eq!(plan.namespace, "acme");
        let hard = plan.quota.hard();
        assert_eq!(hard["requests.cpu"].0, "8");
        assert_eq!(hard["requests.memory"].0, "16Gi");
        assert_eq!(hard["limits.memory"].0, "32Gi");
        assert_eq!(hard["persistentvolumeclaims"].0, "20");
        assert_eq!(hard["requests.storage"].0, "500Gi");
        assert_eq!(plan.limits.defaults()["cpu"].0, "1");
        assert_eq!(plan.limits.defaults()["memory"].0, "2Gi");
        assert_eq!(plan.limits.maximum()["cpu"].0, "4");
    }

    /// A tenant named rather than identified is resolved through the database.
    #[test]
    fn a_tenant_name_is_resolved() {
        let tenant = uuid::Uuid::now_v7();
        let config = config_with(&["tenant=acme:acme-ns:requests.cpu=2"]);
        let plans = plans_from_config(&config, |name| (name == "acme").then_some(tenant));
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].tenant_id, tenant);
    }

    /// A plan knows its tenant, which is what places a pipeline in it.
    #[test]
    fn a_plan_is_found_by_its_tenant() {
        let tenant = uuid::Uuid::now_v7();
        let config = config_with(&[&format!("tenant={tenant}:acme:requests.cpu=2")]);
        assert_eq!(
            plans_from_config(&config, |_| None)
                .into_iter()
                .find(|plan| plan.tenant_id == tenant)
                .map(|plan| plan.namespace),
            Some("acme".to_string())
        );
        assert!(
            plans_from_config(&config, |_| None)
                .iter()
                .all(|plan| plan.tenant_id == tenant)
        );
    }

    /// A quota entry places the tenant it names, so the map the pipeline lands
    /// in and the map the quota counts are the same one.
    #[test]
    fn the_quota_entry_is_what_places_the_tenant() {
        let tenant = uuid::Uuid::now_v7();
        let config = config_with(&[&format!("tenant={tenant}:bounded:requests.cpu=2")]);
        assert_eq!(tenant_of(&config, "bounded"), Some(tenant));
        assert_eq!(tenant_of(&config, "unbounded"), None);
    }

    /// A name that resolves to nothing is skipped, not guessed at.
    #[test]
    fn an_unresolvable_tenant_name_is_skipped() {
        let config = config_with(&["tenant=nobody:acme-ns:requests.cpu=2"]);
        assert!(plans_from_config(&config, |_| None).is_empty());
    }

    /// A misspelled key is refused rather than dropped: a dropped cap reads
    /// like a cap that is in force.
    #[test]
    fn an_unknown_quota_key_is_an_error() {
        let error = parse_quota_spec("limits.memroy=16Gi").unwrap_err();
        assert!(error.contains("limits.memroy"), "{error}");
        assert!(parse_quota_spec("requests.cpu=8").is_ok());
    }

    /// Two entries for one namespace would give two tenants one quota.
    #[test]
    fn a_repeated_namespace_is_skipped() {
        let config = config_with(&[
            "tenant=11111111-1111-1111-1111-111111111111:shared:requests.cpu=1",
            "tenant=22222222-2222-2222-2222-222222222222:shared:requests.cpu=2",
        ]);
        let plans = plans_from_config(&config, |_| None);
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].quota.requests_cpu.as_deref(), Some("1"));
    }

    /// A plan that caps nothing produces no quota object: the API server
    /// rejects one whose `hard` map is empty.
    #[test]
    fn an_empty_quota_produces_no_object() {
        let plan = TenantNamespacePlan {
            tenant_id: uuid::Uuid::nil(),
            namespace: "acme".to_string(),
            quota: QuotaSpec::default(),
            limits: LimitSpec::default(),
        };
        assert!(quota_object(&plan).is_none());
        assert!(limit_range_object(&plan).is_none());
    }

    /// The namespace object holds the labels a teardown keys on.
    #[test]
    fn the_namespace_is_labelled_as_managed() {
        let tenant = uuid::Uuid::now_v7();
        let namespace = namespace_object(&TenantNamespacePlan {
            tenant_id: tenant,
            namespace: "acme".to_string(),
            quota: QuotaSpec::default(),
            limits: LimitSpec::default(),
        });
        let labels = namespace.metadata.labels.unwrap();
        assert_eq!(labels[MANAGED_LABEL], MANAGED_BY);
        assert_eq!(labels[TENANT_ID_LABEL], tenant.to_string());
    }

    /// The quota object names the resources exactly as the Kubernetes API
    /// knows them; a near miss (`request.cpu`) is accepted by the API server as
    /// a custom resource name and caps nothing.
    #[test]
    fn the_quota_uses_the_resource_names_the_api_server_knows() {
        let (quota, _) = parse_quota_spec(
            "requests.cpu=1,requests.memory=1Gi,limits.cpu=2,limits.memory=2Gi,\
             persistentvolumeclaims=1,requests.storage=1Gi",
        )
        .unwrap();
        let hard = quota.hard();
        for key in [
            "requests.cpu",
            "requests.memory",
            "limits.cpu",
            "limits.memory",
            "persistentvolumeclaims",
            "requests.storage",
        ] {
            assert!(hard.contains_key(key), "{key} missing from {hard:?}");
        }
        assert_eq!(hard.len(), 6);
    }

    /// The limit range is one `Container` item with the defaults and the cap.
    #[test]
    fn the_limit_range_carries_the_defaults_and_the_maximum() {
        let plan = TenantNamespacePlan {
            tenant_id: uuid::Uuid::nil(),
            namespace: "acme".to_string(),
            quota: QuotaSpec::default(),
            limits: LimitSpec {
                default_cpu_request: Some("1".to_string()),
                default_memory_request: Some("2Gi".to_string()),
                max_cpu: Some("4".to_string()),
                ..Default::default()
            },
        };
        let range = limit_range_object(&plan).unwrap();
        let item = &range.spec.unwrap().limits[0];
        assert_eq!(item.type_, "Container");
        assert_eq!(item.default_request.as_ref().unwrap()["cpu"].0, "1");
        assert_eq!(item.max.as_ref().unwrap()["cpu"].0, "4");
        assert!(item.default.is_none());
    }

    /// A tenant namespace gets a binding that grants the manager what the
    /// runner needs. Without it the first pipeline in the namespace fails with
    /// `secrets is forbidden`, which reads like a platform bug rather than a
    /// missing grant.
    #[test]
    fn the_runner_binding_names_the_manager_and_the_cluster_role() {
        let plan = TenantNamespacePlan {
            tenant_id: uuid::Uuid::nil(),
            namespace: "acme".to_string(),
            quota: QuotaSpec::default(),
            limits: LimitSpec::default(),
        };
        let binding = runner_binding_object(&plan, "feldera", "feldera-controlplane", "feldera-runner");
        assert_eq!(binding.metadata.name.as_deref(), Some(RUNNER_BINDING_NAME));
        assert_eq!(binding.metadata.namespace.as_deref(), Some("acme"));
        assert_eq!(
            binding.metadata.labels.as_ref().unwrap()[MANAGED_LABEL],
            MANAGED_BY
        );
        assert_eq!(binding.role_ref.kind, "ClusterRole");
        assert_eq!(binding.role_ref.name, "feldera-runner");
        assert_eq!(binding.role_ref.api_group, "rbac.authorization.k8s.io");
        let subject = &binding.subjects.as_ref().unwrap()[0];
        assert_eq!(subject.kind, "ServiceAccount");
        assert_eq!(subject.name, "feldera-controlplane");
        assert_eq!(subject.namespace.as_deref(), Some("feldera"));
    }

    /// The binding is named the same in every namespace, so an operator has one
    /// place to look when asking what the platform granted.
    #[test]
    fn the_runner_binding_has_one_name_per_namespace() {
        let plan = TenantNamespacePlan {
            tenant_id: uuid::Uuid::nil(),
            namespace: "beta".to_string(),
            quota: QuotaSpec::default(),
            limits: LimitSpec::default(),
        };
        let binding = runner_binding_object(&plan, "feldera", "mgr", "role");
        assert_eq!(binding.metadata.name.as_deref(), Some("feldera-pipeline-runner"));
    }

    /// The parsed namespaces are what the start-up check reports.
    #[test]
    fn configured_namespaces_are_reported() {
        let config = config_with(&[
            "tenant=11111111-1111-1111-1111-111111111111:acme:requests.cpu=1",
            "tenant=22222222-2222-2222-2222-222222222222: beta :requests.cpu=1",
        ]);
        assert_eq!(configured_namespaces(&config), vec!["acme", "beta"]);
    }
}
