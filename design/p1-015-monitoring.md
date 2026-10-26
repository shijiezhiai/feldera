# P1-015: pipeline metrics and the monitoring dashboard

P1-009 gave every pipeline its own pod. That pod serves `/metrics` on the same
port as its API, but nothing in the cluster could reach it: the only Service the
runner created was headless and the pipeline's NetworkPolicy admitted the
manager namespace alone. P1-015 adds a scrape target, widens the policy for it,
and rebuilds the shipped dashboard around the series a self-hosted install
actually produces.

Code: `crates/pipeline-manager/src/runner/kubernetes_runner.rs`,
`crates/pipeline-manager/src/config.rs`.
Chart: `charts/feldera/charts/controlplane/{values.yaml,templates/api-server.yaml}`.
Dashboard: `deploy/grafana_dashboard.json`.
Scrape config: `deploy/config/prometheus-k8s.yml`.
Provisions: `deploy/config/grafana_dashboards.yaml`, `deploy/docker-compose.yml`.

## 1. What the work order asked for

| Requirement | Where it landed |
| --- | --- |
| Scrape runner and manager `/metrics` in a kind cluster | `kubernetes_runner_metrics_service`, `deploy/config/prometheus-k8s.yml` |
| Turn `deploy/grafana_dashboard.json` into a dashboard driven by datasource and label variables | `DS_PROMETHEUS` template variable, `pipeline_name` label variable |
| The dashboard shows a checkpoint histogram | "Checkpoint" row, panels 51-55 |
| The dashboard shows backpressure | "Backpressure" row, panels 57-59 |
| The dashboard shows lag | **Not possible as stated** — see §5 |

## 2. Checkpoints exist only when something triggers them

This is the fact that shaped the whole ticket. A community-edition pipeline does
not checkpoint on a timer:

- `crates/adapters/src/controller.rs:5581` takes the interval from
  `config.fault_tolerance.checkpoint_interval()`.
- `crates/feldera-types/src/config.rs:1657` (`is_enabled`) makes that interval
  `Some` only when fault tolerance is configured.
- `StepTrigger::next_action` (`crates/adapters/src/controller.rs:5615-5660`)
  therefore leaves `next_checkpoint` at `None`, and no checkpoint is scheduled.

So a dashboard panel that simply plots `feldera_checkpoint_runtime_seconds` is
empty for a healthy community-edition pipeline, and nothing in the panel can fix
that. The manual endpoint *does* work here: `POST /v0/pipelines/{name}/checkpoint`
is not gated, and the program the manager compiles carries
`--enterprise` (`crates/pipeline-manager/src/compiler/sql_compiler.rs:846`), so
`can_checkpoint()` in `crates/adapters/src/controller.rs:8972` does not refuse
it.

Consequences for the panels:

- The row is titled "Checkpoint" and the runtime panel's description says an
  idle pipeline leaves it empty on purpose. A silent, permanently empty panel
  reads as a bug; a documented one reads as a feature that is waiting for an
  event.
- The end-to-end test (§6) triggers a checkpoint explicitly, because no other
  way exists to make the histogram appear.

## 3. The scrape target

`render_metrics_service` creates a second Service per pipeline, named
`pipeline-<id>-metrics`, with these properties:

- **ClusterIP, not headless.** A headless Service has no address to send a
  request to, which is why the manager's own Service cannot double as a scrape
  target.
- **Same port, `http`/8080.** The pipeline serves `/metrics` from the API
  server. A second listener would carry the same payload over a second socket.
- **Labelled `feldera.com/metrics-scrape: "true"`.** A label rather than a
  `prometheus.io/scrape` annotation, because labels are what `ServiceMonitor`
  and `kubernetes_sd` select on, and because the rest of the runner's objects
  already use labels.

The NetworkPolicy gains the scrape namespace as a **second peer**. A peer holds
one `namespaceSelector` with one `matchLabels` map, so putting the manager
namespace and the scrape namespace into a single selector would match neither.
When both names are equal the second peer is dropped: it would be the same
selector twice.

Metric labels on the pipeline's own endpoint are already right
(`crates/adapters/src/server.rs:1940-1958`): `pipeline` carries
`pipeline-<id>`, `pipeline_name` carries the name the user typed. The dashboard
filters on `pipeline_name` for that reason.

The whole feature is off by default. It costs one Service and one policy peer
per pipeline, and a deployment that runs no Prometheus should not pay for it:

```yaml
controlplane:
  kubernetesRunner:
    metrics:
      enabled: true
      namespace: monitoring   # empty means the manager namespace
```

## 4. The dashboard

`deploy/grafana_dashboard.json` used to be import-only: `__inputs` is substituted
during a manual import and not by provisioning. It is now a provisioned
dashboard:

- `__inputs`, `__requires` and `__elements` are gone.
- A `DS_PROMETHEUS` **template variable** of type `datasource` replaces them.
  `${DS_PROMETHEUS}` resolves in a provisioned dashboard and in an imported one.
- `deploy/config/grafana_dashboards.yaml` tells Grafana to load the file from
  `/etc/grafana/dashboards`, and `deploy/docker-compose.yml` mounts both. A
  fresh `--profile grafana` stack has the dashboard on first start.

Two new rows, placed above the existing ones (the pre-existing panels keep their
definitions and only shift down):

| Panel | Series | Why |
| --- | --- | --- |
| Checkpoint runtime (p50/p99) | `feldera_checkpoint_runtime_seconds` | The DoD's histogram |
| Time the pipeline was blocked by a checkpoint | `feldera_checkpoint_delay_seconds` | The sub-duration during which execution stopped; the gap to the panel above is the non-blocking part |
| Records per checkpoint | `feldera_checkpoint_records_processed_total` / `feldera_checkpoint_runtime_seconds_count` | Answers "how much work does a checkpoint cover"; the DoD's "checkpoint frequency" cannot be plotted because nothing periodic exists |
| Checkpoint bytes written | `feldera_checkpoint_written_bytes` | Checkpoint size, which is what predicts a restore that is too slow |
| Checkpoint persistence latency | `checkpoint_sync_{push,pull}_duration_seconds` | The object-storage leg, present only for a pipeline with a storage backend |
| Input records buffered | `records_input_buffered` | Backpressure that has not yet reached the queue limit |
| Output records queued | `output_connector_queued_records` per endpoint | Which sink is the one falling behind |
| Output stall | `output_stall_seconds` per endpoint | Seconds the pipeline cannot make progress at all |

The work order pointed at `crates/adapters/src/controller.rs:1858-1864` for the
checkpoint histogram. Those lines are the `checkpoint_sync_*` durations, the
persistence layer, not `feldera_checkpoint_*`. Both are now on the dashboard,
and the design record keeps them separate.

## 5. There is no consumer lag, and the dashboard says so

`kafka_consumer_lag` exists in the repository only as a value a test builds
(`crates/adapters/src/controller/test.rs:4825`, `:4871`, `:5002`, `:5040`).
No production code emits it; the Kafka fault-tolerant input uses
`fetch_watermarks` for its start position only, and
`docs.feldera.com`'s metrics reference does not list it.

Plotting that name would give a panel that is empty for every connector, always,
which is worse than no panel. The Backpressure row plots the quantities the
pipeline does report: how much input is waiting, how much output is queued, and
how long the output path has been stalled. Those three answer the question a lag
panel is asked — "is the pipeline keeping up, and if not, with what" — from the
inside.

## 6. Verification

`scripts/e2e-k8s-monitoring.sh` on the kind cluster:

1. Installs the chart with `kubernetesRunner.metrics.enabled=true` and
   `metrics.namespace=monitoring`.
2. Creates and starts a pipeline (unoptimized profile, so it compiles once and
   restarts in seconds).
3. Asserts the `pipeline-<id>-metrics` Service exists and carries
   `feldera.com/metrics-scrape: "true"`.
4. Asserts the pipeline's NetworkPolicy admits two peers.
5. Reads `/metrics` through the Service from inside the cluster and asserts the
   `feldera_checkpoint_runtime_seconds` family is served.
6. Posts a manual checkpoint and asserts `feldera_checkpoint_runtime_seconds` now
   has samples.
7. Runs Prometheus with `deploy/config/prometheus-k8s.yml` and asserts the target
   is `up`, that `pipeline_name` shows up on a scraped series, and that the
   checkpoint series reaches Prometheus.
8. Loads the dashboard into Grafana through the provisioning ConfigMaps (the
   same files a real install mounts) and asserts Grafana serves it with the
   Checkpoint and Backpressure rows.
9. Runs the Checkpoint runtime panel's own query through Grafana's data source,
   with the dashboard variables substituted as Grafana would, and asserts the
   result is non-empty. A second proxied query on
   `feldera_checkpoint_runtime_seconds_count` must return a number ≥ 1, because
   the panel query itself is `histogram_quantile` and legitimately returns `NaN`
   when the rate window holds too few samples — a result that proves the wiring
   but not the data.

Recorded numbers are in §8.

## 7. What is not here

- **Alerts.** The dashboard shows; it does not page.
- **Per-tenant metric isolation.** Any pod in the scrape namespace reads every
  pipeline's metrics. Multi-tenancy (P2) has to decide whether that is
  acceptable.
- **A ServiceMonitor.** `deploy/config/prometheus-k8s.yml` uses
  `kubernetes_sd` with label selection, which works on a bare Prometheus.
  A chart-managed ServiceMonitor belongs to whoever owns the Prometheus
  installation.
- **Dashboards for the manager's own endpoint.** It carries pipeline status
  aggregates only; a status dashboard is P2 work alongside HA.

## 8. Measured

All of the following come from `scripts/e2e-k8s-monitoring.sh` on
`flink-test-02` (kind `bili-p1005`, single node, 48 vCPU).

| Step | Result |
| --- | --- |
| Chart install → API server healthy | 40–60 s |
| Fresh pipeline (compile `unoptimized` + deploy) → `Running` | 78 s end to end |
| `pipeline-<id>-metrics` Service | ClusterIP `10.96.199.180:8080`, label `feldera.com/metrics-scrape="true"`, port name `http` |
| NetworkPolicy peers | `feldera`, `monitoring` |
| `/metrics` through the Service | HTTP 200, 294 KB, 1867 lines carry `pipeline_name` |
| `feldera_checkpoint_runtime_seconds` before a manual checkpoint | family present, `_count` 0 |
| After `POST /v0/pipelines/<name>/checkpoint` | `_count` 1, then 2 on the next scrape |
| Prometheus targets `up` | `feldera-manager`, `feldera-pipelines` |
| Grafana checkpoint count read through the data source | 2 |

Two findings worth carrying forward:

- **The compilers must be built with `feldera-enterprise`.** `POST /checkpoint`
  is gated twice: the manager's route
  (`crates/pipeline-manager/src/api/endpoints/pipeline_interaction.rs:1292`)
  rejects it with a 501 under `#[cfg(not(feature = "feldera-enterprise"))]`, and
  the pipeline binary rejects it again in
  `ControllerInner::can_checkpoint()`
  (`crates/adapters/src/controller.rs:8975`) unless the generated crate was
  compiled with the feature. An overlay image built without the feature returns
  a checkpoint that fails asynchronously with "Suspend is an enterprise
  feature", which is much harder to read than the 501.
- **Nothing schedules checkpoints on a community-edition pipeline.**
  `StepTrigger::next_action` only sets `next_checkpoint` when
  `fault_tolerance.checkpoint_interval()` is `Some`, which
  (`crates/feldera-types/src/config.rs:1663`) requires fault tolerance to be
  enabled. So a healthy pipeline's checkpoint panels are legitimately empty
  until someone asks for a checkpoint; the e2e asks explicitly.
