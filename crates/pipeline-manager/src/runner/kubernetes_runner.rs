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
//! * Pod logs are not streamed into the pipeline's log buffer yet (P1-010).

use crate::config::{CommonConfig, KubernetesRunnerConfig};
use crate::db::types::pipeline::{
    PipelineId, bootstrap_policy_to_string, runtime_desired_status_to_string,
};
use crate::db::types::program::ProgramInfo;
use crate::db::types::version::Version;
use crate::error::ManagerError;
use crate::pipeline_env::validate_pipeline_env;
use crate::runner::error::RunnerError;
use crate::runner::pipeline_executor::{
    PipelineExecutor, ProvisionStatus, discover_namespace_from_runtime_config_json,
};
use crate::runner::pipeline_logs::LogsSender;
use async_trait::async_trait;
use feldera_types::config::{PipelineConfig, StorageCacheConfig, StorageConfig};
use feldera_types::runtime_status::{BootstrapConfig, RuntimeDesiredStatus};
use k8s_openapi::api::apps::v1::{StatefulSet, StatefulSetSpec};
use k8s_openapi::api::core::v1::{
    Container, ContainerPort, EmptyDirVolumeSource, EnvVar, EnvVarSource, ObjectFieldSelector,
    PersistentVolumeClaim, PersistentVolumeClaimSpec, PersistentVolumeClaimVolumeSource, Pod,
    PodSecurityContext, PodSpec, PodTemplateSpec, ResourceRequirements, Secret, SecretVolumeSource,
    Service, ServicePort, ServiceSpec, Volume, VolumeMount, VolumeResourceRequirements,
};
use k8s_openapi::apimachinery::pkg::api::resource::Quantity;
use k8s_openapi::apimachinery::pkg::apis::meta::v1::{LabelSelector, ObjectMeta};
use k8s_openapi::apimachinery::pkg::util::intstr::IntOrString;
use kube::Client;
use kube::api::{Api, DeleteParams, Patch, PatchParams, PostParams};
use std::collections::BTreeMap;
use std::time::Duration;
use tracing::{info, warn};
use uuid::Uuid;

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

/// Writable working directory for the program binary and the port file.
const WORK_DIR: &str = "/var/feldera/work";

/// Base directory of the persistent volume, extended with the pipeline id by
/// [`PipelineExecutor::generate_storage_config`].
const STORAGE_MOUNT_BASE: &str = "/var/feldera/storage";

/// Entrypoint the pipeline executor image must provide. It downloads (or
/// locates) the program binary and `exec`s it with the arguments passed here.
const PIPELINE_ENTRYPOINT: &str = "/usr/local/bin/pipeline-entrypoint";

/// Storage reserved when the runtime configuration requests none, matching the
/// documented default of 30 GiB.
const DEFAULT_STORAGE_MB: u64 = 30 * 1024;

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

/// Name of the single pod a `StatefulSet` with one replica creates.
fn pod_name(pipeline_id: PipelineId) -> String {
    format!("{}-0", resource_base(pipeline_id))
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

/// Storage requested for the pipeline's claim, in MiB.
///
/// `storage_mb_max` wins because it is the ceiling of an autoscaling claim;
/// without any size the documented default applies.
fn storage_mb(config: &PipelineConfig) -> u64 {
    let resources = &config.global.resources;
    resources
        .storage_mb_max
        .or(resources.storage_mb_min)
        .unwrap_or(DEFAULT_STORAGE_MB)
}

/// Maps the runtime configuration's resource requests onto pod resources.
fn pod_resources(config: &PipelineConfig) -> ResourceRequirements {
    let resources = &config.global.resources;
    let mut requests = BTreeMap::new();
    let mut limits = BTreeMap::new();
    if let Some(cores) = resources.cpu_cores_min {
        requests.insert("cpu".to_string(), cpu_quantity(cores));
    }
    if let Some(mb) = resources.memory_mb_min {
        requests.insert("memory".to_string(), mebibyte_quantity(mb));
    }
    if let Some(cores) = resources.cpu_cores_max {
        limits.insert("cpu".to_string(), cpu_quantity(cores));
    }
    if let Some(mb) = resources.memory_mb_max {
        limits.insert("memory".to_string(), mebibyte_quantity(mb));
    }
    ResourceRequirements {
        requests: (!requests.is_empty()).then_some(requests),
        limits: (!limits.is_empty()).then_some(limits),
        ..Default::default()
    }
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
}

/// The objects provisioning creates for one pipeline deployment.
#[derive(Debug)]
struct PipelineObjects {
    secret: Secret,
    storage_claim: Option<PersistentVolumeClaim>,
    service: Service,
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

    fn render_service(&self) -> Service {
        Service {
            metadata: self.metadata(),
            spec: Some(ServiceSpec {
                // Headless: the DNS name resolves to the pod's own address, so
                // the manager can reach the pipeline without a stable ClusterIP.
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
    /// Reserved for later slices: used to call the pipeline's management
    /// endpoint from the manager side (today the automaton does that itself).
    #[allow(dead_code)]
    client: reqwest::Client,
    /// Reserved for P1-010, which streams pod logs into the pipeline log buffer.
    #[allow(dead_code)]
    logs_sender: LogsSender,
    /// Lazily initialized API client: it validates the credentials before any
    /// resource is touched, and its construction is fallible.
    kubernetes: Option<Client>,
}

/// Builds a Kubernetes API client from the runner configuration.
///
/// A kubeconfig path wins over in-cluster credentials so that a manager running
/// outside the cluster (a developer machine against `kind`) works with the usual
/// `--kubernetes-runner-kubeconfig` pointer.
async fn build_kubernetes_client(config: &KubernetesRunnerConfig) -> Result<Client, ManagerError> {
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
    /// The runtime configuration may request a namespace per pipeline; when it
    /// does not, the runner-wide namespace is used.
    fn namespace(&self, runtime_config: &serde_json::Value) -> String {
        discover_namespace_from_runtime_config_json(runtime_config)
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
    ) -> RenderInput {
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
                size_mb: storage_mb(config),
                storage_class: config.global.resources.storage_class.clone(),
            });
        RenderInput {
            pipeline_id: self.pipeline_id,
            deployment_id,
            namespace: namespace.to_string(),
            image,
            config_yaml,
            args,
            env,
            resources: pod_resources(config),
            storage,
            service_account: config.global.resources.service_account_name.clone(),
        }
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
    async fn get_pod(&self, namespace: &str) -> Result<Option<Pod>, ManagerError> {
        let client = match &self.kubernetes {
            Some(client) => client.clone(),
            None => return Ok(None),
        };
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
}

#[async_trait]
impl PipelineExecutor for KubernetesRunner {
    type Config = KubernetesRunnerConfig;

    const DEFAULT_PROVISIONING_TIMEOUT: Duration = DEFAULT_KUBERNETES_PROVISIONING_TIMEOUT;

    fn new(
        pipeline_id: PipelineId,
        common_config: CommonConfig,
        config: Self::Config,
        client: reqwest::Client,
        logs_sender: LogsSender,
    ) -> Self {
        Self {
            pipeline_id,
            common_config,
            config,
            client,
            logs_sender,
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
        let namespaces: Api<k8s_openapi::api::core::v1::Namespace> = Api::all(client);
        match namespaces.get(&namespace).await {
            Ok(_) => Ok(()),
            Err(error) if is_not_found(&error) => Err(RunnerError::RunnerConfigError {
                error: format!(
                    "the Kubernetes namespace '{namespace}' does not exist: create it, or point \
                     --kubernetes-runner-namespace at an existing namespace"
                ),
            }
            .into()),
            Err(error) => Err(RunnerError::RunnerConfigError {
                error: format!("unable to read the Kubernetes namespace '{namespace}': {error}"),
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
        _program_info_url: &str,
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
        let input = self.render(
            *deployment_id,
            &namespace,
            image,
            &config,
            config_yaml,
            args,
            env,
            Some(program_binary_url),
        );
        let objects = input.render();

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

        let statefulsets: Api<StatefulSet> = Api::namespaced(client.clone(), &namespace);
        let statefulset_name = resource_base(self.pipeline_id);
        self.apply(&statefulsets, &statefulset_name, &objects.statefulset)
            .await?;

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
            return Ok(ProvisionStatus::Ongoing { details });
        };
        if let Some(failure) = pod_failure(&pod) {
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
        Ok(pod_details(&pod))
    }

    /// Scales the pipeline down to zero replicas, keeping its storage claim.
    async fn stop(&mut self, runtime_config: &serde_json::Value) -> Result<(), ManagerError> {
        let namespace = self.namespace(runtime_config);
        // A runner that was restarted while its pipeline was running has no
        // cached client; the resources still exist and are found by name.
        let client = self.kubernetes_client().await?;
        self.kubernetes = Some(client);
        self.scale_to_zero(&namespace).await
    }

    /// Deletes the pipeline's compute and storage resources.
    async fn clear(&mut self, runtime_config: &serde_json::Value) -> Result<(), ManagerError> {
        let namespace = self.namespace(runtime_config);
        let client = self.kubernetes_client().await?;
        let statefulsets: Api<StatefulSet> = Api::namespaced(client.clone(), &namespace);
        let secrets: Api<Secret> = Api::namespaced(client.clone(), &namespace);
        let services: Api<Service> = Api::namespaced(client.clone(), &namespace);
        let claims: Api<PersistentVolumeClaim> = Api::namespaced(client, &namespace);

        let deletions: [(&str, String); 4] = [
            ("StatefulSet", resource_base(self.pipeline_id)),
            ("Service", resource_base(self.pipeline_id)),
            ("Secret", config_secret_name(self.pipeline_id)),
            (
                "PersistentVolumeClaim",
                storage_claim_name(self.pipeline_id),
            ),
        ];
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

impl KubernetesRunner {
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
            resources: pod_resources(config),
            storage: config
                .storage_config
                .as_ref()
                .map(|storage| StorageRequest {
                    mount_path: storage.path.clone(),
                    size_mb: storage_mb(config),
                    storage_class: config.global.resources.storage_class.clone(),
                }),
            service_account: config.global.resources.service_account_name.clone(),
        }
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
            Some(format!("{DEFAULT_STORAGE_MB}Mi"))
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
        assert_eq!(requirements.limits.as_ref().unwrap()["memory"].0, "2048Mi");

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
                kubernetes_runner_allow_kubernetes_env_prefix: false,
            },
            client: reqwest::Client::new(),
            logs_sender: logs_sender(),
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
        use http_body_util::Full;
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
            pub namespace_exists: Arc<Mutex<bool>>,
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

        /// Maps a resource path segment to the `apiVersion`/`kind` pair the
        /// Kubernetes API returns for it, which the typed `kube` clients check.
        fn api_type(kind: &str) -> (&'static str, &'static str) {
            match kind {
                "pods" => ("v1", "Pod"),
                "secrets" => ("v1", "Secret"),
                "services" => ("v1", "Service"),
                "persistentvolumeclaims" => ("v1", "PersistentVolumeClaim"),
                "namespaces" => ("v1", "Namespace"),
                "statefulsets" => ("apps/v1", "StatefulSet"),
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
                ["apis", "apps", "v1", "namespaces", _ns, kind] => (*kind, None),
                ["apis", "apps", "v1", "namespaces", _ns, kind, name] => (*kind, Some(*name)),
                _ => return status(StatusCode::NOT_FOUND, "route", path),
            };
            if kind == "pods" && method == Method::GET {
                return match cluster.pod.lock().unwrap().clone() {
                    Some(pod) => json(pod),
                    None => status(StatusCode::NOT_FOUND, kind, name.unwrap_or("")),
                };
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
            kubernetes_runner_allow_kubernetes_env_prefix: false,
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
        assert_eq!(posted.len(), 4);
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
        assert_eq!(details["restarts"], serde_json::json!(0));
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
}
