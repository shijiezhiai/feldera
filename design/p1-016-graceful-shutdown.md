# P1-016 — Graceful shutdown and resume

A pipeline pod can stop in two ways, and only one of them was saving state. This
note records what was missing, what now happens, and what the kind cluster
shows.

## 1. Two ways to stop, one of them silent

The manager stops a pipeline by calling `POST /v0/pipelines/{name}/stop` with
`force=false`, which makes the controller take an exit checkpoint and then
terminates the pod. Kubernetes stops a pod for reasons the manager did not
choose: a `kubectl delete pod`, a `StatefulSet` scale-down, a node drain, an
eviction. In that path the kubelet sends `SIGTERM` to the container's PID 1 and,
`terminationGracePeriodSeconds` later, `SIGKILL`.

`deploy/pipeline-entrypoint.sh:42` runs `exec "${binary}" "$@"`, so the signal
reaches the pipeline process itself. Before this change nothing in the pipeline
listened for it, so the default disposition applied: the process died
immediately, without a checkpoint. The storage claim survived, holding whatever
the last checkpoint wrote — possibly nothing.

The asymmetry is easy to miss in testing, because the path a test normally
exercises (`/stop`) is the one that works.

## 2. The second gap: a volume with no backend

`crates/pipeline-manager/src/runner/kubernetes_runner.rs` provisions a
`PersistentVolumeClaim` per pipeline and mounts it at `STORAGE_MOUNT_BASE`, and
`generate_storage_config` reports the directory inside that mount. What it never
did was fill in `PipelineConfig::global.storage`, the field that names the
backend. `PipelineConfig::storage()` returns `None` unless both halves are
present, and `can_checkpoint()` then reports no storage at all.

The consequence for this work item: a fault-tolerant pipeline failed with
`FtRequiresStorage` on a volume it had just provisioned and mounted, and a
non-fault-tolerant pipeline had no checkpoint backend for the new `SIGTERM`
handler to write to.

The fix is a second method on `PipelineExecutor`,
`generate_storage_options()`, whose default returns `None` so no other runner
changes behaviour, and whose Kubernetes implementation names a file backend. The
automaton fills `global.storage` from it — but only when the user asked for
fault tolerance, and only when the pipeline configuration does not already name
a backend.

Two decisions are worth stating:

- **The user keeps the last word.** The automaton fills a gap; it does not
  override. A pipeline configuration that already names object storage keeps it,
  even though the pod also has a volume.
- **A plain pipeline is untouched.** Without `fault_tolerance`, `global.storage`
  stays `None`, exactly as before: no storage, no checkpointing, no volume
  access. Making every pipeline fault-tolerant would change the durability and
  the failure behaviour of deployments that never asked for either.

## 3. The shutdown handler

`crates/adapters/src/server.rs` gains `spawn_shutdown_handler`, installed just
before the HTTP server starts serving. It registers a `SIGTERM` stream, waits for
one signal, calls `begin_suspend`, and awaits the suspend task before exiting.

`begin_suspend` is the old `/suspend` body, lifted out so that both paths share
one implementation. That sharing is the point: a shutdown that checkpointed
differently from an explicit suspend would lose records the deployment's owner
believes are durable. It returns `Option<JoinHandle<()>>` so that the caller who
must wait (the signal handler) can, and the caller that must not (the HTTP
handler, which answers `202` and lets the client poll `/status`) can drop it.

Because the transition to `Suspended` happens once and is never reversed,
`begin_suspend` returns `None` for every caller after the first. That is what
keeps a `SIGTERM` arriving during an in-flight `/suspend` — a `kubectl delete`
during a manager-initiated stop — from starting a second checkpoint into the
same storage directory.

Three smaller behaviours:

- `Standby` is refused by `/suspend` as before, but `begin_suspend` returns
  `None` rather than panicking, because the signal handler must not panic.
- If the handler cannot be installed (an unusual environment), the pipeline logs
  an error and keeps running. A missing handler degrades to the old behaviour;
  failing the deployment would take down a healthy pipeline over a listener.
- On non-Unix targets the handler is a no-op: there is no `SIGTERM`, and the
  pipeline runs on Linux.

`terminationGracePeriodSeconds` bounds the checkpoint. The handler exits the
process as soon as the checkpoint completes, so the whole grace period is
available to the checkpoint rather than being partly spent on an idle HTTP
server.

## 4. Tests

| Test | What it pins |
| --- | --- |
| `the_runner_names_a_file_backend_for_its_volume` | The Kubernetes runner returns a file backend, not object storage and not `None`. |
| `the_storage_path_lives_under_the_mount_point` | The reported directory is inside the mounted volume, so the path and the backend describe one place. |
| `a_second_suspend_starts_no_second_checkpoint` | A second `SIGTERM`/suspend during an in-flight suspend gets no task, so two checkpoints cannot race. |
| `suspending_a_standby_pipeline_is_refused` | The `/suspend` status code on `Standby` is unchanged. |
| `completed_suspend_is_reported_before_the_phase_is_recorded` | The ordering the refactor had to preserve. |
| `suspend_does_not_overwrite_a_fatal_error` | A failed suspend is still reported as an error rather than a clean stop. |

Counts: `cargo +1.96.1 test -p pipeline-manager --lib runner::` = 100 passed;
`cargo +1.96.1 test -p dbsp_adapters --lib server::test_http_helpers` = 11
passed.

The `SIGTERM` path itself is not unit-tested — a test would have to send a real
signal to the test process. It is verified in the cluster instead (§5, step 6),
which is also the only place the kubelet's behaviour is real.

## 5. Verification in the kind cluster

`scripts/e2e-k8s-graceful.sh`:

1. Installs the chart with the pipeline template from
   `deploy/pipeline-template.example.yaml`. The script reads the template's
   `terminationGracePeriodSeconds` rather than restating it, so the two cannot
   drift apart.
2. Creates a pipeline with `fault_tolerance.model=at_least_once` and
   `checkpoint_interval_secs=10`, starts it, and pushes N records through the
   HTTP API.
3. Waits until `/v0/pipelines/{name}` reports a checkpoint in
   `storage_status_details`, so the storage directory is known to be writable.
   The check reads that field rather than guessing the on-disk layout, which is
   `<storage>/<uuid>/` and not `<storage>/checkpoints/`.
4. Scales the `StatefulSet` to zero, bypassing the manager, so the stop is the
   kubelet's `SIGTERM` and not the API's `/suspend`. Scaling rather than
   deleting the pod matters: a pod a `StatefulSet` owns is recreated as soon as
   it goes, so `kubectl delete pod` leaves no stopped window to resume from, and
   its log and exit code disappear with it.
5. Asserts the pod's log contains `SIGTERM received` and `exit checkpoint
   written` — the handler ran and finished inside the grace period. The log is
   followed in the background from before the scale-down, because a terminated
   pod's log is gone once the controller reclaims the pod.
6. Asserts the pod's termination state was `exitCode 0` and not `137`
   (`SIGKILL`), which is the observable difference between "checkpointed and
   stopped" and "out of time". This is best-effort: the controller may reclaim
   the pod first, in which case the log line in step 5 is the evidence.
7. Starts the pipeline again with no `bootstrap_policy` argument. The default is
   `await_approval`, which the manager only asks for when there is no checkpoint
   to restore; reaching `Running` without an approval therefore proves the
   pipeline restored rather than bootstrapped. The record count must match the
   count the first run ingested, which a fresh bootstrap could not reproduce
   because nothing replays the HTTP pushes.
8. Stops and deletes the pipeline, then asserts no `StatefulSet`, `Pod`,
   `Service`, `NetworkPolicy` or `PVC` carrying the pipeline label remains.

## 6. Recorded numbers

| Step | Measured |
| --- | --- |
| Chart install | 12 s |
| Pipeline compile (unoptimized) + deploy → `Running` | 104 s |
| Records ingested before the kill | 1000 (HTTP push, < 1 s) |
| First scheduled checkpoint | reported by `/v0/pipelines/{name}` before the kill |
| `SIGTERM` → exit checkpoint written | **1 s** |
| Pod termination | `exitCode 0` |
| Restart → `Running` with restored state | 17 s, view still reports 1000 |
| Whole run | 128 s |

The restart reports the same 1000 rows the first run ingested. That number is
what distinguishes a restore from a bootstrap: the table is fed over HTTP, so a
pipeline that bootstrapped instead would report 0.

## 7. What is out of scope

- **Object storage.** `generate_storage_options` names a file backend because
  that is what the runner mounts. A deployment that wants S3 sets
  `global.storage` itself; automatic S3 provisioning is P3's backfill work.
- **`preStop` hooks.** The handler makes one unnecessary: the process listens
  for the signal directly. A `preStop` that slept would only spend the grace
  period.
- **At-least-once across the suspend boundary.** The checkpoint is the recovery
  point, so records written after it are re-read from the source on resume,
  which is the platform's existing delivery semantics; this work item makes the
  checkpoint happen, it does not change the semantics.
- **Backoff and retry for a failed checkpoint.** A failed suspend is reported,
  as before.
