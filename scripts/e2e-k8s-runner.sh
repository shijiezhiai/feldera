#!/usr/bin/env bash
#
# End-to-end check for the Kubernetes pipeline runner (P1-009).
#
# It loads the manager and runner images into a `kind` cluster, installs the
# chart with the Kubernetes runner enabled, creates and starts a pipeline, and
# waits until the manager reports it as Running. The pipeline itself runs in its
# own StatefulSet-managed pod, so a green run proves the whole path: RBAC,
# resource rendering, pod scheduling, program download from the compiler
# service, and the readiness probe that flips the deployment to Running.
#
# Usage:
#
#   TAG=v0.357.0-20-g7a5128651-bili.2 scripts/e2e-k8s-runner.sh
#
# Environment:
#   CLUSTER    kind cluster name (default: bili-p1005)
#   NAMESPACE  Kubernetes namespace (default: feldera)
#   RELEASE    Helm release name (default: feldera)
#   TAG        image tag to deploy; both manager and runner use it (required)
#   TIMEOUT    seconds to wait for the pipeline to reach Running (default: 2400)
#
# The pipeline compiles its program inside the manager pod. `dev` is the
# manager's default profile, but cargo's `dev` profile carries full debug info,
# which turns the final mold link of a 1 GB binary into a 25 minute, 8.8 GB
# resident step. `unoptimized` (defined by the generated workspace as release
# with `opt-level = 0` and no debug info) keeps the product on the manager's
# default while making this test cheap: the link stays a few minutes at most.
#
# With REUSE=1 (the default) the pipeline is created once and started again on
# every later run. A stopped pipeline keeps its program, so the next run skips
# compilation entirely and reaches Running in seconds. Set REUSE=0 to exercise
# the create-then-delete path and assert that no Kubernetes resources leak.
set -euo pipefail

CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
TAG="${TAG:?TAG must be set, for example v0.357.0-20-g7a5128651-bili.2}"
TIMEOUT="${TIMEOUT:-2400}"
# The compile profile decides how long the pipeline takes to build inside the
# manager pod. A cold `optimized` build of dbsp plus the generated program takes
# roughly two hours on a 10-core machine, and `dev` spends most of its time
# linking a binary with full debug info. The end-to-end test verifies the
# Kubernetes runner, not the optimizer, so it defaults to `unoptimized`; set
# PROFILE=optimized to exercise the default product profile.
PROFILE="${PROFILE:-unoptimized}"
# Reusing the pipeline makes repeat runs cheap: no compilation at all, and the
# pod only has to be scaled up from zero.
REUSE="${REUSE:-1}"
PIPELINE="${PIPELINE:-e2e-k8s-${PROFILE}}"
PORT="${PORT:-18080}"
# A cold compile of the generated Rust program takes hours inside the control
# plane pod, so the claim is on by default here: a re-run then compiles in
# seconds. Set COMPILATION_CACHE=0 to test the "no StorageClass" path.
COMPILATION_CACHE_SIZE="${COMPILATION_CACHE_SIZE:-80Gi}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s\n' "$*"; }

for tool in kind kubectl helm curl; do
  command -v "${tool}" >/dev/null || {
    echo "error: ${tool} is required" >&2
    exit 1
  }
done

say "kind cluster ${CLUSTER}"
kind get clusters | grep -qx "${CLUSTER}" || {
  echo "error: kind cluster '${CLUSTER}' does not exist" >&2
  exit 1
}

say "loading images ${TAG} into ${CLUSTER}"
# 三张 feldera 镜像 + postgres：kind 没有 registry，节点只能看见 `kind load`
# 送进去的镜像；漏一张就是 ImagePullBackOff（编译器漏了 pod 起不来，db 漏了
# 整条链起不来）。
for ref in \
  "localhost:5001/feldera-manager:${TAG}" \
  "localhost:5001/feldera-runner:${TAG}" \
  "localhost:5001/feldera-compiler:${TAG}" \
  "postgres:17-alpine"; do
  docker image inspect "${ref}" >/dev/null 2>&1 || {
    echo "error: ${ref} is not available locally" >&2
    exit 1
  }
  kind load docker-image --name "${CLUSTER}" "${ref}"
done

say "installing release ${RELEASE} in namespace ${NAMESPACE}"
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" --create-namespace \
  --set "controlplane.image.tag=${TAG}" \
  --set "controlplane.kubernetesRunner.image.tag=${TAG}" \
  --set "compiler.image.tag=${TAG}" \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --set controlplane.compilationCache.enabled=true \
  --set "controlplane.compilationCache.size=${COMPILATION_CACHE_SIZE:-80Gi}" \
  --wait --timeout 5m

kubectl rollout status "deployment/${RELEASE}-controlplane-api-server" \
  --namespace "${NAMESPACE}" --timeout 5m

say "waiting for the API server"
api="http://127.0.0.1:${PORT}"
forward_pid=""

# A port forward outlives nothing: the API server restarting, or the tunnel
# simply dropping after a long idle period, both leave curl failing. Restart
# the tunnel whenever a request fails instead of letting `set -e` end the run.
start_forward() {
  kubectl port-forward --namespace "${NAMESPACE}" "svc/${RELEASE}-controlplane-api-server" \
    "${PORT}:8080" >/tmp/e2e-k8s-runner-port-forward.log 2>&1 &
  forward_pid=$!
  for _ in $(seq 1 60); do
    if curl --silent --fail --max-time 3 "${api}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  if [ -n "${forward_pid}" ]; then
    kill "${forward_pid}" 2>/dev/null || true
    wait "${forward_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_forward || {
  echo "error: the API server did not become healthy" >&2
  exit 1
}

# `api_call METHOD PATH [curl args...]` retries once over a fresh tunnel.
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

# `delete_pipeline` walks the states the API requires, and each step only
# accepts one state: stop until the deployment reports Stopped, clear until the
# storage is released, then delete. Every step is asynchronous, so the loop
# retries instead of sleeping a fixed amount and hoping.
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
    if api_call DELETE "/v0/pipelines/${PIPELINE}" >/dev/null 2>&1; then
      return 0
    fi
    [ -z "$(deployment_status)" ] && return 0
  done
  echo "error: could not delete pipeline ${PIPELINE} (status $(deployment_status))" >&2
  return 1
}

say "pipeline ${PIPELINE} (profile=${PROFILE} reuse=${REUSE})"
existing="$(api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null || true)"
if [ -n "${existing}" ] && [ "${REUSE}" = "1" ]; then
  status="$(printf '%s' "${existing}" \
    | sed -n 's/.*"deployment_status":"\([^"]*\)".*/\1/p')"
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

if [ -n "${existing}" ]; then
  # REUSE=0 的语义是「跑一遍干净的」：上一轮留下的 pipeline 必须删掉，否则脚本
  # 会走 /start 复用它的状态（数据、程序、存储目录），断言值就不再是 3。
  echo "--- deleting the previous pipeline ${PIPELINE} (reuse=0)"
  delete_pipeline
  sleep 2
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
  status="$(api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null \
    | sed -n 's/.*"deployment_status":"\([^"]*\)".*/\1/p' || true)"
  printf '  [%s] deployment_status=%s\n' "$(elapsed)" "${status:-unknown}"
  case "${status}" in
    Running) break ;;
    Failed)
      # Shutdown and Stopping are transient right after /start, so only a
      # failure ends the wait; everything else falls through to the timeout.
      echo "error: the deployment reached ${status}" >&2
      kubectl get pods --namespace "${NAMESPACE}" -l "app.kubernetes.io/name=feldera-pipeline" -o wide >&2 || true
      exit 1
      ;;
  esac
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "error: timed out waiting for Running (last status: ${status:-unknown})" >&2
    kubectl get pods --namespace "${NAMESPACE}" -o wide >&2 || true
    exit 1
  fi
  sleep 5
done

say "pipeline pod"
kubectl get pods --namespace "${NAMESPACE}" \
  -l "app.kubernetes.io/name=feldera-pipeline,app.kubernetes.io/managed-by=feldera-pipeline-manager" -o wide

pipeline_id="$(api_call GET "/v0/pipelines/${PIPELINE}" \
  | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
kubectl get statefulset,service,networkpolicy,pod --namespace "${NAMESPACE}" \
  -l "feldera.com/pipeline-id=${pipeline_id}" -o wide

say "checking the manager reaches the pipeline over the Service"
network_policy="$(kubectl get networkpolicy --namespace "${NAMESPACE}" \
  "pipeline-${pipeline_id}" -o name 2>/dev/null || true)"
[ -n "${network_policy}" ] || {
  echo "error: the runner did not create a NetworkPolicy for the pipeline" >&2
  exit 1
}
# The manager polls the pipeline's /status through the headless Service; the
# result of the last poll is what the API reports as resource details.
details="$(api_call GET "/v0/pipelines/${PIPELINE}" \
  | sed -n 's/.*"deployment_resources_status_details":\({.*\}\)[,}].*/\1/p')"
printf '  resources status details: %s\n' "${details:-<none>}"
echo "${details}" | grep -q '"http_status":200' || {
  echo "error: the manager has not read the pipeline's /status endpoint yet: ${details}" >&2
  exit 1
}
# The pipeline reports its runtime state as `runtime_status`; a running
# pipeline must say so in the body the manager read.
echo "${details}" | grep -q '"runtime_status":"Running"' || {
  echo "error: the /status report does not say the pipeline is running: ${details}" >&2
  exit 1
}

say "pipeline pod logs (tail)"
kubectl logs --namespace "${NAMESPACE}" "pipeline-${pipeline_id}-0" --tail 10 || true

say "checking the manager collected the pipeline's stdout"
# The manager follows the pod's log stream into the pipeline log API. A line the
# pipeline itself printed is the proof that the follower, the RBAC rule for
# `pods/log` and the log store all work.
# The log endpoint streams: it sends the stored lines and then keeps the
# connection open waiting for new ones, so the transfer ends at our deadline
# instead of at a Content-Length. A timeout is therefore the expected outcome,
# and the assertion below is what decides whether the lines arrived.
logs="$(curl --silent --max-time 20 "${api}/v0/pipelines/${PIPELINE}/logs" || true)"
if ! echo "${logs}" | grep -q "Pipeline initialization complete"; then
  echo "error: the pipeline log API carries the pipeline's own lines: ${logs:0:800}" >&2
  exit 1
fi
echo "  pipeline log API carries $(echo "${logs}" | grep -c .) lines"

say "ingesting into and querying the running pipeline"
PF_PORT="${PF_PORT:-18082}"
if lsof -nP -iTCP:"${PF_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port ${PF_PORT} is busy; refusing to tunnel through an unknown forwarder" >&2
  lsof -nP -iTCP:"${PF_PORT}" -sTCP:LISTEN >&2 || true
  exit 1
fi
kubectl port-forward --namespace "${NAMESPACE}" "pod/pipeline-${pipeline_id}-0" \
  "${PF_PORT}:8080" >/dev/null 2>&1 &
pf_pid=$!
trap 'kill "${pf_pid}" 2>/dev/null || true' EXIT
sleep 3
# The ingress endpoint defaults to CSV, and with format=json the default update
# format is "raw", which wants a bare JSON *string* per line. The insert/delete
# envelope is what the docs use, so ask for it explicitly.
ingest_status="$(curl --silent --output /tmp/e2e-ingest-body -w '%{http_code}' \
  -X POST "http://127.0.0.1:${PF_PORT}/ingress/t?format=json&update_format=insert_delete" \
  -H 'content-type: application/json' \
  --data '{"insert":{"i":1}}
{"insert":{"i":2}}
{"insert":{"i":2}}')"
[ "${ingest_status}" = "200" ] || {
  echo "error: ingest returned ${ingest_status}: $(cat /tmp/e2e-ingest-body)" >&2
  exit 1
}
query_url="http://127.0.0.1:${PF_PORT}/query"
rows="$(curl --silent --fail --get "${query_url}" --data-urlencode 'sql=SELECT c FROM v' \
  --data-urlencode 'format=json')"
printf '  query result: %s\n' "${rows}"
kill "${pf_pid}" 2>/dev/null || true
trap - EXIT
echo "${rows}" | grep -q '"c":3' || {
  echo "error: expected the view to report 3 rows, got: ${rows}" >&2
  exit 1
}

if [ "${REUSE}" = "1" ]; then
  say "keeping pipeline ${PIPELINE} for the next run (REUSE=1; set REUSE=0 to delete it)"
  # Stop it so the pod goes away, but keep the program so the next run skips
  # compilation and only has to scale the StatefulSet back up.
  api_call POST "/v0/pipelines/${PIPELINE}/shutdown" >/dev/null 2>&1 || true
  say "PASS: pipeline ${PIPELINE} reached Running and served a query in $(elapsed)"
  exit 0
fi

say "cleaning up pipeline ${PIPELINE}"
delete_pipeline

sleep 5
orphans="$(kubectl get statefulset,service,networkpolicy,persistentvolumeclaim --namespace "${NAMESPACE}" \
  -l "feldera.com/pipeline-id=${pipeline_id}" -o name 2>/dev/null || true)"
[ -z "${orphans}" ] || {
  echo "error: resources left behind after delete: ${orphans}" >&2
  exit 1
}

say "PASS: pipeline ${PIPELINE} reached Running, served a query and was cleaned up in $(elapsed)"
