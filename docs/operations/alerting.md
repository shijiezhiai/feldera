# Alerting and the on-call runbook

The dashboard answers "what is happening". This page is for the other question:
an alert is firing, the engineer who was paged has never seen this system, and
what they need is the four steps that end the page.

Every alert in `deploy/config/feldera-alerts.yml` carries a `runbook_url` that
points at a section of this page. The anchors below are load-bearing: rename a
heading and the alert's link breaks.

| alert | severity | page on |
|---|---|---|
| `FelderaPipelineNotRunning` | warning | a pipeline has not reached Running for 15 minutes |
| `FelderaCheckpointFailing` | critical | more than 3 permanent checkpoint failures in 15 minutes |
| `FelderaCheckpointStale` | critical | no successful checkpoint for 3 intervals |
| `FelderaStorageVolumeFillingUp` | warning | the storage volume is over 80% full |
| `FelderaCompileQueueSlow` | warning | compilation has been queued or running for 30 minutes |
| `FelderaProvisioningTimeout` | critical | provisioning has taken 30 minutes |
| `FelderaScrapeTargetDown` | critical | Prometheus cannot scrape a target |

## How the rules are wired

`deploy/config/feldera-alerts.yml` holds the rules. Three things load it:

- Docker Compose: `deploy/config/prometheus.yml` names it in `rule_files`, and
  `deploy/docker-compose.yml` mounts it into the Prometheus container.
- Kubernetes: `deploy/config/prometheus-k8s.yml` names it, and the monitoring
  e2e check puts it in the same ConfigMap as that file.
- The rules' own injection tests: `deploy/config/feldera-alerts.test.yml`.

The rules read series from two places. Per-pipeline series (`feldera_*`,
`pipeline_status*`) come from the pipeline's own `/metrics`, which the runner
publishes on a Service labelled `feldera.com/metrics-scrape=true`. Manager-side
series (`pipeline_program_status*`) come from the manager's `/v0/metrics`. A
rule that stops matching usually means one of those scrape targets is gone, so
check `up` before believing an alert is about a pipeline.

Whether a rule still parses and still fires is a build-time question, not an
operational one:

```bash
promtool check rules deploy/config/feldera-alerts.yml
promtool test rules deploy/config/feldera-alerts.test.yml
```

Both run with no cluster and no network. The test file injects synthetic series
for every rule and asserts both directions: the fault fires the alert, and the
healthy look-alike (a Stopped pipeline, a Standby pipeline, a pipeline with
fault tolerance off) stays quiet. `scripts/e2e-k8s-alerts.sh` is the other
half: it proves a live install exports these series at all.

## FelderaPipelineNotRunning

A pipeline that was asked to run has been sitting in a starting status for more
than 15 minutes. The statuses that count are `Provisioning`, `Initializing`,
`Bootstrapping`, `ConcurrentBootstrapping`, `Synchronizing` and `Replaying`.

This rule deliberately ignores three statuses that are long-lived by design:
`Standby` (P3's HA parks a pipeline for days waiting for failover),
`AwaitingApproval` (a human has to approve bootstrapping and their schedule is
not an incident) and `Coordination` (the multihost handshake, also held for as
long as a standby stands by). A `Stopped` pipeline is where its owner left it.

1. Read the status: `pipeline_status{pipeline_name="..."} == 1`.
2. Read why it is stuck:
   `kubectl -n feldera logs deploy/feldera-controlplane-api-server | grep <name>`
   and the pipeline pod's own log.
3. If it is `Provisioning`, go to
   [FelderaProvisioningTimeout](#felderaprovisioningtimeout): that alert
   escalates the same condition at 30 minutes.
4. If it is `Replaying`, the pipeline is restoring a checkpoint. A large
   pipeline legitimately takes minutes; past 15 it usually means the volume
   holding the checkpoint is slow, so check the PVC's node.

## FelderaCheckpointFailing

More than three checkpoints failed for a *permanent* reason in the last 15
minutes. Temporary failures — a delayed checkpoint, a pending barrier — are not
counted, because they resolve themselves and paging on them would page on
normal operation.

While this fires, fault tolerance makes no progress: the pipeline is still
processing, but a restart would lose everything since the last good checkpoint.

1. The last failure's time:
   `feldera_checkpoint_last_failure_timestamp_seconds`.
2. The reason is in the pipeline log at that timestamp, usually one of: the
   storage volume is full (cross-check
   [FelderaStorageVolumeFillingUp](#felderastoragevolumefillingup)), the
   checkpoint directory is not writable, or a connector's commit failed.
3. If the cause is fixed and the counter keeps climbing, restart the pipeline;
   the counter is per-process and resets.

## FelderaCheckpointStale

The last successful checkpoint is more than three times the configured interval
old. The interval comes from `feldera_checkpoint_interval_seconds`, so the
threshold follows the pipeline's own configuration rather than a constant in the
rule.

The rule skips two cases on purpose. A pipeline with fault tolerance disabled
exports an interval of 0 and never checkpoints. A fault-tolerant pipeline that
has never checkpointed exports a last-success timestamp of 0, and `time() - 0` is
every bit as large as a genuinely stale checkpoint. Both are excluded; a
pipeline whose *first* checkpoint never succeeds is caught by
[FelderaCheckpointFailing](#felderacheckpointfailing) instead.

1. Confirm the pipeline is otherwise healthy:
   `pipeline_status{pipeline_name="..."}`.
2. Compare `feldera_checkpoint_failures_total` with
   `feldera_checkpoint_last_success_timestamp_seconds`. A rising failure count
   sends you to the rule above; a flat failure count with no success at all
   points at the checkpointer thread, which is a bug worth reporting.
3. A pipeline that is Running and checkpointing nothing is a durability
   incident even though it looks fine on a dashboard. Say so in the incident.

## FelderaStorageVolumeFillingUp

The volume holding the pipeline's storage is more than 80% full. This reads the
volume, not Feldera's own usage: `storage_usage_bytes` counts what Feldera wrote
and cannot see journals, logs or another tenant's files on the same volume,
which are exactly what fill it up.

1. Which pipeline and how full: the alert's
   `feldera_storage_volume_total_bytes` and
   `feldera_storage_volume_available_bytes`.
2. Free space or grow the claim. A checkpoint that cannot be written leaves the
   pipeline without a recovery point, so this is not a "later" task even at
   `warning` severity.
3. After freeing space, confirm a checkpoint commits: the last-success gauge
   should move within one interval.

## FelderaCompileQueueSlow

A program has been in `pending`, `compiling_sql` or `compiling_rust` for over 30
minutes. The stage comes from `pipeline_program_status` and the time in it from
`pipeline_program_status_since_timestamp_seconds`.

`pending` means the compile queue is backed up: the manager has accepted the
program and no compiler has taken it. A compiler stage means the compiler is
running long.

1. Which stage: the alert's `program_status` label.
2. `pending`: check that the compiler pod is up and that its queue is moving:
   `kubectl -n feldera get pods -l app=feldera-compiler`.
3. A compiler stage: check the compiler pod's CPU and memory. A cold
   `optimized` build of a large program legitimately takes tens of minutes;
   compare against a previous build of the same program before calling it
   stuck.

## FelderaProvisioningTimeout

Provisioning has taken 30 minutes, past the runner's own deadline. Rule 1 warns
on the same condition at 15 minutes; this one fires when the runner should have
given up and did not, which points at the runner rather than the pipeline.

1. `kubectl -n feldera get pods` and look for a pending pipeline pod.
2. A pod stuck in `Pending` is a scheduling problem: check node capacity with
   `kubectl describe pod <pod>` and the node's allocatable resources.
3. A pod that never appears means the runner did not act. Check the runner's
   log for a lease or API error.

## FelderaScrapeTargetDown

Prometheus has failed to scrape a target for ten minutes. While a target is
down, every rule that reads its series is blind: a dead pipeline and a pipeline
that is fine look identical when neither is scraped.

1. `up{job=~"feldera|feldera-manager|feldera-pipelines"} == 0` tells you which.
2. Check the pod serves `/metrics` at all:
   `kubectl -n feldera exec <pod> -- wget -qO- localhost:8080/metrics | head`.
3. If the pod is healthy but unreachable, the target's Service or the
   NetworkPolicy that admits the monitoring namespace is the suspect. Both are
   created by the runner; `scripts/e2e-k8s-monitoring.sh` checks the same two
   things and is the fastest way to see which one broke.

## When an alert fires that this page does not cover

That is a gap in the page, not a gap in the reader. Add the section here and
point the rule's `runbook_url` at it in the same change, then run
`promtool test rules deploy/config/feldera-alerts.test.yml`: it pins every
`runbook_url`, so a rule whose link does not resolve fails the test.
