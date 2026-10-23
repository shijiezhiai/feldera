# P1-010: the manager-to-runner network path

The manager and a pipeline run in different pods, so every interaction between
them crosses the cluster network. This note records what that path is, why each
piece looks the way it does, and what the pipeline's NetworkPolicy does and does
not cover.

Code: `crates/pipeline-manager/src/runner/kubernetes_runner.rs`.
Chart: `charts/feldera/charts/controlplane/templates/{rbac,api-server,api-server-service}.yaml`.

## Objectives

1. The manager reaches the pipeline's HTTP server at a stable address for the
   whole life of the deployment.
2. The pipeline reaches the compiler service, its sources and its sinks.
3. Nothing else in the cluster reaches the pipeline's port.
4. The manager can stream the pipeline's container logs and observe its runtime
   status.

## Addressing: a headless Service, not a pod IP

`render_service` creates a headless Service (`clusterIP: None`) named
`pipeline-<id>` with one port, 8080. The runner reports
`pipeline-<id>.<namespace>.svc.cluster.local:8080` as the deployment location.

A headless Service is the smallest object that turns a pod, whose IP changes on
every restart, into a stable DNS name:

- A pod IP would go stale the first time the pipeline crashes, and the manager
  would keep scraping a dead address until its next `is_provisioned` poll.
- A ClusterIP Service would route through kube-proxy for a single backend and
  give the pipeline an address that survives restarts only by accident: the
  Service selector matches the StatefulSet pod label, so a restarted pod is
  picked up, but nothing about that is more robust than DNS.
- A `NodePort` or `LoadBalancer` would expose the pipeline beyond the cluster
  for no benefit.

The name is derived from the StatefulSet name (`resource_base`), which is
derived from the pipeline id, so all objects of one deployment sort together in
`kubectl get all`.

## The compiler path

A pipeline downloads its program binary from the compiler service
(`crates/pipeline-manager/src/runner/pipeline_automata.rs:1346` builds
`{scheme}://{compiler_host}:{compiler_port}/binary/{id}/{version}/{source_sum}/{integrity_sum}`,
and the pipeline image's entrypoint fetches that URL before `exec`).

Two things follow:

- `--compiler-host` must be an address the pipeline pod can route to. The chart
  sets `COMPILER_HOST` to
  `'{{ include "controlplane.fullname" . }}-api-server.{{ .Release.Namespace }}.svc.cluster.local'`
  and passes it as `--compiler-host`. The default `127.0.0.1` only works for the
  local runner, where the compiler lives in the manager process.
- The api-server Service must expose the compiler port (8085) and the api-server
  Deployment must declare it in `containerPort`, otherwise the pipeline cannot
  open a connection to the DNS name.

`provision` rejects a loopback compiler host explicitly
(`compiler_host_is_loopback`), because the resulting URL would resolve to the
pipeline pod itself and the download would hang until the provisioning deadline.

## The NetworkPolicy

`render_network_policy` creates a policy named `pipeline-<id>` with
`policyTypes: ["Ingress"]` and one rule: TCP 8080 from pods in the manager's
namespace.

The selector is a `namespaceSelector` on
`kubernetes.io/metadata.name: <manager namespace>`, not on `kubernetes.io/…`
guessed from the release name: the API server labels every namespace with its
own name, so the selector works for any namespace naming scheme. The manager
namespace defaults to the pipeline namespace and is configurable with
`--kubernetes-runner-manager-namespace`.

One rule, and not a `podSelector` inside it, is deliberate: the manager pod is
re-created by a Deployment rollout with a new name every time, so pinning a pod
label would break on the next upgrade. A namespace-wide source is the smallest
selector that survives that.

Egress is unrestricted. Pipelines read from Kafka, databases and HTTP sources,
and write to arbitrary sinks; enumerating those destinations would mean a
per-pipeline configuration surface that the work order does not ask for, and a
wrong list would silently stop a pipeline's inputs. The policy is therefore
"ingress closed, egress open".

Consequence worth knowing: the pipeline pod has no readiness or liveness probe
(`render_stateful_set` deliberately omits them), because kubelet probes come
from the node's network namespace and the ingress rule would block them. The
manager's `is_provisioned` poll is the liveness signal instead, and the pipeline
already has its own retry logic for sources.

## Logs

`provision` starts `spawn_log_follower`, a task that follows
`Api::<Pod>::log_stream` (the pipeline's stdout) and forwards each line to the
pipeline's log API through `LogsSender`. Following the stream needs
`pods/log` in the Role; `pods` alone is not enough, and the failure mode is a
403 that only shows up in the manager's own log (the pipeline runs fine), so the
end-to-end test asserts that a line the pipeline printed comes back from
`GET /v0/pipelines/{name}/logs`. `stop` and `clear` stop the task through `logs_task`, so a stopped
pipeline does not keep a broken stream alive.

`log_stream` is used rather than `pods.logs` because the latter collects the
whole log into a `String` and would return only when the container exits.

A failure to follow the stream is reported once (the message is compared with
the previous one, so a persistent failure does not spam the log API) and the
loop retries after 5 seconds; it never fails provisioning, because the pipeline
is still usable without its stdout.

## Status observation

`check` reads the pod, then probes `http://<location>/status` with a 5 second
timeout. The result is stored as the deployment's resources status details:

```json
{
  "pod": { "phase": "Running", "restarts": 0, "ready": true, "reason": null },
  "status_url": "http://pipeline-<id>.feldera.svc.cluster.local:8080/status",
  "http_status": 200,
  "pipeline": { "state": "Running", ... },
  "status_error": null
}
```

The pipeline's own documentation (`crates/adapters/src/server.rs:1578`) defines
three outcomes for `/status`: `200` with the runtime status, `503` when it
cannot read that status right now, and any other code, which means the pipeline
is unhealthy. `status_is_healthy` encodes exactly that: `200` and `503` pass,
anything else fails the check and hands the pipeline to the replacement logic.
A transport error (connection refused, timeout) does not fail the check, because
it is the normal state between container start and the HTTP server binding; the
pod status is what distinguishes "starting" from "crash-looping".

## Environment alignment

`provision` runs the same `validate_pipeline_env` gate as the local runner
(`crates/pipeline-manager/src/pipeline_env.rs`), so user-supplied environment
variables cannot shadow `FELDERA_*`, `TOKIO_*` or (by default) `KUBERNETES_*`.

The runner adds its own variables first (`platform_env`): the program binary
URL and checksum, `RUST_LOG`, and the storage, work and config locations. User
variables are appended after them. Order does not matter for the variables that
matter, because the blocklist rejects `FELDERA_*`, `KUBERNETES_*` and `TOKIO_*`
before provisioning, so the injected values cannot be shadowed by construction.
Plain names such as `RUST_LOG` stay overridable, which is what an operator
expects.

`--kubernetes-runner-allow-kubernetes-env-prefix` relaxes the `KUBERNETES_*`
part for clusters where a pipeline must override injected values; `FELDERA_*`
stays blocked either way.

## Evidence

- Unit tests: `cargo test -p pipeline-manager --lib runner::` — 86 tests,
  including the NetworkPolicy render, the `/status` parser and the health
  mapping (`only_a_status_report_or_a_temporary_unavailability_is_healthy`).
- Cluster (2026-10-23, kind, single 48-vCPU node): `scripts/e2e-k8s-runner.sh`
  passes in 81 s for the full create → Running → observe → ingest → query →
  delete path, and in 60 s when an existing pipeline is reused. The run asserts
  that the NetworkPolicy exists, that `deployment_resources_status_details`
  carries `"http_status": 200` with the pipeline's `runtime_status: Running`,
  that `GET /v0/pipelines/{name}/logs` returns the pipeline's own
  `Pipeline initialization complete` line (88 lines in that run), and that
  cleanup leaves no StatefulSet, Service, NetworkPolicy or PVC behind.

Two properties of the endpoints are worth remembering when writing similar
checks: the log endpoint streams, so a client that waits for the response to end
waits until its own deadline; and the pipeline's `/status` body carries
`runtime_status`, not `state`.
