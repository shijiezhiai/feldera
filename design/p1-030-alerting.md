# P1-030: the alerting baseline

P1-015 made every install scrapable and drew a dashboard. It deliberately drew
the line at paging: `design/p1-015-monitoring.md` §7 said "The dashboard shows;
it does not page." An operator still had to be looking at a screen to notice a
pipeline that had stopped checkpointing overnight, and several of the ticket's
required alerts had no series to be written against at all.

This work order closes both gaps. It adds six series the rules need, seven
rules built on the existing and new series, a runbook whose headings the rules
link to, and one command that proves the wiring against a real cluster.

Code: `crates/adapters/src/controller.rs`,
`crates/pipeline-manager/src/api/endpoints/metrics.rs`,
`crates/pipeline-manager/src/db/types/program.rs`.
Rules: `deploy/config/feldera-alerts.yml` (+ `feldera-alerts.test.yml`).
Scrape config: `deploy/config/prometheus.yml`, `deploy/config/prometheus-k8s.yml`.
Runbook: `docs/operations/alerting.md`.
Provisions: `deploy/docker-compose.yml`, `scripts/e2e-k8s-monitoring.sh`.
Test: `scripts/e2e-k8s-alerts.sh`.

## 1. What the work order asked for

| Requirement | Where it landed |
| --- | --- |
| Pipeline not Running | `FelderaPipelineNotRunning`, on the new `pipeline_status_since_timestamp_seconds` |
| Checkpoint consecutive failures > 3 | `FelderaCheckpointFailing`, on the new `feldera_checkpoint_failures_total` |
| Checkpoint age > 3× interval | `FelderaCheckpointStale`, on the new last-success timestamp and interval gauges |
| PVC > 80 % full | `FelderaStorageVolumeFillingUp`, on the new volume total/available gauges |
| Compile queue delay | `FelderaCompileQueueSlow`, on the new `pipeline_program_status*` family |
| Provisioning timeout | `FelderaProvisioningTimeout`, on `pipeline_status` + its since gauge |
| Every alert has an injection test | `deploy/config/feldera-alerts.test.yml` (one firing and one quiet case per rule) and `scripts/e2e-k8s-alerts.sh` (live cluster) |
| A runbook link | `runbook_url` on every rule, resolving to a heading in `docs/operations/alerting.md` |

The ticket named `adapter_stats.rs:512-521` as the metric source. That file does
not exist (`crates/feldera-types/src/adapter_stats.rs` is the nearest name, and
it carries no checkpoint timing at all), and neither does any alerting artifact
in the tree: no `PrometheusRule`, no alertmanager config, and `grep -i alert`
matched one sentence in the JSON-logging doc. So this is not a re-wiring of an
existing alert layer; every rule here is new.

## 2. Three of the six rules had no series to read

The heart of the ticket is not the rules, which are short, but the series they
need. Three requirements could not be expressed against what P1-015 exported.

**Checkpoint age needs the interval.** The ticket asks for "age > 3× interval",
so the rule needs both numbers. Age alone could have been computed at scrape
time, but the whole point of comparing against the interval is that a pipeline
configured for 60 s and one configured for 1 h do not share a threshold. The
controller now exports the interval it was configured with
(`crates/adapters/src/controller.rs:1799`), taken from
`FtConfig::checkpoint_interval()`.

The interval is exported as **0 when fault tolerance is off**, and that zero is
load-bearing. A community-edition pipeline with no storage configured cannot
checkpoint at all: P1-015 §2 explains the mechanism. Without the zero, the age
of such a pipeline is `time() - 0`, which is fifty-six years, and the rule would
page every night on a pipeline behaving exactly as designed. With it, the rule
carries `feldera_checkpoint_interval_seconds > 0` and skips them.

**"PVC > 80 %" needs a denominator that exists.** The controller already
exported `storage_usage_bytes`, but that is what Feldera itself has written. It
cannot answer "is the volume filling up", because the volume also holds
journals, container logs, and other tenants' files. The ratio the ticket wants
is unavailable-bytes over total-bytes for the *volume*, so the controller now
reports both, from the same `DiskUsage::from_path` that `api_status()` already
calls. A pipeline storing in an object store or in memory has no volume, and
reports neither series, which is why the rule needs no special case for it.

**"Compile queue delay" needs the manager's side.** Nothing in the manager
exported anything about compilation. It does carry `program_status` and
`program_status_since` per pipeline, so the manager's `/metrics` grew two
families: one sample per stage per pipeline (`pipeline_program_status`, eight
per pipeline, always exactly one at 1) and one sample naming the current stage
and when it began (`pipeline_program_status_since_timestamp_seconds`).

The second family intentionally does **not** expand to eight samples. Doing so
would mean six samples whose timestamp claims "this stage began at a time when
it was not the current stage", which is a lie a dashboard would eventually
display. One sample per pipeline, labelled with the stage it belongs to, is the
honest shape; the cost is that a query must select the stage by label rather
than by value.

`ProgramStatus::ALL` exists so the first family cannot silently lose a stage: a
new variant that is not added to `ALL` would publish zero for it forever, and
the unit test `all_lists_every_variant` compares `ALL` against the utoipa schema
rather than against a hand-written list.

## 3. Timestamps, not ages

Every new gauge is a Unix timestamp, never an age in seconds. Two reasons, both
of which show up as bugs in real alerting rules:

- An age computed at scrape time is stale by up to one scrape interval, which at
  a 1 s interval is tolerable and at a 60 s interval is not.
- An age is computed by the exporter, so if the exporter is wedged or scraping
  has silently stopped, the age either freezes at a plausible number or is
  simply absent — both of which look healthy to a `> threshold` rule.

A timestamp compared against `time()` in the *rule* moves with the rule's
evaluation, so a stalled exporter makes the metric stale and Prometheus reports
it as such, rather than reporting a frozen but plausible age.

## 4. The rules, and what each one refuses to fire on

The seven rules live in two groups: pipeline rules at a 30 s evaluation
interval, and one scrape-health rule. Every rule carries `severity`,
`component` and `runbook_url`.

`FelderaPipelineNotRunning` selects only the transitional statuses —
`Provisioning|Initializing|Bootstrapping|ConcurrentBootstrapping|Synchronizing|Replaying`
— and fires once one has lasted 900 s. Three statuses are deliberately absent:

- `Standby`, because a P3 HA standby pipeline waits for promotion and may sit
  there for days. Paging on it would page on the design.
- `AwaitingApproval`, because that is a person's decision, not a fault. An
  alert would only tell the on-call to go and ask the requester.
- `Coordination`, because a multi-host pipeline holds it while waiting for its
  peers, which can also be long.

The same reasoning rules out `Paused`, `Stopped`, `Suspended` and `Unavailable`:
all are states someone chose or a fault already covered by another rule.

`FelderaCheckpointFailing` uses `increase(feldera_checkpoint_failures_total[15m]) > 3`
with `for: 0m`. The ticket says "consecutive failures > 3"; a rate window is
what a Prometheus counter can answer honestly, and the counter itself only
increments on *permanent* failures — a checkpoint that was merely delayed is
not a failure and is not counted. `for: 0m` is deliberate: four failed
checkpoints in a quarter of an hour is already a pipeline whose durability is
in doubt, and waiting longer only lengthens the window in which a restart loses
data.

`FelderaCheckpointStale` compares age against three intervals, and needs both
guards described in §2: interval `> 0` excludes non-FT pipelines, and
last-success `> 0` excludes a pipeline that has not yet committed its first
checkpoint (whose age would otherwise be enormous). The cost of the second
guard is that a pipeline which has never checkpointed successfully is not
covered by this rule at all; a pipeline that keeps failing is covered by
`FelderaCheckpointFailing`, and one that has never tried in its first hours is
covered by nothing, which §7 records as a known gap.

`FelderaStorageVolumeFillingUp` computes
`(total - available) / total > 0.8`. It does not use `storage_usage_bytes`,
for the reason in §2.

`FelderaCompileQueueSlow` fires when a pipeline has been in `pending`,
`compiling_sql` or `compiling_rust` for 1800 s. The other five stages
(`sql_compiled`, `success`, and the three error stages) are excluded: the error
stages are covered by their own pipeline status, and `success` is the healthy
end state.

`FelderaProvisioningTimeout` fires at 1800 s on `status="Provisioning"` alone.
It overlaps `FelderaPipelineNotRunning`, at a different threshold and a
different severity, so an install that is merely slow raises a warning at 15
minutes and a critical at 30. That is the intended escalation path.

`FelderaScrapeTargetDown` fires when `up{job=~"feldera|feldera-manager|feldera-pipelines"}`
has been 0 for 10 minutes. Without it, every other rule fails *silently* when
scraping breaks, because a missing series makes an expression empty rather than
false, and empty is not firing.

## 5. How the rules are tested

Three layers, because each catches something the others cannot.

**Unit tests in Rust** (`crates/pipeline-manager/src/api/endpoints/metrics.rs`,
17 tests) pin the shape of every exported family: exactly one status sample at
1 per pipeline, one since sample, eight program-status samples, one
program-status-since sample named for the current stage, sub-second precision
preserved, and the JSON and Prometheus renderers agreeing after sorting. A
label renamed in Rust breaks these before any cluster is touched.

**`promtool test rules`** (`deploy/config/feldera-alerts.test.yml`) injects
synthetic series and asserts, for each of the seven rules, one case that fires
and one healthy look-alike that stays quiet: a `Stopped` pipeline, a `Standby`
pipeline, an FT-disabled pipeline whose interval is 0, a pipeline that has not
yet checkpointed, an object-store pipeline with no volume series, a `success`
stage, and an unrelated job's `up == 0`. This is the only layer that exercises
the `for:` durations and the actual rule text.

The file records a trap that cost an hour: promtool compares annotations
exactly, so a firing case that omits `exp_annotations` fails with labels that
match perfectly. Every firing case therefore restates the full annotation set,
which also pins each `runbook_url` to a literal string.

**`scripts/e2e-k8s-alerts.sh`** closes the gap promtool cannot: whether a *live
install* exports the series the rules read. A metric renamed in Rust compiles,
passes the unit tests, and leaves an alert that never fires because its series
does not exist. The script runs `promtool check` and `promtool test` in a pod,
installs the platform with metrics enabled, scrapes it, asserts all eight series
including `last_success > 0` and an interval gauge reading the configured 60 s,
asserts that a healthy install has no firing alerts, then injects two faults:

- Checkpoints cannot be written: a root pod mounts the pipeline's claim and
  makes the storage directory read-only, the same technique
  `scripts/e2e-k8s-chaos.sh` uses. The script then waits for
  `FelderaCheckpointFailing`, falling back to `FelderaCheckpointStale`, since a
  read-only directory can manifest either way — which is the reason both rules
  exist. Recovery restores permissions and requires a checkpoint to commit
  again, so an alert that clears while the pipeline stays broken does not pass.
- Every other rule depends on a status that has lasted 15 or 30 minutes, which
  is not something a regression script can wait for, and lowering the deadline
  in a copy of the rules would test the copy. So the *firing* of those rules is
  left to promtool, and the script asserts what promtool cannot see: that the
  status gauge and its age gauge both carry the `pipeline`/`pipeline_name` pair
  the rules join `on`. A broken join makes a rule match nothing, silently.

Two earlier designs for the second point were discarded as dishonest: scaling
the control plane to zero produces `Unavailable`, which is not in any rule's
selector, so it would have proven nothing; and evaluating the rule's expression
by hand proves only that PromQL arithmetic works, not that the rule fires.

## 6. Where the rules are loaded

Three places, so the rules follow whichever install path built the cluster:

- `deploy/docker-compose.yml` mounts the file into the Prometheus container.
- `deploy/config/prometheus-k8s.yml` names it in `rule_files`, and
  `scripts/e2e-k8s-monitoring.sh` adds it to the configmap it already creates.
- `scripts/e2e-k8s-alerts.sh` mounts the same two files into its own Prometheus.

The file is not generated or templated: it is the same YAML in all three, so a
rule edited for one install is edited for all of them.

## 7. What is not here

- **A pipeline that has never checkpointed, and is not failing.** The age rule
  needs `last_success > 0` to avoid paging on non-FT pipelines, and the failure
  rule needs a failure. A pipeline configured for FT that silently never
  attempts a checkpoint would be caught by neither. Closing this needs a
  per-attempt counter, which is P2 work.
- **Alert delivery.** The rules produce firing alerts in Prometheus; routing
  them to a pager is whoever owns the Prometheus installation. `runbook_url` is
  a relative path into `docs/operations/alerting.md` for the same reason.
- **Rule files for the chart.** `charts/` still ships no `PrometheusRule`, for
  the reason P1-015 §7 gives for the ServiceMonitor: a chart-managed rule
  assumes the chart's operator also manages Prometheus.
- **A recording rule layer.** Seven rules over a handful of series do not need
  one; if the rule count grows past roughly twenty, the shared
  `on (pipeline, pipeline_name)` join is the thing to record once.
- **Runbook links from the dashboard.** The panels do not link to the runbook
  yet; the alerts do.
- **`pipeline_status_since` for the manager's own health.** Manager liveness is
  covered only by `FelderaScrapeTargetDown`.

## 8. Measured

| Step | Result |
| --- | --- |
| `promtool check rules deploy/config/feldera-alerts.yml` | `SUCCESS: 7 rules found` |
| `promtool test rules deploy/config/feldera-alerts.test.yml` | `SUCCESS` (a firing and a quiet case per rule) |
| `cargo +1.96.1 test -p pipeline-manager --lib api::endpoints::metrics` | 17 passed |
| `cargo +1.96.1 test -p dbsp_adapters --lib` (`checkpoint_metrics_tests`) | 4 passed |
| Runbook anchors | 7 of 7 `runbook_url` anchors resolve to a heading |
| `scripts/e2e-k8s-alerts.sh` on `flink-test-02` (kind `bili-p1005`) | `PASS` |

The live run installs the chart with `metrics.enabled`, starts a pipeline with
`checkpoint_interval_secs: 60`, and lets a Prometheus built from
`deploy/config/prometheus-k8s.yml` scrape it. The series it reads, as the run
reported them:

```
pipeline_status_since_timestamp_seconds = 1793681507.506
feldera_checkpoint_interval_seconds = 60
feldera_checkpoint_last_success_timestamp_seconds = 1793681513
feldera_checkpoint_failures_total = 0
feldera_storage_volume_total_bytes = 42002106286080
feldera_storage_volume_available_bytes = 41013047336960
pipeline_program_status = 1
pipeline_program_status_since_timestamp_seconds = 1793681498.562
```

A healthy install raised nothing: `no alert is firing`, and both scrape jobs
reported `up == 1`.

The injection makes the pipeline's storage volume read-only, which is the field
failure the checkpoint rules exist for. The run measured:

- `failures_total moved 0 -> 3` before the poll returned, and
  `FelderaCheckpointFailing is firing (3.0158 failures in the window)` — the
  rule's threshold is `increase(...[15m]) > 3`.
- with the volume writable again, `a checkpoint committed at 1793681724`, and
  the failure alert cleared within its 15-minute window without intervention.

Two properties of the run are worth stating because they shaped the script. The
failure rule accumulates over a 15-minute window, so a wait shorter than that
window reports "never fired" on a rule that is only still accumulating; the
script waits up to 1200 s, which the run needed. And queries go through
`kubectl exec` into the Prometheus pod rather than through a `port-forward`: the
forward goes quiet when the poll interval is long, which reads exactly like an
alert that never fired. Both were found by running the script, not by reading
it.

Three of the six conditions (`FelderaPipelineNotRunning`,
`FelderaProvisioningTimeout`, `FelderaCompileQueueSlow`) depend on a status or a
compile stage lasting 15 or 30 minutes. The run asserts the series and the join
key those rules read rather than waiting the deadline out; that the rules fire
on the age is proved by `promtool test rules`, which injects the age directly.
