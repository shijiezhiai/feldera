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
# The first pipeline of a fresh manager pod compiles the generated Rust program
# inside that pod, so a cold cargo target directory needs tens of minutes. Later
# pipelines reuse the directory below and reach Running in a couple of minutes.
set -euo pipefail

CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
TAG="${TAG:?TAG must be set, for example v0.357.0-20-g7a5128651-bili.2}"
TIMEOUT="${TIMEOUT:-2400}"
# The compile profile decides how long the pipeline takes to build inside the
# manager pod. A cold `optimized` build of dbsp plus the generated program takes
# roughly two hours on a 10-core machine, whereas `dev` takes well under an hour.
# The end-to-end test verifies the Kubernetes runner, not the optimizer, so it
# defaults to the cheap profile; set PROFILE=optimized to exercise the default.
PROFILE="${PROFILE:-dev}"
PIPELINE="e2e-k8s-$$"
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
for image in feldera-manager feldera-runner; do
  ref="localhost:5001/${image}:${TAG}"
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
  if response="$(curl --silent --fail --max-time 10 -X "${method}" "${api}${path}" "$@")"; then
    printf '%s' "${response}"
    return 0
  fi
  echo "  (reconnecting to the API server)" >&2
  kill "${forward_pid}" 2>/dev/null || true
  start_forward || return 1
  curl --silent --fail --max-time 10 -X "${method}" "${api}${path}" "$@"
}

say "creating and starting pipeline ${PIPELINE}"
api_call DELETE "/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 || true
api_call POST "/v0/pipelines" \
  -H 'content-type: application/json' \
  --data @- <<JSON >/dev/null
{
  "name": "${PIPELINE}",
  "program_code": "CREATE TABLE t (i INT);\nCREATE VIEW v AS SELECT COUNT(*) AS c FROM t;",
  "program_config": {"profile": "${PROFILE}"},
  "runtime_config": {
    "resources": {"cpu_cores_min": 0, "memory_mb_min": 256, "memory_mb_max": 1024}
  }
}
JSON
api_call POST "/v0/pipelines/${PIPELINE}/start" >/dev/null

say "waiting up to ${TIMEOUT}s for the pipeline to report Running"
deadline=$(( $(date +%s) + TIMEOUT ))
status=""
while :; do
  status="$(api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null \
    | sed -n 's/.*"deployment_status":"\([^"]*\)".*/\1/p' || true)"
  printf '  deployment_status=%s\n' "${status:-unknown}"
  case "${status}" in
    Running) break ;;
    Failed|Shutdown|Cleared|Stopping)
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
kubectl get statefulset,service,pod --namespace "${NAMESPACE}" \
  -l "feldera.com/pipeline-id=${pipeline_id}" -o wide

say "pipeline pod logs (tail)"
kubectl logs --namespace "${NAMESPACE}" "pipeline-${pipeline_id}-0" --tail 10 || true

say "ingesting into and querying the running pipeline"
PF_PORT="${PF_PORT:-18082}"
kubectl port-forward --namespace "${NAMESPACE}" "pod/pipeline-${pipeline_id}-0" \
  "${PF_PORT}:8080" >/dev/null 2>&1 &
pf_pid=$!
trap 'kill "${pf_pid}" 2>/dev/null || true' EXIT
sleep 3
curl --silent --fail -X POST "http://127.0.0.1:${PF_PORT}/ingress/t" \
  -H 'content-type: application/json' --data '[{"i":1},{"i":2},{"i":2}]' >/dev/null
rows="$(curl --silent --fail "http://127.0.0.1:${PF_PORT}/query" \
  --get --data-urlencode 'sql=SELECT c FROM v')"
printf '  query result: %s\n' "${rows}"
kill "${pf_pid}" 2>/dev/null || true
trap - EXIT
echo "${rows}" | grep -q '"c":3' || {
  echo "error: expected the view to report 3 rows, got: ${rows}" >&2
  exit 1
}

say "cleaning up pipeline ${PIPELINE}"
api_call POST "/v0/pipelines/${PIPELINE}/shutdown" >/dev/null 2>&1 || true
sleep 3
api_call DELETE "/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 || true

sleep 5
orphans="$(kubectl get statefulset,service,persistentvolumeclaim --namespace "${NAMESPACE}" \
  -l "feldera.com/pipeline-id=${pipeline_id}" -o name 2>/dev/null || true)"
[ -z "${orphans}" ] || {
  echo "error: resources left behind after delete: ${orphans}" >&2
  exit 1
}

say "PASS: pipeline ${PIPELINE} reached Running, served a query and was cleaned up"
