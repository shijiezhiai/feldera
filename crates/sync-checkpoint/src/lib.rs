//! Self-hosted checkpoint synchronizer backed by a local directory.
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
//! # What it synchronizes
//!
//! [`LocalDirSynchronizer`] is registered via [`inventory::submit!`] and
//! implements checkpoint push and pull against a directory on the local
//! filesystem, so that a self-hosted deployment can exercise
//! [`SyncConfig::start_from_checkpoint`] without the company's S3-compatible
//! object storage.
//!
//! The posix storage layout gives a checkpoint three parts:
//!
//! * the directory named after the checkpoint UUID at the storage root, which
//!   holds the per-operator state files, the `CHECKPOINT` marker, the
//!   `dependencies.json` manifest, and the checkpoint's own `state.json`;
//! * the batch files at the storage root that `dependencies.json` references;
//!   and
//! * the root-level step journal ([`STEPS_FILE`]), a directory the pipeline
//!   replays through after it opens the checkpoint. It may hold no journals
//!   yet, but it must exist: the persistent-input steps `readdir` it during
//!   initialization. It is not referenced by `dependencies.json`, so a
//!   checkpoint that omits it cannot be resumed.
//!
//! A push copies all three into the bucket. The [`CheckpointMetadata`] of every
//! pushed checkpoint also lands in a `checkpoints.feldera` catalog at the
//! bucket root, so that a later pull selects the newest checkpoint instead of
//! guessing from directory timestamps, and so that `list_remote` can enumerate
//! what the bucket holds.
//!
//! # Configuration
//!
//! [`SyncConfig::bucket`] names the local directory. Both a plain absolute path
//! and a `file://` URL are accepted. Every other scheme (for example `s3://`)
//! is rejected with an explicit error rather than being silently mistreated as
//! a relative directory, and so is a relative path, because the manager's
//! working directory is not the pipeline's. The remaining [`SyncConfig`] fields
//! keep their documented meaning: `start_from_checkpoint` selects the
//! checkpoint to pull (`latest` or a specific UUID), `fail_if_no_checkpoint`
//! decides whether an empty bucket is an error, and `pull_interval` /
//! `push_interval` are honored by the caller, not here.
//!
//! A multihost pipeline (`host_info` is `Some`) keeps one subdirectory per host
//! inside the bucket, exactly as the peer object-storage synchronizer does.
//!
//! # Replacement plan (P2)
//!
//! Replace [`LocalDirSynchronizer`]'s bucket handling with the company's
//! S3-compatible object storage. Keep the crate name, the crate path, and the
//! `inventory::submit!` registration below unchanged: pipelines compiled with
//! `--enterprise` depend on this crate by path only, so P2 requires no pipeline
//! regeneration and no change outside this crate.

use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use feldera_storage::{
    checkpoint_synchronizer::CheckpointSynchronizer, StorageBackend, StoragePath,
};
use feldera_types::{
    checkpoint::{CheckpointMetadata, CheckpointSyncMetrics, HostInfo, RemoteCheckpoint},
    config::{PipelineIdentity, StartFromCheckpoint, SyncConfig},
    constants::{CHECKPOINT_FILE_NAME, STATE_FILE, STEPS_FILE},
};

/// Prefix of every error this crate reports, so that operators can tell a
/// self-hosted local-directory synchronization apart from the P2 object-storage
/// one in a log or a `deployment_error`.
const SOURCE: &str = "sync-checkpoint";

/// Root-level entries (files or directories) that belong to the
/// fault-tolerance state of a pipeline and therefore have to travel with every
/// checkpoint.
///
/// `Checkpointer::gc_startup` treats these as in use and never collects them,
/// but `dependencies.json` does not reference them either, so a checkpoint is
/// not restorable without them: the step journal is what the pipeline replays
/// through after it opens a checkpoint. `STATE_FILE` is deliberately absent,
/// because each checkpoint directory carries its own copy and `pull` installs
/// that copy as the root pointer.
const CHECKPOINT_ROOT_FILES: &[&str] = &[STEPS_FILE];

/// Checkpoint synchronizer for self-hosted deployments.
///
/// See the [module documentation](self) for the layout it copies and the
/// configuration it accepts.
#[derive(Debug)]
pub struct LocalDirSynchronizer;

impl CheckpointSynchronizer for LocalDirSynchronizer {
    fn push(
        &self,
        checkpoint: uuid::Uuid,
        storage: Arc<dyn StorageBackend>,
        remote_config: SyncConfig,
        host_info: Option<HostInfo>,
        _pipeline: PipelineIdentity,
    ) -> anyhow::Result<Option<CheckpointSyncMetrics>> {
        if checkpoint.is_nil() {
            anyhow::bail!(
                "{SOURCE}: refusing to push the nil checkpoint: the caller must name the \
                 checkpoint to synchronize"
            );
        }
        let local_root = local_root(&storage)?;
        let bucket = bucket_dir(&remote_config, host_info.as_ref())?;
        let batches = batch_paths(&storage, checkpoint)?;
        let started = Instant::now();
        let bytes = push_checkpoint(&local_root, &bucket, checkpoint, &batches)?;
        Ok(Some(metrics(started, bytes)))
    }

    fn pull(
        &self,
        storage: Arc<dyn StorageBackend>,
        remote_config: SyncConfig,
        host_info: Option<HostInfo>,
        _standby: bool,
        _pipeline: PipelineIdentity,
    ) -> anyhow::Result<(CheckpointMetadata, Option<CheckpointSyncMetrics>)> {
        let local_root = local_root(&storage)?;
        let bucket = bucket_dir(&remote_config, host_info.as_ref())?;
        let started = Instant::now();
        let pulled = pull_checkpoint(
            &local_root,
            &bucket,
            remote_config.start_from_checkpoint.as_ref(),
            remote_config.fail_if_no_checkpoint,
        )?;
        Ok(match pulled {
            Some((metadata, bytes)) => (metadata, Some(metrics(started, bytes))),
            // There is nothing to pull and the caller does not treat that as a
            // failure: leave local storage alone, so the pipeline resumes from
            // its own checkpoints or starts from scratch when it has none.
            None => (CheckpointMetadata::default(), None),
        })
    }

    fn list_remote(&self, remote_config: SyncConfig) -> anyhow::Result<Vec<RemoteCheckpoint>> {
        // A listing is not scoped to a host: it answers "which checkpoints exist
        // in this bucket", which the caller uses to drive the whole pipeline.
        list_bucket(&bucket_dir(&remote_config, None)?)
    }

    // `take_ownership` keeps the trait's default implementation, which reports
    // `take_bucket_ownership` as unsupported: a local directory has no bucket
    // ownership to claim.
}

// -------------------------------------------------------------------------
// Configuration
// -------------------------------------------------------------------------

/// Resolves the `bucket` of `remote_config` to a directory, appending the
/// per-host subdirectory when `host_info` describes a multihost pipeline.
fn bucket_dir(remote_config: &SyncConfig, host_info: Option<&HostInfo>) -> anyhow::Result<PathBuf> {
    let bucket = remote_config.bucket.trim();
    if bucket.is_empty() {
        anyhow::bail!(
            "{SOURCE}: `sync.bucket` is empty; set it to the absolute path of the directory that \
             holds the synchronized checkpoints"
        );
    }
    let dir = match bucket.split_once("://") {
        None => PathBuf::from(bucket),
        Some((scheme, rest)) if scheme.eq_ignore_ascii_case("file") => PathBuf::from(rest),
        Some((scheme, _)) => anyhow::bail!(
            "{SOURCE}: `sync.bucket` ('{bucket}') uses the `{scheme}` scheme, but this build only \
             synchronizes checkpoints through a local directory; give an absolute path, optionally \
             prefixed with `file://`"
        ),
    };
    if !dir.is_absolute() {
        anyhow::bail!(
            "{SOURCE}: `sync.bucket` ('{bucket}') must be an absolute path: the pipeline's working \
             directory is not the one you configured the path in"
        );
    }
    Ok(match host_info {
        Some(host_info) => dir.join(host_info.prefix()),
        None => dir,
    })
}

/// Returns the directory the storage backend keeps its files in.
fn local_root(storage: &Arc<dyn StorageBackend>) -> anyhow::Result<PathBuf> {
    storage
        .file_system_path()
        .map(Path::to_path_buf)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "{SOURCE}: checkpoint synchronization needs a local storage backend, but this \
             pipeline's backend does not report a filesystem path"
            )
        })
}

/// Returns the batches the checkpoint references, sorted so that a push copies
/// them in a stable order.
fn batch_paths(
    storage: &Arc<dyn StorageBackend>,
    checkpoint: uuid::Uuid,
) -> anyhow::Result<Vec<StoragePath>> {
    let mut batches: Vec<StoragePath> = storage
        .gather_batches_for_checkpoint_uuid(checkpoint)
        .map_err(|error| {
            anyhow::anyhow!(
                "{SOURCE}: cannot read the batch list of checkpoint {checkpoint}: {error}"
            )
        })?
        .into_iter()
        .collect();
    batches.sort_by_key(StoragePath::to_string);
    Ok(batches)
}

// -------------------------------------------------------------------------
// Checkpoint catalog
// -------------------------------------------------------------------------

fn catalog_path(dir: &Path) -> PathBuf {
    dir.join(CHECKPOINT_FILE_NAME)
}

/// Reads the checkpoint catalog of `dir`, which lists the checkpoints stored
/// there. A directory without a catalog holds no checkpoints.
fn read_catalog(dir: &Path) -> anyhow::Result<Vec<CheckpointMetadata>> {
    let path = catalog_path(dir);
    match fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| {
            anyhow::anyhow!(
                "{SOURCE}: the checkpoint catalog {} is malformed: {error}",
                path.display()
            )
        }),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(anyhow::anyhow!(
            "{SOURCE}: cannot read the checkpoint catalog {}: {error}",
            path.display()
        )),
    }
}

/// Writes the checkpoint catalog of `dir` atomically, so that a crash never
/// leaves a half-written catalog behind.
fn write_catalog(dir: &Path, checkpoints: &[CheckpointMetadata]) -> anyhow::Result<()> {
    fs::create_dir_all(dir).map_err(|error| {
        anyhow::anyhow!(
            "{SOURCE}: cannot create the checkpoint directory {}: {error}",
            dir.display()
        )
    })?;
    let path = catalog_path(dir);
    let temporary = path.with_extension("feldera.tmp");
    let json = serde_json::to_vec(checkpoints)?;
    fs::write(&temporary, json).map_err(|error| {
        anyhow::anyhow!(
            "{SOURCE}: cannot write the checkpoint catalog {}: {error}",
            temporary.display()
        )
    })?;
    fs::rename(&temporary, &path).map_err(|error| {
        anyhow::anyhow!(
            "{SOURCE}: cannot publish the checkpoint catalog {}: {error}",
            path.display()
        )
    })?;
    Ok(())
}

/// Adds `metadata` to `catalog`, replacing any entry for the same checkpoint,
/// and writes the result.
fn upsert_catalog(dir: &Path, metadata: &CheckpointMetadata) -> anyhow::Result<()> {
    let mut catalog = read_catalog(dir)?;
    catalog.retain(|existing| existing.uuid != metadata.uuid);
    catalog.push(metadata.clone());
    write_catalog(dir, &catalog)
}

// -------------------------------------------------------------------------
// Push
// -------------------------------------------------------------------------

/// Copies the checkpoint `uuid` out of `local_root` into `bucket`, together
/// with the batches it references, and records it in the bucket's catalog.
/// Returns the number of bytes copied.
fn push_checkpoint(
    local_root: &Path,
    bucket: &Path,
    uuid: uuid::Uuid,
    batches: &[StoragePath],
) -> anyhow::Result<u64> {
    if same_dir(local_root, bucket) {
        anyhow::bail!(
            "{SOURCE}: `sync.bucket` ({}) is the pipeline's own storage directory; pushing there \
             would copy a checkpoint onto itself",
            bucket.display()
        );
    }
    let checkpoint_dir = local_root.join(uuid.to_string());
    if !checkpoint_dir.is_dir() {
        anyhow::bail!(
            "{SOURCE}: checkpoint {uuid} is not in local storage: {} does not exist",
            checkpoint_dir.display()
        );
    }
    let metadata = read_catalog(local_root)?
        .into_iter()
        .find(|metadata| metadata.uuid == uuid)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "{SOURCE}: checkpoint {uuid} is not listed in the local checkpoint catalog {}; \
                 refusing to push a checkpoint that could never be pulled back",
                catalog_path(local_root).display()
            )
        })?;

    fs::create_dir_all(bucket).map_err(|error| {
        anyhow::anyhow!(
            "{SOURCE}: cannot create the bucket directory {}: {error}",
            bucket.display()
        )
    })?;
    let mut bytes = copy_tree(&checkpoint_dir, &bucket.join(uuid.to_string()))?;
    for batch in batches {
        let name = relative_path(batch)?;
        let source = local_root.join(&name);
        if source.is_file() {
            bytes += copy_file(&source, &bucket.join(&name))?;
        }
    }
    for name in CHECKPOINT_ROOT_FILES {
        let source = local_root.join(name);
        // The step journal is a directory at runtime: the persistent-input
        // steps `readdir` it when they initialize, so an empty directory must
        // still travel with the checkpoint, and a restorer without it fails to
        // start ("readdir failed: entity not found").
        if source.is_dir() {
            bytes += copy_tree(&source, &bucket.join(name))?;
        } else if source.is_file() {
            bytes += copy_file(&source, &bucket.join(name))?;
        }
    }
    upsert_catalog(bucket, &metadata)?;
    Ok(bytes)
}

// -------------------------------------------------------------------------
// Pull
// -------------------------------------------------------------------------

/// Copies the selected remote checkpoint into `local_root`, points the local
/// storage at it, and returns its metadata.
///
/// `Ok(None)` means the bucket holds no matching checkpoint and the caller did
/// not ask for a hard failure. The local storage is then left untouched.
fn pull_checkpoint(
    local_root: &Path,
    bucket: &Path,
    selection: Option<&StartFromCheckpoint>,
    fail_if_no_checkpoint: bool,
) -> anyhow::Result<Option<(CheckpointMetadata, u64)>> {
    if same_dir(local_root, bucket) {
        anyhow::bail!(
            "{SOURCE}: `sync.bucket` ({}) is the pipeline's own storage directory; pulling from \
             there would copy a checkpoint onto itself",
            bucket.display()
        );
    }
    let catalog = read_catalog(bucket)?;
    let selected = match selection {
        Some(StartFromCheckpoint::Uuid(uuid)) => catalog
            .iter()
            .find(|metadata| metadata.uuid == *uuid)
            .cloned(),
        // `None` never reaches here because the caller only pulls when
        // `start_from_checkpoint` is set; `Latest` is the newest entry, which is
        // the order in which pushes append to the catalog.
        Some(StartFromCheckpoint::Latest) | None => catalog.last().cloned(),
    };
    let Some(metadata) = selected else {
        if fail_if_no_checkpoint {
            anyhow::bail!(
                "{SOURCE}: the bucket {} holds no checkpoint to pull, and the pipeline sets \
                 `fail_if_no_checkpoint`",
                bucket.display()
            );
        }
        return Ok(None);
    };

    let uuid = metadata.uuid;
    let remote_checkpoint_dir = bucket.join(uuid.to_string());
    if !remote_checkpoint_dir.is_dir() {
        anyhow::bail!(
            "{SOURCE}: the bucket {} lists checkpoint {uuid} in {CHECKPOINT_FILE_NAME} but \
             {} does not exist",
            bucket.display(),
            remote_checkpoint_dir.display()
        );
    }
    let remote_state = remote_checkpoint_dir.join(STATE_FILE);
    if !remote_state.is_file() {
        anyhow::bail!(
            "{SOURCE}: checkpoint {uuid} in the bucket {} has no {STATE_FILE}, so the pipeline \
             cannot resume from it",
            bucket.display()
        );
    }

    fs::create_dir_all(local_root).map_err(|error| {
        anyhow::anyhow!(
            "{SOURCE}: cannot create the storage directory {}: {error}",
            local_root.display()
        )
    })?;
    let mut bytes = copy_tree(&remote_checkpoint_dir, &local_root.join(uuid.to_string()))?;
    // The batches a checkpoint references live at the storage root, and the
    // bucket keeps them at its own root. Copy every root file so that whatever
    // the checkpoint references is present; the catalog is rewritten below and
    // the root `state.json` is fixed up afterwards.
    for entry in read_dir(bucket)? {
        let name = entry.file_name();
        if name == OsString::from(CHECKPOINT_FILE_NAME) {
            continue;
        }
        if entry.file_type()?.is_dir() {
            // The only directory a push keeps at the bucket root is the step
            // journal (checkpoint data lives under its own uuid directory,
            // copied above); recreate it so the restorer can `readdir` it.
            let name = name.to_string_lossy();
            if CHECKPOINT_ROOT_FILES.contains(&&*name) {
                bytes += copy_tree(&entry.path(), &local_root.join(&*name))?;
            }
            continue;
        }
        bytes += copy_file(&entry.path(), &local_root.join(entry.file_name()))?;
    }
    // Publish the catalog entry before the root pointer, mirroring the order in
    // which the controller commits a checkpoint: garbage collection only keeps
    // files the catalog references, so a root pointer to an uncatalogued
    // checkpoint would have its files deleted.
    upsert_catalog(local_root, &metadata)?;
    // The root `state.json` names the checkpoint a starting pipeline resumes
    // from. Installing the pulled checkpoint's own copy is what makes
    // `start_from_checkpoint` take effect; the bucket's root copy still names
    // whichever checkpoint was pushed last.
    copy_file(&remote_state, &local_root.join(STATE_FILE))?;
    Ok(Some((metadata, bytes)))
}

// -------------------------------------------------------------------------
// Listing
// -------------------------------------------------------------------------

/// Lists the checkpoints the bucket's catalog records. A bucket that does not
/// exist yet holds none.
fn list_bucket(bucket: &Path) -> anyhow::Result<Vec<RemoteCheckpoint>> {
    Ok(read_catalog(bucket)?
        .into_iter()
        .map(|metadata| RemoteCheckpoint {
            uuid: metadata.uuid,
        })
        .collect())
}

// -------------------------------------------------------------------------
// Filesystem helpers
// -------------------------------------------------------------------------

/// Returns `true` when both paths name the same directory by value. The paths
/// need not exist, so this compares them as written rather than canonicalizing.
fn same_dir(left: &Path, right: &Path) -> bool {
    left == right
}

/// Converts a storage path into a path relative to the storage root.
fn relative_path(storage_path: &StoragePath) -> anyhow::Result<PathBuf> {
    let relative = PathBuf::from(storage_path.to_string().trim_start_matches('/'));
    if relative
        .components()
        .any(|component| !matches!(component, Component::Normal(_)))
    {
        anyhow::bail!(
            "{SOURCE}: `{storage_path}` is not a plain path below the storage root; refusing to \
             copy it"
        );
    }
    Ok(relative)
}

fn read_dir(dir: &Path) -> anyhow::Result<Vec<fs::DirEntry>> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(dir).map_err(|error| {
        anyhow::anyhow!(
            "{SOURCE}: cannot list the bucket directory {}: {error}",
            dir.display()
        )
    })? {
        entries.push(entry?);
    }
    Ok(entries)
}

fn copy_file(source: &Path, destination: &Path) -> anyhow::Result<u64> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(source, destination).map_err(|error| {
        anyhow::anyhow!(
            "{SOURCE}: cannot copy {} to {}: {error}",
            source.display(),
            destination.display()
        )
    })
}

/// Copies the whole tree rooted at `source` below `destination`, and returns
/// the number of bytes copied.
fn copy_tree(source: &Path, destination: &Path) -> anyhow::Result<u64> {
    fs::create_dir_all(destination)?;
    let mut bytes = 0;
    for entry in read_dir(source)? {
        let target = destination.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            bytes += copy_tree(&entry.path(), &target)?;
        } else {
            bytes += copy_file(&entry.path(), &target)?;
        }
    }
    Ok(bytes)
}

fn metrics(started: Instant, bytes: u64) -> CheckpointSyncMetrics {
    let duration = started.elapsed();
    let seconds = duration.as_secs_f64();
    CheckpointSyncMetrics {
        duration,
        speed: if seconds > 0.0 {
            (bytes as f64 / seconds) as u64
        } else {
            0
        },
        bytes,
    }
}

inventory::submit! {
    &LocalDirSynchronizer as &dyn CheckpointSynchronizer
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicI64;

    use feldera_storage::checkpoint_synchronizer::SYNCHRONIZER;

    use super::*;

    /// Builds the on-disk files a checkpoint consists of: the catalog entry, the
    /// checkpoint directory with its own `state.json`, and a batch at the
    /// storage root.
    fn checkpoint(uuid: uuid::Uuid) -> CheckpointMetadata {
        CheckpointMetadata {
            uuid,
            identifier: None,
            fingerprint: 0xfeed,
            size: None,
            steps: Some(7),
            processed_records: Some(11),
        }
    }

    fn write_checkpoint(root: &Path, metadata: &CheckpointMetadata, batches: &[&str]) {
        let dir = root.join(metadata.uuid.to_string());
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("CHECKPOINT"), b"").unwrap();
        fs::write(dir.join(STATE_FILE), metadata.uuid.to_string()).unwrap();
        fs::write(
            dir.join("dependencies.json"),
            serde_json::to_vec(&serde_json::json!({ "batches": batches, "state_files": [] }))
                .unwrap(),
        )
        .unwrap();
        for batch in batches {
            fs::write(root.join(batch), batch.as_bytes()).unwrap();
        }
        for name in CHECKPOINT_ROOT_FILES {
            // Mirror the runtime layout: the step journal is a directory of
            // per-step journals, not a single file.
            let journal = root.join(name);
            fs::create_dir_all(&journal).unwrap();
            fs::write(journal.join("s0.journal"), b"journal record").unwrap();
        }
        upsert_catalog(root, metadata).unwrap();
    }

    fn absolute(dir: &Path) -> SyncConfig {
        SyncConfig {
            bucket: dir.to_str().unwrap().to_owned(),
            ..SyncConfig::default()
        }
    }

    fn uuid(index: u128) -> uuid::Uuid {
        uuid::Uuid::from_u128(index)
    }

    // -- registration -----------------------------------------------------

    #[test]
    fn synchronizer_is_registered_in_inventory() {
        let registered: Vec<&'static dyn CheckpointSynchronizer> =
            inventory::iter::<&dyn CheckpointSynchronizer>()
                .into_iter()
                .copied()
                .collect();
        assert_eq!(
            registered.len(),
            1,
            "exactly one synchronizer must be registered, otherwise the inventory lookup picks \
             one at random"
        );
    }

    #[test]
    fn synchronizer_static_resolves_to_this_crate() {
        let synchronizer: &'static dyn CheckpointSynchronizer = *SYNCHRONIZER;
        let bucket = tempfile::tempdir().unwrap();
        let listed = synchronizer.list_remote(absolute(bucket.path())).unwrap();
        assert!(listed.is_empty());
    }

    // -- configuration ----------------------------------------------------

    #[test]
    fn bucket_accepts_an_absolute_path() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(bucket_dir(&absolute(dir.path()), None).unwrap(), dir.path());
    }

    #[test]
    fn bucket_accepts_a_file_url() {
        let dir = tempfile::tempdir().unwrap();
        let config = SyncConfig {
            bucket: format!("file://{}", dir.path().display()),
            ..SyncConfig::default()
        };
        assert_eq!(bucket_dir(&config, None).unwrap(), dir.path());
    }

    #[test]
    fn bucket_rejects_an_object_store_scheme() {
        let config = SyncConfig {
            bucket: "s3://my-bucket/checkpoints".to_owned(),
            ..SyncConfig::default()
        };
        let error =
            bucket_dir(&config, None).expect_err("an s3 bucket cannot be a local directory");
        assert!(
            error.to_string().contains("s3"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn bucket_rejects_a_relative_path() {
        let config = SyncConfig {
            bucket: "checkpoints".to_owned(),
            ..SyncConfig::default()
        };
        let error = bucket_dir(&config, None).expect_err("a relative bucket is ambiguous");
        assert!(
            error.to_string().contains("absolute"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn bucket_rejects_an_empty_bucket() {
        let error = bucket_dir(&SyncConfig::default(), None)
            .expect_err("an empty bucket names no directory");
        assert!(
            error.to_string().contains("empty"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn bucket_separates_multihost_pipelines() {
        let dir = tempfile::tempdir().unwrap();
        let host_info = HostInfo {
            host_idx: 2,
            n_hosts: 3,
        };
        assert_eq!(
            bucket_dir(&absolute(dir.path()), Some(&host_info)).unwrap(),
            dir.path().join("host2")
        );
    }

    // -- push -------------------------------------------------------------

    #[test]
    fn push_copies_the_checkpoint_the_batches_and_the_catalog() {
        let storage = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        let metadata = checkpoint(uuid(1));
        write_checkpoint(storage.path(), &metadata, &["w0.feldera"]);

        let batches = [StoragePath::from("w0.feldera")];
        let bytes =
            push_checkpoint(storage.path(), bucket.path(), metadata.uuid, &batches).unwrap();
        assert!(bytes > 0, "a push must report the bytes it transferred");

        let pushed = bucket.path().join(metadata.uuid.to_string());
        assert!(pushed.join(STATE_FILE).is_file());
        assert!(pushed.join("CHECKPOINT").is_file());
        assert!(bucket.path().join("w0.feldera").is_file());
        assert!(
            bucket.path().join(STEPS_FILE).join("s0.journal").is_file(),
            "a checkpoint is not resumable without the root-level step journal, which is a \
             directory at runtime"
        );
        assert_eq!(read_catalog(bucket.path()).unwrap(), vec![metadata]);
    }

    #[test]
    fn push_tolerates_a_missing_step_journal() {
        let storage = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        let metadata = checkpoint(uuid(1));
        write_checkpoint(storage.path(), &metadata, &["w0.feldera"]);
        fs::remove_dir_all(storage.path().join(STEPS_FILE)).unwrap();

        push_checkpoint(
            storage.path(),
            bucket.path(),
            metadata.uuid,
            &[StoragePath::from("w0.feldera")],
        )
        .unwrap();

        assert!(
            !bucket.path().join(STEPS_FILE).exists(),
            "a pipeline without fault tolerance has no step journal to push"
        );
        assert_eq!(read_catalog(bucket.path()).unwrap(), vec![metadata]);
    }

    #[test]
    fn push_refreshes_the_entry_of_an_already_pushed_checkpoint() {
        let storage = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        let metadata = checkpoint(uuid(1));
        write_checkpoint(storage.path(), &metadata, &["w0.feldera"]);
        let batches = [StoragePath::from("w0.feldera")];

        push_checkpoint(storage.path(), bucket.path(), metadata.uuid, &batches).unwrap();
        push_checkpoint(storage.path(), bucket.path(), metadata.uuid, &batches).unwrap();

        assert_eq!(
            read_catalog(bucket.path()).unwrap().len(),
            1,
            "pushing the same checkpoint twice must not duplicate its catalog entry"
        );
    }

    #[test]
    fn push_rejects_a_checkpoint_that_is_not_in_local_storage() {
        let storage = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        let error = push_checkpoint(storage.path(), bucket.path(), uuid(9), &[]).unwrap_err();
        assert!(
            error.to_string().contains("not in local storage"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn push_rejects_a_checkpoint_that_has_no_catalog_entry() {
        let storage = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        let metadata = checkpoint(uuid(1));
        write_checkpoint(storage.path(), &metadata, &[]);
        fs::remove_file(catalog_path(storage.path())).unwrap();

        let error = push_checkpoint(storage.path(), bucket.path(), metadata.uuid, &[]).unwrap_err();
        assert!(
            error.to_string().contains("local checkpoint catalog"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn push_rejects_the_storage_directory_as_bucket() {
        let storage = tempfile::tempdir().unwrap();
        let error = push_checkpoint(storage.path(), storage.path(), uuid(1), &[]).unwrap_err();
        assert!(
            error.to_string().contains("onto itself"),
            "unexpected error: {error}"
        );
    }

    // -- pull -------------------------------------------------------------

    #[test]
    fn pull_installs_the_checkpoint_and_points_storage_at_it() {
        let source = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        let metadata = checkpoint(uuid(1));
        write_checkpoint(source.path(), &metadata, &["w0.feldera"]);
        push_checkpoint(
            source.path(),
            bucket.path(),
            metadata.uuid,
            &[StoragePath::from("w0.feldera")],
        )
        .unwrap();

        let target = tempfile::tempdir().unwrap();
        let pulled = pull_checkpoint(
            target.path(),
            bucket.path(),
            Some(&StartFromCheckpoint::Latest),
            false,
        )
        .unwrap()
        .expect("the bucket holds a checkpoint");

        assert_eq!(pulled.0, metadata);
        assert!(pulled.1 > 0);
        assert!(target
            .path()
            .join(metadata.uuid.to_string())
            .join("CHECKPOINT")
            .is_file());
        assert!(target.path().join("w0.feldera").is_file());
        assert!(
            target.path().join(STEPS_FILE).join("s0.journal").is_file(),
            "the step journal must come back with the checkpoint, otherwise the pipeline cannot \
             replay through it"
        );
        assert_eq!(read_catalog(target.path()).unwrap(), vec![metadata.clone()]);
        assert_eq!(
            fs::read_to_string(target.path().join(STATE_FILE)).unwrap(),
            metadata.uuid.to_string(),
            "the root `state.json` must name the checkpoint the pipeline resumes from"
        );
    }

    /// Regression for the first cross-pipeline restore: `steps.bin` is a
    /// directory at runtime that may still be empty, but a restorer without it
    /// fails to initialize (`steps.bin: readdir failed: entity not found`), so
    /// both push and pull must carry the directory itself, not just its files.
    #[test]
    fn pull_recreates_the_step_journal_even_when_it_is_empty() {
        let source = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        let metadata = checkpoint(uuid(1));
        write_checkpoint(source.path(), &metadata, &["w0.feldera"]);
        fs::remove_file(source.path().join(STEPS_FILE).join("s0.journal")).unwrap();

        push_checkpoint(
            source.path(),
            bucket.path(),
            metadata.uuid,
            &[StoragePath::from("w0.feldera")],
        )
        .unwrap();
        assert!(
            bucket.path().join(STEPS_FILE).is_dir(),
            "an empty journal must still be pushed as a directory"
        );

        let target = tempfile::tempdir().unwrap();
        pull_checkpoint(
            target.path(),
            bucket.path(),
            Some(&StartFromCheckpoint::Latest),
            false,
        )
        .unwrap()
        .expect("the bucket holds a checkpoint");
        assert!(
            target.path().join(STEPS_FILE).is_dir(),
            "the restorer opens the journal with readdir, so the empty directory must exist"
        );
    }

    #[test]
    fn pull_selects_the_newest_checkpoint_for_latest() {
        let source = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        for index in [1, 2] {
            let metadata = checkpoint(uuid(index));
            write_checkpoint(source.path(), &metadata, &["w0.feldera"]);
            push_checkpoint(
                source.path(),
                bucket.path(),
                metadata.uuid,
                &[StoragePath::from("w0.feldera")],
            )
            .unwrap();
        }

        let target = tempfile::tempdir().unwrap();
        let pulled = pull_checkpoint(
            target.path(),
            bucket.path(),
            Some(&StartFromCheckpoint::Latest),
            false,
        )
        .unwrap()
        .unwrap();
        assert_eq!(pulled.0.uuid, uuid(2));
    }

    #[test]
    fn pull_honors_a_specific_checkpoint_uuid() {
        let source = tempfile::tempdir().unwrap();
        let bucket = tempfile::tempdir().unwrap();
        for index in [1, 2] {
            let metadata = checkpoint(uuid(index));
            write_checkpoint(source.path(), &metadata, &["w0.feldera"]);
            push_checkpoint(
                source.path(),
                bucket.path(),
                metadata.uuid,
                &[StoragePath::from("w0.feldera")],
            )
            .unwrap();
        }

        let target = tempfile::tempdir().unwrap();
        let pulled = pull_checkpoint(
            target.path(),
            bucket.path(),
            Some(&StartFromCheckpoint::Uuid(uuid(1))),
            false,
        )
        .unwrap()
        .unwrap();
        assert_eq!(pulled.0.uuid, uuid(1));
        assert_eq!(
            fs::read_to_string(target.path().join(STATE_FILE)).unwrap(),
            uuid(1).to_string(),
            "a named checkpoint must win over the newest one"
        );
    }

    #[test]
    fn pull_reports_a_missing_named_checkpoint_when_required() {
        let bucket = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        let error = pull_checkpoint(
            target.path(),
            bucket.path(),
            Some(&StartFromCheckpoint::Uuid(uuid(3))),
            true,
        )
        .unwrap_err();
        assert!(
            error.to_string().contains("no checkpoint"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn pull_of_an_empty_bucket_leaves_storage_untouched() {
        let bucket = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        let pulled = pull_checkpoint(
            target.path(),
            bucket.path(),
            Some(&StartFromCheckpoint::Latest),
            false,
        )
        .unwrap();
        assert!(pulled.is_none());
        assert!(
            fs::read_dir(target.path()).unwrap().next().is_none(),
            "a pipeline that finds no remote checkpoint must keep its own storage"
        );
    }

    #[test]
    fn pull_rejects_a_catalog_entry_without_a_checkpoint_directory() {
        let bucket = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        write_catalog(bucket.path(), &[checkpoint(uuid(1))]).unwrap();
        let error = pull_checkpoint(
            target.path(),
            bucket.path(),
            Some(&StartFromCheckpoint::Latest),
            false,
        )
        .unwrap_err();
        assert!(
            error.to_string().contains("does not exist"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn pull_rejects_the_storage_directory_as_bucket() {
        let storage = tempfile::tempdir().unwrap();
        let error = pull_checkpoint(
            storage.path(),
            storage.path(),
            Some(&StartFromCheckpoint::Latest),
            false,
        )
        .unwrap_err();
        assert!(
            error.to_string().contains("onto itself"),
            "unexpected error: {error}"
        );
    }

    // -- listing ----------------------------------------------------------

    #[test]
    fn list_reports_every_catalogued_checkpoint() {
        let bucket = tempfile::tempdir().unwrap();
        write_catalog(bucket.path(), &[checkpoint(uuid(1)), checkpoint(uuid(2))]).unwrap();

        let listed = list_bucket(bucket.path()).unwrap();
        let uuids: Vec<uuid::Uuid> = listed.into_iter().map(|remote| remote.uuid).collect();
        assert_eq!(uuids, vec![uuid(1), uuid(2)]);
    }

    #[test]
    fn list_of_a_missing_bucket_is_empty() {
        let bucket = tempfile::tempdir().unwrap();
        let listed = list_bucket(&bucket.path().join("not-created")).unwrap();
        assert!(listed.is_empty());
    }

    #[test]
    fn list_rejects_a_malformed_catalog() {
        let bucket = tempfile::tempdir().unwrap();
        fs::write(catalog_path(bucket.path()), b"{ not json").unwrap();
        let error = list_bucket(bucket.path()).unwrap_err();
        assert!(
            error.to_string().contains("malformed"),
            "unexpected error: {error}"
        );
    }

    // -- trait-level behavior --------------------------------------------

    /// Storage backend double for tests that must reach the synchronizer
    /// without touching a real backend. Every method except
    /// `file_system_path` is unreachable: a test that calls one has a bug.
    #[derive(Debug)]
    struct UnusedBackend {
        path: PathBuf,
    }

    impl StorageBackend for UnusedBackend {
        fn create_named(
            &self,
            _name: &StoragePath,
        ) -> Result<Box<dyn feldera_storage::FileWriter>, feldera_storage::error::StorageError>
        {
            unreachable!("the code under test must not create files")
        }

        fn open(
            &self,
            _name: &StoragePath,
        ) -> Result<Arc<dyn feldera_storage::FileReader>, feldera_storage::error::StorageError>
        {
            unreachable!("the code under test must not open files")
        }

        fn file_system_path(&self) -> Option<&Path> {
            Some(&self.path)
        }

        fn list(
            &self,
            _parent: &StoragePath,
            _callback: &mut dyn FnMut(feldera_storage::DirEntry),
        ) -> Result<(), feldera_storage::error::StorageError> {
            unreachable!("the code under test must not list files")
        }

        fn delete(&self, _name: &StoragePath) -> Result<(), feldera_storage::error::StorageError> {
            unreachable!("the code under test must not delete files")
        }

        fn delete_recursive(
            &self,
            _name: &StoragePath,
        ) -> Result<(), feldera_storage::error::StorageError> {
            unreachable!("the code under test must not delete files")
        }

        fn usage(&self) -> Arc<AtomicI64> {
            Arc::new(AtomicI64::new(0))
        }
    }

    fn backend(path: &Path) -> Arc<dyn StorageBackend> {
        Arc::new(UnusedBackend {
            path: path.to_path_buf(),
        })
    }

    fn pipeline() -> PipelineIdentity {
        PipelineIdentity {
            name: "pipeline-test".to_owned(),
            given_name: None,
        }
    }

    #[test]
    fn pull_from_an_empty_bucket_does_not_touch_storage() {
        let bucket = tempfile::tempdir().unwrap();
        let storage = tempfile::tempdir().unwrap();
        let (metadata, sync_metrics) = LocalDirSynchronizer
            .pull(
                backend(storage.path()),
                SyncConfig {
                    bucket: bucket.path().to_str().unwrap().to_owned(),
                    start_from_checkpoint: Some(StartFromCheckpoint::Latest),
                    ..SyncConfig::default()
                },
                None,
                false,
                pipeline(),
            )
            .expect("an empty bucket is not an error unless the pipeline says so");
        assert!(metadata.uuid.is_nil(), "no checkpoint was pulled");
        assert!(sync_metrics.is_none(), "nothing was transferred");
    }

    #[test]
    fn pull_from_an_empty_bucket_fails_when_the_pipeline_requires_a_checkpoint() {
        let bucket = tempfile::tempdir().unwrap();
        let storage = tempfile::tempdir().unwrap();
        let error = LocalDirSynchronizer
            .pull(
                backend(storage.path()),
                SyncConfig {
                    bucket: bucket.path().to_str().unwrap().to_owned(),
                    start_from_checkpoint: Some(StartFromCheckpoint::Latest),
                    fail_if_no_checkpoint: true,
                    ..SyncConfig::default()
                },
                None,
                false,
                pipeline(),
            )
            .expect_err("`fail_if_no_checkpoint` must turn an empty bucket into a failure");
        assert!(
            error.to_string().contains("no checkpoint"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn pull_rejects_an_object_store_bucket() {
        let storage = tempfile::tempdir().unwrap();
        let error = LocalDirSynchronizer
            .pull(
                backend(storage.path()),
                SyncConfig {
                    bucket: "s3://my-bucket/checkpoints".to_owned(),
                    start_from_checkpoint: Some(StartFromCheckpoint::Latest),
                    ..SyncConfig::default()
                },
                None,
                false,
                pipeline(),
            )
            .expect_err("this build cannot read an s3 bucket");
        assert!(
            error.to_string().contains("s3"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn push_rejects_the_nil_checkpoint() {
        let bucket = tempfile::tempdir().unwrap();
        let storage = tempfile::tempdir().unwrap();
        let error = LocalDirSynchronizer
            .push(
                uuid::Uuid::nil(),
                backend(storage.path()),
                SyncConfig {
                    bucket: bucket.path().to_str().unwrap().to_owned(),
                    ..SyncConfig::default()
                },
                None,
                pipeline(),
            )
            .expect_err("a push must name the checkpoint it synchronizes");
        assert!(
            error.to_string().contains("nil checkpoint"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn take_ownership_reports_unsupported() {
        let storage = tempfile::tempdir().unwrap();
        let error = LocalDirSynchronizer
            .take_ownership(backend(storage.path()), SyncConfig::default(), pipeline())
            .expect_err("a local directory has no bucket ownership to claim");
        assert!(
            error.to_string().contains("take_bucket_ownership"),
            "unexpected error: {error}"
        );
    }

    /// Guards against a storage backend that silently stops reporting its path:
    /// synchronization would then fail for every pipeline.
    #[test]
    fn local_root_requires_a_filesystem_path() {
        #[derive(Debug)]
        struct NoPathBackend;

        impl StorageBackend for NoPathBackend {
            fn create_named(
                &self,
                _name: &StoragePath,
            ) -> Result<Box<dyn feldera_storage::FileWriter>, feldera_storage::error::StorageError>
            {
                unreachable!()
            }

            fn open(
                &self,
                _name: &StoragePath,
            ) -> Result<Arc<dyn feldera_storage::FileReader>, feldera_storage::error::StorageError>
            {
                unreachable!()
            }

            fn list(
                &self,
                _parent: &StoragePath,
                _callback: &mut dyn FnMut(feldera_storage::DirEntry),
            ) -> Result<(), feldera_storage::error::StorageError> {
                unreachable!()
            }

            fn delete(
                &self,
                _name: &StoragePath,
            ) -> Result<(), feldera_storage::error::StorageError> {
                unreachable!()
            }

            fn delete_recursive(
                &self,
                _name: &StoragePath,
            ) -> Result<(), feldera_storage::error::StorageError> {
                unreachable!()
            }

            fn usage(&self) -> Arc<AtomicI64> {
                Arc::new(AtomicI64::new(0))
            }
        }

        let error = local_root(&(Arc::new(NoPathBackend) as Arc<dyn StorageBackend>))
            .expect_err("a backend without a filesystem path cannot be synchronized");
        assert!(
            error.to_string().contains("filesystem path"),
            "unexpected error: {error}"
        );
    }
}
