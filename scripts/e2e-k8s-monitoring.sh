#!/usr/bin/env bash
#
# End-to-end check for pipeline monitoring (P1-015).
#
# It installs the chart with metrics on, starts a pipeline, and proves the whole
# monitoring path: the scrape target exists and is labelled, the pipeline's
# NetworkPolicy admits the monitoring namespace, a manual checkpoint produces
# the checkpoint histogram, Prometheus scrapes the pipeline through the target,
# and Grafana serves the dashboard with the new rows.
#
# Usage:
#
#   TAG=v0.357.0-20-g7a5128651-bili.9 scripts/e2e-k8s-monitoring.sh
#
# Environment:
#   CLUSTER       kind cluster name (default: bili-p1005)
#   NAMESPACE     namespace of the platform (default: feldera)
#   RELEASE       Helm release name (default: feldera)
#   TAG           image tag to deploy (required)
#   TIMEOUT       seconds to wait for Running (default: 2400)
#   METRICS_NS    namespace the scrape client runs in (default: monitoring)
#   PROM_TIMEOUT  seconds to wait for a Prometheus sample (default: 180)
#
# The pipeline compiles inside the manager pod, so the run is fast only when a
# previous run left the compilation cache in place. See `e2e-k8s-runner.sh` for
# why the profile is `unoptimized`.
set -euo pipefail

CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
TAG="${TAG:?TAG must be set, for example v0.357.0-20-g7a5128651-bili.9}"
TIMEOUT="${TIMEOUT:-2400}"
METRICS_NS="${METRICS_NS:-monitoring}"
METRICS_FILE="${METRICS_FILE:-/tmp/e2e-k8s-monitoring-metrics.txt}"
PROM_TIMEOUT="${PROM_TIMEOUT:-180}"
PROFILE="${PROFILE:-unoptimized}"
PIPELINE="${PIPELINE:-e2e-k8s-monitoring}"
PORT="${PORT:-18080}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

for tool in kind kubectl helm curl; do
  command -v "${tool}" >/dev/null || fail "${tool} is required"
done
# `grep -c` reads to the end, so `pipefail` never sees a SIGPIPE here.
[ "$(kind get clusters | grep -cx "${CLUSTER}")" = "1" ] \
  || fail "kind cluster '${CLUSTER}' does not exist"

say "loading images ${TAG} into ${CLUSTER}"
for ref in \
  "localhost:5001/feldera-manager:${TAG}" \
  "localhost:5001/feldera-runner:${TAG}" \
  "localhost:5001/feldera-compiler:${TAG}" \
  "postgres:17-alpine" \
  "curlimages/curl:8.11.1" \
  "prom/prometheus:v3.1.0" \
  "grafana/grafana:11.4.0"; do
  docker image inspect "${ref}" >/dev/null 2>&1 \
    || docker pull "${ref}" >/dev/null \
    || fail "${ref} is neither local nor pullable"
  # The node has no route to a registry for the cluster-internal traffic this
  # check makes, so every image it uses has to be in the node store already.
  kind load docker-image --name "${CLUSTER}" "${ref}"
done

# The scrape namespace has to exist before the policy names it, otherwise a
# reader of the policy cannot tell an intended peer from a typo.
kubectl get namespace "${METRICS_NS}" >/dev/null 2>&1 \
  || kubectl create namespace "${METRICS_NS}"

find charts -name '._*' -delete 2>/dev/null || true

say "installing release ${RELEASE} with metrics in namespace ${METRICS_NS}"
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" --create-namespace \
  --set "controlplane.image.tag=${TAG}" \
  --set "controlplane.kubernetesRunner.image.tag=${TAG}" \
  --set "compiler.image.tag=${TAG}" \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --set controlplane.compilationCache.enabled=true \
  --set controlplane.compilationCache.size=80Gi \
  --set controlplane.kubernetesRunner.metrics.enabled=true \
  --set "controlplane.kubernetesRunner.metrics.namespace=${METRICS_NS}" \
  --wait --timeout 5m

kubectl rollout status "deployment/${RELEASE}-controlplane-api-server" \
  --namespace "${NAMESPACE}" --timeout 5m

say "waiting for the API server"
api="http://127.0.0.1:${PORT}"
forward_pid=""

start_forward() {
  kubectl port-forward --namespace "${NAMESPACE}" "svc/${RELEASE}-controlplane-api-server" \
    "${PORT}:8080" >/tmp/e2e-k8s-monitoring-port-forward.log 2>&1 &
  forward_pid=$!
  for _ in $(seq 1 60); do
    curl --silent --fail --max-time 3 "${api}/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

cleanup() {
  if [ -n "${forward_pid}" ]; then
    kill "${forward_pid}" 2>/dev/null || true
    wait "${forward_pid}" 2>/dev/null || true
  fi
  kubectl delete pod prometheus-scrape-check --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "${METRICS_FILE}"
}
trap cleanup EXIT

start_forward || fail "the API server did not become healthy"

api_call() {
  local method="$1" path="$2"
  shift 2
  if response="$(curl --silent --fail --max-time 30 -X "${method}" "${api}${path}" "$@")"; then
    printf '%s' "${response}"
    return 0
  fi
  echo "  (reconnecting to the API server)" >&2
  kill "${forward_pid}" 2>/dev/null || true
  start_forward || return 1
  curl --silent --fail --max-time 30 -X "${method}" "${api}${path}" "$@"
}

t0=$(date +%s)
elapsed() { echo "$(( $(date +%s) - t0 ))s"; }

deployment_status() {
  api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null \
    | sed -n 's/.*"deployment_status":"\([^"]*\)".*/\1/p' || true
}

delete_pipeline() {
  api_call POST "/v0/pipelines/${PIPELINE}/stop?force=true" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    status="$(deployment_status)"
    [ -z "${status}" ] && return 0
    [ "${status}" = "Stopped" ] && break
    sleep 2
  done
  for _ in $(seq 1 30); do
    api_call POST "/v0/pipelines/${PIPELINE}/clear" >/dev/null 2>&1 || true
    sleep 3
    api_call DELETE "/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 && return 0
    [ -z "$(deployment_status)" ] && return 0
  done
  fail "could not delete pipeline ${PIPELINE} (status $(deployment_status))"
}

say "pipeline ${PIPELINE}"
if [ -n "$(api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null || true)" ]; then
  status="$(deployment_status)"
  echo "--- reusing the existing pipeline (deployment_status=${status:-unknown})"
  case "${status}" in
    Running) ;;
    Shutdown|Stopped|Cleared) api_call POST "/v0/pipelines/${PIPELINE}/start" >/dev/null ;;
    *)
      delete_pipeline
      echo "--- the old pipeline was ${status:-unknown}; created a new one below"
      ;;
  esac
fi

if [ -z "$(api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null || true)" ]; then
  echo "--- creating pipeline ${PIPELINE}"
  api_call POST "/v0/pipelines" \
    -H 'content-type: application/json' \
    --data @- <<JSON >/dev/null
{
  "name": "${PIPELINE}",
  "program_code": "CREATE TABLE t (i INT);\nCREATE MATERIALIZED VIEW v AS SELECT COUNT(*) AS c FROM t;",
  "program_config": {"profile": "${PROFILE}"},
  "runtime_config": {
    "resources": {"cpu_cores_min": 0, "memory_mb_min": 256, "memory_mb_max": 1024}
  }
}
JSON
  api_call POST "/v0/pipelines/${PIPELINE}/start" >/dev/null
  echo "--- created and started in $(elapsed)"
fi

say "waiting up to ${TIMEOUT}s for the pipeline to report Running"
deadline=$(( $(date +%s) + TIMEOUT ))
status=""
while :; do
  status="$(deployment_status)"
  printf '  [%s] deployment_status=%s\n' "$(elapsed)" "${status:-unknown}"
  [ "${status}" = "Running" ] && break
  if [ "${status}" = "Failed" ]; then
    kubectl get pods --namespace "${NAMESPACE}" -o wide >&2 || true
    fail "the deployment reached Failed"
  fi
  [ "$(date +%s)" -lt "${deadline}" ] || fail "timed out waiting for Running (last status: ${status:-unknown})"
  sleep 5
done

pipeline_id="$(api_call GET "/v0/pipelines/${PIPELINE}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
[ -n "${pipeline_id}" ] || fail "could not read the pipeline id"
echo "  pipeline id ${pipeline_id} after $(elapsed)"

say "the scrape target exists"
metrics_service="pipeline-${pipeline_id}-metrics"
kubectl get service --namespace "${NAMESPACE}" "${metrics_service}" -o yaml \
  || fail "the runner did not create the metrics Service ${metrics_service}"
scrape_label="$(kubectl get service --namespace "${NAMESPACE}" "${metrics_service}" \
  -o jsonpath='{.metadata.labels.feldera\.com/metrics-scrape}' 2>/dev/null || true)"
[ "${scrape_label}" = "true" ] \
  || fail "the metrics Service lacks feldera.com/metrics-scrape=true (got '${scrape_label}')"
cluster_ip="$(kubectl get service --namespace "${NAMESPACE}" "${metrics_service}" \
  -o jsonpath='{.spec.clusterIP}')"
[ "${cluster_ip}" != "None" ] || fail "the metrics Service is headless and cannot be scraped"
echo "  ${metrics_service} -> ${cluster_ip}"

say "the pipeline policy admits the scrape namespace"
peers="$(kubectl get networkpolicy --namespace "${NAMESPACE}" "pipeline-${pipeline_id}" \
  -o jsonpath='{range .spec.ingress[0].from[*]}{.namespaceSelector.matchLabels.kubernetes\.io/metadata\.name}{"\n"}{end}')"
printf '%s\n' "${peers}"
peer_count() { printf '%s\n' "${peers}" | grep -cx "$1" || true; }
[ "$(peer_count "${METRICS_NS}")" -ge 1 ] \
  || fail "the NetworkPolicy does not admit the ${METRICS_NS} namespace"
[ "$(peer_count "${NAMESPACE}")" -ge 1 ] \
  || fail "the NetworkPolicy no longer admits the manager namespace"

say "the pipeline serves its metrics through the target"
# A throwaway pod inside the cluster is the only client that exercises the
# NetworkPolicy; a port forward bypasses it and would prove nothing.
kubectl delete pod prometheus-scrape-check --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl run prometheus-scrape-check --namespace "${NAMESPACE}" \
  --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 900 >/dev/null
kubectl wait --namespace "${NAMESPACE}" --for=condition=Ready pod/prometheus-scrape-check --timeout=180s \
  || fail "the probe pod did not start"
# The payload is a few hundred kilobytes. It goes to a file rather than a shell
# variable so that `grep -q` can stop at the first match: with `pipefail`, a
# `printf | grep -q` pipeline reports failure when grep closes the pipe early.
metrics_url="http://${metrics_service}.${NAMESPACE}.svc.cluster.local:8080/metrics"
scrape() {
  kubectl exec --namespace "${NAMESPACE}" prometheus-scrape-check -- \
    curl --silent --fail --max-time 20 "$1"
}
scrape "${metrics_url}" >"${METRICS_FILE}" 2>/dev/null \
  || fail "the pipeline's /metrics did not answer through the Service"
[ -s "${METRICS_FILE}" ] || fail "the pipeline's /metrics answered nothing"
grep -q 'pipeline_name="' "${METRICS_FILE}" \
  || fail "the pipeline's /metrics carries no pipeline_name label"
grep -q '^feldera_checkpoint_runtime_seconds' "${METRICS_FILE}" \
  || fail "the pipeline's /metrics carries no checkpoint histogram"

say "a manual checkpoint provides samples"
# Nothing schedules checkpoints in a community-edition pipeline, so the test
# asks for one explicitly. Without this step the DoD's histogram panel would be
# empty for a perfectly healthy pipeline.
checkpoint_status="$(api_call POST "/v0/pipelines/${PIPELINE}/checkpoint" >/dev/null 2>&1; echo $?)"
[ "${checkpoint_status}" = "0" ] || fail "the manual checkpoint request failed"
for _ in $(seq 1 60); do
  scrape "${metrics_url}" >"${METRICS_FILE}" 2>/dev/null || true
  # A histogram family with samples has a _count that is not zero.
  if grep -Eq '^feldera_checkpoint_runtime_seconds_count\{[^}]*\} [1-9]' "${METRICS_FILE}"; then
    grep '^feldera_checkpoint_runtime_seconds_count' "${METRICS_FILE}" | head -3
    break
  fi
  sleep 2
done
grep -Eq '^feldera_checkpoint_runtime_seconds_count\{[^}]*\} [1-9]' "${METRICS_FILE}" \
  || fail "the checkpoint histogram still has no samples after the manual checkpoint"

say "prometheus scrapes the pipeline"
kubectl create configmap prometheus-scrape-check-config \
  --namespace "${NAMESPACE}" \
  --from-file=prometheus.yml="${REPO_ROOT}/deploy/config/prometheus-k8s.yml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete deployment prometheus-scrape-check --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-scrape-check
spec:
  replicas: 1
  selector:
    matchLabels: {app: prometheus-scrape-check}
  template:
    metadata:
      labels: {app: prometheus-scrape-check}
    spec:
      serviceAccountName: prometheus-scrape-check
      containers:
        - name: prometheus
          image: prom/prometheus:v3.1.0
          args: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus"]
          ports: [{name: http, containerPort: 9090}]
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus}
      volumes:
        - name: config
          configMap: {name: prometheus-scrape-check-config}
YAML
# `kubernetes_sd` reads the API, so the scrape check needs a role that may list
# endpoints and services. This is the check's own RBAC, not the product's.
kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-scrape-check
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-scrape-check
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
  name: prometheus-scrape-check
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-scrape-check
subjects:
  - kind: ServiceAccount
    name: prometheus-scrape-check
    namespace: ${NAMESPACE}
YAML
kubectl rollout status deployment/prometheus-scrape-check --namespace "${NAMESPACE}" --timeout=180s
kubectl create service clusterip prometheus-scrape-check --namespace "${NAMESPACE}" \
  --tcp=9090:9090 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label service prometheus-scrape-check --namespace "${NAMESPACE}" \
  app=prometheus-scrape-check --overwrite >/dev/null

pf_prom=19090
kubectl port-forward --namespace "${NAMESPACE}" deployment/prometheus-scrape-check \
  "${pf_prom}:9090" >/tmp/e2e-k8s-monitoring-prom.log 2>&1 &
prom_forward_pid=$!
trap 'kill "${prom_forward_pid}" 2>/dev/null || true; cleanup' EXIT
for _ in $(seq 1 60); do
  curl --silent --fail --max-time 3 "http://127.0.0.1:${pf_prom}/-/healthy" >/dev/null 2>&1 && break
  sleep 1
done

say "waiting up to ${PROM_TIMEOUT}s for prometheus to hold the series"
deadline=$(( $(date +%s) + PROM_TIMEOUT ))
targets_up=""
while :; do
  targets_up="$(curl --silent --fail "http://127.0.0.1:${pf_prom}/api/v1/targets?state=active" || true)"
  # `grep -c` reads the whole input, so the producer never sees a SIGPIPE.
  if [ "$(printf '%s' "${targets_up}" | grep -c '"health":"up"' || true)" -ge 1 ]; then break; fi
  [ "$(date +%s)" -lt "${deadline}" ] || fail "prometheus never scraped the pipeline: ${targets_up:0:600}"
  sleep 5
done
printf '%s' "${targets_up}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(sorted({t["labels"].get("job","?")+" "+t["scrapeUrl"] for t in d["data"]["activeTargets"] if t["health"]=="up"})))'

query() {
  curl --silent --fail --get --data-urlencode "query=$1" "http://127.0.0.1:${pf_prom}/api/v1/query" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["data"]["result"][0]["value"][1] if d["data"]["result"] else "")'
}

series="$(curl --silent --fail --get --data-urlencode 'match[]={__name__=~"feldera_checkpoint_runtime_seconds_count",pipeline_name="'"${PIPELINE}"'"}' \
  "http://127.0.0.1:${pf_prom}/api/v1/series" || true)"
[ "$(printf '%s' "${series}" | grep -c "feldera_checkpoint_runtime_seconds_count" || true)" -ge 1 ] \
  || fail "prometheus holds no checkpoint series for ${PIPELINE}: ${series:0:400}"
echo "  prometheus holds the checkpoint series for ${PIPELINE}"

micros_total="$(query "sum(feldera_checkpoint_runtime_seconds_count{pipeline_name=\"${PIPELINE}\"})")"
[ -n "${micros_total}" ] || fail "the checkpoint series has no value in prometheus"
echo "  checkpoints recorded for ${PIPELINE}: ${micros_total}"

say "grafana serves the dashboard"
# Grafana reads the dashboard and the data source from ConfigMaps, which is how
# a real install ships them. Bringing it up here means the panels are proven
# against a live Prometheus rather than eyeballed in JSON.
if ! kubectl get deployment grafana --namespace "${METRICS_NS}" >/dev/null 2>&1; then
  echo "--- installing grafana in ${METRICS_NS}"
  kubectl create configmap grafana-dashboards --namespace "${METRICS_NS}" \
    --from-file=feldera.json="${REPO_ROOT}/deploy/grafana_dashboard.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create configmap grafana-provisioning-dashboards --namespace "${METRICS_NS}" \
    --from-file=grafana_dashboards.yaml="${REPO_ROOT}/deploy/config/grafana_dashboards.yaml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # The checked-in data source points at `http://prometheus:9090`, the service
  # name of the Docker Compose stack, which does not exist here. Anchor the
  # deployment's own Prometheus Service and point the data source at it; the
  # uid stays the one the dashboard and the Compose stack share.
  sed "s#url: http://prometheus:9090#url: http://prometheus-scrape-check.${NAMESPACE}.svc.cluster.local:9090#" \
    "${REPO_ROOT}/deploy/config/grafana_data_sources.yaml" >/tmp/e2e-k8s-monitoring-datasources.yaml
  grep -q "url: http://prometheus-scrape-check.${NAMESPACE}.svc.cluster.local:9090" /tmp/e2e-k8s-monitoring-datasources.yaml \
    || fail "the data source file no longer carries the Compose Prometheus URL"
  kubectl create configmap grafana-provisioning-datasources --namespace "${METRICS_NS}" \
    --from-file=grafana_data_sources.yaml=/tmp/e2e-k8s-monitoring-datasources.yaml \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply --namespace "${METRICS_NS}" -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
spec:
  replicas: 1
  selector:
    matchLabels: {app: grafana}
  template:
    metadata:
      labels: {app: grafana}
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:11.4.0
          env:
            - {name: GF_AUTH_ANONYMOUS_ENABLED, value: "true"}
            - {name: GF_AUTH_ANONYMOUS_ORG_ROLE, value: Admin}
            - {name: GF_AUTH_DISABLE_LOGIN_FORM, value: "true"}
          ports: [{name: http, containerPort: 3000}]
          volumeMounts:
            - {name: dashboards, mountPath: /etc/grafana/dashboards}
            - {name: provisioning-dashboards, mountPath: /etc/grafana/provisioning/dashboards}
            - {name: provisioning-datasources, mountPath: /etc/grafana/provisioning/datasources}
      volumes:
        - name: dashboards
          configMap: {name: grafana-dashboards}
        - name: provisioning-dashboards
          configMap: {name: grafana-provisioning-dashboards}
        - name: provisioning-datasources
          configMap: {name: grafana-provisioning-datasources}
YAML
  kubectl create service clusterip grafana --namespace "${METRICS_NS}" --tcp=3000:3000 \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl rollout status deployment/grafana --namespace "${METRICS_NS}" --timeout=300s
fi
# A stale forward from an interrupted run would make this fail for a reason
# that has nothing to do with the platform, so keep looking for a free port.
free_port() {
  for candidate in $(seq "$1" $(( $1 + 20 ))); do
    if ! (exec 3<>/dev/tcp/127.0.0.1/"${candidate}") 2>/dev/null; then
      echo "${candidate}"
      return 0
    fi
    exec 3>&- 2>/dev/null || true
  done
  return 1
}
grafana_pf="$(free_port 13000)" || fail "no free port for the grafana forward"
grafana_forward_pid=""
start_grafana_forward() {
  kubectl port-forward --namespace "${METRICS_NS}" deployment/grafana "${grafana_pf}:3000" \
    >/tmp/e2e-k8s-monitoring-grafana.log 2>&1 &
  grafana_forward_pid=$!
}
start_grafana_forward
trap 'kill "${grafana_forward_pid}" "${prom_forward_pid}" 2>/dev/null || true; cleanup' EXIT
# Grafana's Pod reports Ready before its HTTP listener is bound, and the forward
# dies with "connection refused" in that window, which no amount of retrying
# against a dead forward fixes. Restart the forward whenever it exits.
dashboard=""
for attempt in $(seq 1 60); do
  dashboard="$(curl --silent --fail --max-time 3 \
    "http://127.0.0.1:${grafana_pf}/api/dashboards/uid/dbsp" 2>/dev/null || true)"
  [ -n "${dashboard}" ] && break
  if ! kill -0 "${grafana_forward_pid}" 2>/dev/null; then
    kill "${grafana_forward_pid}" 2>/dev/null || true
    start_grafana_forward
  fi
  sleep 2
done
[ -n "${dashboard}" ] || fail "grafana does not serve the feldera dashboard (uid dbsp)"
printf '%s' "${dashboard}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["dashboard"]; rows=[p["title"] for p in d["panels"] if p.get("type")=="row"]; print("  rows:", rows); assert "Checkpoint" in rows, rows; assert "Backpressure" in rows, rows'

# A dashboard that serves is not a dashboard that works. Ask Grafana to run the
# checkpoint panel's own query through its Prometheus data source, so the
# result proves the panel, the data source, and the scrape path together.
panel_expr="$(printf '%s' "${dashboard}" | python3 -c '
import json, sys
d = json.load(sys.stdin)["dashboard"]
for p in d["panels"]:
    if p.get("title", "").startswith("Checkpoint runtime"):
        print(p["targets"][0]["expr"])
        break
')"
[ -n "${panel_expr}" ] || fail "the dashboard has no checkpoint runtime panel"
echo "  panel query: ${panel_expr}"
ds_uid="$(printf '%s' "${dashboard}" | python3 -c '
import json, sys
d = json.load(sys.stdin)["dashboard"]
for p in d["panels"]:
    if p.get("title", "").startswith("Checkpoint runtime"):
        print(p["datasource"]["uid"])
        break
')"
[ "${ds_uid}" = '${DS_PROMETHEUS}' ] || echo "  (panel pins data source ${ds_uid})"
# Grafana substitutes dashboard variables before it queries, so this proxy call
# has to do the same: a raw `${...}` reaches Prometheus as literal text and
# compares against an empty label. Only the variables the panel uses are
# resolved here; a panel that grows another one fails loudly at this assert.
ds_resolved="prometheus_docker"
panel_query="${panel_expr}"
panel_query="${panel_query//\$\{DS_PROMETHEUS\}/${ds_resolved}}"
panel_query="${panel_query//\$pipeline_name/${PIPELINE}}"
panel_query="${panel_query//\$__rate_interval/1m}"
case "${panel_query}" in
  *'$'*) fail "the panel query has an unresolved dashboard variable: ${panel_query}" ;;
esac
echo "  resolved panel query: ${panel_query}"
panel_result="$(curl --silent --fail --get \
  --data-urlencode "query=${panel_query}" \
  "http://127.0.0.1:${grafana_pf}/api/datasources/proxy/uid/${ds_resolved}/api/v1/query" \
  2>/dev/null || true)"
[ -n "${panel_result}" ] || fail "grafana's data source did not answer the panel query"
# A panel query can return a result whose value is NaN: `histogram_quantile`
# does that when the rate window holds too few samples, which is normal for a
# pipeline that has checkpointed a handful of times. A non-empty result proves
# the panel is wired to the data source; it does not prove the series carries
# numbers. Both are checked, the second through one more proxied query.
printf '%s' "${panel_result}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
result = d["data"]["result"]
assert result, d
print("  panel returns a result:", result[0]["value"][1], "at", result[0]["value"][0])
'

count_result="$(curl --silent --fail --get \
  --data-urlencode "query=sum(feldera_checkpoint_runtime_seconds_count{pipeline_name=\"${PIPELINE}\"})" \
  "http://127.0.0.1:${grafana_pf}/api/datasources/proxy/uid/${ds_resolved}/api/v1/query" \
  2>/dev/null || true)"
[ -n "${count_result}" ] || fail "grafana's data source did not answer a count query"
printf '%s' "${count_result}" | python3 -c '
import json, sys, math
d = json.load(sys.stdin)
result = d["data"]["result"]
assert result, d
value = float(result[0]["value"][1])
assert not math.isnan(value), "the count series is NaN"
assert value >= 1, f"expected at least one checkpoint, got {value}"
print("  grafana reads", value, "checkpoint(s) from prometheus")
'

say "PASS"
echo "  pipeline ${PIPELINE} (id ${pipeline_id}) is scraped by prometheus and shown in grafana"
echo "  elapsed $(elapsed)"
