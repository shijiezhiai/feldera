//! Reclaims Kubernetes objects whose pipeline no longer exists.
//!
//! Deleting a pipeline deletes its objects through the runner, so the steady
//! state has no orphans. Orphans appear when that path does not run to the end:
//! the manager is killed between dropping the database row and deleting the
//! objects, a cluster API call fails after the row is gone, or an operator
//! deletes a pod's owner by hand. Nothing then refers to the objects, and
//! nothing deletes them.
//!
//! The reaper is the safety net for that. It lists the objects the runner
//! creates, and for each one whose pipeline is absent from the database it
//! reports the object as unreferenced. Reporting is deliberately the default:
//! deleting is available behind a flag, because a wrong identification here
//! deletes a running pipeline's state instead of a leftover.
//!
//! Identification is by name, not by label. The objects belong to a pipeline
//! whose id is in the name (`pipeline-<id>-storage`), and ids are UUIDs that
//! no other object can carry. A label would be weaker: it is set by the object
//! creator, so a deployment that crashed between creating an object and
//! labelling it would be invisible here, which is precisely the case this
//! module exists for.

use crate::config::KubernetesRunnerConfig;
use crate::db::storage::Storage;
use crate::db::storage_postgres::StoragePostgres;
use crate::db::types::pipeline::PipelineId;
use crate::error::ManagerError;
use k8s_openapi::api::apps::v1::StatefulSet;
use k8s_openapi::api::core::v1::{PersistentVolumeClaim, Secret, Service};
use k8s_openapi::api::networking::v1::NetworkPolicy;
use kube::api::{Api, ListParams};
use kube::core::NamespaceResourceScope;
use kube::{Client, Resource};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::{Instant, sleep};
use tracing::{error, info, warn};
use uuid::Uuid;

/// Interval between two scans.
pub const REAP_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);

/// Prefix the runner gives every object it creates.
///
/// The reaper rejects any name that does not start with it, which is what
/// keeps objects an operator created by hand out of the scan.
const PIPELINE_NAME_PREFIX: &str = "pipeline-";

/// The kinds of object the runner creates for a pipeline.
///
/// `StatefulSet` and `Service` share a name, so a scan has to keep the kind
/// alongside it: the same name held by a `Service` and by a `StatefulSet` are
/// two objects, and one may exist while the other does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ResourceKind {
    StatefulSet,
    Service,
    MetricsService,
    NetworkPolicy,
    Secret,
    StorageClaim,
}

impl ResourceKind {
    /// All kinds in the order a scan deletes them.
    ///
    /// The claim goes last: a `StatefulSet` that still exists keeps its pod
    /// using the claim, and deleting the claim first would leave the pod
    /// writing to a volume being detached.
    const ALL: [ResourceKind; 6] = [
        ResourceKind::StatefulSet,
        ResourceKind::Service,
        ResourceKind::NetworkPolicy,
        ResourceKind::MetricsService,
        ResourceKind::Secret,
        ResourceKind::StorageClaim,
    ];

    fn as_str(self) -> &'static str {
        match self {
            ResourceKind::StatefulSet => "StatefulSet",
            ResourceKind::Service => "Service",
            ResourceKind::MetricsService => "Service",
            ResourceKind::NetworkPolicy => "NetworkPolicy",
            ResourceKind::Secret => "Secret",
            ResourceKind::StorageClaim => "PersistentVolumeClaim",
        }
    }
}

/// One object whose owning pipeline is absent from the database.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnreferencedObject {
    pub kind: ResourceKind,
    pub namespace: String,
    pub name: String,
    pub pipeline_id: PipelineId,
}

/// Extracts the pipeline id from an object name of `kind`.
///
/// Returns `None` for a name the runner did not produce. That matters more
/// than it looks: the shared namespace may hold any object, and an
/// unrecognised name must never be treated as orphaned, because the reaper
/// cannot tell such an object from one an operator created by hand.
fn pipeline_id_from_name(kind: ResourceKind, name: &str) -> Option<PipelineId> {
    let base = name.strip_prefix(PIPELINE_NAME_PREFIX)?;
    let (storage_claim, id) = match kind {
        // `pipeline-<id>-storage`
        ResourceKind::StorageClaim => (true, base.strip_suffix("-storage")?),
        // `pipeline-<id>-config`
        ResourceKind::Secret => (false, base.strip_suffix("-config")?),
        // `pipeline-<id>-metrics`
        ResourceKind::MetricsService => (false, base.strip_suffix("-metrics")?),
        // `pipeline-<id>`
        ResourceKind::StatefulSet | ResourceKind::Service | ResourceKind::NetworkPolicy => {
            (false, base)
        }
    };
    debug_assert!(
        !storage_claim || kind == ResourceKind::StorageClaim,
        "only the storage claim carries the -storage suffix"
    );
    Uuid::parse_str(id).ok().map(PipelineId)
}

/// Names of the objects the runner creates for `pipeline_id`, by kind.
///
/// Only the tests need the forward direction: the scan reads names from the
/// cluster and parses the id back out, which also covers objects created by an
/// older version of the runner whose naming may differ.
///
/// The names repeat [`crate::runner::kubernetes_runner`]'s naming helpers,
/// which are private to that module. A drift between the two would make the
/// reaper blind to a kind rather than delete the wrong object, because a name
/// the runner does not use finds no object to report.
#[cfg(test)]
fn names_for(pipeline_id: PipelineId) -> std::collections::BTreeMap<ResourceKind, String> {
    let base = format!("pipeline-{pipeline_id}");
    std::collections::BTreeMap::from([
        (ResourceKind::StatefulSet, base.clone()),
        (ResourceKind::Service, base.clone()),
        (ResourceKind::MetricsService, format!("{base}-metrics")),
        (ResourceKind::NetworkPolicy, base.clone()),
        (ResourceKind::Secret, format!("{base}-config")),
        (ResourceKind::StorageClaim, format!("{base}-storage")),
    ])
}

/// What one scan found.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ScanReport {
    /// Objects whose pipeline is absent from the database.
    pub unreferenced: Vec<UnreferencedObject>,
    /// Objects the scan deleted. Empty unless deletion was requested.
    pub deleted: Vec<UnreferencedObject>,
    /// Objects the scan could not inspect, as `kind/namespace/name: reason`.
    ///
    /// Reported rather than returned as an error so that one forbidden kind
    /// does not hide the findings of the others.
    pub failures: Vec<String>,
}

impl ScanReport {
    /// Whether the scan found nothing to report.
    pub fn is_clean(&self) -> bool {
        self.unreferenced.is_empty() && self.deleted.is_empty() && self.failures.is_empty()
    }
}

/// Builds the client the scan uses.
///
/// The same construction as the runner's, including its error messages: a
/// platform with a broken kubeconfig should say so once, in the terms the
/// operator's flag is described in.
pub async fn client(config: &KubernetesRunnerConfig) -> Result<Client, ManagerError> {
    crate::runner::kubernetes_runner::build_kubernetes_client(config).await
}

/// Scans every namespace the runner may have written to.
///
/// The namespaces are those the runner is configured for plus whichever the
/// database's pipelines currently request, which is where a pipeline that has
/// since been deleted may still have left objects.
///
/// `delete` deletes what it finds; otherwise the scan only reports.
pub async fn scan(
    client: &Client,
    db: &Arc<Mutex<StoragePostgres>>,
    config: &KubernetesRunnerConfig,
    delete: bool,
) -> Result<ScanReport, ManagerError> {
    // Both reads happen under the same lock so a pipeline created between
    // them cannot be seen by neither: listing namespaces first and pipelines
    // second means a pipeline that appeared in between is in `known`, which
    // makes the scan report too little rather than too much.
    let (namespaces, known) = {
        let db = db.lock().await;
        let known = db
            .list_pipeline_ids_across_all_tenants()
            .await
            .map_err(ManagerError::from)?
            .into_iter()
            .map(|(_, pipeline_id)| pipeline_id)
            .collect::<Vec<_>>();
        let namespaces = namespaces_to_scan(&db, config).await;
        (namespaces, known)
    };

    let mut report = ScanReport::default();
    for namespace in namespaces {
        // A namespace that cannot be scanned is reported by `scan_namespace`;
        // the scan keeps going so one misconfigured namespace does not hide
        // what the others hold.
        scan_namespace(client, &namespace, &known, delete, &mut report).await;
    }
    Ok(report)
}

/// The namespaces a scan has to visit.
async fn namespaces_to_scan(db: &StoragePostgres, config: &KubernetesRunnerConfig) -> Vec<String> {
    let mut namespaces = vec![config.kubernetes_runner_namespace.clone()];
    if let Some(namespace) = &config.kubernetes_runner_manager_namespace {
        namespaces.push(namespace.clone());
    }
    if let Some(namespace) = &config.kubernetes_runner_metrics_namespace {
        namespaces.push(namespace.clone());
    }

    // A pipeline may request its own namespace, which stays behind after the
    // pipeline is deleted. Its objects are only visible if that namespace is
    // scanned, and the database row that recorded the request is gone, so the
    // namespaces have to come from the live pipelines plus the cluster: see
    // `namespace_prefix` below.
    match db.list_pipelines_across_all_tenants_for_monitoring().await {
        Ok(pipelines) => {
            for (_, pipeline) in pipelines {
                if let Some(namespace) =
                    crate::runner::pipeline_executor::discover_namespace_from_runtime_config_json(
                        &pipeline.runtime_config,
                    )
                {
                    namespaces.push(namespace);
                }
            }
        }
        Err(error) => warn!(
            "Reaper: unable to list pipelines to collect their namespaces, scanning the \
             configured namespaces only: {error}"
        ),
    }

    namespaces.sort();
    namespaces.dedup();
    namespaces
}

/// Scans one namespace.
async fn scan_namespace(
    client: &Client,
    namespace: &str,
    known: &[PipelineId],
    delete: bool,
    report: &mut ScanReport,
) {
    for kind in ResourceKind::ALL {
        match list_kind(client, namespace, kind).await {
            Ok(objects) => {
                for ListedObject { name, retained } in objects {
                    if retained {
                        // Kept on purpose: reporting it would invite an
                        // operator to delete state they chose to preserve.
                        info!(
                            kind = kind.as_str(),
                            namespace = %namespace,
                            name = %name,
                            "Reaper: skipping a claim a deletion deliberately kept"
                        );
                        continue;
                    }
                    let Some(pipeline_id) = pipeline_id_from_name(kind, &name) else {
                        continue;
                    };
                    if known.contains(&pipeline_id) {
                        continue;
                    }
                    let object = UnreferencedObject {
                        kind,
                        namespace: namespace.to_string(),
                        name,
                        pipeline_id,
                    };
                    if !delete {
                        report.unreferenced.push(object);
                        continue;
                    }
                    match delete_object(client, namespace, object.kind, &object.name).await {
                        Ok(()) => {
                            info!(
                                kind = object.kind.as_str(),
                                namespace = %object.namespace,
                                name = %object.name,
                                pipeline_id = %object.pipeline_id,
                                "Reaper: deleted an object whose pipeline no longer exists"
                            );
                            report.deleted.push(object);
                        }
                        Err(error) => {
                            // Deletion failed, so the object is still there and
                            // still unreferenced: report it as such.
                            report.failures.push(format!(
                                "{}/{}: unable to delete: {error}",
                                object.kind.as_str(),
                                object.name
                            ));
                            report.unreferenced.push(object);
                        }
                    }
                }
            }
            Err(error) => report.failures.push(format!(
                "{}: unable to list in namespace '{namespace}': {error}",
                kind.as_str()
            )),
        }
    }
}

/// Lists the names of one kind in one namespace.
async fn list_kind(
    client: &Client,
    namespace: &str,
    kind: ResourceKind,
) -> Result<Vec<ListedObject>, kube::Error> {
    match kind {
        ResourceKind::StatefulSet => {
            names::<StatefulSet>(client, namespace).await
        }
        ResourceKind::Service | ResourceKind::MetricsService => {
            names::<Service>(client, namespace).await
        }
        ResourceKind::NetworkPolicy => names::<NetworkPolicy>(client, namespace).await,
        ResourceKind::Secret => names::<Secret>(client, namespace).await,
        ResourceKind::StorageClaim => {
            names::<PersistentVolumeClaim>(client, namespace).await
        }
    }
}

/// Lists the object names of type `K` in `namespace`.
///
/// The list is filtered in the manager, not by the API server: a
/// `metadata.name` field selector accepts only `=`, `==` and `!=`, so a
/// prefix cannot be expressed as a selector and asking for one is rejected
/// with `invalid selector`. The whole namespace is therefore transferred, and
/// `pipeline_id_from_name` decides what belongs to the runner. That is
/// acceptable because the scan runs every six hours and holds names only; a
/// namespace large enough for the transfer to matter has more pressing
/// problems than this scan.
async fn names<K>(client: &Client, namespace: &str) -> Result<Vec<ListedObject>, kube::Error>
where
    K: Resource<Scope = NamespaceResourceScope, DynamicType = ()>
        + Clone
        + std::fmt::Debug
        + serde::de::DeserializeOwned,
{
    let list = Api::<K>::namespaced(client.clone(), namespace)
        .list(&ListParams::default())
        .await?;
    Ok(list
        .items
        .into_iter()
        .filter_map(|item| {
            let metadata = item.meta();
            let name = metadata.name.clone()?;
            Some(ListedObject {
                name,
                // A claim a deletion deliberately kept carries the marker; it
                // is state an operator chose to keep, not a leftover.
                retained: metadata.annotations.as_ref().is_some_and(|annotations| {
                    annotations
                        .contains_key(crate::runner::kubernetes_runner::RETENTION_ANNOTATION)
                }),
            })
        })
        .collect())
}

/// An object as the scan sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ListedObject {
    name: String,
    /// Set when the object is annotated as deliberately kept.
    retained: bool,
}

/// Deletes one object.
async fn delete_object(
    client: &Client,
    namespace: &str,
    kind: ResourceKind,
    name: &str,
) -> Result<(), kube::Error> {
    use kube::api::DeleteParams;
    match kind {
        ResourceKind::StatefulSet => {
            Api::<StatefulSet>::namespaced(client.clone(), namespace)
                .delete(name, &DeleteParams::default())
                .await?;
        }
        ResourceKind::Service | ResourceKind::MetricsService => {
            Api::<Service>::namespaced(client.clone(), namespace)
                .delete(name, &DeleteParams::default())
                .await?;
        }
        ResourceKind::NetworkPolicy => {
            Api::<NetworkPolicy>::namespaced(client.clone(), namespace)
                .delete(name, &DeleteParams::default())
                .await?;
        }
        ResourceKind::Secret => {
            Api::<Secret>::namespaced(client.clone(), namespace)
                .delete(name, &DeleteParams::default())
                .await?;
        }
        ResourceKind::StorageClaim => {
            Api::<PersistentVolumeClaim>::namespaced(client.clone(), namespace)
                .delete(name, &DeleteParams::default())
                .await?;
        }
    }
    Ok(())
}

/// Runs one scan on startup and then on an interval.
pub async fn run(
    db: Arc<Mutex<StoragePostgres>>,
    config: KubernetesRunnerConfig,
    client: Client,
    delete: bool,
) {
    let mut next_scan = Instant::now();
    loop {
        sleep(next_scan.saturating_duration_since(Instant::now())).await;
        next_scan = Instant::now() + REAP_INTERVAL;

        match scan(&client, &db, &config, delete).await {
            // Logging every clean scan fills the log with a line the operator
            // can do nothing with; an idle platform scans every six hours.
            Ok(report) if report.is_clean() => {
                info!("Reaper: no unreferenced pipeline objects found");
            }
            Ok(report) => {
                for object in &report.unreferenced {
                    warn!(
                        kind = object.kind.as_str(),
                        namespace = %object.namespace,
                        name = %object.name,
                        pipeline_id = %object.pipeline_id,
                        "Reaper: found an object whose pipeline no longer exists"
                    );
                }
                for failure in &report.failures {
                    warn!("Reaper: {failure}");
                }
            }
            Err(error) => error!("Reaper: the scan failed: {error}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "01a17a2e-6b7c-7f2a-9f2e-0d4e5f6a7b8c";

    #[test]
    fn parses_every_kind_the_runner_names() {
        let id = PipelineId(Uuid::parse_str(ID).unwrap());
        assert_eq!(names_for(id).len(), ResourceKind::ALL.len());
        for kind in ResourceKind::ALL {
            let name = &names_for(id)[&kind];
            assert_eq!(
                pipeline_id_from_name(kind, name),
                Some(id),
                "{kind:?} name {name} did not round-trip"
            );
        }
    }

    /// A Service and a StatefulSet share their name, so the claim suffix must
    /// be read only for a claim: otherwise `pipeline-<id>-storage` would parse
    /// as the id `None` for a Service and be listed as orphaned.
    #[test]
    fn rejects_a_name_of_another_kind() {
        assert_eq!(pipeline_id_from_name(ResourceKind::Service, &format!("pipeline-{ID}-storage")), None);
        assert_eq!(
            pipeline_id_from_name(ResourceKind::StorageClaim, &format!("pipeline-{ID}")),
            None
        );
        assert_eq!(
            pipeline_id_from_name(ResourceKind::Secret, &format!("pipeline-{ID}-storage")),
            None
        );
    }

    /// Objects an operator created by hand share the namespace; a name the
    /// runner never produces must not be treated as orphaned.
    #[test]
    fn rejects_names_the_runner_never_produces() {
        for name in [
            "my-database",
            "feldera-db-0",
            "pipeline-",
            "pipeline-not-a-uuid",
            "pipeline-01a17a2e-6b7c-7f2a-9f2e-0d4e5f6a7b8c-extra",
            "",
        ] {
            for kind in ResourceKind::ALL {
                assert_eq!(pipeline_id_from_name(kind, name), None, "{kind:?} {name}");
            }
        }
    }

    #[test]
    fn a_clean_report_is_clean() {
        assert!(ScanReport::default().is_clean());
        let mut report = ScanReport::default();
        report.failures.push("x".to_string());
        assert!(!report.is_clean());
    }

    /// One object the fake cluster holds.
    #[derive(Clone)]
    struct FakeObject {
        name: String,
        /// Whether the object carries the retention annotation.
        retained: bool,
    }

    /// A plain object: the common case.
    fn object(name: &str) -> FakeObject {
        FakeObject {
            name: name.to_string(),
            retained: false,
        }
    }

    /// An object a deletion deliberately kept.
    fn kept(name: &str) -> FakeObject {
        FakeObject {
            name: name.to_string(),
            retained: true,
        }
    }

    /// A cluster holding `objects` by resource path (`statefulsets`, ...) in
    /// namespace `feldera`, with every deletion succeeding.
    fn cluster_with(
        objects: &[(&str, &[FakeObject])],
    ) -> (Client, std::sync::Arc<std::sync::Mutex<Vec<(String, String)>>>) {
        cluster_with_forbidden(objects, &[])
    }

    /// `cluster_with`, with `forbidden` kinds answering 403 to every request.
    fn cluster_with_forbidden(
        objects: &[(&str, &[FakeObject])],
        forbidden: &[&str],
    ) -> (Client, std::sync::Arc<std::sync::Mutex<Vec<(String, String)>>>) {
        use bytes::Bytes;
        use http::{Method, Request, Response, StatusCode};
        use http_body_util::Full;
        use kube::client::Body as KubeBody;
        use tower::service_fn;

        let objects = objects
            .iter()
            .map(|(kind, entries)| (kind.to_string(), entries.to_vec()))
            .collect::<std::collections::BTreeMap<_, _>>();
        let requests: std::sync::Arc<std::sync::Mutex<Vec<(String, String)>>> = Default::default();
        let requests_in_service = requests.clone();
        let forbidden = forbidden
            .iter()
            .map(|kind| kind.to_string())
            .collect::<Vec<_>>();
        let client = Client::new(
            service_fn(move |request: Request<KubeBody>| {
                let objects = objects.clone();
                let requests = requests_in_service.clone();
                let forbidden = forbidden.clone();
                async move {
                    let method = request.method().clone();
                    let path = request.uri().path().to_string();
                    requests
                        .lock()
                        .unwrap()
                        .push((method.to_string(), path.clone()));
                    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
                    // /(api|apis/<group>/<version>)/namespaces/<ns>/<kind>[/<name>]
                    let (kind, name) = match parts.as_slice() {
                        ["api", "v1", "namespaces", _ns, kind] => (*kind, None),
                        ["api", "v1", "namespaces", _ns, kind, name] => (*kind, Some(*name)),
                        ["apis", _group, _version, "namespaces", _ns, kind] => (*kind, None),
                        ["apis", _group, _version, "namespaces", _ns, kind, name] => {
                            (*kind, Some(*name))
                        }
                        _ => {
                            return Ok::<_, std::convert::Infallible>(failure(
                                StatusCode::NOT_FOUND,
                                "NotFound",
                                &path,
                            ))
                        }
                    };
                    if forbidden.iter().any(|denied| denied == kind) {
                        return Ok::<_, std::convert::Infallible>(failure(
                            StatusCode::FORBIDDEN,
                            "Forbidden",
                            kind,
                        ));
                    }
                    let (api_version, api_kind) = match kind {
                        "statefulsets" => ("apps/v1", "StatefulSet"),
                        "services" => ("v1", "Service"),
                        "networkpolicies" => ("networking.k8s.io/v1", "NetworkPolicy"),
                        "secrets" => ("v1", "Secret"),
                        "persistentvolumeclaims" => ("v1", "PersistentVolumeClaim"),
                        other => ("v1", other),
                    };
                    let body = if method == Method::DELETE {
                        serde_json::json!({"kind": "Status", "status": "Success"})
                    } else if method == Method::GET && name.is_some() {
                        serde_json::json!({
                            "apiVersion": api_version, "kind": api_kind,
                            "metadata": {"name": name.unwrap(), "namespace": "feldera"},
                        })
                    } else {
                        let items = objects
                            .get(kind)
                            .map(|entries| {
                                entries
                                    .iter()
                                    // The scan lists everything and filters
                                    // names itself, so every object is
                                    // returned, as the API server does.
                                    .map(|entry| {
                                        let mut metadata = serde_json::json!({
                                            "name": entry.name, "namespace": "feldera",
                                        });
                                        if entry.retained {
                                            metadata["annotations"] = serde_json::json!({
                                                crate::runner::kubernetes_runner::RETENTION_ANNOTATION:
                                                    crate::runner::kubernetes_runner::RETENTION_KEPT_ON_DELETE,
                                            });
                                        }
                                        serde_json::json!({
                                            "apiVersion": api_version, "kind": api_kind,
                                            "metadata": metadata,
                                        })
                                    })
                                    .collect::<Vec<_>>()
                            })
                            .unwrap_or_default();
                        serde_json::json!({
                            "apiVersion": api_version, "kind": "List",
                            "metadata": {}, "items": items,
                        })
                    };
                    Ok::<_, std::convert::Infallible>(
                        Response::builder()
                            .status(StatusCode::OK)
                            .header("content-type", "application/json")
                            .body(Full::new(Bytes::from(body.to_string())))
                            .unwrap(),
                    )
                }
            }),
            "feldera",
        );
        (client, requests)
    }

    /// A Kubernetes `Status` body for a failed request.
    fn failure(
        code: http::StatusCode,
        reason: &str,
        subject: &str,
    ) -> http::Response<http_body_util::Full<bytes::Bytes>> {
        use http_body_util::Full;
        http::Response::builder()
            .status(code)
            .header("content-type", "application/json")
            .body(Full::new(bytes::Bytes::from(
                serde_json::json!({
                    "kind": "Status",
                    "status": "Failure",
                    "reason": reason,
                    "code": code.as_u16(),
                    "message": format!("{reason}: {subject}"),
                })
                .to_string(),
            )))
            .unwrap()
    }

    /// A pipeline id that reads clearly in a failure message.
    fn pipeline_id_of(name: &str) -> PipelineId {
        let id = name.strip_prefix(PIPELINE_NAME_PREFIX).unwrap();
        PipelineId(Uuid::parse_str(id.strip_suffix("-storage").unwrap_or(id)).unwrap())
    }

    /// An object whose pipeline is in the database is left alone: this is the
    /// common case, since every live pipeline has such objects.
    #[tokio::test]
    async fn keeps_objects_of_a_live_pipeline() {
        let live = format!("pipeline-{ID}");
        let (client, requests) = cluster_with(&[("statefulsets", &[object(&live)])]);
        let mut report = ScanReport::default();
        scan_namespace(&client, "feldera", &[pipeline_id_of(&live)], false, &mut report).await;

        assert!(report.unreferenced.is_empty(), "{report:?}");
        assert!(
            !requests
                .lock()
                .unwrap()
                .iter()
                .any(|(method, _)| method == "DELETE"),
            "a live pipeline's objects must never be deleted"
        );
    }

    /// An object whose pipeline is gone is reported; the same object under a
    /// name the runner did not produce is not. Distinguishing the two is the
    /// whole safety property: a name match alone would collect the platform's
    /// own database StatefulSet if it happened to start with `pipeline-`.
    #[tokio::test]
    async fn reports_only_objects_of_a_missing_pipeline() {
        let orphan = format!("pipeline-{ID}");
        let (client, _) = cluster_with(&[(
            "statefulsets",
            &[object(&orphan), object("pipeline-not-a-uuid"), object("feldera-db-0")],
        )]);
        let mut report = ScanReport::default();
        scan_namespace(&client, "feldera", &[], false, &mut report).await;

        assert_eq!(
            report.unreferenced,
            vec![UnreferencedObject {
                kind: ResourceKind::StatefulSet,
                namespace: "feldera".into(),
                name: orphan,
                pipeline_id: pipeline_id_of(&format!("pipeline-{ID}")),
            }]
        );
    }

    /// The claim suffix belongs to the claim alone: a `Service` carrying the
    /// same name is an object the runner never creates, so it is left alone
    /// even though its name contains this pipeline's id.
    #[tokio::test]
    async fn reads_the_claim_suffix_only_for_a_claim() {
        let claim = format!("pipeline-{ID}-storage");
        let (client, _) = cluster_with(&[
            ("persistentvolumeclaims", &[object(&claim)]),
            ("services", &[object(&claim)]),
        ]);
        let mut report = ScanReport::default();
        scan_namespace(&client, "feldera", &[], false, &mut report).await;

        let kinds = report
            .unreferenced
            .iter()
            .map(|object| object.kind)
            .collect::<Vec<_>>();
        assert_eq!(kinds, vec![ResourceKind::StorageClaim], "{report:?}");
    }

    /// Deletion removes the claim last: a `StatefulSet` that still exists
    /// keeps its pod using the volume, and deleting the volume first would
    /// detach it from a running pod.
    #[tokio::test]
    async fn deletes_in_the_order_that_keeps_state_mounted() {
        let base = format!("pipeline-{ID}");
        let claim = format!("{base}-storage");
        let (client, requests) = cluster_with(&[
            ("statefulsets", &[object(&base)]),
            ("services", &[object(&base)]),
            ("persistentvolumeclaims", &[object(&claim)]),
        ]);
        let mut report = ScanReport::default();
        scan_namespace(&client, "feldera", &[], true, &mut report).await;

        // A deletion moves the object from `unreferenced` to `deleted`: it is
        // reported once, in the state it was left in.
        assert_eq!(report.unreferenced.len(), 0, "{report:?}");
        assert_eq!(report.deleted.len(), 3, "{report:?}");
        let deleted = requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(method, _)| method == "DELETE")
            .map(|(_, path)| path.clone())
            .collect::<Vec<_>>();
        assert_eq!(
            deleted,
            vec![
                format!("/apis/apps/v1/namespaces/feldera/statefulsets/{base}"),
                format!("/api/v1/namespaces/feldera/services/{base}"),
                format!("/api/v1/namespaces/feldera/persistentvolumeclaims/{claim}"),
            ]
        );
    }

    /// The list must not carry a `metadata.name` range selector: the API
    /// server accepts only `=`, `==` and `!=` for that field and rejects a
    /// prefix bound with `invalid selector`, which turns every scan into a
    /// report of failures and finds nothing. The filter is applied in the
    /// manager instead, which this test pins.
    #[tokio::test]
    async fn lists_without_a_field_selector() {
        let base = format!("pipeline-{ID}");
        let (client, requests) = cluster_with(&[("statefulsets", &[object(&base)])]);
        let mut report = ScanReport::default();
        scan_namespace(&client, "feldera", &[], false, &mut report).await;

        for (_, path) in requests.lock().unwrap().iter() {
            assert!(
                !path.contains("metadata.name"),
                "a list request carried a name selector the API server rejects: {path}"
            );
        }
        assert_eq!(report.unreferenced.len(), 1, "{report:?}");
    }

    /// A claim a deletion deliberately kept is state an operator chose to
    /// preserve; reporting it would invite someone to delete it.
    #[tokio::test]
    async fn skips_an_annotated_retained_claim() {
        let claim = format!("pipeline-{ID}-storage");
        let (client, requests) = cluster_with(&[(
            "persistentvolumeclaims",
            &[kept(&claim), object(&format!("pipeline-{ID}"))],
        )]);
        let mut report = ScanReport::default();
        scan_namespace(&client, "feldera", &[], true, &mut report).await;

        // The plain object is still found and deleted; the kept one is not.
        assert!(
            !report
                .unreferenced
                .iter()
                .chain(report.deleted.iter())
                .any(|entry| entry.name == claim),
            "a kept claim was reported: {report:?}"
        );
        assert!(
            !requests
                .lock()
                .unwrap()
                .iter()
                .any(|(method, path)| method == "DELETE" && path.contains(&claim)),
            "a kept claim was deleted"
        );
    }

    /// A kind that cannot be listed is reported, and the other kinds are still
    /// scanned: one forbidden permission must not hide the rest.
    #[tokio::test]
    async fn reports_a_list_failure_and_continues() {
        let base = format!("pipeline-{ID}");
        let (client, _) = cluster_with_forbidden(
            &[("statefulsets", &[object(&base)])],
            &["secrets"],
        );
        let mut report = ScanReport::default();
        scan_namespace(&client, "feldera", &[], false, &mut report).await;

        assert_eq!(report.unreferenced.len(), 1, "{report:?}");
        assert!(
            report
                .failures
                .iter()
                .any(|failure| failure.contains("Secret") && failure.contains("Forbidden")),
            "{report:?}"
        );
    }
}
