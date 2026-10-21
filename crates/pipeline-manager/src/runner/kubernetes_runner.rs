//! Kubernetes pipeline runner.
//!
//! This module contains the [`PipelineExecutor`] implementation selected by
//! `FELDERA_RUNNER=kubernetes`. It is currently a skeleton: executor selection,
//! configuration and validation wiring are in place, while creating, observing
//! and deleting Kubernetes resources (pods, services, secrets, persistent
//! volume claims) lands in the vertical-slice work orders that follow the
//! Kubernetes runner ADR (`docs/design/adr-k8s-runner.md`).
//!
//! Every trait method that would provision resources returns an explicit error
//! instead of silently doing nothing, so that a manager started with
//! `FELDERA_RUNNER=kubernetes` fails loudly rather than appearing healthy while
//! pipelines never start.

use crate::config::{CommonConfig, KubernetesRunnerConfig};
use crate::db::types::pipeline::PipelineId;
use crate::db::types::version::Version;
use crate::error::ManagerError;
use crate::runner::error::RunnerError;
use crate::runner::pipeline_executor::{PipelineExecutor, ProvisionStatus};
use crate::runner::pipeline_logs::LogsSender;
use async_trait::async_trait;
use feldera_types::config::{PipelineConfig, StorageCacheConfig, StorageConfig};
use feldera_types::runtime_status::{BootstrapConfig, RuntimeDesiredStatus};
use std::time::Duration;
use uuid::Uuid;

/// Timeout for the `Provisioning` stage.
///
/// Pulling the pipeline image and starting the pod takes longer than spawning a
/// local process, so the Kubernetes runner allows more time than the local
/// runner (20s). See `docs/design/adr-k8s-runner.md` for the rationale.
pub const DEFAULT_KUBERNETES_PROVISIONING_TIMEOUT: Duration = Duration::from_secs(180);

/// The Kubernetes pipeline runner.
pub struct KubernetesRunner {
    pipeline_id: PipelineId,
    /// Reserved for the resource-management implementation: it carries the
    /// API/compiler endpoint configuration used to wire the pipeline pod.
    #[allow(dead_code)]
    common_config: CommonConfig,
    config: KubernetesRunnerConfig,
    /// Reserved for the resource-management implementation: used to call the
    /// pipeline's management endpoint once the pod is running.
    #[allow(dead_code)]
    client: reqwest::Client,
    /// Reserved for the resource-management implementation: used to stream pod
    /// logs into the pipeline's log buffer.
    #[allow(dead_code)]
    logs_sender: LogsSender,
}

impl KubernetesRunner {
    /// Describes an operation that this skeleton does not implement yet.
    fn unimplemented(operation: &str) -> String {
        format!(
            "the Kubernetes runner cannot yet perform '{operation}': only executor \
             selection and configuration are wired (P1-007); resource management \
             follows the Kubernetes runner ADR"
        )
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
        }
    }

    /// Storage lives on a persistent volume mounted into the pipeline pod.
    ///
    /// The concrete volume layout (claim name, mount path and storage class) is
    /// part of the storage slice; the path returned here is the in-pod mount
    /// point every slice agrees on.
    async fn generate_storage_config(&self) -> StorageConfig {
        StorageConfig {
            path: format!("/var/feldera/storage/{}", self.pipeline_id),
            cache: StorageCacheConfig::default(),
        }
    }

    /// Rejects provisioning early when the runner is misconfigured.
    ///
    /// The full check (API reachability and RBAC permissions in the target
    /// namespace) arrives with the resource-management slice; requiring the
    /// pipeline image already here turns the most common misconfiguration into
    /// a clear `Stopped` state error instead of a pod that never starts.
    async fn can_provision(
        &self,
        _deployment_config: &PipelineConfig,
        _runtime_config: &serde_json::Value,
    ) -> Result<(), ManagerError> {
        if self.config.kubernetes_runner_pipeline_executor_image.is_none() {
            return Err(RunnerError::RunnerConfigError {
                error: format!(
                    "the Kubernetes runner requires --kubernetes-runner-pipeline-executor-image \
                     (or {}) to be set: it is the image each pipeline pod runs",
                    "FELDERA_KUBERNETES_RUNNER_PIPELINE_EXECUTOR_IMAGE"
                ),
            }
            .into());
        }
        Ok(())
    }

    async fn provision(
        &mut self,
        _deployment_initial: RuntimeDesiredStatus,
        _bootstrap_config: Option<BootstrapConfig>,
        _deployment_id: &Uuid,
        _deployment_config: &PipelineConfig,
        _program_info: &serde_json::Value,
        _program_binary_url: &str,
        _program_info_url: &str,
        _program_version: Version,
        _runtime_config: &serde_json::Value,
        _is_gen2: bool,
    ) -> Result<(), ManagerError> {
        Err(RunnerError::RunnerProvisionError {
            error: Self::unimplemented("provision"),
        }
        .into())
    }

    async fn is_provisioned(
        &mut self,
        _runtime_config: &serde_json::Value,
    ) -> Result<ProvisionStatus, ManagerError> {
        Err(RunnerError::RunnerProvisionError {
            error: Self::unimplemented("is_provisioned"),
        }
        .into())
    }

    async fn check(
        &mut self,
        _runtime_config: &serde_json::Value,
    ) -> Result<serde_json::Value, ManagerError> {
        Err(RunnerError::RunnerCheckError {
            error: Self::unimplemented("check"),
        }
        .into())
    }

    async fn stop(&mut self, _runtime_config: &serde_json::Value) -> Result<(), ManagerError> {
        Err(RunnerError::RunnerStopError {
            error: Self::unimplemented("stop"),
        }
        .into())
    }

    async fn clear(&mut self, _runtime_config: &serde_json::Value) -> Result<(), ManagerError> {
        Err(RunnerError::RunnerClearError {
            error: Self::unimplemented("clear"),
        }
        .into())
    }
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_KUBERNETES_PROVISIONING_TIMEOUT, KubernetesRunner};
    use crate::runner::pipeline_executor::PipelineExecutor;
    use std::time::Duration;

    /// The provisioning timeout is longer than the local runner's 20s: image
    /// pulls and pod scheduling do not fit that budget.
    #[test]
    fn provisioning_timeout_is_kubernetes_sized() {
        assert_eq!(
            <KubernetesRunner as PipelineExecutor>::DEFAULT_PROVISIONING_TIMEOUT,
            DEFAULT_KUBERNETES_PROVISIONING_TIMEOUT
        );
        assert!(DEFAULT_KUBERNETES_PROVISIONING_TIMEOUT >= Duration::from_secs(120));
    }

    /// Unimplemented operations name the operation and point at the ADR instead
    /// of returning a generic error.
    #[test]
    fn unimplemented_errors_are_actionable() {
        let message = KubernetesRunner::unimplemented("provision");
        assert!(message.contains("provision"), "{message}");
        assert!(message.contains("Kubernetes runner ADR"), "{message}");
    }
}
