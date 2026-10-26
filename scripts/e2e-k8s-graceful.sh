#!/usr/bin/env bash
#
# End-to-end check for graceful shutdown and resume (P1-016).
#
# It starts a fault-tolerant pipeline, pushes records into it, kills the pod
# with `SIGTERM` the way the kubelet does (not through the manager's API), and
# then starts the pipeline again. The second run has to come back with the
# records the first run ingested, which is only possible if the exit checkpoint
# was written and read back.
#
# Usage:
#
#   TAG=v0.357.0-20-g7a5128651-bili.14 scripts/e2e-k8s-graceful.sh
#
# Environment:
#   CLUSTER      kind cluster name (default: bili-p1005)
#   NAMESPACE    namespace of the platform (default: feldera)
#   RELEASE      Helm release name (default: feldera)
#   TAG          image tag to deploy (required)
#   TIMEOUT      seconds to wait for Running (default: 2400)
#   RECORDS      records to push before the kill (default: 1000)
#   GRACE        terminationGracePeriodSeconds (default: 120)
#   PROFILE      compilation profile (default: unoptimized)
#   PIPELINE     pipeline name (default: e2e-k8s-graceful)
#   PORT         local port for the API-forward (default: 18081)
#
# The pipeline compiles inside the manager pod, so the run is fast only when a
# previous run left the compilation cache in place.
set -euo pipefail

CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
TAG="${TAG:?TAG must be set, for example v0.357.0-20-g7a5128651-bili.14}"
TIMEOUT="${TIMEOUT:-2400}"
RECORDS="${RECORDS:-1000}"
GRACE="${GRACE:-0}"
PROFILE="${PROFILE:-unoptimized}"
PIPELINE="${PIPELINE:-e2e-k8s-graceful}"
PORT="${PORT:-18081}"

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
  "postgres:17-alpine"; do
  docker image inspect "${ref}" >/dev/null 2>&1 \
    || docker pull "${ref}" >/dev/null \
    || fail "${ref} is neither local nor pullable"
  kind load docker-image --name "${CLUSTER}" "${ref}"
done

find charts -name '._*' -delete 2>/dev/null || true

# The pipeline template is what gives the pod a grace period and what lets the
# runner mount the storage claim up front. Both have to be in place before the
# chart is installed, because the runner reads the template when it provisions,
# not when it starts.
template_file="${REPO_ROOT}/deploy/pipeline-template.example.yaml"
[ -f "${template_file}" ] || fail "${template_file} is missing"
# The example is itself a ConfigMap that holds the template under
# `data.pipelineTemplate`; feeding the whole manifest to `--from-file` would
# install a ConfigMap whose value is that manifest, and the runner would then
# fail to parse it into a StatefulSet.
template_body=/tmp/e2e-k8s-graceful-template.yaml
python3 - "${template_file}" "${template_body}" <<'PY'
import sys, yaml
example, out = sys.argv[1], sys.argv[2]
with open(example) as handle:
    manifest = yaml.safe_load(handle)
body = manifest["data"]["pipelineTemplate"]
with open(out, "w") as handle:
    handle.write(body)
PY
# A template that does not set a grace period long enough for a checkpoint
# would make the kubelet `SIGKILL` the pod mid-write. Read the value the chart
# is about to install instead of restating it in this script, so the two cannot
# drift apart.
template_grace="$(python3 -c '
import sys, yaml
with open(sys.argv[1]) as handle:
    template = yaml.safe_load(handle)
print(template["spec"]["template"]["spec"]["terminationGracePeriodSeconds"])
' "${template_body}")"
[ -n "${template_grace}" ] \
  || fail "${template_file} sets no terminationGracePeriodSeconds"
[ "${template_grace}" -ge 60 ] \
  || fail "${template_file} gives the pod ${template_grace}s, too short for an exit checkpoint"
echo "  the template gives the pod ${template_grace}s to exit"
GRACE="${template_grace}"

kubectl create configmap e2e-pipeline-template \
  --namespace "${NAMESPACE}" \
  --from-file=pipelineTemplate="${template_body}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

say "installing release ${RELEASE}"
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" --create-namespace \
  --set "controlplane.image.tag=${TAG}" \
  --set "controlplane.kubernetesRunner.image.tag=${TAG}" \
  --set "compiler.image.tag=${TAG}" \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --set controlplane.compilationCache.enabled=true \
  --set controlplane.compilationCache.size=80Gi \
  --set controlplane.kubernetesRunner.template.configMap=e2e-pipeline-template \
  --set controlplane.kubernetesRunner.template.key=pipelineTemplate \
  --wait --timeout 5m

kubectl rollout status "deployment/${RELEASE}-controlplane-api-server" \
  --namespace "${NAMESPACE}" --timeout 5m

say "waiting for the API server"
api="http://127.0.0.1:${PORT}"
forward_pid=""

start_forward() {
  kubectl port-forward --namespace "${NAMESPACE}" "svc/${RELEASE}-controlplane-api-server" \
    "${PORT}:8080" >/tmp/e2e-k8s-graceful-port-forward.log 2>&1 &
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
}
trap cleanup EXIT

start_forward || fail "the API server did not become healthy"

api_call() {
  local method="$1" path="$2"
  shift 2
  if response="$(curl --silent --fail --max-time 60 -X "${method}" "${api}${path}" "$@")"; then
    printf '%s' "${response}"
    return 0
  fi
  echo "  (reconnecting to the API server)" >&2
  kill "${forward_pid}" 2>/dev/null || true
  start_forward || return 1
  curl --silent --fail --max-time 60 -X "${method}" "${api}${path}" "$@"
}

t0=$(date +%s)
elapsed() { echo "$(( $(date +%s) - t0 ))s"; }

deployment_status() {
  api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null \
    | sed -n 's/.*"deployment_status":"\([^"]*\)".*/\1/p' || true
}

# The pipeline descriptor carries both the runtime status and the storage
# details; there is no per-pipeline `/status` endpoint (the manager reads these
# same fields when it decides whether a pipeline has come back).
runtime_status() {
  api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null \
    | sed -n 's/.*"deployment_runtime_status":"\([^"]*\)".*/\1/p' || true
}

wait_for_running() {
  local deadline=$(( $(date +%s) + $1 )) status=""
  while :; do
    status="$(runtime_status)"
    printf '  [%s] runtime_status=%s\n' "$(elapsed)" "${status:-unknown}"
    [ "${status}" = "Running" ] && return 0
    if [ "${status}" = "Unavailable" ] || [ "$(deployment_status)" = "Failed" ]; then
      kubectl get pods --namespace "${NAMESPACE}" -o wide >&2 || true
      kubectl logs --namespace "${NAMESPACE}" --selector="feldera.com/pipeline-id" \
        --tail=40 >&2 2>/dev/null || true
      fail "the pipeline did not become healthy (status ${status:-unknown})"
    fi
    [ "$(date +%s)" -lt "${deadline}" ] \
      || fail "timed out waiting for Running (last status: ${status:-unknown})"
    sleep 5
  done
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
  echo "--- removing the pipeline this check left behind last time"
  delete_pipeline
fi

# The table is fed through the HTTP API rather than a data generator, because
# the assertion below is an exact count: a generator would produce a different
# number of rows after a restart, and "roughly the same" cannot tell a restored
# checkpoint from a fresh bootstrap.
echo "--- creating pipeline ${PIPELINE}"
api_call POST "/v0/pipelines" \
  -H 'content-type: application/json' \
  --data @- <<JSON >/dev/null
{
  "name": "${PIPELINE}",
  "program_code": "CREATE TABLE t (i INT NOT NULL);\nCREATE MATERIALIZED VIEW v AS SELECT COUNT(*) AS c FROM t;",
  "program_config": {"profile": "${PROFILE}"},
  "runtime_config": {
    "resources": {"cpu_cores_min": 0, "memory_mb_min": 256, "memory_mb_max": 1024},
    "fault_tolerance": {"model": "at_least_once", "checkpoint_interval_secs": 10}
  }
}
JSON

say "starting the pipeline"
# `bootstrap_policy=allow` is the first start: there is no checkpoint yet, so
# the pipeline bootstraps from scratch. The second start below uses the same
# policy and finds a checkpoint, which it restores without asking.
api_call POST "/v0/pipelines/${PIPELINE}/start?bootstrap_policy=allow" >/dev/null
wait_for_running "${TIMEOUT}"
pipeline_id="$(api_call GET "/v0/pipelines/${PIPELINE}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
[ -n "${pipeline_id}" ] || fail "could not read the pipeline id"
echo "  pipeline id ${pipeline_id} Running after $(elapsed)"

pod="pipeline-${pipeline_id}-0"
kubectl get pod --namespace "${NAMESPACE}" "${pod}" >/dev/null \
  || fail "the runner did not create pod ${pod}"

# The runner reports the mount path it baked into the deployment; the storage
# directory the controller writes to lives under it. Asserting the directory
# exists now means the checkpoint below has somewhere to go.
say "the pipeline sees its storage directory"
storage_dir="/var/feldera/storage/${pipeline_id}"
kubectl exec --namespace "${NAMESPACE}" "${pod}" -- test -d "${storage_dir}" \
  || fail "the pipeline pod has no storage directory at ${storage_dir}"
echo "  ${storage_dir} exists in ${pod}"

# The query returns one row with one column; the column's spelling depends on
# how the SQL compiler folds `AS c`, so read the single value instead of the
# key.
count_from_json() {
  python3 -c '
import json, sys
body = json.load(sys.stdin)
# A one-row result arrives as the row itself when the pipeline answers in
# `format=json`; multi-row results arrive as a list. Both are one row here.
rows = body if isinstance(body, list) else [body]
assert len(rows) == 1, f"expected one row, got {body!r}"
values = list(rows[0].values())
assert len(values) == 1, f"expected one column, got {rows[0]!r}"
print(values[0])
'
}

say "pushing ${RECORDS} records"
# One request with a newline-separated CSV body; the manager forwards it to the
# pipeline's `/ingress` endpoint and waits for the pipeline to accept the data.
seq 1 "${RECORDS}" >/tmp/e2e-k8s-graceful-records.csv
api_call POST "/v0/pipelines/${PIPELINE}/ingress/t?format=csv&force=true" \
  -H 'content-type: text/plain' \
  --data-binary @/tmp/e2e-k8s-graceful-records.csv \
  >/dev/null
echo "  pushed in $(elapsed)"

count_before="$(api_call GET "/v0/pipelines/${PIPELINE}/query?sql=SELECT%20c%20FROM%20v&format=json" \
  | count_from_json)"
echo "  view reports ${count_before} records"
[ "${count_before}" = "${RECORDS}" ] \
  || fail "the view reports ${count_before} records after pushing ${RECORDS}"

say "waiting for a scheduled checkpoint"
# Fault tolerance is what schedules checkpoints; without one this check would
# be testing a kill with nothing on disk to recover from. The status endpoint
# reports what the pipeline knows about, which is the same surface the manager
# reads (`storage_status_details`), so it does not depend on the storage
# crate's on-disk layout.
checkpoint_count=0
for _ in $(seq 1 60); do
  checkpoint_count="$(api_call GET "/v0/pipelines/${PIPELINE}" 2>/dev/null \
    | python3 -c '
import json, sys
pipeline = json.load(sys.stdin)
details = pipeline.get("storage_status_details") or {}
print(len(details.get("checkpoints") or []))
' 2>/dev/null || true)"
  [ "${checkpoint_count:-0}" -ge 1 ] && break
  checkpoint_count=0
  sleep 2
done
[ "${checkpoint_count:-0}" -ge 1 ] \
  || fail "the pipeline reported no checkpoint in 120s, so there is nothing to resume from"
echo "  the pipeline reports ${checkpoint_count} checkpoint(s)"

say "stopping the pod with SIGTERM, bypassing the manager"
# `kubectl scale` is the kubelet's path: the StatefulSet controller deletes the
# pod, which sends SIGTERM to the pipeline process and waits
# `terminationGracePeriodSeconds`. The manager's `/stop` would call `/suspend`
# over HTTP instead, which is the path that already worked. Scaling rather than
# `kubectl delete pod` matters too: deleting a pod a StatefulSet owns recreates
# it immediately, so there would be no stopped window to resume from.
#
# The log is followed in the background because a terminated pod's log goes
# away with the pod object; reading it afterwards would race the controller.
shutdown_log=/tmp/e2e-k8s-graceful-shutdown.log
: >"${shutdown_log}"
kubectl logs --namespace "${NAMESPACE}" "${pod}" --follow >"${shutdown_log}" 2>/dev/null &
log_pid=$!
kill_start=$(date +%s)
kubectl scale statefulset --namespace "${NAMESPACE}" "pipeline-${pipeline_id}" --replicas=0 >/dev/null
echo "  scaled the StatefulSet to 0"

# The exit checkpoint is what the handler writes; the log proves it ran and
# that it finished rather than being killed mid-write.
say "the shutdown handler checkpointed before exiting"
for _ in $(seq 1 "${GRACE}"); do
  grep -q 'exit checkpoint written' "${shutdown_log}" && break
  sleep 1
done
wait "${log_pid}" 2>/dev/null || true
grep -q 'SIGTERM received' "${shutdown_log}" \
  || fail "the pod log shows no SIGTERM handler (last lines: $(tail -5 "${shutdown_log}"))"
grep -q 'exit checkpoint written' "${shutdown_log}" \
  || fail "the shutdown handler did not finish its checkpoint (last lines: $(tail -5 "${shutdown_log}"))"
kill_seconds=$(( $(date +%s) - kill_start ))
echo "  SIGTERM to exit checkpoint: ${kill_seconds}s"

# A pod that runs out of grace is `SIGKILL`ed and reports 137. The handler
# exits with 0 after the checkpoint, so the code is the observable difference
# between "checkpointed and stopped" and "kept working until the kubelet killed
# it". The pod object is gone once the controller finishes deleting it, so this
# reads the code while the terminated pod is still there.
exit_code="$(kubectl get pod --namespace "${NAMESPACE}" "${pod}" \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || true)"
if [ -z "${exit_code}" ]; then
  exit_code="$(kubectl get pod --namespace "${NAMESPACE}" "${pod}" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
fi
if [ -n "${exit_code}" ]; then
  [ "${exit_code}" = "0" ] \
    || fail "the pipeline exited with ${exit_code}; 137 means the kubelet had to SIGKILL it"
  echo "  pod terminated with exit code ${exit_code}"
else
  # The controller removed the pod before this read. The log line above is
  # then the evidence: a SIGKILLed pipeline never writes it.
  echo "  the pod was already reclaimed; the checkpoint log line is the evidence"
fi

say "the storage claim survived the kill"
claim="pipeline-${pipeline_id}-storage"
kubectl get persistentvolumeclaim --namespace "${NAMESPACE}" "${claim}" >/dev/null \
  || fail "the storage claim ${claim} did not survive the pod deletion"

say "starting again, with no bootstrap approval"
# The pipeline is not running but the manager still wants it to be: settle it
# with a forced stop so the next start is a real start and not a no-op.
api_call POST "/v0/pipelines/${PIPELINE}/stop?force=true" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  status="$(deployment_status)"
  [ "${status}" = "Stopped" ] && break
  sleep 2
done
# No `bootstrap_policy` argument: the default is `await_approval`, which the
# manager only asks for when there is no checkpoint to restore. Reaching
# `Running` without an approval therefore proves the pipeline restored instead
# of bootstrapping.
api_call POST "/v0/pipelines/${PIPELINE}/start" >/dev/null
wait_for_running "${TIMEOUT}"
pod="pipeline-${pipeline_id}-0"
kubectl get pod --namespace "${NAMESPACE}" "${pod}" >/dev/null \
  || fail "the pipeline did not come back"
echo "  Running again after $(elapsed)"

count_after="$(api_call GET "/v0/pipelines/${PIPELINE}/query?sql=SELECT%20c%20FROM%20v&format=json" \
  | count_from_json)"
echo "  view reports ${count_after} records"
# A bootstrap would report 0: the table is fed by HTTP, and nothing replays the
# pushes. The count surviving is the checkpoint coming back.
[ "${count_after}" = "${RECORDS}" ] \
  || fail "the view reports ${count_after} records after the restart; expected ${RECORDS} (a fresh bootstrap would report 0)"

say "the restart left no duplicate objects"
statefulsets="$(kubectl get statefulset --namespace "${NAMESPACE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -cx "pipeline-${pipeline_id}" || true)"
[ "${statefulsets}" = "1" ] \
  || fail "expected one StatefulSet for the pipeline, found ${statefulsets}"

say "cleaning up"
delete_pipeline
kubectl delete configmap e2e-pipeline-template --namespace "${NAMESPACE}" \
  --ignore-not-found >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  left="$(kubectl get statefulset,pod,service,networkpolicy,persistentvolumeclaim \
    --namespace "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep -c "pipeline-${pipeline_id}" || true)"
  [ "${left}" = "0" ] && break
  sleep 2
done
[ "${left}" = "0" ] || fail "cleanup left ${left} objects carrying pipeline-${pipeline_id}"

say "PASS"
echo "  pipeline ${PIPELINE} (id ${pipeline_id}) checkpointed on SIGTERM and resumed with ${count_after} records"
echo "  elapsed $(elapsed)"
