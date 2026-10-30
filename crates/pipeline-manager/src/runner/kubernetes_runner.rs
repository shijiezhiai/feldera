//! Kubernetes pipeline runner.
//!
//! This module contains the [`PipelineExecutor`] implementation selected by
//! `FELDERA_RUNNER=kubernetes`. The design is recorded in
//! `docs/design/adr-k8s-runner.md`; this file implements the vertical slice
//! from P1-009: create the resources a pipeline needs, wait until its pod is
//! ready, report health, scale it down, and clean up.
//!
//! # Resources per pipeline
//!
//! Every object is named after the pipeline identifier, so a manager restart
//! can manage pipelines that it did not provision (see the trait documentation
//! on `provision`):
//!
//! | Object | Name | Purpose |
//! | --- | --- | --- |
//! | `StatefulSet` | `pipeline-<id>` | exactly one pod that runs the pipeline |
//! | `Service` (headless) | `pipeline-<id>` | stable DNS name for the pod |
//! | `Secret` | `pipeline-<id>-config` | the pipeline's `config.yaml` |
//! | `PersistentVolumeClaim` | `pipeline-<id>-storage` | checkpoint and fault-tolerance files |
//! | `NetworkPolicy` | `pipeline-<id>` | only the manager namespace may reach the pipeline port |
//!
//! The manager reaches the pipeline through the headless Service's DNS name
//! (`pipeline-<id>.<namespace>.svc.cluster.local:<port>`), which is also what
//! `deployment_location` reports and what `check` probes on every pass.
//!
//! The pod pulls its program binary from `program_binary_url` (the compiler
//! service) through `/usr/local/bin/pipeline-entrypoint`, which the pipeline
//! executor image provides; the entrypoint then `exec`s the binary with the
//! arguments the runner passes. This keeps the runner image free of any specific
//! pipeline and makes the binary location the only thing the pod needs from the
//! manager side.
//!
//! # Limitations
//!
//! * Gen-2 pipelines are rejected: the Kubernetes runner launches a compiled
//!   binary, and Gen-2 has none to download.
//! * Manager↔pipeline TLS is rejected: the certificate and key would have to be
//!   mounted into the pipeline pod, which is not part of this slice.
//! * Pod logs are followed and forwarded into the pipeline's log buffer, but a
//!   container that restarts loses the lines written before the restart.

use crate::config::{CommonConfig, KubernetesRunnerConfig};
use crate::db::types::pipeline::{
    PipelineId, bootstrap_policy_to_string, runtime_desired_status_to_string,
};
use crate::db::types::tenant::TenantId;
use crate::db::types::program::ProgramInfo;
use crate::db::types::version::Version;
use crate::error::ManagerError;
use crate::pipeline_env::validate_pipeline_env;
use crate::runner::error::RunnerError;
use crate::runner::pipeline_executor::{
    PipelineExecutor, ProvisionStatus, discover_namespace_from_runtime_config_json,
};
use crate::runner::pipeline_logs::{LogMessage, LogsSender};
use crate::runner::tenant_namespace;
use async_trait::async_trait;
use feldera_types::config::{
    PipelineConfig, StorageBackendConfig, StorageCacheConfig, StorageConfig, StorageOptions,
};
use feldera_types::runtime_status::{BootstrapConfig, RuntimeDesiredStatus};
use futures_util::{AsyncBufReadExt, TryStreamExt};
use k8s_openapi::api::apps::v1::{StatefulSet, StatefulSetSpec};
use k8s_openapi::api::core::v1::{
    ConfigMap, Container, ContainerPort, EmptyDirVolumeSource, EnvVar, EnvVarSource, Event,
    KeyToPath, ObjectFieldSelector, PersistentVolumeClaim, PersistentVolumeClaimSpec,
    PersistentVolumeClaimVolumeSource, Pod, PodSecurityContext, PodSpec, PodTemplateSpec,
    ResourceRequirements, Secret, SecretVolumeSource, Service, ServicePort, ServiceSpec, Volume,
    VolumeMount, VolumeResourceRequirements,
};
use k8s_openapi::api::networking::v1::{
    NetworkPolicy, NetworkPolicyIngressRule, NetworkPolicyPeer, NetworkPolicyPort,
    NetworkPolicySpec,
};
use k8s_openapi::apimachinery::pkg::api::resource::Quantity;
use k8s_openapi::apimachinery::pkg::apis::meta::v1::{LabelSelector, ObjectMeta};
use k8s_openapi::apimachinery::pkg::util::intstr::IntOrString;
use kube::Client;
use kube::api::{Api, DeleteParams, ListParams, LogParams, Patch, PatchParams, PostParams};
use std::collections::{BTreeMap, BTreeSet};
use std::str::FromStr;
use std::time::Duration;
use tokio::task::JoinHandle;
use tracing::{Level, info, warn};
use uuid::Uuid;

/// Label every namespace carries, set by the API server, which makes a
/// namespace selector independent of how the namespace was named or labeled.
const NAMESPACE_NAME_LABEL: &str = "kubernetes.io/metadata.name";

/// Timeout for the `Provisioning` stage.
///
/// Pulling the pipeline image and starting the pod takes longer than spawning a
/// local process, so the Kubernetes runner allows more time than the local
/// runner (20s). See `docs/design/adr-k8s-runner.md` for the rationale.
pub const DEFAULT_KUBERNETES_PROVISIONING_TIMEOUT: Duration = Duration::from_secs(180);

/// TCP port the pipeline's HTTP server listens on inside the pod.
///
/// The pipeline binds a fixed port instead of writing a port file the way a
/// local pipeline does: the manager cannot read files from the pod, and a fixed
/// port lets the headless `Service` be created before the pod exists.
const PIPELINE_PORT: u16 = 8080;

/// Directory the pipeline's `config.yaml` is mounted into.
const CONFIG_MOUNT_DIR: &str = "/var/feldera/config";

/// Directory the pipeline's secret references are mounted into.
///
/// `secret_resolver` looks for `${secret:kubernetes:<name>/<key>}` under
/// `<secrets dir>/kubernetes/<name>/<key>` with the default secrets directory
/// being `/etc/feldera-secrets` (`feldera-types/src/secret_resolver.rs:76,185`).
/// Mounting a Secret named `n` with `items` key `k` at
/// `/etc/feldera-secrets/kubernetes/n` therefore makes `k` appear as the file
/// the resolver reads, with no change to the resolver itself.
const SECRETS_MOUNT_DIR: &str = "/etc/feldera-secrets";

/// Writable working directory for the program binary and the port file.
const WORK_DIR: &str = "/var/feldera/work";

/// Base directory of the persistent volume, extended with the pipeline id by
/// [`PipelineExecutor::generate_storage_config`].
const STORAGE_MOUNT_BASE: &str = "/var/feldera/storage";

/// Entrypoint the pipeline executor image must provide. It downloads (or
/// locates) the program binary and `exec`s it with the arguments passed here.
const PIPELINE_ENTRYPOINT: &str = "/usr/local/bin/pipeline-entrypoint";

/// Name of the dry-run Secret that `can_provision` sends to check that the
/// runner may deploy into the namespace. It is never persisted.
const CONNECTIVITY_PROBE_NAME: &str = "feldera-runner-connectivity-probe";

/// UID/GID the pipeline runs as.
///
/// The pipeline executor image's `ubuntu` user owns uid 1000; running with an
/// explicit UID keeps the emptyDir writable and lets `fs_group` grant write
/// access to a mounted claim regardless of how the volume was provisioned.
const PIPELINE_RUN_AS_UID: i64 = 1000;

/// Label carrying the pipeline identifier; used to find and garbage collect
/// resources that belong to a pipeline (P1-017).
const LABEL_PIPELINE_ID: &str = "feldera.com/pipeline-id";

/// Label carrying the deployment identifier. It changes on every deployment and
/// is therefore *not* part of the `StatefulSet` selector, which is immutable.
const LABEL_DEPLOYMENT_ID: &str = "feldera.com/deployment-id";

/// Label with the application name, part of the stable selector.
const LABEL_NAME: &str = "app.kubernetes.io/name";

/// Label with the managed-by marker, part of the stable selector.
const LABEL_MANAGED_BY: &str = "app.kubernetes.io/managed-by";

/// Label carrying the pipeline identifier, part of the stable selector.
const LABEL_INSTANCE: &str = "app.kubernetes.io/instance";

/// Label a scrape job selects on to find the metrics `Service` of a pipeline.
///
/// It follows the `app.kubernetes.io` convention the rest of the objects use
/// instead of the `prometheus.io/scrape` annotation: annotations cannot be
/// selected by a `ServiceMonitor`, and a label also survives a scraper that
/// reads Services rather than pods.
const LABEL_METRICS_SCRAPE: &str = "feldera.com/metrics-scrape";

/// Name shared by the `StatefulSet` and its headless `Service`.
fn resource_base(pipeline_id: PipelineId) -> String {
    format!("pipeline-{pipeline_id}")
}

/// The pipeline's `config.yaml` secret.
fn config_secret_name(pipeline_id: PipelineId) -> String {
    format!("{}-config", resource_base(pipeline_id))
}

/// The pipeline's storage claim.
fn storage_claim_name(pipeline_id: PipelineId) -> String {
    format!("{}-storage", resource_base(pipeline_id))
}

/// Annotation marking a claim a deletion deliberately kept.
///
/// A kept claim is the only object a deletion leaves behind, so it has to say
/// so: an operator who later finds it needs to know it was not an accident,
/// which pipeline it belongs to (the pipeline row is gone by then), and which
/// option kept it. Without the annotation the reaper would also collect it,
/// because nothing else distinguishes it from the leftover of a crash.
pub const RETENTION_ANNOTATION: &str = "feldera.com/storage-retention";

/// Value of [`RETENTION_ANNOTATION`] for a claim kept by an explicit deletion.
pub const RETENTION_KEPT_ON_DELETE: &str = "kept-on-pipeline-delete";

/// Annotation recording the pipeline a kept claim belonged to.
pub const RETAINED_PIPELINE_ANNOTATION: &str = "feldera.com/retained-pipeline-id";

/// Name of the single pod a `StatefulSet` with one replica creates.
fn pod_name(pipeline_id: PipelineId) -> String {
    format!("{}-0", resource_base(pipeline_id))
}

/// The `ClusterIP` `Service` a Prometheus server scrapes.
///
/// Distinct from [`resource_base`] because that name belongs to the headless
/// `Service` the manager talks to, and a `StatefulSet` may name only one
/// governing Service.
fn metrics_service_name(pipeline_id: PipelineId) -> String {
    format!("{}-metrics", resource_base(pipeline_id))
}

/// Labels that identify the metrics `Service` to a generic scrape job.
///
/// A Prometheus Operator `ServiceMonitor` and a plain
/// `kubernetes_sd_configs` job both select on these, so they are the hook a
/// deployment uses to pick pipeline metrics up without knowing the pipeline
/// ids.
fn metrics_service_labels(
    pipeline_id: PipelineId,
    deployment_id: Uuid,
) -> BTreeMap<String, String> {
    let mut labels = object_labels(pipeline_id, deployment_id);
    labels.insert(LABEL_METRICS_SCRAPE.to_string(), "true".to_string());
    labels
}

/// Labels applied to every object of one deployment.
fn object_labels(pipeline_id: PipelineId, deployment_id: Uuid) -> BTreeMap<String, String> {
    BTreeMap::from([
        (LABEL_NAME.to_string(), "feldera-pipeline".to_string()),
        (
            LABEL_MANAGED_BY.to_string(),
            "feldera-pipeline-manager".to_string(),
        ),
        (LABEL_INSTANCE.to_string(), pipeline_id.to_string()),
        (LABEL_PIPELINE_ID.to_string(), pipeline_id.to_string()),
        (LABEL_DEPLOYMENT_ID.to_string(), deployment_id.to_string()),
    ])
}

/// The subset of the labels that identifies a pod across deployments.
///
/// `StatefulSet.spec.selector` is immutable, so it must not depend on the
/// deployment identifier.
fn selector_labels(pipeline_id: PipelineId) -> BTreeMap<String, String> {
    BTreeMap::from([
        (LABEL_NAME.to_string(), "feldera-pipeline".to_string()),
        (
            LABEL_MANAGED_BY.to_string(),
            "feldera-pipeline-manager".to_string(),
        ),
        (LABEL_INSTANCE.to_string(), pipeline_id.to_string()),
        (LABEL_PIPELINE_ID.to_string(), pipeline_id.to_string()),
    ])
}

/// Formats CPU cores as a Kubernetes quantity.
///
/// Whole cores are emitted as `2`, fractional ones as millicores (`500m`),
/// which is how the Kubernetes API documents CPU quantities.
fn cpu_quantity(cores: f64) -> Quantity {
    let millis = (cores * 1000.0).round() as i64;
    if millis > 0 && millis.rem_euclid(1000) == 0 {
        Quantity(format!("{}", millis / 1000))
    } else {
        Quantity(format!("{millis}m"))
    }
}

/// Formats a megabyte count as a Kubernetes quantity in mebibytes.
fn mebibyte_quantity(mb: u64) -> Quantity {
    Quantity(format!("{mb}Mi"))
}

/// The platform limits applied to what one pipeline may request.
///
/// They mirror the `kubernetesRunner` section of the Helm chart
/// (`lowerLimitMemoryMegabyte`, `upperLimitMemoryMegabyte`,
/// `defaultStorageMegabyte`, `upperLimitStorageMegabyte`), so an operator
/// changes the range by changing chart values, not by rebuilding the manager.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResourceLimits {
    /// Smallest memory the platform provisions, in MB.
    ///
    /// Below this a container is killed before its runtime finishes starting.
    pub memory_mb_min: u64,
    /// Largest memory the platform provisions, in MB.
    pub memory_mb_max: u64,
    /// Storage a pipeline gets when it asks for none, in MB.
    pub storage_mb_default: u64,
    /// Largest storage claim the platform provisions, in MB.
    pub storage_mb_max: u64,
}

impl Default for ResourceLimits {
    fn default() -> Self {
        Self {
            memory_mb_min: 100,
            memory_mb_max: 32_000,
            storage_mb_default: 30_000,
            storage_mb_max: 128_000,
        }
    }
}

impl ResourceLimits {
    /// Caps a requested memory quantity to the range the platform provisions.
    ///
    /// The clamp applies to what the user asked for, not to the derived
    /// container limit, so a request of 1 MB becomes the lower limit and a
    /// request of a terabyte becomes the upper limit.
    pub fn clamp_memory(&self, mb: u64) -> u64 {
        mb.clamp(self.memory_mb_min, self.memory_mb_max)
    }

    /// Caps a requested storage size to the platform's ceiling.
    pub fn clamp_storage(&self, mb: u64) -> u64 {
        mb.min(self.storage_mb_max)
    }

    /// Reads the range the deployment configured in the chart values.
    fn from_config(config: &KubernetesRunnerConfig) -> Self {
        Self {
            memory_mb_min: config.kubernetes_runner_lower_memory_mb,
            memory_mb_max: config.kubernetes_runner_upper_memory_mb,
            storage_mb_default: config.kubernetes_runner_default_storage_mb,
            storage_mb_max: config.kubernetes_runner_upper_storage_mb,
        }
    }

    /// Storage requested by a pipeline, in MB, with the default applied.
    pub fn storage_for(&self, config: &PipelineConfig) -> u64 {
        let resources = &config.global.resources;
        let requested = resources
            .storage_mb_max
            .or(resources.storage_mb_min)
            .unwrap_or(self.storage_mb_default);
        self.clamp_storage(requested)
    }
}

/// The namespace one tenant's pipelines are provisioned in.
///
/// Tenants share the platform's namespace by default. Giving a tenant its own
/// namespace is what lets the platform scope quotas, network policy and RBAC
/// to one tenant instead of to everyone who shares the namespace.
#[derive(Debug, Clone)]
pub struct TenantNamespace {
    /// Tenant the mapping was looked up for.
    pub tenant_id: TenantId,
    /// Namespace its pipelines go in.
    pub namespace: String,
}

impl TenantNamespace {
    /// Looks up the tenant in the `tenant=<uuid>:<namespace>` mapping.
    ///
    /// An entry that cannot be parsed is skipped with a warning rather than
    /// failing start-up: one malformed entry must not keep every other
    /// tenant's pipelines from being provisioned, and a skipped entry merely
    /// falls back to the shared namespace, which is where those pipelines went
    /// before the mapping existed.
    fn from_config(
        config: &KubernetesRunnerConfig,
        tenant_id: &TenantId,
    ) -> Option<Self> {
        // A tenant that carries a quota is placed by that entry, which names
        // one namespace and one quota for it. Consulting the plain mapping
        // first would let the two settings disagree about where a tenant's
        // pipelines go, and the quota would then count a namespace those
        // pipelines are not in: a quota that reads as enforced and is not.
        for namespace in tenant_namespace::configured_namespaces(config) {
            if tenant_namespace::tenant_of(config, &namespace) == Some(tenant_id.0) {
                return Some(Self {
                    tenant_id: *tenant_id,
                    namespace,
                });
            }
        }
        for entry in &config.kubernetes_runner_tenant_namespaces {
            let Some((tenant, namespace)) = entry.split_once(':') else {
                warn!(
                    entry,
                    "ignoring a tenant namespace that is not of the form tenant=<uuid>:<namespace>"
                );
                continue;
            };
            let Some(tenant) = tenant.strip_prefix("tenant=") else {
                warn!(
                    entry,
                    "ignoring a tenant namespace without a 'tenant=' prefix"
                );
                continue;
            };
            if namespace.is_empty() {
                warn!(entry, "ignoring a tenant namespace with an empty namespace");
                continue;
            }
            match Uuid::from_str(tenant) {
                Ok(uuid) if TenantId(uuid) == *tenant_id => {
                    return Some(Self {
                        tenant_id: *tenant_id,
                        namespace: namespace.to_string(),
                    })
                }
                Ok(_) => continue,
                Err(error) => {
                    warn!(
                        entry,
                        "ignoring a tenant namespace whose tenant is not a UUID: {error}"
                    );
                }
            }
        }
        None
    }
}

/// Which storage classes a pipeline may be provisioned onto.
///
/// The class decides where a pipeline's checkpointed state lives, and with it
/// whether a node draining loses that state. A cluster commonly has several
/// classes — one network-replicated, one local-path — so leaving the choice
/// open to the pipeline is what lets a pipeline land on the one that cannot
/// survive an eviction.
#[derive(Debug, Clone, Default)]
pub struct StorageClassPolicy {
    /// Classes a pipeline may name. Ignored unless `enabled`.
    allowed: Vec<String>,
    /// Whether the list applies at all.
    enabled: bool,
    /// Class given to a pipeline that names none.
    default: Option<String>,
}

impl StorageClassPolicy {
    /// Reads the policy from the runner configuration.
    pub fn from_config(config: &KubernetesRunnerConfig) -> Self {
        Self {
            allowed: config.kubernetes_runner_storage_classes.clone(),
            enabled: config.kubernetes_runner_enable_storage_classes,
            default: config.kubernetes_runner_storage_class.clone(),
        }
    }

    /// The class a pipeline gets, or the reason it may not have any.
    ///
    /// A pipeline that names no class gets the configured default, if there is
    /// one, and otherwise the cluster's own default — which is the one case in
    /// which the policy cannot choose, because naming a class the cluster does
    /// not have would fail provisioning outright.
    pub fn resolve(
        &self,
        requested: Option<&str>,
    ) -> Result<Option<String>, ManagerError> {
        let selected = requested
            .map(|name| name.to_string())
            .or_else(|| self.default.clone());

        if !self.enabled {
            return Ok(selected);
        }

        match selected {
            // No class at all means the cluster default applies. The allowlist
            // cannot rule on a name it was not given, and refusing would leave
            // the pipeline unprovisionable for naming nothing, which is the
            // request of every pipeline that does not care about the class.
            None => Ok(None),
            Some(name) if self.allowed.iter().any(|allowed| allowed == &name) => Ok(Some(name)),
            Some(name) => Err(ManagerError::from(RunnerError::StorageClassNotAllowed {
                storage_class: name,
                allowed: self.allowed.clone(),
            })),
        }
    }
}

/// Maps the runtime configuration's resource requests onto pod resources.
///
/// Zero quantities are dropped: a `cpu: "0"` request is legal but meaningless,
/// and it hides the fact that the user never asked for a reservation.
fn pod_resources(config: &PipelineConfig, platform: ResourceLimits) -> ResourceRequirements {
    let resources = &config.global.resources;
    let mut requests = BTreeMap::new();
    let mut limits = BTreeMap::new();
    if let Some(cores) = resources.cpu_cores_min.filter(|cores| *cores > 0.0) {
        requests.insert("cpu".to_string(), cpu_quantity(cores));
    }
    if let Some(mb) = resources.memory_mb_min.filter(|mb| *mb > 0) {
        requests.insert(
            "memory".to_string(),
            mebibyte_quantity(platform.clamp_memory(mb)),
        );
    }
    if let Some(cores) = resources.cpu_cores_max.filter(|cores| *cores > 0.0) {
        limits.insert("cpu".to_string(), cpu_quantity(cores));
    }
    if let Some(mb) = resources.memory_mb_max.filter(|mb| *mb > 0) {
        let limit = memory_limit_mb(platform.clamp_memory(mb)).min(platform.memory_mb_max);
        limits.insert("memory".to_string(), mebibyte_quantity(limit));
    }
    ResourceRequirements {
        requests: (!requests.is_empty()).then_some(requests),
        limits: (!limits.is_empty()).then_some(limits),
        ..Default::default()
    }
}

/// Headroom the container limit leaves above the pipeline's own budget.
const MIN_MEMORY_HEADROOM_MB: u64 = 256;

/// The container memory limit for a pipeline whose runtime memory budget is
/// `max_rss_mb`.
///
/// The pipeline enforces `max_rss_mb` on the memory it accounts for itself, so a
/// container limit equal to the budget kills it: the generated binary's pages,
/// the worker thread stacks and allocator overhead all live in the same cgroup.
/// A quarter more, and at least [`MIN_MEMORY_HEADROOM_MB`], keeps the process
/// inside its limit while the runtime still stops growing at its own budget.
fn memory_limit_mb(max_rss_mb: u64) -> u64 {
    let headroom = ((max_rss_mb as f64) * 0.25).ceil() as u64;
    max_rss_mb + headroom.max(MIN_MEMORY_HEADROOM_MB)
}

/// Placeholder values the runner substitutes into a StatefulSet template.
///
/// The names match the ones the pipeline template documentation lists, so a
/// template written against the documented set needs no translation.
struct TemplateValues<'a> {
    /// Kubernetes name of the pipeline, used for object names and labels.
    id: &'a str,
    /// Namespace the pipeline runs in.
    namespace: &'a str,
    /// Image of the pipeline executor.
    image: &'a str,
    /// URL the entrypoint downloads the program binary from.
    binary_ref: &'a str,
    /// URL of the program information document.
    program_info_ref: &'a str,
    /// Mount path of the pipeline's storage, if it has any.
    pipeline_storage_path: &'a str,
    /// Storage class of the pipeline's claim, if it has any.
    storage_class_name: &'a str,
    /// UUID of this deployment.
    deployment_id: &'a str,
    /// Initial runtime status, as the pipeline CLI spells it.
    deployment_initial: &'a str,
    /// Bootstrap policy, or the empty string when there is none.
    bootstrap_policy: &'a str,
}

impl TemplateValues<'_> {
    /// The placeholder/value pairs, in the order the documentation lists them.
    fn pairs(&self) -> [(&'static str, &str); 11] {
        [
            ("{id}", self.id),
            ("{namespace}", self.namespace),
            ("{pipeline_executor_image}", self.image),
            ("{binary_ref}", self.binary_ref),
            ("{program_info_ref}", self.program_info_ref),
            ("{pipeline_storage_path}", self.pipeline_storage_path),
            ("{storage_class_name}", self.storage_class_name),
            ("{deployment_id}", self.deployment_id),
            ("{deployment_initial}", self.deployment_initial),
            ("{bootstrap_policy}", self.bootstrap_policy),
            // Belt and braces: a template that adds a trailing slash, or a
            // manifest written by an operator who read the placeholder as
            // `{storage_class}`, still renders.
            ("{storage_class}", self.storage_class_name),
        ]
    }
}

/// Replaces the documented placeholders in a StatefulSet template.
///
/// Substitution is plain string replacement, as the documentation promises:
/// a placeholder in a comment is replaced too, and an unknown `{name}` is left
/// alone so that the YAML parser reports where it is instead of the runner
/// silently dropping it.
fn substitute_placeholders(template: &str, values: &TemplateValues<'_>) -> String {
    let mut rendered = template.to_string();
    for (placeholder, value) in values.pairs() {
        rendered = rendered.replace(placeholder, value);
    }
    rendered
}

/// A storage request for one pipeline.
#[derive(Debug, Clone, PartialEq, Eq)]
struct StorageRequest {
    /// Absolute path the claim is mounted at, which is also the path the
    /// pipeline's `storage_config` points at.
    mount_path: String,
    size_mb: u64,
    storage_class: Option<String>,
}

/// Everything needed to render the objects of one pipeline deployment.
#[derive(Debug, Clone)]
struct RenderInput {
    pipeline_id: PipelineId,
    deployment_id: Uuid,
    namespace: String,
    image: String,
    config_yaml: String,
    args: Vec<String>,
    env: Vec<EnvVar>,
    resources: ResourceRequirements,
    storage: Option<StorageRequest>,
    service_account: Option<String>,
    /// Namespace the manager runs in. Only its pods may reach the pipeline port.
    manager_namespace: String,
    /// Namespace allowed to scrape the pipeline metrics Service, if any.
    ///
    /// `Some` adds the metrics Service and widens the `NetworkPolicy` to
    /// admit that namespace; see `--kubernetes-runner-metrics-service`.
    metrics_namespace: Option<String>,
    /// Kubernetes Secrets the configuration references, already checked
    /// against the allowlist. See [`connector_secrets`].
    secrets: Vec<RenderedSecret>,
}

/// One Kubernetes `Secret` a pipeline configuration references.
///
/// Carries only the names: the values are never read by the manager, so they
/// cannot leak into the pipeline's stored configuration, the logs, or the
/// database. Kubernetes mounts the Secret into the pod and the resolver reads
/// the files at start-up.
#[derive(Debug, Clone, PartialEq, Eq)]
struct RenderedSecret {
    name: String,
    /// Keys of this Secret the configuration uses, sorted and deduplicated.
    keys: Vec<String>,
}

impl RenderedSecret {
    /// Volume name for this Secret.
    ///
    /// A volume name must be a DNS label and no longer than 63 characters,
    /// which a 253-character Secret name can exceed, so the name is sanitized
    /// rather than reused. Truncation plus a hash keeps two long names from
    /// colliding into one volume.
    fn mount_name(&self) -> String {
        let sanitized: String = self
            .name
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect();
        if sanitized.len() <= 40 {
            sanitized
        } else {
            let hash = self
                .name
                .bytes()
                .fold(0u64, |acc, byte| acc.wrapping_mul(31).wrapping_add(u64::from(byte)));
            format!("{}-{hash:016x}", &sanitized[..40])
        }
    }
}

/// The objects provisioning creates for one pipeline deployment.
#[derive(Debug)]
struct PipelineObjects {
    secret: Secret,
    storage_claim: Option<PersistentVolumeClaim>,
    service: Service,
    /// `ClusterIP` Service a Prometheus server scrapes; absent unless the
    /// platform exposes pipeline metrics.
    metrics_service: Option<Service>,
    network_policy: NetworkPolicy,
    statefulset: StatefulSet,
}

impl RenderInput {
    /// Renders all objects of the deployment.
    ///
    /// This is a pure function: it makes no API calls, which keeps the shape of
    /// the objects unit-testable without a cluster.
    fn render(&self) -> PipelineObjects {
        PipelineObjects {
            secret: self.render_secret(),
            storage_claim: self.render_storage_claim(),
            service: self.render_service(),
            metrics_service: self.render_metrics_service(),
            network_policy: self.render_network_policy(),
            statefulset: self.render_statefulset(),
        }
    }

    fn metadata(&self) -> ObjectMeta {
        ObjectMeta {
            name: Some(resource_base(self.pipeline_id)),
            namespace: Some(self.namespace.clone()),
            labels: Some(object_labels(self.pipeline_id, self.deployment_id)),
            ..Default::default()
        }
    }

    fn render_secret(&self) -> Secret {
        Secret {
            metadata: ObjectMeta {
                name: Some(config_secret_name(self.pipeline_id)),
                ..self.metadata()
            },
            string_data: Some(BTreeMap::from([(
                "config.yaml".to_string(),
                self.config_yaml.clone(),
            )])),
            type_: Some("Opaque".to_string()),
            ..Default::default()
        }
    }

    fn render_storage_claim(&self) -> Option<PersistentVolumeClaim> {
        let storage = self.storage.as_ref()?;
        Some(PersistentVolumeClaim {
            metadata: ObjectMeta {
                name: Some(storage_claim_name(self.pipeline_id)),
                ..self.metadata()
            },
            spec: Some(PersistentVolumeClaimSpec {
                access_modes: Some(vec!["ReadWriteOnce".to_string()]),
                resources: Some(VolumeResourceRequirements {
                    requests: Some(BTreeMap::from([(
                        "storage".to_string(),
                        mebibyte_quantity(storage.size_mb),
                    )])),
                    ..Default::default()
                }),
                storage_class_name: storage.storage_class.clone(),
                ..Default::default()
            }),
            ..Default::default()
        })
    }

    /// The headless Service the manager addresses the pipeline through.
    ///
    /// `headless`: the DNS name resolves to the pod's own address, so the
    /// manager can reach the pipeline without a stable ClusterIP.
    fn render_service(&self) -> Service {
        Service {
            metadata: self.metadata(),
            spec: Some(ServiceSpec {
                cluster_ip: Some("None".to_string()),
                ports: Some(vec![ServicePort {
                    name: Some("http".to_string()),
                    port: i32::from(PIPELINE_PORT),
                    target_port: Some(IntOrString::Int(i32::from(PIPELINE_PORT))),
                    protocol: Some("TCP".to_string()),
                    ..Default::default()
                }]),
                selector: Some(selector_labels(self.pipeline_id)),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    /// Renders the Service a Prometheus server scrapes.
    ///
    /// The headless Service above exists for the manager: its DNS name resolves
    /// to the pod's own address, which is exactly what the manager needs and
    /// exactly what a `prometheus.io/scrape` target list cannot use, because a
    /// headless Service has no cluster address to point at. This Service is
    /// therefore a second, `ClusterIP`-backed one with the metrics labels a
    /// generic Prometheus job selects on.
    ///
    /// It points at the same port as the headless Service: the pipeline serves
    /// its `/metrics` from the same HTTP server as its API. Widening the scrape
    /// path would mean a second listener in the pipeline, which buys nothing
    /// because the payload is public inside the cluster anyway.
    fn render_metrics_service(&self) -> Option<Service> {
        self.metrics_namespace.as_ref()?;
        Some(Service {
            metadata: ObjectMeta {
                name: Some(metrics_service_name(self.pipeline_id)),
                labels: Some(metrics_service_labels(self.pipeline_id, self.deployment_id)),
                ..self.metadata()
            },
            spec: Some(ServiceSpec {
                // ClusterIP, not headless: a scraper needs a stable address.
                ports: Some(vec![ServicePort {
                    // The name becomes the endpoint port name, which is what
                    // `prometheus-k8s.yml` selects on; keep the two in step.
                    name: Some("http".to_string()),
                    port: i32::from(PIPELINE_PORT),
                    target_port: Some(IntOrString::Int(i32::from(PIPELINE_PORT))),
                    protocol: Some("TCP".to_string()),
                    ..Default::default()
                }]),
                selector: Some(selector_labels(self.pipeline_id)),
                ..Default::default()
            }),
            ..Default::default()
        })
    }

    /// Restricts the pipeline port to the manager namespace.
    ///
    /// The pipeline's HTTP API is an internal control interface: the manager
    /// polls it for health and forwards user queries to it. Sources and sinks
    /// are the pipeline's own business, so egress stays unrestricted (the
    /// policy only lists `Ingress` in `policyTypes`). A cluster whose CNI does
    /// not implement NetworkPolicy ignores the object, which is the Kubernetes
    /// contract for it.
    ///
    /// When the platform exposes pipeline metrics, the scrape namespace is
    /// admitted as a second peer on the same port. It has to be a peer of its
    /// own: a peer matches whole namespaces, and folding the two names into one
    /// selector would match neither.
    fn render_network_policy(&self) -> NetworkPolicy {
        let mut peers = vec![self.namespace_peer(&self.manager_namespace)];
        if let Some(metrics_namespace) = self
            .metrics_namespace
            .as_deref()
            .filter(|namespace| *namespace != self.manager_namespace)
        {
            peers.push(self.namespace_peer(metrics_namespace));
        }
        NetworkPolicy {
            metadata: ObjectMeta {
                name: Some(resource_base(self.pipeline_id)),
                ..self.metadata()
            },
            spec: Some(NetworkPolicySpec {
                pod_selector: Some(LabelSelector {
                    match_labels: Some(selector_labels(self.pipeline_id)),
                    ..Default::default()
                }),
                policy_types: Some(vec!["Ingress".to_string()]),
                ingress: Some(vec![NetworkPolicyIngressRule {
                    from: Some(peers),
                    ports: Some(vec![NetworkPolicyPort {
                        port: Some(IntOrString::Int(i32::from(PIPELINE_PORT))),
                        protocol: Some("TCP".to_string()),
                        ..Default::default()
                    }]),
                }]),
                egress: None,
            }),
            ..Default::default()
        }
    }

    /// A peer that admits every pod of `namespace`.
    ///
    /// The selector uses the label the API server stamps on every namespace,
    /// so it does not depend on how the namespace was created.
    fn namespace_peer(&self, namespace: &str) -> NetworkPolicyPeer {
        NetworkPolicyPeer {
            namespace_selector: Some(LabelSelector {
                match_labels: Some(BTreeMap::from([(
                    NAMESPACE_NAME_LABEL.to_string(),
                    namespace.to_string(),
                )])),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn render_statefulset(&self) -> StatefulSet {
        let mut volumes = vec![
            Volume {
                name: "config".to_string(),
                secret: Some(SecretVolumeSource {
                    secret_name: Some(config_secret_name(self.pipeline_id)),
                    ..Default::default()
                }),
                ..Default::default()
            },
            Volume {
                name: "work".to_string(),
                empty_dir: Some(EmptyDirVolumeSource::default()),
                ..Default::default()
            },
        ];
        let mut volume_mounts = vec![
            VolumeMount {
                name: "config".to_string(),
                mount_path: CONFIG_MOUNT_DIR.to_string(),
                read_only: Some(true),
                ..Default::default()
            },
            VolumeMount {
                name: "work".to_string(),
                mount_path: WORK_DIR.to_string(),
                ..Default::default()
            },
        ];
        if let Some(storage) = &self.storage {
            volumes.push(Volume {
                name: "storage".to_string(),
                persistent_volume_claim: Some(PersistentVolumeClaimVolumeSource {
                    claim_name: storage_claim_name(self.pipeline_id),
                    ..Default::default()
                }),
                ..Default::default()
            });
            volume_mounts.push(VolumeMount {
                name: "storage".to_string(),
                mount_path: storage.mount_path.clone(),
                ..Default::default()
            });
        }

        // One volume per referenced Secret, mounted where `secret_resolver`
        // expects to find it. `items` names only the keys the configuration
        // actually uses, so a Secret holding other credentials does not expose
        // them to the pod's filesystem: the file the resolver reads is the
        // projection, not the whole Secret.
        for secret in &self.secrets {
            volumes.push(Volume {
                name: format!("secret-{}", secret.mount_name()),
                secret: Some(SecretVolumeSource {
                    secret_name: Some(secret.name.clone()),
                    items: Some(
                        secret
                            .keys
                            .iter()
                            .map(|key| KeyToPath {
                                key: key.clone(),
                                path: key.clone(),
                                ..Default::default()
                            })
                            .collect(),
                    ),
                    ..Default::default()
                }),
                ..Default::default()
            });
            volume_mounts.push(VolumeMount {
                name: format!("secret-{}", secret.mount_name()),
                mount_path: format!("{SECRETS_MOUNT_DIR}/kubernetes/{}", secret.name),
                read_only: Some(true),
                ..Default::default()
            });
        }

        let container = Container {
            name: "pipeline".to_string(),
            image: Some(self.image.clone()),
            // The entrypoint downloads the program binary and `exec`s it with
            // these arguments; see the module documentation.
            command: Some(vec![PIPELINE_ENTRYPOINT.to_string()]),
            args: Some(self.args.clone()),
            env: Some(self.env.clone()),
            ports: Some(vec![ContainerPort {
                name: Some("http".to_string()),
                container_port: i32::from(PIPELINE_PORT),
                protocol: Some("TCP".to_string()),
                ..Default::default()
            }]),
            resources: Some(self.resources.clone()),
            volume_mounts: Some(volume_mounts),
            working_dir: Some(WORK_DIR.to_string()),
            ..Default::default()
        };

        StatefulSet {
            metadata: self.metadata(),
            spec: Some(StatefulSetSpec {
                service_name: Some(resource_base(self.pipeline_id)),
                replicas: Some(1),
                selector: LabelSelector {
                    match_labels: Some(selector_labels(self.pipeline_id)),
                    ..Default::default()
                },
                template: PodTemplateSpec {
                    metadata: Some(ObjectMeta {
                        labels: Some(object_labels(self.pipeline_id, self.deployment_id)),
                        ..Default::default()
                    }),
                    spec: Some(PodSpec {
                        containers: vec![container],
                        volumes: Some(volumes),
                        service_account_name: self.service_account.clone(),
                        security_context: Some(PodSecurityContext {
                            run_as_user: Some(PIPELINE_RUN_AS_UID),
                            run_as_group: Some(PIPELINE_RUN_AS_UID),
                            fs_group: Some(PIPELINE_RUN_AS_UID),
                            ..Default::default()
                        }),
                        // Give the pipeline time to write its exit checkpoint
                        // before the kubelet sends SIGKILL.
                        termination_grace_period_seconds: Some(60),
                        ..Default::default()
                    }),
                },
                ..Default::default()
            }),
            ..Default::default()
        }
    }
}

/// Arguments passed to the program binary inside the pod.
///
/// Mirrors what the local runner passes on the command line, except that the
/// port is fixed instead of being read from a port file.
fn program_args(
    deployment_id: Uuid,
    deployment_initial: RuntimeDesiredStatus,
    bootstrap_config: Option<BootstrapConfig>,
) -> Vec<String> {
    let mut args = vec![
        "--config-file".to_string(),
        format!("{CONFIG_MOUNT_DIR}/config.yaml"),
        "--bind-address".to_string(),
        "0.0.0.0".to_string(),
        "--default-port".to_string(),
        PIPELINE_PORT.to_string(),
        "--initial".to_string(),
        runtime_desired_status_to_string(deployment_initial),
        "--deployment-id".to_string(),
        deployment_id.to_string(),
    ];
    if let Some(bootstrap_config) = bootstrap_config {
        args.push("--bootstrap-policy".to_string());
        args.push(bootstrap_policy_to_string(
            bootstrap_config.active_bootstrap_policy(),
        ));
        if bootstrap_config.silent_bootstrap {
            args.push("--silent-bootstrap".to_string());
        }
        if bootstrap_config.concurrent_bootstrap {
            args.push("--concurrent-bootstrap".to_string());
        }
    }
    args
}

/// Environment shared by every pipeline pod.
fn platform_env(config: &PipelineConfig) -> Vec<EnvVar> {
    let mut env = vec![
        EnvVar {
            name: "TOKIO_WORKER_THREADS".to_string(),
            value: Some(
                config
                    .global
                    .io_workers
                    .unwrap_or(u64::from(config.global.workers))
                    .to_string(),
            ),
            ..Default::default()
        },
        EnvVar {
            name: "POD_NAME".to_string(),
            value_from: Some(EnvVarSource {
                field_ref: Some(ObjectFieldSelector {
                    field_path: "metadata.name".to_string(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        },
        EnvVar {
            name: "POD_NAMESPACE".to_string(),
            value_from: Some(EnvVarSource {
                field_ref: Some(ObjectFieldSelector {
                    field_path: "metadata.namespace".to_string(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        },
    ];
    env.extend(config.global.env.iter().map(|(name, value)| EnvVar {
        name: name.clone(),
        value: Some(value.clone()),
        ..Default::default()
    }));
    env
}

/// The Kubernetes Secrets a configuration references, checked against the
/// allowlist.
///
/// Two references are refused and one is honoured:
///
/// * `${secret:kubernetes:<name>/<key>}` is honoured when `<name>` is on the
///   allowlist, and refused when it is not. A reference outside the list is a
///   configuration mistake the author can fix, so the error names the Secret
///   and the list rather than failing later inside the pod.
/// * `${secret:kubernetes:<name>/<key>}` is also refused when `<name>` is not a
///   valid Secret name. The resolver would build a path from it, so an invalid
///   name (or one containing `..`) has to stop here.
/// * `${env:NAME}` is left alone: it never reaches the filesystem.
///
/// The keys are returned with their Secret so the StatefulSet can project
/// exactly those keys: mounting the whole Secret would put every key in it in
/// the pod's filesystem, which is more than the configuration asked for.
fn connector_secrets(
    config: &PipelineConfig,
    allowlist: &[String],
) -> Result<Vec<RenderedSecret>, RunnerError> {
    use feldera_types::secret_resolver::discover_secret_references_in_connector_config;
    use feldera_types::secret_ref::{SecretRef, validate_kubernetes_secret_name};

    // (Secret name, key) pairs, collected from every input and output.
    let mut references: BTreeSet<(String, String)> = BTreeSet::new();
    let connector_configs = config
        .inputs
        .values()
        .map(|input| &input.connector_config)
        .chain(config.outputs.values().map(|output| &output.connector_config));
    for connector_config in connector_configs {
        let as_json = serde_json::to_value(connector_config).map_err(|error| {
            RunnerError::RunnerProvisionError {
                error: format!("unable to inspect connector configuration for secret references: {error}"),
            }
        })?;
        let discovered = discover_secret_references_in_connector_config(&as_json).map_err(
            |error| RunnerError::RunnerProvisionError {
                error: format!("unable to parse a secret reference: {error}"),
            },
        )?;
        for secret_ref in discovered {
            if let SecretRef::Kubernetes { name, data_key } = secret_ref {
                references.insert((name, data_key));
            }
        }
    }

    let mut secrets: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (name, data_key) in references {
        if let Err(error) = validate_kubernetes_secret_name(&name) {
            return Err(RunnerError::RunnerProvisionError {
                error: format!(
                    "the pipeline configuration references the Kubernetes Secret '{name}', \
                     which is not a valid Secret name: {error}"
                ),
            });
        }
        if !allowlist.iter().any(|allowed| allowed == &name) {
            return Err(RunnerError::RunnerProvisionError {
                error: format!(
                    "the pipeline configuration references the Kubernetes Secret '{name}', \
                     which is not on the allowlist: {}",
                    if allowlist.is_empty() {
                        "no Secret is allowed (set \
                         --kubernetes-runner-connector-kubernetes-secrets-allowlist)"
                            .to_string()
                    } else {
                        allowlist.join(", ")
                    }
                ),
            });
        }
        secrets.entry(name).or_default().push(data_key);
    }

    Ok(secrets
        .into_iter()
        .map(|(name, keys)| RenderedSecret { name, keys })
        .collect())
}

/// Whether a Kubernetes error is a 404.
fn is_not_found(error: &kube::Error) -> bool {
    matches!(error, kube::Error::Api(response) if response.code == 404)
}

/// Whether a Kubernetes error is a 409 (already exists).
fn is_conflict(error: &kube::Error) -> bool {
    matches!(error, kube::Error::Api(response) if response.code == 409)
}

/// Reasons a waiting container will not recover on its own without a change to
/// the deployment, so provisioning fails immediately instead of burning the
/// whole provisioning timeout.
fn fatal_waiting_reason(reason: &str) -> bool {
    matches!(
        reason,
        "CrashLoopBackOff"
            | "ImagePullBackOff"
            | "ErrImagePull"
            | "InvalidImageName"
            | "CreateContainerConfigError"
            | "CreateContainerError"
    )
}

/// Whether the StatefulSet controller failed to create the pipeline's pod.
///
/// A rejected pod does not exist, so [`pod_failure`] never sees it, and the
/// StatefulSet controller does not record the rejection on the StatefulSet's
/// own status either: `status.conditions` stays empty and the object keeps
/// reporting `replicas: 0`. What it does do is emit a `Warning`/`FailedCreate`
/// Event against the StatefulSet, with the API server's message. That event is
/// what this reads.
///
/// Without it a pipeline whose tenant quota is full would sit in `Provisioning`
/// until the provisioning timeout and then report "pod does not exist", leaving
/// the operator to discover the quota on their own.
///
/// `reason` is the event's reason; `message` its text.
fn statefulset_failure(reason: &str, message: &str) -> Option<String> {
    if reason != "FailedCreate" {
        return None;
    }
    Some(if quota_exceeded(message) {
        format!(
            "the tenant's namespace has no room for this pipeline: {message}. Free capacity by \
             deleting or shrinking another pipeline in the same tenant, or raise the tenant's \
             quota"
        )
    } else {
        format!("the StatefulSet controller could not create the pipeline's pod: {message}")
    })
}

/// Whether a Kubernetes message says a `ResourceQuota` refused the request.
fn quota_exceeded(message: &str) -> bool {
    // Two shapes from the API server, both about a `ResourceQuota`:
    //   "exceeded quota: req, requested: ..., used: ..., limited: ..."
    //   "failed quota: req: must specify requests.cpu for: pipeline"
    // The second is the namespace's LimitRange not covering a container the
    // manager did not size, which is equally a "this namespace has no room".
    message.contains("exceeded quota")
        || message.contains("failed quota")
        || message.contains("must specify")
}

/// Extracts the first fatal condition of a pod, if any.
fn pod_failure(pod: &Pod) -> Option<String> {
    let status = pod.status.as_ref()?;
    if status.phase.as_deref() == Some("Failed") {
        return Some(format!(
            "pod {}{} failed: {}",
            pod.metadata.name.clone().unwrap_or_default(),
            status
                .reason
                .as_deref()
                .map(|reason| format!(" ({reason})"))
                .unwrap_or_default(),
            status.message.clone().unwrap_or_default()
        ));
    }
    let container_statuses = status.container_statuses.as_deref().unwrap_or_default();
    for container_status in container_statuses {
        let waiting = container_status
            .state
            .as_ref()
            .and_then(|state| state.waiting.as_ref());
        if let Some(waiting) = waiting
            && let Some(reason) = waiting.reason.as_deref()
            && fatal_waiting_reason(reason)
        {
            return Some(format!(
                "container '{}' of pod '{}' is in {}: {}",
                container_status.name,
                pod.metadata.name.clone().unwrap_or_default(),
                reason,
                waiting.message.clone().unwrap_or_default()
            ));
        }
        let terminated = container_status
            .state
            .as_ref()
            .and_then(|state| state.terminated.as_ref());
        if let Some(terminated) = terminated
            && terminated.exit_code != 0
            && status.phase.as_deref() != Some("Running")
        {
            return Some(format!(
                "container '{}' of pod '{}' exited with code {}: {}",
                container_status.name,
                pod.metadata.name.clone().unwrap_or_default(),
                terminated.exit_code,
                terminated.message.clone().unwrap_or_default()
            ));
        }
    }
    None
}

/// Whether the pod reports the `Ready` condition.
fn pod_ready(pod: &Pod) -> bool {
    pod.status
        .as_ref()
        .and_then(|status| status.conditions.as_deref())
        .unwrap_or_default()
        .iter()
        .any(|condition| condition.type_ == "Ready" && condition.status == "True")
}

/// Number of container restarts reported by the pod.
fn pod_restarts(pod: &Pod) -> i32 {
    pod.status
        .as_ref()
        .and_then(|status| status.container_statuses.as_deref())
        .unwrap_or_default()
        .iter()
        .map(|container_status| container_status.restart_count)
        .max()
        .unwrap_or(0)
}

/// JSON health details reported for a pod.
fn pod_details(pod: &Pod) -> serde_json::Value {
    serde_json::json!({
        "pod": pod.metadata.name.clone(),
        "namespace": pod.metadata.namespace.clone(),
        "phase": pod.status.as_ref().and_then(|status| status.phase.clone()),
        "ready": pod_ready(pod),
        "restarts": pod_restarts(pod),
    })
}

/// The Kubernetes pipeline runner.
pub struct KubernetesRunner {
    pipeline_id: PipelineId,
    common_config: CommonConfig,
    config: KubernetesRunnerConfig,
    /// Used by [`PipelineExecutor::check`] to probe the pipeline's `/status`
    /// endpoint through the headless Service.
    client: reqwest::Client,
    /// Receives the lines of the pipeline pod's log stream.
    logs_sender: LogsSender,
    /// Task that follows the pod's log stream; aborted when the pipeline stops.
    logs_task: Option<JoinHandle<()>>,
    /// The platform's resource range, read from the chart values through the
    /// manager configuration.
    limits: ResourceLimits,
    /// The class this pipeline's claim was resolved onto. Resolved once, when
    /// the runner is constructed, so every object of one deployment agrees.
    storage_class: Option<String>,
    /// The namespace this pipeline's tenant maps to, when it has one.
    tenant_namespace: Option<TenantNamespace>,
    /// Lazily initialized API client: it validates the credentials before any
    /// resource is touched, and its construction is fallible.
    kubernetes: Option<Client>,
}

/// Builds a Kubernetes API client from the runner configuration.
///
/// A kubeconfig path wins over in-cluster credentials so that a manager running
/// outside the cluster (a developer machine against `kind`) works with the usual
/// `--kubernetes-runner-kubeconfig` pointer.
pub(crate) async fn build_kubernetes_client(
    config: &KubernetesRunnerConfig,
) -> Result<Client, ManagerError> {
    let kubeconfig_path = config
        .kubernetes_runner_kubeconfig
        .as_deref()
        .filter(|path| !path.is_empty());
    let kube_config = match kubeconfig_path {
        Some(path) => {
            let kubeconfig = kube::config::Kubeconfig::read_from(path).map_err(|error| {
                RunnerError::RunnerConfigError {
                    error: format!(
                        "unable to read the Kubernetes configuration file '{path}': {error}"
                    ),
                }
            })?;
            kube::Config::from_custom_kubeconfig(
                kubeconfig,
                &kube::config::KubeConfigOptions::default(),
            )
            .await
            .map_err(|error| RunnerError::RunnerConfigError {
                error: format!("unable to build a Kubernetes configuration from '{path}': {error}"),
            })?
        }
        None => kube::Config::incluster().map_err(|error| RunnerError::RunnerConfigError {
            error: format!(
                "the Kubernetes runner is configured without a kubeconfig and is not \
                     running inside a cluster, so no service account credentials are \
                     available: {error}. Set --kubernetes-runner-kubeconfig (or \
                     FELDERA_KUBERNETES_RUNNER_KUBECONFIG)."
            ),
        })?,
    };
    Client::try_from(kube_config).map_err(|error| {
        ManagerError::from(RunnerError::RunnerConfigError {
            error: format!("unable to create the Kubernetes API client: {error}"),
        })
    })
}

impl KubernetesRunner {
    /// Marks the pipeline's claim as deliberately kept.
    ///
    /// Runs before the rest of the deletion, so a deletion that fails partway
    /// still leaves the claim identifiable. A missing claim is not an error:
    /// a pipeline deleted before it ever provisioned has none.
    async fn mark_storage_claim_retained(&self, client: &Client, namespace: &str) {
        let claims: Api<PersistentVolumeClaim> = Api::namespaced(client.clone(), namespace);
        let name = storage_claim_name(self.pipeline_id);
        let patch = serde_json::json!({
            "metadata": {"annotations": {
                RETENTION_ANNOTATION: RETENTION_KEPT_ON_DELETE,
                RETAINED_PIPELINE_ANNOTATION: self.pipeline_id.to_string(),
            }},
        });
        match claims
            .patch(&name, &PatchParams::default(), &Patch::Merge(&patch))
            .await
        {
            Ok(_) => info!(
                name,
                "retaining storage claim: the pipeline's data stays in the cluster"
            ),
            Err(error) if is_not_found(&error) => {}
            // The deletion still proceeds. Keeping the claim is the safe
            // outcome and it happens whether or not the annotation lands, so
            // failing the deletion over the annotation would turn a cosmetic
            // loss into an operator-visible failure. The warning names the
            // claim so it can be annotated by hand.
            Err(error) => warn!(
                name,
                "unable to mark the retained storage claim; it is kept but not annotated: \
                 {error}"
            ),
        }
    }

    /// Builds the Kubernetes API client from the configured credentials.
    ///
    /// A kubeconfig path wins over in-cluster credentials so that a manager
    /// running outside the cluster (a developer machine against `kind`) works
    /// with the usual `--kubernetes-runner-kubeconfig` pointer.
    async fn kubernetes_client(&mut self) -> Result<Client, ManagerError> {
        if let Some(client) = &self.kubernetes {
            return Ok(client.clone());
        }
        let client = build_kubernetes_client(&self.config).await?;
        self.kubernetes = Some(client.clone());
        Ok(client)
    }

    /// Namespace the pipeline's objects live in.
    ///
    /// An explicit per-pipeline namespace wins. Otherwise the tenant's
    /// namespace applies, from the `tenant=<uuid>:<namespace>` mapping, and a
    /// tenant without a mapping uses the runner-wide namespace.
    ///
    /// A per-pipeline namespace is honoured as given rather than checked
    /// against the tenant mapping: the mapping states where a tenant's
    /// pipelines go by default, and an explicit request has always been the way
    /// to place one pipeline elsewhere. Refusing it would break the existing
    /// pipelines that already rely on it.
    fn namespace(&self, runtime_config: &serde_json::Value) -> String {
        discover_namespace_from_runtime_config_json(runtime_config)
            .or_else(|| {
                self.tenant_namespace
                    .as_ref()
                    .map(|mapping| mapping.namespace.clone())
            })
            .unwrap_or_else(|| self.config.kubernetes_runner_namespace.clone())
    }

    /// The `host:port` at which the manager reaches the pipeline's HTTP API.
    fn location(&self, namespace: &str) -> String {
        format!(
            "{}.{namespace}.svc.cluster.local:{PIPELINE_PORT}",
            resource_base(self.pipeline_id)
        )
    }

    /// The executor image, or an actionable error when it is missing.
    fn executor_image(&self) -> Result<String, ManagerError> {
        self.config
            .kubernetes_runner_pipeline_executor_image
            .as_deref()
            .filter(|image| !image.is_empty())
            .map(str::to_string)
            .ok_or_else(|| {
                RunnerError::RunnerConfigError {
                    error: "the Kubernetes runner requires --kubernetes-runner-pipeline-executor-image \
                            (or FELDERA_KUBERNETES_RUNNER_PIPELINE_EXECUTOR_IMAGE) to be set: it is \
                            the image each pipeline pod runs"
                        .to_string(),
                }
                .into()
            })
    }

    /// Builds the objects of the deployment.
    fn render(
        &self,
        deployment_id: Uuid,
        namespace: &str,
        image: String,
        config: &PipelineConfig,
        config_yaml: String,
        args: Vec<String>,
        mut env: Vec<EnvVar>,
        binary_url: Option<&str>,
    ) -> Result<RenderInput, RunnerError> {
        // Checked before anything is created: an unlisted Secret reference is
        // a configuration mistake, and discovering it after the objects exist
        // would leave a half-provisioned deployment behind.
        let secrets = connector_secrets(
            config,
            &self.config.kubernetes_runner_connector_kubernetes_secrets_allowlist,
        )?;
        if let Some(binary_url) = binary_url {
            env.push(EnvVar {
                name: "FELDERA_PROGRAM_BINARY_URL".to_string(),
                value: Some(binary_url.to_string()),
                ..Default::default()
            });
        }
        let storage = config
            .storage_config
            .as_ref()
            .map(|storage_config| StorageRequest {
                mount_path: storage_config.path.clone(),
                size_mb: self.limits.storage_for(config),
                storage_class: self.storage_class.clone(),
            });
        Ok(RenderInput {
            pipeline_id: self.pipeline_id,
            deployment_id,
            namespace: namespace.to_string(),
            image,
            config_yaml,
            args,
            env,
            resources: pod_resources(config, self.limits),
            storage,
            service_account: config.global.resources.service_account_name.clone(),
            manager_namespace: self
                .config
                .kubernetes_runner_manager_namespace
                .clone()
                .unwrap_or_else(|| namespace.to_string()),
            // A metrics Service without a namespace to admit would create an
            // object nobody may scrape. Fall back to the manager namespace,
            // which keeps the policy exactly as it was and still leaves the
            // Service reachable on a CNI that does not enforce the policy.
            metrics_namespace: self.config.kubernetes_runner_metrics_service.then(|| {
                self.config
                    .kubernetes_runner_metrics_namespace
                    .clone()
                    .unwrap_or_else(|| namespace.to_string())
            }),
            secrets,
        })
    }

    /// Creates or updates one object.
    ///
    /// Creation is the common case; a conflict means a previous attempt (or the
    /// same attempt after a manager restart) got there first, in which case the
    /// live object is patched to the desired state so that provisioning stays
    /// idempotent.
    async fn apply<T>(&self, api: &Api<T>, name: &str, object: &T) -> Result<(), ManagerError>
    where
        T: Clone
            + serde::de::DeserializeOwned
            + serde::Serialize
            + std::fmt::Debug
            + kube::Resource<Scope = kube::core::NamespaceResourceScope>,
        T::DynamicType: Default,
    {
        match api.create(&PostParams::default(), object).await {
            Ok(_) => Ok(()),
            Err(error) if is_conflict(&error) => {
                warn!(
                    object = name,
                    "Kubernetes object already exists; patching it"
                );
                let patch = serde_json::to_value(object).map_err(|error| {
                    RunnerError::RunnerProvisionError {
                        error: format!("unable to serialize '{name}' for patching: {error}"),
                    }
                })?;
                api.patch(name, &PatchParams::default(), &Patch::Merge(patch))
                    .await
                    .map(|_| ())
                    .map_err(|error| {
                        RunnerError::RunnerProvisionError {
                            error: format!("unable to patch '{name}': {error}"),
                        }
                        .into()
                    })
            }
            Err(error) => Err(RunnerError::RunnerProvisionError {
                error: format!("unable to create '{name}': {error}"),
            }
            .into()),
        }
    }

    /// Fetches the pod, treating "not found" as `None`.
    ///
    /// A pod that cannot be read and a pod that does not exist are different
    /// answers, and the difference decides whether the caller stops a running
    /// pipeline. Building the client here rather than returning early when none
    /// is cached keeps them apart: an instance that has just been promoted has
    /// no cached client yet, and reporting its pipelines' pods as absent would
    /// stop every pipeline the previous leader was running.
    async fn get_pod(&mut self, namespace: &str) -> Result<Option<Pod>, ManagerError> {
        let client = self.kubernetes_client().await?;
        let pods: Api<Pod> = Api::namespaced(client, namespace);
        match pods.get(&pod_name(self.pipeline_id)).await {
            Ok(pod) => Ok(Some(pod)),
            Err(error) if is_not_found(&error) => Ok(None),
            Err(error) => Err(RunnerError::RunnerCheckError {
                error: format!("unable to read the pipeline pod: {error}"),
            }
            .into()),
        }
    }

    /// Reads why the cluster refused to create the pipeline's pod, if it did.
    ///
    /// The StatefulSet controller reports the rejection as an Event against the
    /// StatefulSet, not in its status (see [`statefulset_failure`]). Events are
    /// a separate resource and carry the involved object as a reference, so
    /// they are filtered by that name here rather than by a path.
    ///
    /// An unreadable Event list is not an error: provisioning continues and the
    /// deployment reports progress, which is what it did before this check
    /// existed. Being forbidden from listing events is a plausible RBAC setup,
    /// and it must not turn into a provisioning failure.
    async fn get_statefulset_failure(
        &mut self,
        namespace: &str,
    ) -> Result<Option<String>, ManagerError> {
        let client = self.kubernetes_client().await?;
        let statefulset_name = resource_base(self.pipeline_id);
        let events: Api<Event> = Api::namespaced(client, namespace);
        let list = match events.list(&ListParams::default()).await {
            Ok(list) => list,
            Err(error) => {
                // Forbidden is expected on a cluster whose manager role omits
                // events.read: say so once per poll at debug level, not as a
                // failure.
                tracing::debug!(
                    pipeline_id = %self.pipeline_id,
                    namespace = %namespace,
                    %error,
                    "unable to list events to look for a rejected pod"
                );
                return Ok(None);
            }
        };
        Ok(list
            .items
            .iter()
            .filter(|event| {
                event
                    .involved_object
                    .name
                    .as_deref()
                    .is_some_and(|name| name == statefulset_name)
                    && event
                        .involved_object
                        .kind
                        .as_deref()
                        .is_some_and(|kind| kind == "StatefulSet")
                    && event.type_.as_deref() == Some("Warning")
            })
            .filter_map(|event| {
                statefulset_failure(
                    event.reason.as_deref().unwrap_or_default(),
                    event.message.as_deref().unwrap_or_default(),
                )
            })
            .next())
    }

    /// Renders the StatefulSet from the operator-supplied template.
    ///
    /// The template lives in a ConfigMap so that an operator can change the pod
    /// shape without rebuilding the manager. Everything that identifies the
    /// object (name and namespace) is set here rather than taken from the
    /// template, because the runner looks the StatefulSet up by that name when
    /// it stops or scales the pipeline.
    async fn render_from_template(
        &self,
        client: &Client,
        configmap_name: &str,
        pipeline_namespace: &str,
        values: &TemplateValues<'_>,
    ) -> Result<StatefulSet, ManagerError> {
        let namespace = self
            .config
            .kubernetes_runner_template_namespace
            .clone()
            .unwrap_or_else(|| pipeline_namespace.to_string());
        let key = &self.config.kubernetes_runner_template_key;
        let configmaps: Api<ConfigMap> = Api::namespaced(client.clone(), &namespace);
        let configmap = configmaps.get(configmap_name).await.map_err(|error| {
            RunnerError::RunnerProvisionError {
                error: format!(
                    "unable to read the pipeline template ConfigMap '{namespace}/{configmap_name}':                      {error} (the runner's Role needs 'get' on configmaps)"
                ),
            }
        })?;
        let template = configmap
            .data
            .as_ref()
            .and_then(|data| data.get(key))
            .ok_or_else(|| RunnerError::RunnerProvisionError {
                error: format!(
                    "the template ConfigMap '{namespace}/{configmap_name}' has no '{key}' entry:                      set --kubernetes-runner-template-key to the entry that holds the template"
                ),
            })?
            .clone();

        let rendered = substitute_placeholders(&template, values);
        let mut statefulset: StatefulSet =
            serde_yaml::from_str(&rendered).map_err(|error| {
                RunnerError::RunnerProvisionError {
                    error: format!(
                        "the pipeline template in '{namespace}/{configmap_name}' is not a valid                          StatefulSet after placeholder substitution: {error}"
                    ),
                }
            })?;
        // The manager owns the identity of the pipeline pod, not the template.
        // A template that spelled its own selector labels would leave the
        // headless Service without endpoints — the placeholder set carries no
        // bare pipeline UUID, so it could not even spell them correctly — and a
        // template that named its own object would escape the runner's
        // lifecycle. Both are overwritten here instead of being validated,
        // because a working pipeline beats a rejected template.
        let name = resource_base(self.pipeline_id);
        let selectors = selector_labels(self.pipeline_id);
        let spec = statefulset
            .spec
            .as_mut()
            .ok_or_else(|| RunnerError::RunnerProvisionError {
                error: format!(
                    "the pipeline template in '{namespace}/{configmap_name}' has no spec:                      a StatefulSet template must describe the pod it runs"
                ),
            })?;
        statefulset.metadata.name = Some(name.clone());
        statefulset.metadata.namespace = Some(pipeline_namespace.to_string());
        spec.service_name = Some(name);
        spec.selector.match_labels = Some(selectors.clone());
        let pod_labels = spec
            .template
            .metadata
            .get_or_insert_with(Default::default)
            .labels
            .get_or_insert_with(Default::default);
        pod_labels.extend(selectors);
        Ok(statefulset)
    }
}

#[async_trait]
impl PipelineExecutor for KubernetesRunner {
    type Config = KubernetesRunnerConfig;

    const DEFAULT_PROVISIONING_TIMEOUT: Duration = DEFAULT_KUBERNETES_PROVISIONING_TIMEOUT;

    fn new(
        pipeline_id: PipelineId,
        tenant_id: TenantId,
        common_config: CommonConfig,
        config: Self::Config,
        client: reqwest::Client,
        logs_sender: LogsSender,
    ) -> Self {
        let limits = ResourceLimits::from_config(&config);
        let tenant_namespace = TenantNamespace::from_config(&config, &tenant_id);
        Self {
            pipeline_id,
            common_config,
            config,
            client,
            logs_sender,
            logs_task: None,
            limits,
            // A pipeline whose class the policy rejects fails at provisioning,
            // where the error reaches the user, rather than here: the
            // constructor returns no `Result`, and the request it would reject
            // is the pipeline configuration's, which the automaton re-reads.
            storage_class: None,
            tenant_namespace,
            kubernetes: None,
        }
    }

    /// Storage lives on a persistent volume mounted into the pipeline pod.
    async fn generate_storage_config(&self) -> StorageConfig {
        StorageConfig {
            path: format!("{STORAGE_MOUNT_BASE}/{}", self.pipeline_id),
            cache: StorageCacheConfig::default(),
        }
    }

    /// The pipeline pod writes its state to the volume the runner mounts, so
    /// the backend is the local file system.
    ///
    /// Only a fault-tolerant pipeline asks for this (see the automaton), which
    /// keeps a plain in-memory pipeline exactly as it was: no storage, no
    /// checkpointing, no volume access.
    fn generate_storage_options(&self) -> Option<StorageOptions> {
        Some(StorageOptions {
            backend: StorageBackendConfig::File(Box::default()),
            ..Default::default()
        })
    }

    /// Rejects provisioning early when the runner cannot work at all.
    ///
    /// Failing here surfaces a clear error while the pipeline is still `Stopped`
    /// instead of a pod that never starts.
    async fn can_provision(
        &self,
        _deployment_config: &PipelineConfig,
        runtime_config: &serde_json::Value,
    ) -> Result<(), ManagerError> {
        self.executor_image()?;
        if self.common_config.enable_https {
            return Err(RunnerError::RunnerConfigError {
                error: "the Kubernetes runner does not support manager/pipeline TLS yet: the \
                        certificate and key would have to be mounted into the pipeline pod"
                    .to_string(),
            }
            .into());
        }
        // This method takes `&self`, so the cached client (if any) is reused and
        // otherwise one is built without caching: a missing kubeconfig or
        // in-cluster credential is the most common misconfiguration.
        let client = match &self.kubernetes {
            Some(client) => client.clone(),
            None => build_kubernetes_client(&self.config).await?,
        };
        let namespace = self.namespace(runtime_config);
        // Probe the namespace with a dry-run create rather than reading the
        // Namespace object: the runner's Role is namespaced, so it cannot read
        // cluster-scoped resources, but it can always create a Secret in the
        // namespace it deploys into. A missing namespace answers 404 here
        // instead of surfacing fifteen minutes later as a provisioning timeout.
        let secrets: Api<Secret> = Api::namespaced(client.clone(), &namespace);
        let probe = Secret {
            metadata: ObjectMeta {
                name: Some(CONNECTIVITY_PROBE_NAME.to_string()),
                namespace: Some(namespace.clone()),
                ..Default::default()
            },
            ..Default::default()
        };
        let params = PostParams {
            dry_run: true,
            ..Default::default()
        };
        match secrets.create(&params, &probe).await {
            Ok(_) => Ok(()),
            Err(error) if is_not_found(&error) => Err(RunnerError::RunnerConfigError {
                error: format!(
                    "the Kubernetes namespace '{namespace}' does not exist: create it, or point \
                     --kubernetes-runner-namespace at an existing namespace"
                ),
            }
            .into()),
            Err(error) => Err(RunnerError::RunnerConfigError {
                error: format!(
                    "unable to talk to the Kubernetes API server for namespace '{namespace}': \
                     {error} (check the runner's kubeconfig, in-cluster credentials and RBAC)"
                ),
            }
            .into()),
        }
    }

    async fn provision(
        &mut self,
        deployment_initial: RuntimeDesiredStatus,
        bootstrap_config: Option<BootstrapConfig>,
        deployment_id: &Uuid,
        deployment_config: &PipelineConfig,
        program_info: &serde_json::Value,
        program_binary_url: &str,
        program_info_url: &str,
        _program_version: Version,
        runtime_config: &serde_json::Value,
        is_gen2: bool,
    ) -> Result<(), ManagerError> {
        if let Err(error) = validate_pipeline_env(&deployment_config.global.env) {
            return Err(RunnerError::RunnerProvisionError { error }.into());
        }
        if is_gen2 {
            return Err(RunnerError::RunnerProvisionError {
                error: "the Kubernetes runner cannot run Gen-2 pipelines yet: it launches a \
                        compiled program binary, and a Gen-2 pipeline has none"
                    .to_string(),
            }
            .into());
        }
        if self.common_config.compiler_host_is_loopback() {
            return Err(RunnerError::RunnerProvisionError {
                error: format!(
                    "the pipeline pod fetches its program binary from the compiler at \
                     '{}:{}', which is a loopback address: a pod cannot reach the manager's \
                     own loopback. Expose the compiler service and set --compiler-host to its \
                     in-cluster DNS name",
                    self.common_config.compiler_host, self.common_config.compiler_port
                ),
            }
            .into());
        }
        let image = self.executor_image()?;
        let client = self.kubernetes_client().await?;
        let namespace = self.namespace(runtime_config);

        // Resolve the storage class before anything is created: a class the
        // policy does not allow is a configuration mistake, and discovering it
        // after the claim exists would leave that claim behind.
        let storage_class = StorageClassPolicy::from_config(&self.config).resolve(
            deployment_config
                .global
                .resources
                .storage_class
                .as_deref(),
        )?;
        self.storage_class = storage_class;

        // Merge the program information into the deployment configuration, the
        // same way the local runner merges the downloaded program info file.
        // The automaton hands over the stored program information, which carries
        // the schema and the connector maps; the pipeline expects the subset in
        // `PipelineConfigProgramInfo`.
        let stored_program_info: ProgramInfo = serde_json::from_value(program_info.clone())
            .map_err(|error| RunnerError::RunnerProvisionError {
                error: format!("unable to parse the program information: {error}"),
            })?;
        let program_info = stored_program_info.to_pipeline_config_program_info();
        let mut config = deployment_config.clone();
        config.inputs = program_info.inputs;
        config.outputs = program_info.outputs;
        config.program_ir = program_info.program_ir;
        // The pipeline process sizes its heap from `max_rss_mb`; without a pod
        // memory limit it would grow until the OOM killer fires.
        if config.global.max_rss_mb.is_none() {
            config.global.max_rss_mb = deployment_config.global.resources.memory_mb_max;
        }

        let config_yaml =
            serde_yaml::to_string(&config).map_err(|error| RunnerError::RunnerProvisionError {
                error: format!("unable to serialize the pipeline configuration: {error}"),
            })?;
        // Secrets and ConfigMaps are capped at 1 MiB.
        const MAX_CONFIG_BYTES: usize = 900 * 1024;
        if config_yaml.len() > MAX_CONFIG_BYTES {
            return Err(RunnerError::RunnerProvisionError {
                error: format!(
                    "the pipeline configuration is {} bytes, which exceeds the {} byte limit of \
                     a Kubernetes Secret: reduce the program size or split the configuration",
                    config_yaml.len(),
                    MAX_CONFIG_BYTES
                ),
            }
            .into());
        }

        let args = program_args(*deployment_id, deployment_initial, bootstrap_config);
        let env = platform_env(&config);
        let input = self
            .render(
                *deployment_id,
                &namespace,
                image.clone(),
                &config,
                config_yaml,
                args,
                env,
                Some(program_binary_url),
            )
            .map_err(ManagerError::from)?;
        let objects = input.render();

        // Resolve the template before the first object is applied: a broken or
        // missing template then fails provisioning while nothing has been
        // created, instead of leaving a claim and a service behind.
        let statefulset_name = resource_base(self.pipeline_id);
        let statefulset = match self.config.kubernetes_runner_template_configmap.clone() {
            None => objects.statefulset.clone(),
            Some(configmap_name) => {
                let initial = runtime_desired_status_to_string(deployment_initial);
                let bootstrap_policy = bootstrap_config
                    .map(|config| bootstrap_policy_to_string(config.active_bootstrap_policy()))
                    .unwrap_or_default();
                let deployment_id = deployment_id.to_string();
                let values = TemplateValues {
                    id: &statefulset_name,
                    namespace: &namespace,
                    image: &image,
                    binary_ref: program_binary_url,
                    program_info_ref: program_info_url,
                    pipeline_storage_path: input
                        .storage
                        .as_ref()
                        .map(|storage| storage.mount_path.as_str())
                        .unwrap_or(""),
                    storage_class_name: self
                        .storage_class
                        .as_deref()
                        .unwrap_or(""),
                    deployment_id: &deployment_id,
                    deployment_initial: &initial,
                    bootstrap_policy: &bootstrap_policy,
                };
                self.render_from_template(&client, &configmap_name, &namespace, &values)
                    .await?
            }
        };

        // Storage first: the pod cannot start without its claim.
        let claims: Api<PersistentVolumeClaim> = Api::namespaced(client.clone(), &namespace);
        if let Some(claim) = &objects.storage_claim {
            let name = storage_claim_name(self.pipeline_id);
            self.apply(&claims, &name, claim).await?;
        }

        let secrets: Api<Secret> = Api::namespaced(client.clone(), &namespace);
        let secret_name = config_secret_name(self.pipeline_id);
        self.apply(&secrets, &secret_name, &objects.secret).await?;

        let services: Api<Service> = Api::namespaced(client.clone(), &namespace);
        let service_name = resource_base(self.pipeline_id);
        self.apply(&services, &service_name, &objects.service)
            .await?;
        if let Some(metrics_service) = &objects.metrics_service {
            let metrics_name = metrics_service_name(self.pipeline_id);
            self.apply(&services, &metrics_name, metrics_service)
                .await?;
        }

        // The policy has to exist before the pod, otherwise the pod is briefly
        // reachable from everywhere the cluster allows.
        let policies: Api<NetworkPolicy> = Api::namespaced(client.clone(), &namespace);
        let policy_name = resource_base(self.pipeline_id);
        self.apply(&policies, &policy_name, &objects.network_policy)
            .await?;

        let statefulsets: Api<StatefulSet> = Api::namespaced(client.clone(), &namespace);
        self.apply(&statefulsets, &statefulset_name, &statefulset)
            .await?;

        // Follow the pod's log stream from now on. The task ends when it is
        // aborted by `stop` or `clear`, or when the stream ends and the pod is
        // gone for good.
        if let Some(task) = self.logs_task.take() {
            task.abort();
        }
        self.logs_task = Some(self.spawn_log_follower(client.clone(), namespace.clone()));

        info!(
            pipeline_id = %self.pipeline_id,
            namespace = %namespace,
            "pipeline resources provisioned"
        );
        self.kubernetes = Some(client);
        Ok(())
    }

    async fn is_provisioned(
        &mut self,
        runtime_config: &serde_json::Value,
    ) -> Result<ProvisionStatus, ManagerError> {
        let namespace = self.namespace(runtime_config);
        let details = serde_json::json!({ "namespace": namespace });
        let Some(pod) = self.get_pod(&namespace).await? else {
            // The pod may be missing because the cluster refused to create it.
            // Check the owner before reporting progress: a quota that stays
            // full would otherwise read as "still provisioning" forever.
            if let Some(failure) = self.get_statefulset_failure(&namespace).await? {
                return Err(RunnerError::RunnerProvisionError { error: failure }.into());
            }
            return Ok(ProvisionStatus::Ongoing { details });
        };
        if let Some(failure) = pod_failure(&pod) {
            return Err(RunnerError::RunnerProvisionError { error: failure }.into());
        }
        // A refused container is recorded by the kubelet as a `Failed` pod *and*
        // as a `FailedCreate` event, so the event is also worth reading when a
        // pod exists: `pod_failure` reports the kubelet's message, which for a
        // quota says "Error: failed quota" without the actionable numbers.
        if let Some(failure) = self.get_statefulset_failure(&namespace).await? {
            return Err(RunnerError::RunnerProvisionError { error: failure }.into());
        }
        let details = pod_details(&pod);
        if pod_ready(&pod) {
            Ok(ProvisionStatus::Provisioned {
                location: self.location(&namespace),
                details,
            })
        } else {
            Ok(ProvisionStatus::Ongoing { details })
        }
    }

    /// Checks the pod that runs the pipeline.
    async fn check(
        &mut self,
        runtime_config: &serde_json::Value,
    ) -> Result<serde_json::Value, ManagerError> {
        let namespace = self.namespace(runtime_config);
        let Some(pod) = self.get_pod(&namespace).await? else {
            return Err(RunnerError::RunnerCheckError {
                error: format!(
                    "the pipeline pod '{}' does not exist in namespace '{namespace}'",
                    pod_name(self.pipeline_id)
                ),
            }
            .into());
        };
        if let Some(failure) = pod_failure(&pod) {
            return Err(RunnerError::RunnerCheckError { error: failure }.into());
        }
        // Probe the same route the automaton and the user will use, so a broken
        // path shows up in the pipeline's resource details instead of only when
        // the first query arrives. A refused connection is not fatal: the
        // pipeline binds its port a moment after the pod is ready, and the
        // automaton would otherwise bounce a starting pipeline.
        let status_url = format!("http://{}/status", self.location(&namespace));
        let probe = fetch_status(&self.client, &status_url).await;
        // The pipeline documents three outcomes: 200 with its runtime status,
        // 503 when it cannot read that status right now, and anything else,
        // which means the pipeline is unhealthy.
        match probe.http_status {
            Some(code) if !status_is_healthy(code) => {
                return Err(RunnerError::RunnerCheckError {
                    error: format!(
                        "the pipeline's {status_url} returned {code}, which is neither a status                          report (200) nor a temporary unavailability (503)"
                    ),
                }
                .into());
            }
            _ => {}
        }
        Ok(serde_json::json!({
            "pod": pod_details(&pod),
            "status_url": status_url,
            "http_status": probe.http_status,
            "pipeline": probe.body,
            "status_error": probe.error,
        }))
    }

    /// Scales the pipeline down to zero replicas, keeping its storage claim.
    async fn stop(&mut self, runtime_config: &serde_json::Value) -> Result<(), ManagerError> {
        let namespace = self.namespace(runtime_config);
        // A runner that was restarted while its pipeline was running has no
        // cached client; the resources still exist and are found by name.
        let client = self.kubernetes_client().await?;
        self.kubernetes = Some(client);
        self.stop_log_follower();
        self.scale_to_zero(&namespace).await
    }

    /// Deletes the pipeline's compute and storage resources.
    async fn clear(&mut self, runtime_config: &serde_json::Value) -> Result<(), ManagerError> {
        let namespace = self.namespace(runtime_config);
        let client = self.kubernetes_client().await?;
        self.stop_log_follower();
        let statefulsets: Api<StatefulSet> = Api::namespaced(client.clone(), &namespace);
        let secrets: Api<Secret> = Api::namespaced(client.clone(), &namespace);
        let services: Api<Service> = Api::namespaced(client.clone(), &namespace);
        let claims: Api<PersistentVolumeClaim> = Api::namespaced(client.clone(), &namespace);
        if self.config.kubernetes_runner_retain_storage_claims {
            self.mark_storage_claim_retained(&client, &namespace).await;
        }
        let policies: Api<NetworkPolicy> = Api::namespaced(client, &namespace);
        let mut deletions: Vec<(&str, String)> = vec![
            ("StatefulSet", resource_base(self.pipeline_id)),
            ("Service", resource_base(self.pipeline_id)),
            // Deleting a Service that was never created is a 404, which the
            // loop below tolerates, so the metrics Service needs no branch on
            // whether this deployment had one.
            ("Service", metrics_service_name(self.pipeline_id)),
            ("NetworkPolicy", resource_base(self.pipeline_id)),
            ("Secret", config_secret_name(self.pipeline_id)),
        ];
        if !self.config.kubernetes_runner_retain_storage_claims {
            deletions.push((
                "PersistentVolumeClaim",
                storage_claim_name(self.pipeline_id),
            ));
        }
        for (kind, name) in deletions {
            let result = match kind {
                "StatefulSet" => statefulsets
                    .delete(&name, &DeleteParams::default())
                    .await
                    .map(|_| ()),
                "Service" => services
                    .delete(&name, &DeleteParams::default())
                    .await
                    .map(|_| ()),
                "Secret" => secrets
                    .delete(&name, &DeleteParams::default())
                    .await
                    .map(|_| ()),
                "NetworkPolicy" => policies
                    .delete(&name, &DeleteParams::default())
                    .await
                    .map(|_| ()),
                _ => claims
                    .delete(&name, &DeleteParams::default())
                    .await
                    .map(|_| ()),
            };
            match result {
                Ok(()) => info!(kind, name, "deleted pipeline resource"),
                Err(error) if is_not_found(&error) => {}
                Err(error) => {
                    return Err(RunnerError::RunnerClearError {
                        error: format!("unable to delete {kind} '{name}': {error}"),
                    }
                    .into());
                }
            }
        }
        Ok(())
    }

}

/// Whether an HTTP status from the pipeline's `/status` endpoint means the
/// pipeline is alive.
///
/// `200` carries the runtime status and `503` means the pipeline cannot read
/// that status at this instant, which its documentation calls "unavailable"
/// rather than broken. Everything else is a failure.
fn status_is_healthy(code: u16) -> bool {
    code == 200 || code == 503
}

/// One probe of the pipeline's `/status` endpoint.
#[derive(Debug)]
struct StatusProbe {
    /// HTTP status code, absent when the request never completed.
    http_status: Option<u16>,
    /// Parsed response body, absent when the response is not JSON or failed.
    body: Option<serde_json::Value>,
    /// Transport or parsing error, absent on a successful exchange.
    error: Option<String>,
}

/// Calls the pipeline's `/status` endpoint once.
///
/// Split out from [`PipelineExecutor::check`] so that the timeout and the
/// error-shape mapping can be tested against a local socket, without a cluster.
async fn fetch_status(client: &reqwest::Client, url: &str) -> StatusProbe {
    let response = match client.get(url).timeout(Duration::from_secs(5)).send().await {
        Ok(response) => response,
        Err(error) => {
            return StatusProbe {
                http_status: None,
                body: None,
                error: Some(error.to_string()),
            };
        }
    };
    let http_status = response.status().as_u16();
    let body = match response.json::<serde_json::Value>().await {
        Ok(body) => Some(body),
        Err(error) => {
            return StatusProbe {
                http_status: Some(http_status),
                body: None,
                error: Some(format!("the response is not JSON: {error}")),
            };
        }
    };
    StatusProbe {
        http_status: Some(http_status),
        body,
        error: None,
    }
}

impl KubernetesRunner {
    /// Follows the pod's log stream and forwards every line into the pipeline's
    /// log buffer.
    ///
    /// The stream ends whenever the container restarts, so the follower starts a
    /// new one after a short pause until it is aborted. API errors are reported
    /// once per burst rather than once per retry, which would otherwise flood
    /// the buffer with the same message.
    fn spawn_log_follower(&self, client: Client, namespace: String) -> JoinHandle<()> {
        let mut logs_sender = self.logs_sender.clone();
        let pipeline_id = self.pipeline_id;
        tokio::spawn(async move {
            let pods: Api<Pod> = Api::namespaced(client, &namespace);
            let name = pod_name(pipeline_id);
            let mut last_error: Option<String> = None;
            loop {
                let params = LogParams {
                    follow: true,
                    ..Default::default()
                };
                match pods.log_stream(&name, &params).await {
                    Ok(stream) => {
                        last_error = None;
                        let mut lines = stream.lines();
                        loop {
                            match lines.try_next().await {
                                Ok(Some(line)) => {
                                    logs_sender.send(LogMessage::new_from_pipeline(&line)).await;
                                }
                                Ok(None) => break,
                                Err(error) => {
                                    let line = format!("pod log stream ended: {error}");
                                    if last_error.as_deref() != Some(line.as_str()) {
                                        logs_sender
                                            .send(LogMessage::new_from_control_plane(
                                                module_path!(),
                                                "runner",
                                                String::new(),
                                                pipeline_id.to_string(),
                                                Level::ERROR,
                                                &line,
                                            ))
                                            .await;
                                        last_error = Some(line);
                                    }
                                    break;
                                }
                            }
                        }
                    }
                    Err(error) => {
                        let line = format!("unable to follow the pod log stream: {error}");
                        if last_error.as_deref() != Some(line.as_str()) {
                            logs_sender
                                .send(LogMessage::new_from_control_plane(
                                    module_path!(),
                                    "runner",
                                    String::new(),
                                    pipeline_id.to_string(),
                                    Level::ERROR,
                                    &line,
                                ))
                                .await;
                            last_error = Some(line);
                        }
                    }
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        })
    }

    /// Stops forwarding pod logs.
    fn stop_log_follower(&mut self) {
        if let Some(task) = self.logs_task.take() {
            task.abort();
        }
    }

    /// Patches the `StatefulSet` to zero replicas and waits until the pod is
    /// gone, so that `stop()` really blocks until compute is released.
    async fn scale_to_zero(&mut self, namespace: &str) -> Result<(), ManagerError> {
        let client = self.kubernetes_client().await?;
        let statefulsets: Api<StatefulSet> = Api::namespaced(client.clone(), namespace);
        let name = resource_base(self.pipeline_id);
        let patch = serde_json::json!({ "spec": { "replicas": 0 } });
        match statefulsets
            .patch(&name, &PatchParams::default(), &Patch::Merge(&patch))
            .await
        {
            Ok(_) => {}
            Err(error) if is_not_found(&error) => return Ok(()),
            Err(error) => {
                return Err(RunnerError::RunnerStopError {
                    error: format!("unable to scale StatefulSet '{name}' to zero: {error}"),
                }
                .into());
            }
        }

        // Wait for the pod to disappear: the automaton only reports the
        // pipeline as stopped once its compute is really gone.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(120);
        loop {
            match self.get_pod(namespace).await? {
                None => return Ok(()),
                Some(pod)
                    if pod.metadata.deletion_timestamp.is_some() || pod_failure(&pod).is_some() =>
                {
                    // Terminating (or already dead): wait for the API server to
                    // finish removing it.
                }
                Some(_) => {}
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(RunnerError::RunnerStopError {
                    error: format!(
                        "the pipeline pod '{}' did not terminate within 120 seconds of scaling \
                         the StatefulSet to zero",
                        pod_name(self.pipeline_id)
                    ),
                }
                .into());
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use feldera_types::config::ResourceConfig;
    use feldera_types::runtime_status::{BootstrapPolicy, RuntimeDesiredStatus};
    use serde_json::json;

    fn pipeline_config(resources: ResourceConfig, env: &[(&str, &str)]) -> PipelineConfig {
        let mut config = PipelineConfig {
            global: feldera_types::config::RuntimeConfig::default(),
            multihost: None,
            name: Some("test".to_string()),
            given_name: None,
            storage_config: None,
            secrets_dir: None,
            inputs: Default::default(),
            outputs: Default::default(),
            program_ir: None,
        };
        config.global.resources = resources;
        config.global.env = env
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect();
        config
    }

    fn logs_sender() -> LogsSender {
        // The receiving half is dropped: these tests never send a log line.
        let (sender, _receiver) = tokio::sync::mpsc::channel(1);
        LogsSender::new(sender)
    }

    fn render_input(config: &PipelineConfig) -> RenderInput {
        let pipeline_id = PipelineId(Uuid::nil());
        let deployment_id = Uuid::max();
        let yaml = serde_yaml::to_string(&config).unwrap();
        RenderInput {
            pipeline_id,
            deployment_id,
            namespace: "feldera".to_string(),
            image: "example/pipeline:1".to_string(),
            config_yaml: yaml,
            args: program_args(deployment_id, RuntimeDesiredStatus::Paused, None),
            env: platform_env(config),
            resources: pod_resources(config, ResourceLimits::default()),
            storage: config
                .storage_config
                .as_ref()
                .map(|storage| StorageRequest {
                    mount_path: storage.path.clone(),
                    size_mb: ResourceLimits::default().storage_for(config),
                    storage_class: config.global.resources.storage_class.clone(),
                }),
            service_account: config.global.resources.service_account_name.clone(),
            manager_namespace: "feldera".to_string(),
            metrics_namespace: None,
            secrets: Vec::new(),
        }
    }

    /// Same as [`render_input`], with pipeline metrics exposed to `namespace`.
    fn render_input_with_metrics(config: &PipelineConfig, namespace: &str) -> RenderInput {
        RenderInput {
            metrics_namespace: Some(namespace.to_string()),
            ..render_input(config)
        }
    }

    #[test]
    fn network_policy_admits_only_the_manager_namespace() {
        let config = pipeline_config(ResourceConfig::default(), &[]);
        let policy = render_input(&config).render_network_policy();
        let spec = policy.spec.expect("the policy has a spec");

        assert_eq!(
            spec.pod_selector.and_then(|selector| selector.match_labels),
            Some(selector_labels(PipelineId(Uuid::nil())))
        );
        // Ingress only: source and sink traffic leaves the pod freely.
        assert_eq!(spec.policy_types, Some(vec!["Ingress".to_string()]));

        let rules = spec.ingress.expect("one ingress rule");
        assert_eq!(rules.len(), 1);
        let peers = rules[0].from.clone().expect("one peer");
        assert_eq!(peers.len(), 1);
        assert_eq!(
            peers[0]
                .namespace_selector
                .as_ref()
                .and_then(|selector| selector.match_labels.clone()),
            Some(BTreeMap::from([(
                NAMESPACE_NAME_LABEL.to_string(),
                "feldera".to_string()
            )]))
        );
        // Any pod of the manager namespace may call the pipeline port; the
        // port is the only thing exposed.
        assert!(peers[0].pod_selector.is_none());
        let ports = rules[0].ports.clone().expect("one port");
        assert_eq!(ports.len(), 1);
        assert_eq!(ports[0].port, Some(IntOrString::Int(8080)));
        assert_eq!(ports[0].protocol.as_deref(), Some("TCP"));
    }

    /// The Kubernetes runner's state lives on a volume, so it names a file
    /// backend for it.
    ///
    /// The controller reads the mount path and the backend as one pair. Naming
    /// only the path leaves `PipelineConfig::storage()` at `None`, and a
    /// fault-tolerant deployment then fails with `FtRequiresStorage` on a
    /// volume it provisioned and mounted itself.
    #[test]
    fn the_runner_names_a_file_backend_for_its_volume() {
        // The backend decision reads no cluster state, so this builds the
        // runner without a fake API server: `fake_runner` would start a kube
        // client that needs a Tokio reactor and an API server it never uses.
        let runner = KubernetesRunner {
            pipeline_id: PipelineId(Uuid::nil()),
            common_config: common_config(),
            config: runner_config(),
            client: reqwest::Client::new(),
            logs_sender: logs_sender(),
            logs_task: None,
            limits: ResourceLimits::default(),
            storage_class: None,
            tenant_namespace: None,
            kubernetes: None,
        };

        let options = runner
            .generate_storage_options()
            .expect("a Kubernetes pipeline keeps its state on a volume");
        assert!(
            matches!(options.backend, StorageBackendConfig::File(_)),
            "the volume is a mounted file system, not object storage: {:?}",
            options.backend
        );
    }

    /// The two halves of the storage configuration describe the same volume.
    ///
    /// `generate_storage_config` names the directory inside the pod and
    /// `generate_storage_options` names the backend that reads it; a
    /// deployment where they disagree would checkpoint into one place and
    /// resume from another.
    #[tokio::test]
    async fn the_storage_path_lives_under_the_mount_point() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let runner = fake_runner(&cluster);

        let config = runner.generate_storage_config().await;
        assert!(
            config.path.starts_with(STORAGE_MOUNT_BASE),
            "the state directory '{}' must be inside the mounted volume '{}'",
            config.path,
            STORAGE_MOUNT_BASE
        );
        assert!(runner.generate_storage_options().is_some());
    }

    /// The default deployment creates no scrape target.
    ///
    /// Exposing pipeline metrics widens the NetworkPolicy, so it has to be an
    /// explicit choice and not something the chart does on install.
    #[test]
    fn no_metrics_service_by_default() {
        let config = pipeline_config(ResourceConfig::default(), &[]);
        let input = render_input(&config);
        assert!(input.render_metrics_service().is_none());
        let objects = input.render();
        assert!(objects.metrics_service.is_none());
    }

    /// The metrics Service is a ClusterIP, labelled for a scrape job, and
    /// selects the same pods as the headless Service.
    #[test]
    fn metrics_service_is_scrapable() {
        let config = pipeline_config(ResourceConfig::default(), &[]);
        let input = render_input_with_metrics(&config, "monitoring");
        let service = input.render_metrics_service().expect("metrics are exposed");

        assert_eq!(
            service.metadata.name.as_deref(),
            Some(metrics_service_name(PipelineId(Uuid::nil())).as_str())
        );
        let labels = service.metadata.labels.clone().expect("labels");
        assert_eq!(
            labels.get(LABEL_METRICS_SCRAPE).map(String::as_str),
            Some("true")
        );
        // The pipeline identity survives on the Service, so a scrape job can
        // still tell instances apart.
        assert_eq!(
            labels.get(LABEL_PIPELINE_ID).map(String::as_str),
            Some(Uuid::nil().to_string().as_str())
        );

        let spec = service.spec.expect("the service has a spec");
        // Not headless: a scraper needs an address to send requests to.
        assert_eq!(spec.cluster_ip, None);
        let ports = spec.ports.expect("one port");
        assert_eq!(ports.len(), 1);
        // The port name is what the endpoint carries, and therefore what the
        // scrape job matches on (`prometheus-k8s.yml` selects `http`).
        assert_eq!(ports[0].name.as_deref(), Some("http"));
        assert_eq!(ports[0].port, 8080);
        assert_eq!(ports[0].target_port, Some(IntOrString::Int(8080)));
        assert_eq!(
            spec.selector,
            Some(selector_labels(PipelineId(Uuid::nil())))
        );
    }

    /// The metrics Service must not reuse the headless Service's name: a
    /// StatefulSet names exactly one governing Service, and a second Service
    /// with the same name cannot exist.
    #[test]
    fn metrics_service_has_its_own_name() {
        let pipeline_id = PipelineId(Uuid::nil());
        assert_ne!(
            metrics_service_name(pipeline_id),
            resource_base(pipeline_id),
            "the metrics Service would collide with the headless Service"
        );
        assert_eq!(
            metrics_service_name(pipeline_id),
            format!("{}-metrics", resource_base(pipeline_id))
        );
    }

    /// Exposing metrics admits the scrape namespace in the NetworkPolicy.
    #[test]
    fn network_policy_admits_the_metrics_namespace() {
        let config = pipeline_config(ResourceConfig::default(), &[]);
        let policy = render_input_with_metrics(&config, "monitoring").render_network_policy();
        let rules = policy
            .spec
            .expect("the policy has a spec")
            .ingress
            .expect("one ingress rule");
        let peers = rules[0].from.clone().expect("two peers");
        assert_eq!(
            peers.len(),
            2,
            "the manager namespace and the scrape namespace are separate peers, \
             because a namespace selector matches one name"
        );
        let names: Vec<String> = peers
            .iter()
            .filter_map(|peer| {
                peer.namespace_selector
                    .as_ref()
                    .and_then(|selector| selector.match_labels.as_ref())
                    .and_then(|labels| labels.get(NAMESPACE_NAME_LABEL))
                    .cloned()
            })
            .collect();
        assert_eq!(names, vec!["feldera".to_string(), "monitoring".to_string()]);
    }

    /// A scrape namespace equal to the manager namespace adds no peer.
    ///
    /// It would be the same selector twice, which Kubernetes accepts but which
    /// makes the rendered object misleading.
    #[test]
    fn metrics_namespace_that_is_the_manager_namespace_adds_no_peer() {
        let config = pipeline_config(ResourceConfig::default(), &[]);
        let policy = render_input_with_metrics(&config, "feldera").render_network_policy();
        let rules = policy
            .spec
            .expect("the policy has a spec")
            .ingress
            .expect("one ingress rule");
        assert_eq!(rules[0].from.clone().expect("one peer").len(), 1);
    }

    #[test]
    fn placeholders_are_replaced_and_unknown_braces_are_left_alone() {
        let values = TemplateValues {
            id: "pipeline-abc",
            namespace: "feldera",
            image: "example/pipeline:1",
            binary_ref: "http://compiler/binary/abc",
            program_info_ref: "http://compiler/program_info/abc",
            pipeline_storage_path: "/var/feldera/storage",
            storage_class_name: "standard",
            deployment_id: "0190f4d0-0000-7000-8000-000000000000",
            deployment_initial: "running",
            bootstrap_policy: "await_approval",
        };
        let template = concat!(
            "id: {id}\n",
            "namespace: {namespace}\n",
            "image: {pipeline_executor_image}\n",
            "binary: {binary_ref}\n",
            "program_info: {program_info_ref}\n",
            "storage: {pipeline_storage_path}\n",
            "class: {storage_class_name}\n",
            "deployment: {deployment_id}\n",
            "initial: {deployment_initial}\n",
            "bootstrap: {bootstrap_policy}\n",
            "unknown: {not_a_placeholder}\n",
        );
        let rendered = substitute_placeholders(template, &values);
        for (placeholder, value) in values.pairs() {
            assert!(
                !rendered.contains(placeholder),
                "the rendered template still contains {placeholder}"
            );
            assert!(
                rendered.contains(value),
                "the rendered template lost the value {value}"
            );
        }
        assert!(rendered.contains("{not_a_placeholder}"));
    }

    #[tokio::test]
    async fn a_template_configmap_provides_the_statefulset() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let template = concat!(
            "apiVersion: apps/v1\n",
            "kind: StatefulSet\n",
            "metadata:\n",
            "  name: from-the-template\n",
            "spec:\n",
            "  serviceName: {id}\n",
            "  replicas: 1\n",
            "  selector:\n",
            "    matchLabels:\n",
            "      app: {id}\n",
            "  template:\n",
            "    metadata:\n",
            "      labels:\n",
            "        app: {id}\n",
            "    spec:\n",
            "      containers:\n",
            "        - name: pipeline\n",
            "          image: {pipeline_executor_image}\n",
            "          args: [\"{deployment_initial}\"]\n",
        );
        *cluster.configmap.lock().unwrap() = Some(serde_json::json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "pipelines", "namespace": "feldera"},
            "data": {"pipelineTemplate": template},
        }));
        let mut runner = fake_runner(&cluster);
        runner.config.kubernetes_runner_template_configmap = Some("pipelines".to_string());

        let values = TemplateValues {
            id: &resource_base(runner.pipeline_id),
            namespace: "feldera",
            image: "example/pipeline:1",
            binary_ref: "http://compiler/binary/abc",
            program_info_ref: "http://compiler/program_info/abc",
            pipeline_storage_path: "",
            storage_class_name: "",
            deployment_id: "0190f4d0-0000-7000-8000-000000000000",
            deployment_initial: "running",
            bootstrap_policy: "",
        };
        let statefulset = runner
            .render_from_template(
                &fake_api::client(cluster.clone()),
                "pipelines",
                "feldera",
                &values,
            )
            .await
            .expect("the template renders");

        // The runner keeps its own name, because it looks the object up by it.
        assert_eq!(
            statefulset.metadata.name,
            Some(resource_base(runner.pipeline_id))
        );
        assert_eq!(statefulset.metadata.namespace.as_deref(), Some("feldera"));
        let spec = statefulset.spec.expect("a spec");
        assert_eq!(
            spec.service_name,
            Some(resource_base(runner.pipeline_id)),
            "the {{id}} placeholder must be substituted"
        );
        // The identity the runner relies on is the manager's, not the
        // template's: the Service selects the pod by these labels, so a template
        // that spelled its own would leave the pipeline unreachable.
        assert_eq!(
            spec.selector.match_labels,
            Some(selector_labels(runner.pipeline_id))
        );
        let pod_labels = spec
            .template
            .metadata
            .expect("pod metadata")
            .labels
            .expect("pod labels");
        for (label, value) in selector_labels(runner.pipeline_id) {
            assert_eq!(pod_labels.get(&label), Some(&value), "label {label}");
        }
        let container = &spec.template.spec.expect("a pod spec").containers[0];
        assert_eq!(container.image.as_deref(), Some("example/pipeline:1"));
        assert_eq!(
            container.args,
            Some(vec!["running".to_string()]),
            "the {{deployment_initial}} placeholder must be substituted"
        );
    }

    #[tokio::test]
    async fn a_missing_template_configmap_fails_provisioning() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        runner.config.kubernetes_runner_template_configmap = Some("pipelines".to_string());
        let values = TemplateValues {
            id: "pipeline-abc",
            namespace: "feldera",
            image: "example/pipeline:1",
            binary_ref: "",
            program_info_ref: "",
            pipeline_storage_path: "",
            storage_class_name: "",
            deployment_id: "0190f4d0-0000-7000-8000-000000000000",
            deployment_initial: "running",
            bootstrap_policy: "",
        };
        let error = runner
            .render_from_template(
                &fake_api::client(cluster.clone()),
                "pipelines",
                "feldera",
                &values,
            )
            .await
            .expect_err("a missing ConfigMap is a provisioning error");
        assert!(
            error.to_string().contains("pipelines"),
            "unexpected: {error}"
        );
    }

    #[test]
    fn only_a_status_report_or_a_temporary_unavailability_is_healthy() {
        assert!(status_is_healthy(200));
        assert!(status_is_healthy(503));
        assert!(!status_is_healthy(500));
        assert!(!status_is_healthy(404));
        assert!(!status_is_healthy(401));
    }

    #[tokio::test]
    async fn fetch_status_parses_a_json_response() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 1024];
            let _ = socket.read(&mut request).await;
            let body = r#"{"state":"Running","num_workers":1}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                body.len(),
                body
            );
            socket.write_all(response.as_bytes()).await.unwrap();
        });

        let probe =
            fetch_status(&reqwest::Client::new(), &format!("http://{address}/status")).await;
        assert_eq!(probe.http_status, Some(200));
        assert!(probe.error.is_none(), "unexpected error: {probe:?}");
        assert_eq!(
            probe.body.expect("a JSON body")["state"],
            serde_json::json!("Running")
        );
    }

    #[tokio::test]
    async fn fetch_status_reports_an_unreachable_endpoint() {
        // Binding and immediately dropping the listener yields a port nothing
        // listens on, which is what a pipeline that has not bound yet looks
        // like from the manager.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);

        let probe =
            fetch_status(&reqwest::Client::new(), &format!("http://{address}/status")).await;
        assert!(probe.http_status.is_none());
        assert!(probe.body.is_none());
        assert!(probe.error.is_some());
    }

    #[test]
    fn selector_is_stable_across_deployments() {
        let one = object_labels(PipelineId(Uuid::nil()), Uuid::max());
        let two = object_labels(PipelineId(Uuid::nil()), Uuid::nil());
        let selector = selector_labels(PipelineId(Uuid::nil()));

        // The deployment label differs between deployments...
        assert_ne!(one.get(LABEL_DEPLOYMENT_ID), two.get(LABEL_DEPLOYMENT_ID));
        // ...and the selector must not depend on it.
        assert!(!selector.contains_key(LABEL_DEPLOYMENT_ID));
        for (key, value) in &selector {
            assert_eq!(one.get(key), Some(value));
            assert_eq!(two.get(key), Some(value));
        }
    }

    #[test]
    fn statefulset_names_and_ports_are_stable() {
        let config = pipeline_config(ResourceConfig::default(), &[]);
        let input = render_input(&config);
        let objects = input.render();
        let statefulset = objects.statefulset;
        let spec = statefulset.spec.expect("statefulset spec");

        assert_eq!(
            statefulset.metadata.name.as_deref(),
            Some("pipeline-00000000-0000-0000-0000-000000000000")
        );
        assert_eq!(spec.replicas, Some(1));
        assert_eq!(
            spec.service_name.as_deref(),
            Some("pipeline-00000000-0000-0000-0000-000000000000")
        );
        let pod_spec = spec.template.spec.expect("pod spec");
        let container = &pod_spec.containers[0];
        assert_eq!(
            container.command,
            Some(vec![PIPELINE_ENTRYPOINT.to_string()])
        );
        assert_eq!(
            container
                .ports
                .as_ref()
                .map(|ports| ports[0].container_port),
            Some(i32::from(PIPELINE_PORT))
        );
        assert!(
            container
                .args
                .as_ref()
                .unwrap()
                .contains(&"--default-port".to_string())
        );

        let service = objects.service;
        let service_spec = service.spec.expect("service spec");
        assert_eq!(service_spec.cluster_ip.as_deref(), Some("None"));
        assert_eq!(
            service_spec.ports.unwrap()[0].port,
            i32::from(PIPELINE_PORT)
        );
    }

    #[test]
    fn storage_claim_is_only_rendered_when_storage_is_enabled() {
        let config = pipeline_config(ResourceConfig::default(), &[]);
        assert!(render_input(&config).render().storage_claim.is_none());

        let mut config = config;
        config.storage_config = Some(StorageConfig {
            path: "/var/feldera/storage/x".to_string(),
            cache: StorageCacheConfig::default(),
        });
        let input = render_input(&config);
        let claim = input.render().storage_claim.expect("storage claim");
        assert_eq!(
            claim.metadata.name.as_deref(),
            Some("pipeline-00000000-0000-0000-0000-000000000000-storage")
        );
        let claim_spec = claim.spec.expect("claim spec");
        let requests = claim_spec.resources.unwrap().requests.unwrap();
        assert_eq!(
            requests.get("storage").map(|quantity| quantity.0.clone()),
            Some(format!(
                "{}Mi",
                ResourceLimits::default().storage_mb_default
            ))
        );
        // The pod mounts the claim at the path the storage config points at.
        let pod_spec = input
            .render()
            .statefulset
            .spec
            .unwrap()
            .template
            .spec
            .unwrap();
        let mounts = pod_spec.containers[0].volume_mounts.clone().unwrap();
        assert!(
            mounts
                .iter()
                .any(|mount| mount.mount_path == "/var/feldera/storage/x")
        );
    }

    #[test]
    fn the_memory_limit_leaves_headroom_above_the_pipeline_budget() {
        // Below 1 GiB the fixed headroom dominates; above it, a quarter.
        assert_eq!(memory_limit_mb(256), 512);
        assert_eq!(memory_limit_mb(1024), 1280);
        assert_eq!(memory_limit_mb(4096), 5120);
        // A pipeline configured with no memory budget gets no limit at all.
        let resources = ResourceConfig {
            memory_mb_max: None,
            ..ResourceConfig::default()
        };
        let requirements =
            pod_resources(&pipeline_config(resources, &[]), ResourceLimits::default());
        assert!(requirements.limits.is_none());
    }

    #[test]
    fn zero_quantities_are_dropped_instead_of_becoming_zero_requests() {
        let resources = ResourceConfig {
            cpu_cores_min: Some(0.0),
            memory_mb_min: Some(0),
            cpu_cores_max: Some(1.0),
            memory_mb_max: Some(1024),
            ..ResourceConfig::default()
        };
        let requirements =
            pod_resources(&pipeline_config(resources, &[]), ResourceLimits::default());
        let requests = requirements.requests.unwrap_or_default();
        assert!(!requests.contains_key("cpu"), "a zero CPU request is noise");
        assert!(!requests.contains_key("memory"));
        assert_eq!(requirements.limits.unwrap()["memory"].0, "1280Mi");
    }

    #[test]
    fn resources_are_mapped_from_the_runtime_configuration() {
        let resources = ResourceConfig {
            cpu_cores_min: Some(0.5),
            cpu_cores_max: Some(2.0),
            memory_mb_min: Some(512),
            memory_mb_max: Some(2048),
            storage_mb_max: Some(4096),
            storage_class: Some("fast".to_string()),
            ..ResourceConfig::default()
        };
        let mut config = pipeline_config(resources, &[]);
        config.storage_config = Some(StorageConfig {
            path: "/var/feldera/storage/x".to_string(),
            cache: StorageCacheConfig::default(),
        });
        let input = render_input(&config);
        let requirements = input.resources.clone();
        assert_eq!(requirements.requests.as_ref().unwrap()["cpu"].0, "500m");
        assert_eq!(requirements.limits.as_ref().unwrap()["cpu"].0, "2");
        assert_eq!(requirements.requests.as_ref().unwrap()["memory"].0, "512Mi");
        assert_eq!(requirements.limits.as_ref().unwrap()["memory"].0, "2560Mi");

        let claim = input.render().storage_claim.unwrap();
        let claim_spec = claim.spec.unwrap();
        assert_eq!(
            claim_spec
                .resources
                .unwrap()
                .requests
                .unwrap()
                .get("storage")
                .map(|quantity| quantity.0.clone()),
            Some("4096Mi".to_string())
        );
        assert_eq!(claim_spec.storage_class_name.as_deref(), Some("fast"));
    }

    #[test]
    fn cpu_quantities_use_whole_cores_or_millicores() {
        assert_eq!(cpu_quantity(2.0).0, "2");
        assert_eq!(cpu_quantity(0.5).0, "500m");
        assert_eq!(cpu_quantity(0.333).0, "333m");
        assert_eq!(cpu_quantity(1.5).0, "1500m");
    }

    #[test]
    fn program_args_mirror_the_local_runner() {
        let args = program_args(
            Uuid::max(),
            RuntimeDesiredStatus::Running,
            Some(BootstrapConfig {
                bootstrap_policy: Some(BootstrapPolicy::Allow),
                ..Default::default()
            }),
        );
        assert!(args.windows(2).any(|pair| pair == ["--initial", "running"]));
        assert!(
            args.windows(2)
                .any(|pair| pair == ["--default-port", "8080"])
        );
        assert!(
            args.windows(2)
                .any(|pair| pair == ["--bootstrap-policy", "allow"])
        );
        assert!(args.windows(2).any(|pair| pair[0] == "--deployment-id"));
    }

    #[test]
    fn service_account_and_env_are_forwarded() {
        let resources = ResourceConfig {
            service_account_name: Some("pipeline-sa".to_string()),
            ..ResourceConfig::default()
        };
        let config = pipeline_config(resources, &[("FOO", "bar")]);
        let input = render_input(&config);
        let objects = input.render();
        let pod_spec = objects.statefulset.spec.unwrap().template.spec.unwrap();
        assert_eq!(
            pod_spec.service_account_name.as_deref(),
            Some("pipeline-sa")
        );
        let env = pod_spec.containers[0].env.clone().unwrap();
        assert!(
            env.iter()
                .any(|var| var.name == "FOO" && var.value.as_deref() == Some("bar"))
        );
        assert!(env.iter().any(|var| var.name == "POD_NAME"));
    }

    /// The allowlist rejects a class the platform does not provision on, and
    /// says which classes it does, so the message can be acted on.
    #[test]
    fn a_storage_class_outside_the_allowlist_is_rejected() {
        let policy = StorageClassPolicy {
            allowed: vec!["fast".to_string(), "standard".to_string()],
            enabled: true,
            default: None,
        };
        assert_eq!(
            policy.resolve(Some("fast")).unwrap(),
            Some("fast".to_string())
        );
        let error = policy
            .resolve(Some("local-path"))
            .expect_err("an unlisted class must be rejected");
        let message = error.to_string();
        assert!(
            message.contains("local-path") && message.contains("fast"),
            "the error must name the rejected class and the allowed ones: {message}"
        );
    }

    /// A pipeline that names no class gets the configured default, and the
    /// default itself is subject to the allowlist: a default the allowlist
    /// rejects would otherwise provision every pipeline onto a class the
    /// platform does not offer.
    #[test]
    fn the_default_storage_class_goes_through_the_allowlist() {
        let policy = StorageClassPolicy {
            allowed: vec!["fast".to_string()],
            enabled: true,
            default: Some("fast".to_string()),
        };
        assert_eq!(policy.resolve(None).unwrap(), Some("fast".to_string()));

        let rejecting = StorageClassPolicy {
            allowed: vec!["fast".to_string()],
            enabled: true,
            default: Some("local-path".to_string()),
        };
        assert!(
            rejecting.resolve(None).is_err(),
            "a default that is not allowed must fail rather than provision"
        );
    }

    /// With the allowlist off, whatever the pipeline asked for is used, so an
    /// existing deployment keeps its classes when the policy is not enabled.
    #[test]
    fn a_disabled_allowlist_passes_the_requested_class_through() {
        let policy = StorageClassPolicy {
            allowed: vec!["fast".to_string()],
            enabled: false,
            default: Some("standard".to_string()),
        };
        assert_eq!(
            policy.resolve(Some("local-path")).unwrap(),
            Some("local-path".to_string())
        );
        assert_eq!(
            policy.resolve(None).unwrap(),
            Some("standard".to_string())
        );
    }

    /// An enabled allowlist with no entries refuses every named class: an
    /// empty list is a configuration mistake, and the safe reading of "these
    /// classes are allowed" with nothing listed is "none".
    #[test]
    fn an_enabled_empty_allowlist_refuses_every_class() {
        let policy = StorageClassPolicy {
            allowed: Vec::new(),
            enabled: true,
            default: None,
        };
        assert_eq!(policy.resolve(None).unwrap(), None);
        assert!(policy.resolve(Some("fast")).is_err());
    }

    /// Provisioning a pipeline whose class the allowlist rejects fails before
    /// any object is created, so a rejected class leaves no claim behind.
    #[tokio::test]
    async fn provision_rejects_a_disallowed_storage_class_before_creating_anything() {
        let cluster = fake_api::FakeCluster::default();
        let mut runner = fake_runner(&cluster);
        runner.config.kubernetes_runner_enable_storage_classes = true;
        runner.config.kubernetes_runner_storage_classes = vec!["fast".to_string()];
        let config = pipeline_config(
            ResourceConfig {
                storage_class: Some("local-path".to_string()),
                ..ResourceConfig::default()
            },
            &[],
        );

        let error = runner
            .provision(
                RuntimeDesiredStatus::Paused,
                None,
                &Uuid::max(),
                &config,
                &program_info(),
                "http://api-server:8085/binary/00000000-0000-0000-0000-000000000000/1/checksum/integrity",
                "http://api-server:8085/program_info/00000000-0000-0000-0000-000000000000/1/checksum",
                Version(1),
                &json!({}),
                false,
            )
            .await
            .expect_err("a class outside the allowlist must fail provisioning");
        assert!(
            error.to_string().contains("local-path"),
            "the error must name the class the pipeline asked for: {error}"
        );
        assert_eq!(
            cluster.count("POST", ""),
            0,
            "nothing may be created when the storage class is rejected"
        );
    }

    /// The class the policy resolves is the one the claim and the template
    /// placeholder both carry, so one deployment never mixes two classes.
    #[tokio::test]
    async fn the_resolved_storage_class_reaches_the_claim() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        runner.config.kubernetes_runner_enable_storage_classes = true;
        runner.config.kubernetes_runner_storage_classes = vec!["fast".to_string()];
        let mut config = pipeline_config(
            ResourceConfig {
                storage_class: Some("fast".to_string()),
                ..ResourceConfig::default()
            },
            &[],
        );
        // A claim is only rendered for a pipeline that keeps state on a volume.
        config.storage_config = Some(StorageConfig {
            path: "/storage".to_string(),
            cache: Default::default(),
        });
        runner
            .provision(
                RuntimeDesiredStatus::Paused,
                None,
                &Uuid::max(),
                &config,
                &program_info(),
                "http://api-server:8085/binary/00000000-0000-0000-0000-000000000000/1/checksum/integrity",
                "http://api-server:8085/program_info/00000000-0000-0000-0000-000000000000/1/checksum",
                Version(1),
                &json!({}),
                false,
            )
            .await
            .expect("the allowed class must provision");

        assert_eq!(runner.storage_class.as_deref(), Some("fast"));
        let input = runner.render(
            Uuid::max(),
            "feldera",
            "example/pipeline:1".to_string(),
            &config,
            String::new(),
            Vec::new(),
            Vec::new(),
            None,
        )
        .expect("rendering a configuration without secret references succeeds");
        assert_eq!(
            input
                .render()
                .storage_claim
                .and_then(|claim| claim.spec)
                .and_then(|spec| spec.storage_class_name),
            Some("fast".to_string())
        );
    }

    /// A tenant with an entry gets a namespace of its own.
    #[test]
    fn a_tenant_namespace_is_looked_up_by_tenant_id() {
        let tenant = TenantId(Uuid::nil());
        let config = KubernetesRunnerConfig {
            kubernetes_runner_tenant_namespaces: vec![
                format!("tenant={}:tenant-a", Uuid::max()),
                format!("tenant={}:tenant-b", tenant.0),
            ],
            ..runner_config()
        };
        let mapping = TenantNamespace::from_config(&config, &tenant)
            .expect("the tenant has an entry of its own");
        assert_eq!(mapping.namespace, "tenant-b");
    }

    /// A tenant in both maps is placed by the one that also bounds it: a quota
    /// that counts a namespace the tenant's pipelines are not in would read as
    /// enforced while bounding nothing.
    #[test]
    fn a_quota_entry_takes_precedence_over_a_plain_namespace() {
        let tenant = TenantId(Uuid::nil());
        let config = KubernetesRunnerConfig {
            kubernetes_runner_tenant_namespaces: vec![format!("tenant={}:unbounded", tenant.0)],
            kubernetes_runner_tenant_quotas: vec![format!(
                "tenant={}:bounded:requests.cpu=2",
                tenant.0
            )],
            ..runner_config()
        };
        let mapping = TenantNamespace::from_config(&config, &tenant)
            .expect("the tenant has an entry of its own");
        assert_eq!(mapping.namespace, "bounded");
    }

    /// A quota entry alone is enough to place a tenant.
    #[test]
    fn a_quota_entry_alone_places_a_tenant() {
        let tenant = TenantId(Uuid::nil());
        let config = KubernetesRunnerConfig {
            kubernetes_runner_tenant_quotas: vec![format!(
                "tenant={}:bounded:requests.cpu=2",
                tenant.0
            )],
            ..runner_config()
        };
        assert_eq!(
            TenantNamespace::from_config(&config, &tenant).map(|mapping| mapping.namespace),
            Some("bounded".to_string())
        );
        assert!(
            TenantNamespace::from_config(&config, &TenantId(Uuid::max())).is_none(),
            "a tenant the map does not name keeps the shared namespace"
        );
    }

    /// A tenant with no entry has no mapping, and its pipelines stay in the
    /// shared namespace.
    #[test]
    fn a_tenant_without_a_namespace_has_no_mapping() {
        let config = KubernetesRunnerConfig {
            kubernetes_runner_tenant_namespaces: vec![format!(
                "tenant={}:tenant-a",
                Uuid::max()
            )],
            ..runner_config()
        };
        assert!(TenantNamespace::from_config(&config, &TenantId(Uuid::nil())).is_none());
    }

    /// A malformed entry is skipped instead of failing every tenant's
    /// provisioning, and the entries after it are still read.
    #[test]
    fn a_malformed_tenant_namespace_entry_is_skipped() {
        let tenant = TenantId(Uuid::nil());
        let config = KubernetesRunnerConfig {
            kubernetes_runner_tenant_namespaces: vec![
                "not-a-mapping".to_string(),
                "no-prefix:tenant-x".to_string(),
                format!("tenant=not-a-uuid:tenant-y"),
                format!("tenant={}:", tenant.0),
                format!("tenant={}:tenant-z", tenant.0),
            ],
            ..runner_config()
        };
        let mapping = TenantNamespace::from_config(&config, &tenant)
            .expect("the one well-formed entry must still be found");
        assert_eq!(mapping.namespace, "tenant-z");
    }

    /// A per-pipeline namespace still wins over the tenant mapping, because
    /// that is how a pipeline is placed somewhere else on purpose.
    #[test]
    fn namespace_from_runtime_config_wins() {
        let runner = KubernetesRunner {
            pipeline_id: PipelineId(Uuid::nil()),
            common_config: CommonConfig::test_config(),
            config: KubernetesRunnerConfig {
                kubernetes_runner_kubeconfig: None,
                kubernetes_runner_namespace: "feldera".to_string(),
                kubernetes_runner_pipeline_executor_image: None,
                kubernetes_runner_per_pipeline_namespace: false,
                kubernetes_runner_manager_namespace: None,
                kubernetes_runner_allow_kubernetes_env_prefix: false,
                kubernetes_runner_template_configmap: None,
                kubernetes_runner_template_key: "pipelineTemplate".to_string(),
                kubernetes_runner_template_namespace: None,
                kubernetes_runner_lower_memory_mb: 100,
                kubernetes_runner_upper_memory_mb: 32_000,
                kubernetes_runner_default_storage_mb: 30_000,
                kubernetes_runner_upper_storage_mb: 128_000,
                kubernetes_runner_metrics_service: false,
                kubernetes_runner_metrics_namespace: None,
                kubernetes_runner_reap_orphans: false,
                kubernetes_runner_retain_storage_claims: false,
                kubernetes_runner_enable_storage_classes: false,
                kubernetes_runner_storage_classes: Vec::new(),
                ..runner_config()
            },
            client: reqwest::Client::new(),
            logs_sender: logs_sender(),
            logs_task: None,
            limits: ResourceLimits::default(),
            storage_class: None,
            tenant_namespace: None,
            kubernetes: None,
        };
        assert_eq!(runner.namespace(&json!({})), "feldera");
        assert_eq!(
            runner.namespace(&json!({"resources": {"namespace": "tenant-a"}})),
            "tenant-a"
        );
        assert_eq!(
            runner.location("tenant-a"),
            "pipeline-00000000-0000-0000-0000-000000000000.tenant-a.svc.cluster.local:8080"
        );
    }

    /// The tenant's namespace applies when the pipeline names none, and an
    /// explicit per-pipeline namespace still overrides it.
    #[test]
    fn the_tenant_namespace_applies_when_the_pipeline_names_none() {
        let runner = KubernetesRunner {
            tenant_namespace: Some(TenantNamespace {
                tenant_id: TenantId(Uuid::nil()),
                namespace: "tenant-b".to_string(),
            }),
            ..KubernetesRunner {
                pipeline_id: PipelineId(Uuid::nil()),
                common_config: CommonConfig::test_config(),
                config: runner_config(),
                client: reqwest::Client::new(),
                logs_sender: logs_sender(),
                logs_task: None,
                limits: ResourceLimits::default(),
                storage_class: None,
                tenant_namespace: None,
                kubernetes: None,
            }
        };
        assert_eq!(runner.namespace(&json!({})), "tenant-b");
        assert_eq!(
            runner.namespace(&json!({"resources": {"namespace": "elsewhere"}})),
            "elsewhere"
        );
    }

    /// Property tests: the DoD of P1-011 asks for them, because the interesting
    /// inputs are the arbitrary numbers a user can put in a resource request.
    mod properties {
        use super::*;
        use proptest::prelude::*;

        proptest! {
            #[test]
            fn a_memory_request_is_clamped_into_the_platform_range(mb in 0u64..200_000) {
                let limits = ResourceLimits::default();
                let clamped = limits.clamp_memory(mb);
                prop_assert!(clamped >= limits.memory_mb_min);
                prop_assert!(clamped <= limits.memory_mb_max);
                // Clamping is idempotent: the platform never re-clamps a value
                // it produced.
                prop_assert_eq!(limits.clamp_memory(clamped), clamped);
            }

            #[test]
            fn the_container_limit_never_falls_below_the_budget(mb in 1u64..200_000) {
                let limits = ResourceLimits::default();
                let budget = limits.clamp_memory(mb);
                let limit = memory_limit_mb(budget).min(limits.memory_mb_max);
                // A limit below the budget is an OOM kill waiting for the
                // pipeline to reach its own ceiling.
                prop_assert!(limit >= budget);
            }

            #[test]
            fn a_storage_request_never_exceeds_the_platform_ceiling(mb in 0u64..1_000_000) {
                let limits = ResourceLimits::default();
                let clamped = limits.clamp_storage(mb);
                prop_assert!(clamped <= limits.storage_mb_max);
                prop_assert_eq!(limits.clamp_storage(clamped), clamped);
            }

            #[test]
            fn placeholder_substitution_consumes_every_known_placeholder(
                id in "[a-z0-9-]{1,40}",
                namespace in "[a-z0-9-]{1,20}",
            ) {
                let template = "{id}|{namespace}|{pipeline_executor_image}|{binary_ref}|{program_info_ref}|{pipeline_storage_path}|{storage_class_name}|{deployment_id}|{deployment_initial}|{bootstrap_policy}|{storage_class}";
                let values = TemplateValues {
                    id: &id,
                    namespace: &namespace,
                    image: "example/pipeline:1",
                    binary_ref: "http://compiler/binary",
                    program_info_ref: "http://compiler/program_info",
                    pipeline_storage_path: "/var/feldera/storage",
                    storage_class_name: "standard",
                    deployment_id: "00000000-0000-0000-0000-000000000001",
                    deployment_initial: "paused",
                    bootstrap_policy: "await_approval",
                };
                let rendered = substitute_placeholders(template, &values);
                for (placeholder, _) in values.pairs() {
                    prop_assert!(
                        !rendered.contains(placeholder),
                        "the substitution left {placeholder} in {rendered}"
                    );
                }
                prop_assert!(rendered.starts_with(id.as_str()));
            }
        }
    }

    #[test]
    fn fatal_waiting_reasons_fail_fast() {
        assert!(fatal_waiting_reason("CrashLoopBackOff"));
        assert!(fatal_waiting_reason("ImagePullBackOff"));
        assert!(!fatal_waiting_reason("ContainerCreating"));
    }

    /// A fake Kubernetes API server.
    ///
    /// `kube::Client::new` accepts any `tower` service, so the runner's API calls
    /// can be driven without a cluster: the service answers the handful of
    /// routes the runner uses and records every request, which lets the tests
    /// assert the order of operations (storage before pod) and the error paths
    /// (missing pod, conflicting object) that a real cluster makes hard to
    /// reproduce deterministically.
    mod fake_api {
        use super::*;
        use bytes::Bytes;
        use http::{Method, Request, Response, StatusCode};
        use http_body_util::{BodyExt, Full};
        use kube::client::Body as KubeBody;
        use std::sync::{Arc, Mutex};
        use tower::service_fn;

        #[derive(Clone, Default)]
        pub struct FakeCluster {
            pub requests: Arc<Mutex<Vec<(String, String)>>>,
            /// Return 409 for this resource kind, as an already existing object would.
            pub conflict_on: Arc<Mutex<Option<String>>>,
            /// The pod's JSON, or `None` when it does not exist.
            pub pod: Arc<Mutex<Option<serde_json::Value>>>,
            /// The events in the namespace, as the API server lists them.
            pub events: Arc<Mutex<Vec<serde_json::Value>>>,
            /// Answer 403 for the event list, as a manager role without
            /// `events.read` would.
            pub events_forbidden: Arc<Mutex<bool>>,
            pub namespace_exists: Arc<Mutex<bool>>,
            /// The template ConfigMap's JSON, or `None` when it does not exist.
            pub configmap: Arc<Mutex<Option<serde_json::Value>>>,
            /// The bodies of the requests, in order.
            pub bodies: Arc<Mutex<Vec<String>>>,
        }

        impl FakeCluster {
            pub fn with_namespace() -> Self {
                let cluster = Self::default();
                *cluster.namespace_exists.lock().unwrap() = true;
                cluster
            }

            pub fn requests(&self) -> Vec<(String, String)> {
                self.requests.lock().unwrap().clone()
            }

            /// Number of requests of a method whose path ends with `suffix`.
            pub fn count(&self, method: &str, suffix: &str) -> usize {
                self.requests()
                    .into_iter()
                    .filter(|(m, path)| m == method && path.ends_with(suffix))
                    .count()
            }

            /// The body of the first request of `method`, if any.
            pub fn body_of(&self, method: &str) -> Option<String> {
                self.bodies
                    .lock()
                    .unwrap()
                    .iter()
                    .find(|body| body.starts_with(method))
                    .map(|body| body[method.len()..].to_string())
            }
        }

        pub fn client(cluster: FakeCluster) -> Client {
            let service = service_fn(move |request: Request<KubeBody>| {
                let cluster = cluster.clone();
                async move {
                    let method = request.method().clone();
                    let path = request.uri().path().to_string();
                    cluster
                        .requests
                        .lock()
                        .unwrap()
                        .push((method.to_string(), path.clone()));
                    // Only a patch has a body worth asserting on, and reading
                    // it is the only way to see what the manager asked the API
                    // server to record.
                    if method == Method::PATCH {
                        let request = request;
                        let bytes = request.into_body().collect().await.map(|body| {
                            body.to_bytes()
                        });
                        if let Ok(bytes) = bytes {
                            cluster.bodies.lock().unwrap().push(format!(
                                "{method}{}",
                                String::from_utf8_lossy(&bytes)
                            ));
                        }
                    }
                    Ok::<_, std::convert::Infallible>(respond(&cluster, &method, &path))
                }
            });
            Client::new(service, "feldera")
        }

        fn json(value: serde_json::Value) -> Response<Full<Bytes>> {
            Response::builder()
                .status(StatusCode::OK)
                .header("content-type", "application/json")
                .body(Full::new(Bytes::from(value.to_string())))
                .unwrap()
        }

        fn status(code: StatusCode, kind: &str, name: &str) -> Response<Full<Bytes>> {
            Response::builder()
                .status(code)
                .header("content-type", "application/json")
                .body(Full::new(Bytes::from(
                    serde_json::json!({
                        "apiVersion": "v1",
                        "kind": "Status",
                        "status": "Failure",
                        "reason": if code == StatusCode::NOT_FOUND { "NotFound" } else { "Conflict" },
                        "message": format!("{kind} '{name}'"),
                        "code": code.as_u16(),
                    })
                    .to_string(),
                )))
                .unwrap()
        }

        fn forbidden(kind: &str) -> Response<Full<Bytes>> {
            Response::builder()
                .status(StatusCode::FORBIDDEN)
                .header("content-type", "application/json")
                .body(Full::new(Bytes::from(
                    serde_json::json!({
                        "apiVersion": "v1",
                        "kind": "Status",
                        "status": "Failure",
                        "reason": "Forbidden",
                        "message": format!("{kind} is forbidden: User \"system:serviceaccount:feldera:feldera\" cannot list resource \"{kind}\" in API group \"\" in the namespace \"feldera\""),
                        "code": 403,
                    })
                    .to_string(),
                )))
                .unwrap()
        }

        /// Maps a resource path segment to the `apiVersion`/`kind` pair the
        /// Kubernetes API returns for it, which the typed `kube` clients check.
        fn api_type(kind: &str) -> (&'static str, &'static str) {
            match kind {
                "pods" => ("v1", "Pod"),
                "secrets" => ("v1", "Secret"),
                "services" => ("v1", "Service"),
                "persistentvolumeclaims" => ("v1", "PersistentVolumeClaim"),
                "namespaces" => ("v1", "Namespace"),
                "configmaps" => ("v1", "ConfigMap"),
                "statefulsets" => ("apps/v1", "StatefulSet"),
                "networkpolicies" => ("networking.k8s.io/v1", "NetworkPolicy"),
                _ => ("v1", "Unknown"),
            }
        }

        fn object(kind: &str, name: &str) -> serde_json::Value {
            let (api_version, api_kind) = api_type(kind);
            serde_json::json!({
                "apiVersion": api_version,
                "kind": api_kind,
                "metadata": {"name": name, "namespace": "feldera"},
            })
        }

        fn respond(cluster: &FakeCluster, method: &Method, path: &str) -> Response<Full<Bytes>> {
            let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
            if !*cluster.namespace_exists.lock().unwrap()
                && parts.starts_with(&["api", "v1", "namespaces", "feldera"])
            {
                return status(StatusCode::NOT_FOUND, "namespaces", "feldera");
            }
            if parts == ["api", "v1", "namespaces", "feldera"] {
                return if *cluster.namespace_exists.lock().unwrap() {
                    json(object("namespaces", "feldera"))
                } else {
                    status(StatusCode::NOT_FOUND, "namespaces", "feldera")
                };
            }
            let (kind, name) = match parts.as_slice() {
                ["api", "v1", "namespaces", _ns, kind] => (*kind, None),
                ["api", "v1", "namespaces", _ns, kind, name] => (*kind, Some(*name)),
                ["apis", _group, _version, "namespaces", _ns, kind] => (*kind, None),
                ["apis", _group, _version, "namespaces", _ns, kind, name] => (*kind, Some(*name)),
                _ => return status(StatusCode::NOT_FOUND, "route", path),
            };
            if kind == "configmaps" && method == Method::GET {
                return match cluster.configmap.lock().unwrap().clone() {
                    Some(configmap) => json(configmap),
                    None => status(StatusCode::NOT_FOUND, kind, name.unwrap_or("")),
                };
            }
            if kind == "pods" && method == Method::GET {
                return match cluster.pod.lock().unwrap().clone() {
                    Some(pod) => json(pod),
                    None => status(StatusCode::NOT_FOUND, kind, name.unwrap_or("")),
                };
            }
            if kind == "events" && method == Method::GET && name.is_none() {
                if *cluster.events_forbidden.lock().unwrap() {
                    return forbidden(kind);
                }
                let items = cluster.events.lock().unwrap().clone();
                return json(serde_json::json!({
                    "apiVersion": "v1",
                    "kind": "EventList",
                    "metadata": {},
                    "items": items,
                }));
            }
            if method == Method::POST {
                let conflict = cluster.conflict_on.lock().unwrap().clone();
                if conflict.as_deref() == Some(kind) {
                    return status(StatusCode::CONFLICT, kind, name.unwrap_or(""));
                }
                return json(object(kind, name.unwrap_or("created")));
            }
            json(object(kind, name.unwrap_or("")))
        }
    }

    /// A `Warning`/`FailedCreate` event such as the StatefulSet controller
    /// emits when the API server refuses the pod.
    fn failed_create_event(statefulset: &str, message: &str) -> serde_json::Value {
        serde_json::json!({
            "apiVersion": "v1",
            "kind": "Event",
            "metadata": {"name": format!("{statefulset}.18e2e353f7540972"), "namespace": "feldera"},
            "involvedObject": {
                "apiVersion": "apps/v1",
                "kind": "StatefulSet",
                "name": statefulset,
                "namespace": "feldera",
            },
            "reason": "FailedCreate",
            "type": "Warning",
            "message": message,
            "count": 14,
        })
    }

    fn ready_pod() -> serde_json::Value {
        serde_json::json!({
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"name": "pipeline-00000000-0000-0000-0000-000000000000-0", "namespace": "feldera"},
            "status": {
                "phase": "Running",
                "conditions": [{"type": "Ready", "status": "True"}],
                "containerStatuses": [{"name": "pipeline", "ready": true, "restartCount": 0,
                                       "image": "example/pipeline:1", "imageID": "", "state": {"running": {}}}],
            },
        })
    }

    fn crashing_pod() -> serde_json::Value {
        serde_json::json!({
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"name": "pipeline-00000000-0000-0000-0000-000000000000-0", "namespace": "feldera"},
            "status": {
                "phase": "Running",
                "conditions": [{"type": "Ready", "status": "False"}],
                "containerStatuses": [{"name": "pipeline", "ready": false, "restartCount": 3,
                                       "image": "example/pipeline:1", "imageID": "",
                                       "state": {"waiting": {"reason": "CrashLoopBackOff", "message": "back-off"}}}],
            },
        })
    }

    fn runner_config() -> KubernetesRunnerConfig {
        KubernetesRunnerConfig {
            kubernetes_runner_kubeconfig: None,
            kubernetes_runner_namespace: "feldera".to_string(),
            kubernetes_runner_pipeline_executor_image: Some("example/pipeline:1".to_string()),
            kubernetes_runner_per_pipeline_namespace: false,
            kubernetes_runner_manager_namespace: None,
            kubernetes_runner_allow_kubernetes_env_prefix: false,
            kubernetes_runner_template_configmap: None,
            kubernetes_runner_template_key: "pipelineTemplate".to_string(),
            kubernetes_runner_template_namespace: None,
            kubernetes_runner_lower_memory_mb: 100,
            kubernetes_runner_upper_memory_mb: 32_000,
            kubernetes_runner_default_storage_mb: 30_000,
            kubernetes_runner_upper_storage_mb: 128_000,
            kubernetes_runner_metrics_service: false,
            kubernetes_runner_metrics_namespace: None,
            kubernetes_runner_reap_orphans: false,
            kubernetes_runner_retain_storage_claims: false,
            kubernetes_runner_enable_storage_classes: false,
            kubernetes_runner_storage_classes: Vec::new(),
            kubernetes_runner_storage_class: None,
            kubernetes_runner_tenant_namespaces: Vec::new(),
            kubernetes_runner_tenant_quotas: Vec::new(),
            kubernetes_runner_tenant_namespace_automation: false,
            kubernetes_runner_manager_service_account: None,
            kubernetes_runner_tenant_cluster_role: None,
            kubernetes_runner_connector_kubernetes_secrets_allowlist: Vec::new(),
        }
    }

    fn common_config() -> CommonConfig {
        let mut config = CommonConfig::test_config();
        // A pod cannot reach the manager's loopback, so a real deployment points
        // the compiler host at the in-cluster service name.
        config.compiler_host = "api-server.feldera.svc.cluster.local".to_string();
        config
    }

    fn fake_runner(cluster: &fake_api::FakeCluster) -> KubernetesRunner {
        KubernetesRunner {
            pipeline_id: PipelineId(Uuid::nil()),
            common_config: common_config(),
            config: runner_config(),
            client: reqwest::Client::new(),
            logs_sender: logs_sender(),
            logs_task: None,
            limits: ResourceLimits::default(),
            storage_class: None,
            tenant_namespace: None,
            kubernetes: Some(fake_api::client(cluster.clone())),
        }
    }

    fn program_info() -> serde_json::Value {
        serde_json::json!({
            "schema": {},
            "input_connectors": {},
            "output_connectors": {}
        })
    }

    async fn provision(runner: &mut KubernetesRunner) -> Result<(), ManagerError> {
        runner
            .provision(
                RuntimeDesiredStatus::Paused,
                None,
                &Uuid::max(),
                &pipeline_config(ResourceConfig::default(), &[]),
                &program_info(),
                "http://api-server:8085/binary/00000000-0000-0000-0000-000000000000/1/checksum/integrity",
                "http://api-server:8085/program_info/00000000-0000-0000-0000-000000000000/1/checksum",
                Version(1),
                &json!({}),
                false,
            )
            .await
    }

    #[tokio::test]
    async fn provision_creates_the_deployment_resources() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);

        provision(&mut runner).await.expect("provisioning succeeds");

        let requests = cluster.requests();
        let posted: Vec<&str> = requests
            .iter()
            .filter(|(method, _)| method == "POST")
            .map(|(_, path)| path.as_str())
            .collect();
        assert_eq!(
            posted,
            vec![
                "/api/v1/namespaces/feldera/secrets",
                "/api/v1/namespaces/feldera/services",
                // The policy is in place before the pod exists.
                "/apis/networking.k8s.io/v1/namespaces/feldera/networkpolicies",
                "/apis/apps/v1/namespaces/feldera/statefulsets",
            ]
        );
        // No storage configured means no claim is created.
        assert_eq!(cluster.count("POST", "/persistentvolumeclaims"), 0);
    }

    #[tokio::test]
    async fn provision_creates_the_storage_claim_first() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        let mut config = pipeline_config(ResourceConfig::default(), &[]);
        config.storage_config = Some(StorageConfig {
            path: "/var/feldera/storage/x".to_string(),
            cache: StorageCacheConfig::default(),
        });

        runner
            .provision(
                RuntimeDesiredStatus::Paused,
                None,
                &Uuid::max(),
                &config,
                &program_info(),
                "http://api-server:8085/binary/x",
                "http://api-server:8085/program_info/x",
                Version(1),
                &json!({}),
                false,
            )
            .await
            .expect("provisioning succeeds");

        let posted: Vec<String> = cluster
            .requests()
            .into_iter()
            .filter(|(method, _)| method == "POST")
            .map(|(_, path)| path)
            .collect();
        assert_eq!(
            posted[0],
            "/api/v1/namespaces/feldera/persistentvolumeclaims"
        );
        assert_eq!(posted.len(), 5);
    }

    #[tokio::test]
    async fn provision_patches_objects_that_already_exist() {
        let cluster = fake_api::FakeCluster::with_namespace();
        *cluster.conflict_on.lock().unwrap() = Some("statefulsets".to_string());
        let mut runner = fake_runner(&cluster);

        provision(&mut runner).await.expect("provisioning succeeds");

        assert_eq!(
            cluster.count(
                "PATCH",
                "/statefulsets/pipeline-00000000-0000-0000-0000-000000000000"
            ),
            1
        );
    }

    #[tokio::test]
    async fn provision_rejects_a_loopback_compiler_host() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        runner.common_config = CommonConfig::test_config(); // compiler_host = 127.0.0.1

        let error = provision(&mut runner)
            .await
            .expect_err("loopback must be rejected");
        assert!(
            error.to_string().contains("loopback"),
            "unexpected error: {error}"
        );
        // Rejected before any object is created.
        assert!(cluster.requests().is_empty());
    }

    #[tokio::test]
    async fn provision_rejects_a_missing_executor_image() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        runner.config.kubernetes_runner_pipeline_executor_image = None;

        let error = provision(&mut runner)
            .await
            .expect_err("the image is required");
        assert!(
            error
                .to_string()
                .contains("kubernetes-runner-pipeline-executor-image"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn is_provisioned_waits_for_a_ready_pod() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);

        // No pod yet: the deployment is still ongoing.
        assert!(matches!(
            runner.is_provisioned(&json!({})).await.unwrap(),
            ProvisionStatus::Ongoing { .. }
        ));

        *cluster.pod.lock().unwrap() = Some(ready_pod());
        match runner.is_provisioned(&json!({})).await.unwrap() {
            ProvisionStatus::Provisioned { location, details } => {
                assert_eq!(
                    location,
                    "pipeline-00000000-0000-0000-0000-000000000000.feldera.svc.cluster.local:8080"
                );
                assert_eq!(details["ready"], serde_json::json!(true));
            }
            ProvisionStatus::Ongoing { .. } => {
                panic!("a ready pod must be reported as provisioned")
            }
        }
    }

    #[tokio::test]
    async fn is_provisioned_fails_fast_on_a_crash_loop() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        *cluster.pod.lock().unwrap() = Some(crashing_pod());

        match runner.is_provisioned(&json!({})).await {
            Err(error) => assert!(
                error.to_string().contains("CrashLoopBackOff"),
                "unexpected error: {error}"
            ),
            Ok(_) => panic!("a crash loop must fail provisioning"),
        }
    }

    /// A full tenant quota is reported at once, from the event the
    /// StatefulSet controller emits, not after the provisioning timeout.
    #[tokio::test]
    async fn is_provisioned_fails_fast_when_the_tenant_quota_refused_the_pod() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        // The pod was never created, so `pod` stays `None`; the rejection is
        // the StatefulSet's FailedCreate event.
        cluster.events.lock().unwrap().push(failed_create_event(
            "pipeline-00000000-0000-0000-0000-000000000000",
            "pods \"pipeline-00000000-0000-0000-0000-000000000000-0\" is forbidden: \
             exceeded quota: tenant-acme, requested: requests.cpu=4, \
             used: requests.cpu=16, limited: requests.cpu=16",
        ));

        let error = runner
            .is_provisioned(&json!({}))
            .await
            .expect_err("a full quota must fail provisioning");
        let message = error.to_string();
        assert!(
            message.contains("no room for this pipeline"),
            "unexpected error: {message}"
        );
        // The operator needs the quota's own numbers, not just a verdict.
        assert!(
            message.contains("requested: requests.cpu=4"),
            "the quota message must survive: {message}"
        );
        assert!(
            message.contains("raise the tenant's quota"),
            "the error must say what to do: {message}"
        );
    }

    /// A quota with a `requests.cpu` cap and a pod that does not declare one
    /// is a different API server message — "failed quota: ... must specify" —
    /// and it means the same thing to the operator: this namespace has no room.
    ///
    /// The chart's LimitRange normally fills the request in, so this shape
    /// appears when an operator maps a tenant to a namespace they created
    /// without one; it must not be reported as a generic StatefulSet failure.
    #[tokio::test]
    async fn a_quota_that_needs_a_request_the_pod_omits_is_also_a_quota_refusal() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        cluster.events.lock().unwrap().push(failed_create_event(
            "pipeline-00000000-0000-0000-0000-000000000000",
            "pods \"pipeline-0\" is forbidden: failed quota: tenant-acme: must specify \
             requests.cpu for: pipeline",
        ));

        let error = runner
            .is_provisioned(&json!({}))
            .await
            .expect_err("a failed quota must fail provisioning");
        let message = error.to_string();
        assert!(
            message.contains("no room for this pipeline"),
            "unexpected error: {message}"
        );
        assert!(
            message.contains("raise the tenant's quota"),
            "the error must still say what to do: {message}"
        );
    }

    /// A FailedCreate that is not about a quota still fails provisioning, but
    /// without the quota advice.
    #[tokio::test]
    async fn is_provisioned_reports_a_statefulset_failure_that_is_not_a_quota() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        cluster.events.lock().unwrap().push(failed_create_event(
            "pipeline-00000000-0000-0000-0000-000000000000",
            "create Pod pipeline-0 in StatefulSet pipeline failed error: the node has insufficient cpu",
        ));

        let error = runner
            .is_provisioned(&json!({}))
            .await
            .expect_err("a failed create must fail provisioning");
        let message = error.to_string();
        assert!(
            message.contains("insufficient cpu"),
            "unexpected error: {message}"
        );
        assert!(
            !message.contains("raise the tenant's quota"),
            "a non-quota failure must not mention quotas: {message}"
        );
    }

    /// An event about some other pipeline does not fail this one: namespaces
    /// are shared until a tenant gets its own, so every pipeline's events are
    /// in the same list.
    #[tokio::test]
    async fn an_event_about_another_pipeline_does_not_fail_provisioning() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        cluster.events.lock().unwrap().push(failed_create_event(
            "pipeline-11111111-1111-1111-1111-111111111111",
            "pods is forbidden: exceeded quota: other-tenant",
        ));

        assert!(matches!(
            runner.is_provisioned(&json!({})).await.unwrap(),
            ProvisionStatus::Ongoing { .. }
        ));
    }

    /// A Warning that is not a FailedCreate does not fail provisioning: a
    /// pipeline that is merely restarting emits its own warnings.
    #[tokio::test]
    async fn a_warning_that_is_not_a_failed_create_does_not_fail_provisioning() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        let mut event = failed_create_event(
            "pipeline-00000000-0000-0000-0000-000000000000",
            "something else went wrong",
        );
        event["reason"] = json!("FailedScheduling");
        cluster.events.lock().unwrap().push(event);

        assert!(matches!(
            runner.is_provisioned(&json!({})).await.unwrap(),
            ProvisionStatus::Ongoing { .. }
        ));
    }

    /// Being unable to read events is not a provisioning failure: it leaves the
    /// deployment reporting progress, as it did before the check existed.
    #[tokio::test]
    async fn an_unreadable_event_list_does_not_fail_provisioning() {
        let cluster = fake_api::FakeCluster::with_namespace();
        *cluster.events_forbidden.lock().unwrap() = true;
        let mut runner = fake_runner(&cluster);

        assert!(matches!(
            runner.is_provisioned(&json!({})).await.unwrap(),
            ProvisionStatus::Ongoing { .. }
        ));
    }

    #[tokio::test]
    async fn check_reports_a_missing_pod() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);

        let error = runner
            .check(&json!({}))
            .await
            .expect_err("a missing pod is unhealthy");
        assert!(
            error.to_string().contains("does not exist"),
            "unexpected error: {error}"
        );

        *cluster.pod.lock().unwrap() = Some(ready_pod());
        let details = runner
            .check(&json!({}))
            .await
            .expect("a ready pod is healthy");
        assert_eq!(details["pod"]["restarts"], serde_json::json!(0));
        // The probe runs against the Service DNS name, which does not resolve
        // in a unit test: it reports the failure instead of panicking.
        assert!(details["status_error"].is_string());
        assert_eq!(details["http_status"], serde_json::Value::Null);
    }

    /// A runner that has not built its client yet is the state of every
    /// automaton that a promoted instance spawns: the previous leader held the
    /// client, and the pipelines it was running are still up.
    ///
    /// Reporting their pods as missing would transition each one to stopping,
    /// so an unbuildable client has to surface as the configuration error it
    /// is. In a unit test there is no kubeconfig and no cluster, which is
    /// exactly what a misconfigured deployment looks like.
    #[tokio::test]
    async fn check_without_a_client_reports_the_configuration_error() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        runner.kubernetes = None;

        let error = runner
            .check(&json!({}))
            .await
            .expect_err("a client that cannot be built is an error");
        let message = error.to_string();
        assert!(
            !message.contains("does not exist"),
            "an unbuildable client must not be reported as a missing pod: {message}"
        );
        assert!(
            message.contains("kubernetes") || message.contains("Kubernetes"),
            "the error should name the Kubernetes configuration: {message}"
        );
    }

    /// The same state reached through `is_provisioned`, which is the other
    /// reader that decides a pipeline's fate from the pod's existence.
    #[tokio::test]
    async fn is_provisioned_without_a_client_reports_the_configuration_error() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        runner.kubernetes = None;

        let error = match runner.is_provisioned(&json!({})).await {
            Ok(status) => panic!("a client that cannot be built is an error, got {status:?}"),
            Err(error) => error,
        };
        assert!(
            !error.to_string().contains("does not exist"),
            "an unbuildable client must not be reported as a missing pod: {error}"
        );
    }

    #[tokio::test]
    async fn clear_deletes_every_resource_of_the_pipeline() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);

        runner.clear(&json!({})).await.expect("clearing succeeds");

        assert_eq!(
            cluster.count(
                "DELETE",
                "/statefulsets/pipeline-00000000-0000-0000-0000-000000000000"
            ),
            1
        );
        assert_eq!(
            cluster.count(
                "DELETE",
                "/services/pipeline-00000000-0000-0000-0000-000000000000"
            ),
            1
        );
        assert_eq!(
            cluster.count(
                "DELETE",
                "/services/pipeline-00000000-0000-0000-0000-000000000000-metrics"
            ),
            1,
            "a deployment that exposed metrics must not leave its Service behind"
        );
        assert_eq!(
            cluster.count(
                "DELETE",
                "/secrets/pipeline-00000000-0000-0000-0000-000000000000-config"
            ),
            1
        );
        assert_eq!(
            cluster.count(
                "DELETE",
                "/persistentvolumeclaims/pipeline-00000000-0000-0000-0000-000000000000-storage"
            ),
            1
        );
    }

    /// Retaining the claim keeps a deletion from destroying the pipeline's
    /// state, and says so on the claim the deletion leaves behind.
    #[tokio::test]
    async fn clear_retains_the_storage_claim_when_configured() {
        let cluster = fake_api::FakeCluster::with_namespace();
        let mut runner = fake_runner(&cluster);
        runner.config.kubernetes_runner_retain_storage_claims = true;

        runner.clear(&json!({})).await.expect("clearing succeeds");

        assert_eq!(
            cluster.count(
                "DELETE",
                "/persistentvolumeclaims/pipeline-00000000-0000-0000-0000-000000000000-storage"
            ),
            0,
            "a retained claim must survive the deletion that keeps it"
        );
        // Everything else still goes, or the retention becomes a leak.
        for path in [
            "/statefulsets/pipeline-00000000-0000-0000-0000-000000000000",
            "/services/pipeline-00000000-0000-0000-0000-000000000000",
            "/secrets/pipeline-00000000-0000-0000-0000-000000000000-config",
        ] {
            assert_eq!(cluster.count("DELETE", path), 1, "{path} was not deleted");
        }
        assert_eq!(
            cluster.count(
                "PATCH",
                "/persistentvolumeclaims/pipeline-00000000-0000-0000-0000-000000000000-storage"
            ),
            1,
            "a kept claim must be annotated, or nobody can tell why it is there"
        );
        let patch = cluster.body_of("PATCH").expect("the retention patch");
        assert!(
            patch.contains(RETENTION_KEPT_ON_DELETE),
            "the patch does not record the reason: {patch}"
        );
        assert!(
            patch.contains(&Uuid::nil().to_string()),
            "the patch does not record which pipeline the claim belonged to: {patch}"
        );
    }

    /// A marked claim carries the annotation the reaper reads, and the unmarked
    /// one does not: the two deletions differ only in this flag.
    #[test]
    fn the_retention_annotation_is_the_one_the_reaper_reads() {
        assert_eq!(RETENTION_ANNOTATION, "feldera.com/storage-retention");
        assert_eq!(RETAINED_PIPELINE_ANNOTATION, "feldera.com/retained-pipeline-id");
    }

    #[tokio::test]
    async fn can_provision_reports_a_missing_namespace() {
        let cluster = fake_api::FakeCluster::default(); // namespace_exists = false
        let runner = fake_runner(&cluster);

        let error = runner
            .can_provision(&pipeline_config(ResourceConfig::default(), &[]), &json!({}))
            .await
            .expect_err("a missing namespace is a configuration error");
        assert!(
            error.to_string().contains("does not exist"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn stop_scales_the_statefulset_to_zero_and_waits() {
        let cluster = fake_api::FakeCluster::with_namespace();
        // A pod that reports a deletion timestamp keeps the loop waiting, so the
        // test removes it after the first poll by starting without one.
        *cluster.pod.lock().unwrap() = None;
        let mut runner = fake_runner(&cluster);

        runner.stop(&json!({})).await.expect("stopping succeeds");

        assert_eq!(
            cluster.count(
                "PATCH",
                "/statefulsets/pipeline-00000000-0000-0000-0000-000000000000"
            ),
            1
        );
        assert_eq!(
            cluster.count(
                "GET",
                "/pods/pipeline-00000000-0000-0000-0000-000000000000-0"
            ),
            1
        );
    }

    /// A pipeline configuration whose only connector is a Kafka input carrying
    /// `options` verbatim, which is where a secret reference in a transport
    /// configuration lives.
    fn pipeline_config_with_kafka_options(kafka_options: &[(&str, &str)]) -> PipelineConfig {
        use feldera_types::config::{ConnectorConfig, InputEndpointConfig};
        use feldera_types::transport::kafka::KafkaInputConfig;
        let mut config = pipeline_config(ResourceConfig::default(), &[]);
        config.inputs.insert(
            std::borrow::Cow::Borrowed("orders"),
            InputEndpointConfig {
                stream: std::borrow::Cow::Borrowed("orders"),
                connector_config: ConnectorConfig::new(
                    feldera_types::config::TransportConfig::KafkaInput(KafkaInputConfig::default(
                        kafka_options
                            .iter()
                            .map(|(key, value)| (key.to_string(), value.to_string()))
                            .collect(),
                        "orders",
                    )),
                    None,
                ),
            },
        );
        config
    }

    #[test]
    fn a_listed_secret_becomes_a_volume_mounted_where_the_resolver_looks() {
        let config = pipeline_config_with_kafka_options(&[
            ("sasl.username", "${secret:kubernetes:kafka-creds/username}"),
            ("sasl.password", "${secret:kubernetes:kafka-creds/password}"),
        ]);

        let secrets = connector_secrets(&config, &["kafka-creds".to_string()]).unwrap();

        // One volume per Secret, not per key, and only the keys the
        // configuration uses are projected.
        assert_eq!(secrets.len(), 1);
        assert_eq!(secrets[0].name, "kafka-creds");
        assert_eq!(secrets[0].keys, vec!["password", "username"]);

        let input = RenderInput {
            secrets: secrets.clone(),
            ..render_input(&config)
        };
        let statefulset = input.render_statefulset();
        let pod = statefulset.spec.unwrap().template.spec.unwrap();

        let volume = pod
            .volumes
            .as_ref()
            .unwrap()
            .iter()
            .find(|volume| volume.name == format!("secret-{}", secrets[0].mount_name()))
            .expect("the referenced Secret has a volume");
        let source = volume.secret.as_ref().unwrap();
        assert_eq!(source.secret_name.as_deref(), Some("kafka-creds"));
        assert_eq!(
            source
                .items
                .as_ref()
                .unwrap()
                .iter()
                .map(|item| (item.key.as_str(), item.path.as_str()))
                .collect::<Vec<_>>(),
            vec![("password", "password"), ("username", "username")]
        );

        // The mount path is the layout `secret_resolver` reads:
        // `<secrets dir>/kubernetes/<name>/<key>`.
        let mount = pod.containers[0]
            .volume_mounts
            .as_ref()
            .unwrap()
            .iter()
            .find(|mount| mount.name == format!("secret-{}", secrets[0].mount_name()))
            .expect("the volume is mounted");
        assert_eq!(mount.mount_path, "/etc/feldera-secrets/kubernetes/kafka-creds");
        assert_eq!(mount.read_only, Some(true));
    }

    #[test]
    fn an_unlisted_secret_is_refused_before_anything_is_created() {
        let config = pipeline_config_with_kafka_options(&[(
            "sasl.password",
            "${secret:kubernetes:kafka-creds/password}",
        )]);

        // Empty allowlist: no configuration may name a Secret at all.
        let error = connector_secrets(&config, &[]).expect_err("an empty allowlist refuses");
        assert!(
            error
                .to_string()
                .contains("not on the allowlist: no Secret is allowed"),
            "unexpected error: {error}"
        );

        // A different Secret does not authorise this one.
        let error = connector_secrets(&config, &["other-creds".to_string()])
            .expect_err("a different Secret does not authorise this one");
        assert!(
            error.to_string().contains("not on the allowlist: other-creds"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn a_secret_reference_in_the_output_configuration_is_checked_too() {
        use feldera_types::config::{ConnectorConfig, OutputEndpointConfig};
        use feldera_types::config::TransportConfig;
        let mut config = pipeline_config(ResourceConfig::default(), &[]);
        config.outputs.insert(
            std::borrow::Cow::Borrowed("sink"),
            OutputEndpointConfig {
                stream: std::borrow::Cow::Borrowed("sink"),
                connector_config: ConnectorConfig::new(
                    feldera_types::config::TransportConfig::HttpOutput(
                        feldera_types::transport::http::HttpOutputConfig::default(),
                    ),
                    None,
                ),
            },
        );
        // An output without references passes with an empty list; the point of
        // this test is that outputs are inspected at all, so plant the
        // reference in a place the input scan would never look.
        assert!(connector_secrets(&config, &[]).unwrap().is_empty());

        // `KafkaOutputConfig` needs a topic and broker; build it through JSON so
        // the test states the reference, not the struct shape.
        let json = serde_json::json!({
            "sink": {
                "stream": "sink",
                "transport": {
                    "name": "kafka_output",
                    "config": {
                        "topic": "sink",
                        "bootstrap.servers": "localhost:9092",
                        "sasl.password": "${secret:kubernetes:kafka-creds/password}"
                    }
                },
                "format": null
            }
        });
        let outputs: BTreeMap<
            std::borrow::Cow<'static, str>,
            feldera_types::config::OutputEndpointConfig,
        > = serde_json::from_value(json).expect("the test configuration parses");
        let mut config = config;
        config.outputs = outputs;
        let error = connector_secrets(&config, &[]).expect_err("an output reference is checked");
        assert!(
            error.to_string().contains("no Secret is allowed"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn an_environment_reference_is_left_alone() {
        let config = pipeline_config_with_kafka_options(&[
            ("sasl.username", "${env:KAFKA_USERNAME}"),
            ("sasl.password", "${env:KAFKA_PASSWORD}"),
        ]);

        let secrets = connector_secrets(&config, &[]).expect("env references need no allowlist");
        assert!(secrets.is_empty());
    }

    /// Two Secret names that sanitize to the same prefix must not share a
    /// volume, or one would shadow the other's files.
    #[test]
    fn long_secret_names_do_not_collide_as_volume_names() {
        let first = RenderedSecret {
            name: format!("{}-a", "x".repeat(60)),
            keys: vec!["k".to_string()],
        };
        let second = RenderedSecret {
            name: format!("{}-b", "x".repeat(60)),
            keys: vec!["k".to_string()],
        };
        assert_ne!(first.mount_name(), second.mount_name());
        assert!(first.mount_name().len() <= 63);
        assert!(second.mount_name().len() <= 63);
    }
}
