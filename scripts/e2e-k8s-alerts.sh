#!/usr/bin/env bash
#
# End-to-end check for the alerting baseline (P1-030).
#
# The rules themselves are tested without a cluster: `promtool test rules
# deploy/config/feldera-alerts.test.yml` injects synthetic series and proves
# every rule fires on its fault and stays quiet on the healthy look-alike. What
# that cannot prove is that a real install *exports* the series the rules read.
# A metric renamed in Rust compiles, passes the unit tests, and leaves an alert
# that never fires because its series does not exist. This script closes that
# gap: it installs the platform, scrapes what it exports, and asserts each of
# the seven series is present with the labels the rules assume.
#
# It then fires a rule for real, rather than waiting out a 15- or 30-minute
# grace period: `FelderaCheckpointFailing` (or `FelderaCheckpointStale`) by
# making the pipeline's storage directory read-only, which is the fault that
# actually stops checkpoints in the field. The result is read back from
# Prometheus's active alerts, so what is asserted is what an alerting rule would
# page on, not what the raw series looks like.
#
# The other rules page on a status that has lasted 15 or 30 minutes. Waiting one
# of those deadlines out is not something a regression check can do, and
# lowering the deadline in a copy of the rules would test the copy. Their firing
# is proven by `promtool test rules`, which injects the age directly; what this
# script proves for them is the half promtool cannot see — that a live install
# exports the status gauge and its age gauge with the same label pair the rules
# join on.
#
# Usage:
#
#   TAG=p1-030 scripts/e2e-k8s-alerts.sh
#
# Environment:
#   CLUSTER       kind cluster name (default: bili-p1005)
#   NAMESPACE     namespace of the platform (default: feldera)
#   RELEASE       Helm release name (default: feldera)
#   TAG           image tag to deploy (required)
#   MANAGER_TAG   manager image tag (default: TAG)
#   RUNNER_TAG    runner image tag (default: TAG)
#   COMPILER_TAG  compiler image tag (default: TAG)
#   TIMEOUT       seconds to wait for Running (default: 2400)
#   METRICS_NS    namespace the scrape client runs in (default: monitoring)
#   FAULT_TIMEOUT seconds to wait for an injected alert (default: 1200)
#                 The failure rule counts four failures inside a 15-minute
#                 window and the pipeline retries roughly every minute, so a
#                 short wait would report "never fired" on a rule that was only
#                 still accumulating. The stale rule additionally has a 5-minute
#                 `for:`.
#   PROFILE       compilation profile (default: unoptimized)
#   PIPELINE      pipeline name (default: e2e-k8s-alerts)
#   PORT          local port for the API-forward (default: 18082)
#   PROM_PORT     local port for the Prometheus-forward (default: 19091)
#
# The pipeline compiles inside the manager pod, so the run is fast only when a
# previous run left the compilation cache in place.
set -euo pipefail

CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
TAG="${TAG:?TAG must be set, for example p1-030}"
# The runner and the compiler move far more slowly than the manager, and a
# hand-built platform usually rebuilds only the manager. Name them separately
# when they differ from TAG.
MANAGER_TAG="${MANAGER_TAG:-${TAG}}"
RUNNER_TAG="${RUNNER_TAG:-${TAG}}"
COMPILER_TAG="${COMPILER_TAG:-${TAG}}"
TIMEOUT="${TIMEOUT:-2400}"
METRICS_NS="${METRICS_NS:-monitoring}"
FAULT_TIMEOUT="${FAULT_TIMEOUT:-1200}"
PROFILE="${PROFILE:-unoptimized}"
PIPELINE="${PIPELINE:-e2e-k8s-alerts}"
PORT="${PORT:-18082}"
PROM_PORT="${PROM_PORT:-19091}"
RUNNER_IMAGE="${RUNNER_IMAGE:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

for tool in kind kubectl helm curl; do
  command -v "${tool}" >/dev/null || fail "${tool} is required"
done
# `grep -c` reads to the end, so `pipefail` never sees a SIGPIPE here.
[ "$(kind get clusters | grep -cx "${CLUSTER}")" = "1" ] \
  || fail "kind cluster '${CLUSTER}' does not exist"
RUNNER_IMAGE="${RUNNER_IMAGE:-localhost:5001/feldera-runner:${RUNNER_TAG}}"

say "the rules parse"
# The container image the cluster already holds carries `promtool`; running it
# here rather than on the host keeps the check working on a machine that has no
# Prometheus installed.
kubectl create configmap alert-rules --namespace "${NAMESPACE}" \
  --from-file=feldera-alerts.yml="${REPO_ROOT}/deploy/config/feldera-alerts.yml" \
  --from-file=feldera-alerts.test.yml="${REPO_ROOT}/deploy/config/feldera-alerts.test.yml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete pod alert-rules-check --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: alert-rules-check
spec:
  restartPolicy: Never
  containers:
    - name: promtool
      image: prom/prometheus:v3.1.0
      imagePullPolicy: IfNotPresent
      command: ["/bin/sh", "-c"]
      args:
        - >-
          /bin/promtool check rules /etc/prometheus/feldera-alerts.yml &&
          cd /etc/prometheus && /bin/promtool test rules feldera-alerts.test.yml
      volumeMounts:
        - {name: rules, mountPath: /etc/prometheus}
  volumes:
    - name: rules
      configMap: {name: alert-rules}
YAML
kubectl wait --namespace "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Succeeded \
  pod/alert-rules-check --timeout=180s >/dev/null 2>&1 || true
kubectl logs --namespace "${NAMESPACE}" pod/alert-rules-check 2>&1 | tail -20
phase="$(kubectl get pod --namespace "${NAMESPACE}" alert-rules-check \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[ "${phase}" = "Succeeded" ] || fail "the alert rules failed promtool (pod phase: ${phase:-unknown})"

say "loading images into ${CLUSTER} (manager ${MANAGER_TAG}, runner ${RUNNER_TAG}, compiler ${COMPILER_TAG})"
for ref in \
  "localhost:5001/feldera-manager:${MANAGER_TAG}" \
  "localhost:5001/feldera-runner:${RUNNER_TAG}" \
  "localhost:5001/feldera-compiler:${COMPILER_TAG}" \
  "postgres:17-alpine" \
  "curlimages/curl:8.11.1" \
  "prom/prometheus:v3.1.0"; do
  docker image inspect "${ref}" >/dev/null 2>&1 \
    || docker pull "${ref}" >/dev/null \
    || fail "${ref} is neither local nor pullable"
  kind load docker-image --name "${CLUSTER}" "${ref}"
done

kubectl get namespace "${METRICS_NS}" >/dev/null 2>&1 \
  || kubectl create namespace "${METRICS_NS}"

find charts -name '._*' -delete 2>/dev/null || true

say "installing release ${RELEASE} with metrics in namespace ${METRICS_NS}"
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" --create-namespace \
  --set "controlplane.image.tag=${MANAGER_TAG}" \
  --set "controlplane.kubernetesRunner.image.tag=${RUNNER_TAG}" \
  --set "compiler.image.tag=${COMPILER_TAG}" \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --set controlplane.compilationCache.enabled=true \
  --set controlplane.compilationCache.size=80Gi \
  --set controlplane.kubernetesRunner.metrics.enabled=true \
  --set "controlplane.kubernetesRunner.metrics.namespace=${METRICS_NS}" \
  --wait --timeout 5m

kubectl rollout status "deployment/${RELEASE}-controlplane-api-server" \
  --namespace "${NAMESPACE}" --timeout 5m

api="http://127.0.0.1:${PORT}"
api_forward_pid=""
prom_forward_pid=""

start_fwd() {
  local pid_var="$1" log="$2"
  shift 2
  kubectl port-forward --namespace "${NAMESPACE}" "$@" >"${log}" 2>&1 &
  printf -v "${pid_var}" '%s' "$!"
}

start_api_forward() {
  start_fwd api_forward_pid /tmp/e2e-k8s-alerts-api-forward.log \
    "svc/${RELEASE}-controlplane-api-server" "${PORT}:8080"
  for _ in $(seq 1 60); do
    curl --silent --fail --max-time 3 "${api}/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

cleanup() {
  for pid in "${api_forward_pid}" "${prom_forward_pid}"; do
    [ -n "${pid}" ] && { kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; }
  done
  kubectl delete pod --namespace "${NAMESPACE}" \
    alert-rules-check alert-storage-helper --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete deployment --namespace "${NAMESPACE}" prometheus-alerts-check \
    --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_api_forward || fail "the API server did not become healthy"

api_call() {
  local method="$1" path="$2"
  shift 2
  local response
  if response="$(curl --silent --fail --max-time 30 -X "${method}" "${api}${path}" "$@")"; then
    printf '%s' "${response}"
    return 0
  fi
  echo "  (reconnecting to the API server)" >&2
  kill "${api_forward_pid}" 2>/dev/null || true
  start_api_forward || return 1
  curl --silent --fail --max-time 30 -X "${method}" "${api}${path}" "$@"
}

# A pipeline's `deployment_status` is the manager's opinion of the data plane.
# Everything that waits on the pipeline waits on this one field.
deployment_status() {
  api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null \
    | sed -n 's/.*"deployment_status":"\([^"]*\)".*/\1/p' || true
}

pipeline_id() {
  api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' || true
}

delete_pipeline() {
  api_call POST "/v0/pipelines/${PIPELINE}/stop?force=true" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    local status; status="$(deployment_status)"
    [ -z "${status}" ] && return 0
    [ "${status}" = "Stopped" ] && break
    sleep 2
  done
  for _ in $(seq 1 30); do
    api_call POST "/v0/pipelines/${PIPELINE}/clear" >/dev/null 2>&1 || true
    sleep 3
    api_call DELETE "/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 && return 0
    [ -z "$(pipeline_id)" ] && return 0
  done
  fail "could not delete pipeline ${PIPELINE}"
}

say "pipeline ${PIPELINE} with a 60-second checkpoint interval"
if [ -n "$(api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null || true)" ]; then
  echo "--- removing the pipeline this check left behind last time"
  delete_pipeline
fi
# Fault tolerance is what makes the checkpoint series exist at all, so the
# pipeline under test has it on. The interval decides the staleness threshold,
# so a short one lets the stale rule be exercised inside a test run.
api_call POST "/v0/pipelines" \
  -H 'content-type: application/json' \
  --data @- <<JSON >/dev/null
{
  "name": "${PIPELINE}",
  "program_code": "CREATE TABLE t (i INT NOT NULL);\nCREATE MATERIALIZED VIEW v AS SELECT COUNT(*) AS c FROM t;",
  "program_config": {"profile": "${PROFILE}"},
  "runtime_config": {
    "resources": {"cpu_cores_min": 0, "memory_mb_min": 256, "memory_mb_max": 1024},
    "fault_tolerance": {"model": "at_least_once", "checkpoint_interval_secs": 60}
  }
}
JSON
api_call POST "/v0/pipelines/${PIPELINE}/start?bootstrap_policy=allow" >/dev/null

say "waiting up to ${TIMEOUT}s for the pipeline to report Running"
deadline=$(( $(date +%s) + TIMEOUT ))
status=""
while :; do
  status="$(deployment_status)"
  printf '  deployment_status=%s\n' "${status:-unknown}"
  [ "${status}" = "Running" ] && break
  [ "${status}" = "Failed" ] && { kubectl get pods --namespace "${NAMESPACE}" -o wide >&2 || true; fail "the deployment reached Failed"; }
  [ "$(date +%s)" -lt "${deadline}" ] || fail "timed out waiting for Running (last status: ${status:-unknown})"
  sleep 5
done
id="$(pipeline_id)"
[ -n "${id}" ] || fail "could not read the pipeline id"
metrics_service="pipeline-${id}-metrics"
MANAGER_SERVICE="${RELEASE}-controlplane-api-server"

say "prometheus scrapes it"
kubectl create configmap prometheus-alerts-check-config \
  --namespace "${NAMESPACE}" \
  --from-file=prometheus.yml="${REPO_ROOT}/deploy/config/prometheus-k8s.yml" \
  --from-file=feldera-alerts.yml="${REPO_ROOT}/deploy/config/feldera-alerts.yml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete deployment prometheus-alerts-check --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-alerts-check
spec:
  replicas: 1
  selector:
    matchLabels: {app: prometheus-alerts-check}
  template:
    metadata:
      labels: {app: prometheus-alerts-check}
    spec:
      serviceAccountName: prometheus-alerts-check
      containers:
        - name: prometheus
          image: prom/prometheus:v3.1.0
          imagePullPolicy: IfNotPresent
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
            - --storage.tsdb.retention.time=1h
          ports: [{name: http, containerPort: 9090}]
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus}
      volumes:
        - name: config
          configMap: {name: prometheus-alerts-check-config}
YAML
# `kubernetes_sd` lists endpoints and services from the API; the manager's own
# ServiceAccount has no such right, and this is the check's RBAC, not a product
# setting.
kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-alerts-check
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-alerts-check
rules:
  - apiGroups: [""]
    resources: [services, endpoints, pods, nodes]
    verbs: [get, list, watch]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-alerts-check
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-alerts-check
subjects:
  - kind: ServiceAccount
    name: prometheus-alerts-check
    namespace: ${NAMESPACE}
YAML
kubectl rollout status deployment/prometheus-alerts-check --namespace "${NAMESPACE}" --timeout=180s

start_fwd prom_forward_pid /tmp/e2e-k8s-alerts-prom.log \
  deployment/prometheus-alerts-check "${PROM_PORT}:9090"
prom="http://127.0.0.1:${PROM_PORT}"
for _ in $(seq 1 60); do
  curl --silent --fail --max-time 3 "${prom}/-/healthy" >/dev/null 2>&1 && break
  sleep 1
done
curl --silent --fail --max-time 3 "${prom}/-/healthy" >/dev/null \
  || fail "prometheus never became healthy"

# Queries run from inside the Prometheus pod, not over the port-forward. The
# forward is fine for a health check, but it goes quiet when a query window is
# long: a run that slept 300 s between queries had every later request come back
# empty while the pod was healthy, which reads as "no alert fired". `kubectl
# exec` has no such idle state.
prom_get() {
  kubectl exec --namespace "${NAMESPACE}" deploy/prometheus-alerts-check -c prometheus -- \
    wget -qO- "http://localhost:9090$1" 2>/dev/null || true
}

# `query` prints the single scalar result, or an empty string when there is none.
# The expression is URL-encoded on this side, where a Python is guaranteed,
# rather than inside the Prometheus image, where one is not.
query() {
  local encoded
  encoded="$(printf '%s' "$1" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')"
  prom_get "/api/v1/query?query=${encoded}" \
    | python3 -c 'import json,sys
try: d = json.load(sys.stdin)["data"]["result"]
except Exception: raise SystemExit(0)
print(d[0]["value"][1] if d else "")'
}

# `assert_series <label> <promql>` waits for the expression to return a sample.
# The rules read these series by name, so "the series exists" is the property
# that a renamed metric breaks silently.
assert_series() {
  local what="$1" expr="$2" value="" waited=0
  while [ "${waited}" -lt 120 ]; do
    value="$(query "${expr}" || true)"
    [ -n "${value}" ] && { note "${what} = ${value}"; return 0; }
    sleep 5; waited=$(( waited + 5 ))
  done
  fail "no series for ${what} (${expr}); check the pipeline's /metrics"
}

say "every series the rules read is exported"
# A checkpoint has to commit before the last-success gauge moves off zero.
api_call POST "/v0/pipelines/${PIPELINE}/checkpoint" >/dev/null 2>&1 || true
assert_series "pipeline_status_since_timestamp_seconds" \
  "pipeline_status_since_timestamp_seconds{pipeline_name=\"${PIPELINE}\"}"
assert_series "feldera_checkpoint_interval_seconds" \
  "feldera_checkpoint_interval_seconds{pipeline_name=\"${PIPELINE}\"}"
assert_series "feldera_checkpoint_last_success_timestamp_seconds" \
  "feldera_checkpoint_last_success_timestamp_seconds{pipeline_name=\"${PIPELINE}\"} > 0"
assert_series "feldera_checkpoint_failures_total" \
  "feldera_checkpoint_failures_total{pipeline_name=\"${PIPELINE}\"}"
assert_series "feldera_storage_volume_total_bytes" \
  "feldera_storage_volume_total_bytes{pipeline_name=\"${PIPELINE}\"}"
assert_series "feldera_storage_volume_available_bytes" \
  "feldera_storage_volume_available_bytes{pipeline_name=\"${PIPELINE}\"}"
# The manager serves its own series on a separate job, under /v0/metrics, so a
# rule that reads them proves the `feldera-manager` scrape target is live too.
assert_series "pipeline_program_status" \
  "pipeline_program_status{job=\"feldera-manager\",pipeline_name=\"${PIPELINE}\",program_status=\"success\"}"
assert_series "pipeline_program_status_since_timestamp_seconds" \
  "pipeline_program_status_since_timestamp_seconds{job=\"feldera-manager\",pipeline_name=\"${PIPELINE}\"}"

interval="$(query "feldera_checkpoint_interval_seconds{pipeline_name=\"${PIPELINE}\"}")"
[ "${interval}" = "60" ] \
  || fail "the interval gauge reads ${interval}, expected the configured 60"
note "the interval gauge follows the pipeline config, so the stale rule's threshold does too"

say "a healthy install raises nothing"
# The rules are loaded from the checked-in file, so this is the real rule set
# evaluating against the real series. An alert here means the baseline pages on
# a healthy platform, which is the failure mode that makes on-call ignore it.
sleep 30
firing="$(curl --silent --fail "${prom}/api/v1/alerts" \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]["alerts"]
print("\n".join(sorted(a["labels"]["alertname"]+" "+a["labels"].get("pipeline_name","")
                      for a in d if a.get("state")=="firing")))')"
if [ -n "${firing}" ]; then
  printf '%s\n' "${firing}" >&2
  fail "the alert baseline fires on a healthy install"
fi
note "no alert is firing"

# `FelderaScrapeTargetDown` keys on `up`, so both scrape jobs have to be up, not
# just the one whose series were asserted above.
for job in feldera-manager feldera-pipelines; do
  up="$(query "up{job=\"${job}\"}")"
  [ "${up}" = "1" ] || fail "scrape job ${job} is not up (up=${up:-none})"
  note "scrape job ${job} is up"
done

# `wait_for_alert <name>` waits for a named alert to reach `firing` state and
# prints the value the rule's expression took.
wait_for_alert() {
  local name="$1" waited=0 out=""
  while [ "${waited}" -lt "${FAULT_TIMEOUT}" ]; do
    # The alert name is passed as an argv word, not through a heredoc: a
    # heredoc script and the piped JSON would compete for stdin, so the piped
    # document would never reach json.load and every poll would parse nothing.
    out="$(prom_get /api/v1/alerts | python3 -c '
import json, sys
name = sys.argv[1]
try:
    alerts = json.load(sys.stdin)["data"]["alerts"]
except Exception:
    raise SystemExit(0)
for a in alerts:
    if a["labels"]["alertname"] == name and a["state"] == "firing":
        print(a["value"])
        break
' "${name}" || true)"
    [ -n "${out}" ] && { echo "${out}"; return 0; }
    sleep 5; waited=$(( waited + 5 ))
  done
  return 1
}

say "the grace-period rules have the series and the age they need"
# Three rules page on a status that has lasted 15 or 30 minutes:
# FelderaPipelineNotRunning, FelderaProvisioningTimeout and
# FelderaCompileQueueSlow. Waiting one of those deadlines out is not something a
# regression check can do, and lowering the deadline in a copy of the rules
# would test the copy rather than the file under test.
#
# Their firing is proven by `promtool test rules` above, which injects the age
# directly. What is proven here is the half promtool cannot see: that a live
# install exports the status gauge and its companion age gauge, both carrying
# the same `pipeline`/`pipeline_name` pair, since that pair is the join key that
# every one of the three rules matches `on`.
# `pipeline_status` carries one series per combined status -- fifteen of them --
# and exactly one of those is 1. The rules select the status by its label, so
# what has to hold is that exactly one status is selected and that the `since`
# gauge has a single series to join it against.
status_count="$(query "count(pipeline_status{pipeline_name=\"${PIPELINE}\"})")"
status_one="$(query "count(pipeline_status{pipeline_name=\"${PIPELINE}\"} == 1)")"
since_count="$(query "count(pipeline_status_since_timestamp_seconds{pipeline_name=\"${PIPELINE}\"})")"
[ "${status_count}" -ge 1 ] 2>/dev/null \
  || fail "pipeline_status has ${status_count:-0} series for ${PIPELINE}"
[ "${status_one}" = "1" ] || fail "pipeline_status has ${status_one:-0} series equal to 1, expected exactly one"
[ "${since_count}" = "1" ] || fail "pipeline_status_since has ${since_count:-0} series for ${PIPELINE}, expected one"
note "pipeline_status has ${status_count} statuses with one at 1, and its since gauge has one series"

# The join has to be exact or the rule silently matches nothing, and Prometheus
# hides a failed join: the rule simply never fires. So the labels are read off
# the exporters rather than through a query, which would already have applied
# the selector the rule applies.
#
# `pipeline_status` and its age gauge come from the *manager* (`/v0/metrics`),
# not from the pipeline pod. Reading them off the pipeline's Service would find
# nothing and the run would fail on an assertion that is correct, which is the
# failure this script hit on its first live run.
scrape_manager_metrics() {
  kubectl run alert-label-probe --namespace "${NAMESPACE}" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --command -- \
    curl --silent --fail --max-time 20 \
    "http://${MANAGER_SERVICE}.${NAMESPACE}.svc.cluster.local:8080/v0/metrics"
}

metrics_text="$(scrape_manager_metrics 2>/dev/null || true)"
[ -n "${metrics_text}" ] || fail "the label probe pod could not read the manager's /v0/metrics"
# Other pipelines share this exporter, so the line is selected by name before
# its labels are read; taking the first match would read whichever pipeline
# happens to sort first.
status_labels="$(printf '%s\n' "${metrics_text}" \
  | grep -F "pipeline_name=\"${PIPELINE}\"" \
  | sed -n 's/^pipeline_status{\([^}]*\)} 1$/\1/p' | head -1)"
case "${status_labels}" in
  *"pipeline=\"pipeline-${id}\""*"pipeline_name=\"${PIPELINE}\""*) ;;
  *) fail "pipeline_status lacks the pipeline/pipeline_name pair the rules join on (got '${status_labels}')" ;;
esac
since_labels="$(printf '%s\n' "${metrics_text}" \
  | grep -F "pipeline_name=\"${PIPELINE}\"" \
  | sed -n 's/^pipeline_status_since_timestamp_seconds{\([^}]*\)}.*/\1/p' | head -1)"
case "${since_labels}" in
  *"pipeline=\"pipeline-${id}\""*"pipeline_name=\"${PIPELINE}\""*) ;;
  *) fail "the since gauge lacks the same pair, so the join returns nothing (got '${since_labels}')" ;;
esac
note "both series carry the join key: ${status_labels}"

# The compile-queue rule also needs a stage gauge and its age. A pipeline that
# has finished compiling exports `success`, which is the state the rule must not
# fire on.
assert_series "the program stage the compile rule reads" \
  "pipeline_program_status{pipeline_name=\"${PIPELINE}\",program_status=\"success\"}"

say "inject: checkpoints cannot be written"
# The fault that stops checkpoints in the field is a storage volume that cannot
# be written, so this is the real thing rather than a synthetic counter. A root
# pod mounts the same claim and takes write permission away.
pod="$(kubectl get pods --namespace "${NAMESPACE}" \
  -l "feldera.com/pipeline-id=${id}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "${pod}" ]; then
  pod="$(kubectl get pods --namespace "${NAMESPACE}" -o name \
    | sed 's|.*/||' | while read -r candidate; do
        kubectl get pod --namespace "${NAMESPACE}" "${candidate}" \
          -o jsonpath='{.metadata.labels.feldera\.com/pipeline-id}' 2>/dev/null \
          | grep -qx "${id}" && echo "${candidate}" && break
      done)"
fi
[ -n "${pod}" ] || fail "could not find the pipeline pod for ${id}"
note "pipeline pod ${pod}"
kubectl delete pod --namespace "${NAMESPACE}" alert-storage-helper --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: alert-storage-helper
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 0, runAsGroup: 0}
  containers:
    - name: helper
      image: ${RUNNER_IMAGE}
      # The claim is that one pipeline's state directory: the manager mounts it
      # at /var/feldera/storage/<pipeline-id>, so the volume root is the
      # directory the checkpointer writes to. Making the root read-only is
      # therefore the injection; the UUID-named subdirectories are checkpoints,
      # and they are covered so that no stale directory stays writable.
      #
      # No sleep: the mode bits live on the volume, so they outlive the pod,
      # and a pod that exits lets kubectl wait prove the chmod ran rather than
      # trusting that it was applied.
      command: ["sh", "-c", "chmod 500 /storage && find /storage -mindepth 1 -exec chmod 500 {} + && echo done"]
      volumeMounts:
        - {name: storage, mountPath: /storage}
  volumes:
    - name: storage
      persistentVolumeClaim: {claimName: pipeline-${id}-storage}
YAML
kubectl wait --namespace "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Succeeded \
  pod/alert-storage-helper --timeout=180s >/dev/null \
  || fail "the helper pod could not make the storage read-only"
kubectl logs --namespace "${NAMESPACE}" pod/alert-storage-helper >/dev/null 2>&1 \
  || fail "the helper pod produced no output"
note "storage made read-only; waiting for a checkpoint failure"

failures_before="$(query "feldera_checkpoint_failures_total{pipeline_name=\"${PIPELINE}\"}")"
value="$(wait_for_alert FelderaCheckpointFailing || true)"
if [ -n "${value}" ]; then
  note "FelderaCheckpointFailing is firing (${value} failures in the window)"
else
  # A read-only directory can also make the checkpointer retry rather than fail
  # permanently; in that case the age rule is the one that notices, which is
  # exactly why the two rules coexist.
  value="$(wait_for_alert FelderaCheckpointStale || true)"
  [ -n "${value}" ] || fail "neither checkpoint rule fired after storage went read-only"
  note "FelderaCheckpointStale is firing (${value}s past three intervals)"
fi
failures_after="$(query "feldera_checkpoint_failures_total{pipeline_name=\"${PIPELINE}\"}")"
note "failures_total moved ${failures_before:-0} -> ${failures_after:-0}"

say "recovery"
# A later checkpoint has to succeed once the volume is writable again; a
# pipeline that never recovers its durability is still broken even if the alert
# cleared.
kubectl delete pod --namespace "${NAMESPACE}" alert-storage-helper --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: alert-storage-helper
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 0, runAsGroup: 0}
  containers:
    - name: helper
      image: ${RUNNER_IMAGE}
      command: ["sh", "-c", "chmod 777 /storage && find /storage -mindepth 1 -exec chmod 777 {} + && echo done"]
      volumeMounts:
        - {name: storage, mountPath: /storage}
  volumes:
    - name: storage
      persistentVolumeClaim: {claimName: pipeline-${id}-storage}
YAML
kubectl wait --namespace "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Succeeded \
  pod/alert-storage-helper --timeout=180s >/dev/null \
  || fail "the helper pod could not restore write permission"
api_call POST "/v0/pipelines/${PIPELINE}/checkpoint" >/dev/null 2>&1 || true
last_before="$(query "feldera_checkpoint_last_success_timestamp_seconds{pipeline_name=\"${PIPELINE}\"}")"
waited=0
recovered=""
while [ "${waited}" -lt 300 ]; do
  recovered="$(query "feldera_checkpoint_last_success_timestamp_seconds{pipeline_name=\"${PIPELINE}\"}")"
  if [ -n "${recovered}" ] && [ "${recovered}" != "${last_before}" ]; then break; fi
  sleep 5; waited=$(( waited + 5 ))
done
[ -n "${recovered}" ] && [ "${recovered}" != "${last_before}" ] \
  || fail "no checkpoint committed after the volume became writable again"
note "a checkpoint committed at ${recovered}"
# The failure alert is about a rate, so it clears on its own once the window
# has no failures in it; that is the 15-minute `increase` window, not a `for`.
note "the failure alert clears within its 15-minute window without intervention"

say "the runbook links resolve"
# The work order's second deliverable is a runbook link, and a link to a
# heading that was renamed is worse than no link.
missing=0
for anchor in $(grep -o 'alerting\.md#[a-z0-9]*' "${REPO_ROOT}/deploy/config/feldera-alerts.yml" \
  | sed 's/.*#//' | sort -u); do
  python3 - "${REPO_ROOT}/docs/operations/alerting.md" "${anchor}" <<'PY' || missing=$(( missing + 1 ))
import re, sys
doc, anchor = sys.argv[1], sys.argv[2]
text = open(doc).read()
# GitHub's heading anchors: drop punctuation, lowercase, spaces to hyphens.
heads = [re.sub(r'[^a-z0-9 -]', '', h.lower()).replace(' ', '-')
         for h in re.findall(r'^##? (.+)$', text, re.M)]
sys.exit(0 if anchor in heads else 1)
PY
done
[ "${missing}" = "0" ] || fail "${missing} runbook anchor(s) do not resolve in docs/operations/alerting.md"
note "every runbook_url points at a heading that exists"

say "cleaning up the pipeline"
delete_pipeline
say "PASS: the alert baseline parses, its series are exported, a healthy install is quiet, and an injected fault fires"
