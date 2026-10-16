//! Self-hosted placeholder for the enterprise checkpoint-sync crate.
//!
//! # Why this crate exists
//!
//! The closed-source Feldera distribution ships the remote checkpoint
//! synchronizer in a private `sync-checkpoint` crate. The open-source tree
//! discovers it only through `inventory`
//! ([`feldera_storage::checkpoint_synchronizer::SYNCHRONIZER`]), which panics
//! when nothing is registered, and the SQL compiler in `--enterprise` mode
//! injects a path dependency on this crate into every generated pipeline
//! (`MultiCratesWriter`), which links it with `extern crate sync_checkpoint;`
//! (`CircuitWriter`). Without this crate, an `--enterprise` pipeline fails to
//! compile, and with it absent from the link graph the synchronizer lookup
//! panics.
//!
//! # Semantics of the stub
//!
//! [`NoopSynchronizer`] is registered via [`inventory::submit!`] and behaves as
//! follows, so that misconfiguration fails loudly instead of silently losing
//! data:
//!
//! * `push` and `pull` return an explicit "not configured" error naming
//!   [`NOT_CONFIGURED`]. A checkpoint is never reported as synced when nothing
//!   was transferred.
//! * `take_ownership` inherits the trait's default implementation, which the
//!   trait documents as the way to report `take_bucket_ownership` as
//!   unsupported.
//! * `list_remote` returns an empty list.
//!
//! Local checkpointing is unaffected: the synchronizer is only consulted when a
//! pipeline configures remote sync ([`SyncConfig`]).
//!
//! # Replacement plan (P2)
//!
//! Replace [`NoopSynchronizer`]'s method bodies with a synchronizer backed by
//! the company S3-compatible object storage. Keep the crate name, the crate
//! path, and the `inventory::submit!` registration below unchanged: pipelines
//! compiled with `--enterprise` depend on this crate by path only, so P2
//! requires no pipeline regeneration and no change outside this crate.

use std::sync::Arc;

use feldera_storage::{checkpoint_synchronizer::CheckpointSynchronizer, StorageBackend};
use feldera_types::{
    checkpoint::{CheckpointMetadata, CheckpointSyncMetrics, HostInfo, RemoteCheckpoint},
    config::{PipelineIdentity, SyncConfig},
};

/// Core message every rejected operation reports. Tests and operators grep for
/// this string to tell "remote sync is not available in this deployment" apart
/// from a genuine synchronization failure.
pub const NOT_CONFIGURED: &str = "self-hosted stub: no remote synchronizer configured";

/// Builds the error returned by every operation that would need remote object
/// storage. `operation` is the trait method name, so the message pinpoints
/// which step of the sync flow was attempted.
fn not_configured(operation: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "{NOT_CONFIGURED}; `{operation}` requires the self-hosted object-storage synchronizer \
         (scheduled for P2)"
    )
}

/// Placeholder [`CheckpointSynchronizer`] for self-hosted builds.
///
/// See the [module documentation](self) for the contract this stub upholds and
/// the plan to replace it.
#[derive(Debug)]
pub struct NoopSynchronizer;

impl CheckpointSynchronizer for NoopSynchronizer {
    fn push(
        &self,
        _checkpoint: uuid::Uuid,
        _storage: Arc<dyn StorageBackend>,
        _remote_config: SyncConfig,
        _host_info: Option<HostInfo>,
        _pipeline: PipelineIdentity,
    ) -> anyhow::Result<Option<CheckpointSyncMetrics>> {
        Err(not_configured("push"))
    }

    fn pull(
        &self,
        _storage: Arc<dyn StorageBackend>,
        _remote_config: SyncConfig,
        _host_info: Option<HostInfo>,
        _standby: bool,
        _pipeline: PipelineIdentity,
    ) -> anyhow::Result<(CheckpointMetadata, Option<CheckpointSyncMetrics>)> {
        Err(not_configured("pull"))
    }

    fn list_remote(&self, _remote_config: SyncConfig) -> anyhow::Result<Vec<RemoteCheckpoint>> {
        Ok(Vec::new())
    }

    // `take_ownership` is deliberately not overridden. The trait's default
    // implementation reports `take_bucket_ownership` as unsupported, which is
    // exactly the stub's behavior; overriding it would duplicate that message
    // for no gain.
}

inventory::submit! {
    &NoopSynchronizer as &dyn CheckpointSynchronizer
}

#[cfg(test)]
mod tests {
    use super::*;
    use feldera_storage::{checkpoint_synchronizer::SYNCHRONIZER, DirEntry, FileWriter, StoragePath};
    use std::sync::atomic::AtomicI64;

    /// Local-storage double that panics on any file operation. The stub must
    /// fail before touching local storage, so reaching any method here is a
    /// test failure by construction.
    struct UnusedBackend;

    impl StorageBackend for UnusedBackend {
        fn create_named(&self, _name: &StoragePath) -> Result<Box<dyn FileWriter>, feldera_storage::error::StorageError> {
            unimplemented!("the stub synchronizer must not touch local storage")
        }

        fn open(
            &self,
            _name: &StoragePath,
        ) -> Result<Arc<dyn feldera_storage::FileReader>, feldera_storage::error::StorageError>
        {
            unimplemented!("the stub synchronizer must not touch local storage")
        }

        fn list(
            &self,
            _parent: &StoragePath,
            _cb: &mut dyn FnMut(DirEntry),
        ) -> Result<(), feldera_storage::error::StorageError> {
            unimplemented!("the stub synchronizer must not touch local storage")
        }

        fn delete(&self, _name: &StoragePath) -> Result<(), feldera_storage::error::StorageError> {
            unimplemented!("the stub synchronizer must not touch local storage")
        }

        fn delete_recursive(
            &self,
            _name: &StoragePath,
        ) -> Result<(), feldera_storage::error::StorageError> {
            unimplemented!("the stub synchronizer must not touch local storage")
        }

        fn usage(&self) -> Arc<AtomicI64> {
            Arc::new(AtomicI64::new(0))
        }
    }

    fn backend() -> Arc<dyn StorageBackend> {
        Arc::new(UnusedBackend)
    }

    fn pipeline() -> PipelineIdentity {
        PipelineIdentity {
            name: "pipeline-test".to_string(),
            given_name: None,
        }
    }

    /// The regression this crate exists to prevent: `inventory` must enumerate
    /// at least one synchronizer, or the runtime's lazy lookup panics.
    #[test]
    fn stub_is_registered_in_inventory() {
        let count = inventory::iter::<&dyn CheckpointSynchronizer>
            .into_iter()
            .count();
        assert!(
            count >= 1,
            "sync-checkpoint must register at least one CheckpointSynchronizer, found {count}"
        );
    }

    /// The lazy static in `feldera-storage` must resolve without panicking,
    /// and must resolve to *this* crate's stub.
    #[test]
    fn synchronizer_static_resolves_to_the_stub() {
        let synchronizer: &'static dyn CheckpointSynchronizer = *SYNCHRONIZER;
        let error = synchronizer
            .pull(
                backend(),
                SyncConfig::default(),
                None,
                false,
                pipeline(),
            )
            .expect_err("the stub must reject `pull`");
        assert!(
            error.to_string().contains(NOT_CONFIGURED),
            "unexpected error from the resolved synchronizer: {error}"
        );
    }

    #[test]
    fn push_reports_not_configured() {
        let error = NoopSynchronizer
            .push(
                uuid::Uuid::nil(),
                backend(),
                SyncConfig::default(),
                None,
                pipeline(),
            )
            .expect_err("`push` must fail until remote sync is implemented");
        let message = error.to_string();
        assert!(message.contains(NOT_CONFIGURED), "unexpected error: {message}");
        assert!(message.contains("push"), "error must name the operation: {message}");
    }

    #[test]
    fn pull_reports_not_configured() {
        let error = NoopSynchronizer
            .pull(backend(), SyncConfig::default(), None, true, pipeline())
            .expect_err("`pull` must fail until remote sync is implemented");
        assert!(
            error.to_string().contains(NOT_CONFIGURED),
            "unexpected error: {error}"
        );
    }

    /// `take_ownership` is expected to keep the trait default, which reports
    /// the option as unsupported rather than silently claiming the bucket.
    #[test]
    fn take_ownership_reports_unsupported() {
        let error = NoopSynchronizer
            .take_ownership(backend(), SyncConfig::default(), pipeline())
            .expect_err("`take_ownership` must not claim a bucket the stub cannot manage");
        assert!(
            error.to_string().contains("take_bucket_ownership"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn list_remote_is_empty() {
        let checkpoints = NoopSynchronizer
            .list_remote(SyncConfig::default())
            .expect("`list_remote` must report an empty inventory, not an error");
        assert!(
            checkpoints.is_empty(),
            "the stub cannot know about remote checkpoints: {checkpoints:?}"
        );
    }
}
