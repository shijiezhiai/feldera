#!/usr/bin/env bash
#
# Fault-injection matrix over the Kubernetes runner (P1-028).
#
# Each cell injects one fault at one fault-tolerance tier and asserts what the
# platform promises for that tier: the data watermark after recovery and the
# duplicate rate. The tiers are the ones in
# `design/self-hosted-enterprise-platform-plan.md` §5.5:
#
#   L1  graceful restart: exit checkpoint on SIGTERM, resume with nothing lost
#   L2  at-least-once:    periodic checkpoints, resume at the last completed one
#
# The matrix is five faults times the two tiers. Not every cell can promise the
# same thing -- deleting the storage claim of a pipeline whose only copy of the
# state was on that claim destroys the state, and the honest assertion there is
# that the platform notices and the operator can see it -- so each cell states
# its own expectation next to the code that checks it.
#
# Usage:
#
#   # the whole matrix
#   TAG=v0.357.0-52-gc13e46766-bili.1 bash scripts/e2e-k8s-chaos.sh
#
#   # one fault, both tiers
#   FAULTS=kill-pod TAG=... bash scripts/e2e-k8s-chaos.sh
#
#   # one cell
#   CELLS=kill-pod:L1 TAG=... bash scripts/e2e-k8s-chaos.sh
#
# Environment:
#   CLUSTER      kind cluster name (default: bili-p1005)
#   NAMESPACE    namespace of the platform (default: feldera)
#   RELEASE      Helm release name (default: feldera)
#   TAG          image tag for all three images (or set the three below)
#   MANAGER_TAG  manager image tag (default: TAG)
#   RUNNER_TAG   runner image tag (default: TAG)
#   COMPILER_TAG compiler image tag (default: TAG)
#   TIMEOUT      seconds to wait for Running (default: 2400)
#   MAX_START_RETRIES  how many times to retry a start that failed during
#                initialization (default: 3). A connector that cannot reach its
#                input fails the whole start, and the automaton does not retry
#                it, so the script does.
#   RECORDS      records to push before the fault (default: 1000)
#   PROFILE      compilation profile (default: unoptimized)
#   PORT         local port for the API-forward. Defaults to a free port, so a
#                run cannot join a forward another run left behind -- attaching
#                to the wrong API server makes every assertion meaningless.
#   START_TIMEOUT seconds to wait for a pipeline to reach Running (default:
#               900). Provisioning a cold pipeline waits for the storage claim
#                to bind and for the pod to pull and start a ~600 MB binary;
#                that is not the fault under test, so it gets its own budget
#                rather than eating into the one that bounds the injection.
#   KAFKA_IMAGE  broker image for the Kafka cells (default: apache/kafka:3.9.0)
#   CELLS        comma-separated <fault>:<tier> cells (default: the matrix)
#   FAULTS       comma-separated faults, expanding to both tiers
#   KEEP         set to 1 to leave the pipelines behind for inspection
#   RTO_LIMIT    seconds a crash may take to serve its view again (default:
#                120). Only kill-pod:L2 measures it; it is the P1 exit
#                criterion for a crashed pod, so the cell fails rather than
#                reports when it slips.
#
# The pipeline compiles inside the manager pod, so a run is fast only when a
# previous run left the compilation cache in place.
set -euo pipefail
# A cell that dies without a message teaches nothing: `set -e` exits quietly on
# an unguarded command and the matrix then prints a bare FAIL. The trap makes
# the shell name the line it was running, so the next silent failure is a
# diagnosis instead of a rerun.
set -E
trap 'rc=$?; printf "error: %s:%s exited %s running: %s\n" \
  "${BASH_SOURCE[0]}" "${LINENO}" "${rc}" "${BASH_COMMAND}" >&2' ERR

CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
# CI builds all three images under one tag, so TAG alone is enough there. A
# hand-built platform usually does not: the runner is a slow-moving base that
# the other two are layered on, and rebuilding it costs more than it changes.
# Name any of the three separately when they differ.
TAG="${TAG:-}"
MANAGER_TAG="${MANAGER_TAG:-${TAG}}"
RUNNER_TAG="${RUNNER_TAG:-${TAG}}"
COMPILER_TAG="${COMPILER_TAG:-${TAG}}"
[ -n "${MANAGER_TAG}" ] && [ -n "${RUNNER_TAG}" ] && [ -n "${COMPILER_TAG}" ] \
  || fail "set TAG, or MANAGER_TAG/RUNNER_TAG/COMPILER_TAG individually"
# The image the chaos helper pods run: any image with a shell works, and the
# runner is the one image guaranteed to be on the node.
RUNNER_IMAGE="localhost:5001/feldera-runner:${RUNNER_TAG}"
START_TIMEOUT="${START_TIMEOUT:-900}"
# A start that fails during initialization is retried. Three attempts covers a
# broker that needs a moment to accept connections without hiding a pipeline
# that genuinely cannot start.
MAX_START_RETRIES="${MAX_START_RETRIES:-3}"
TIMEOUT="${TIMEOUT:-2400}"
RECORDS="${RECORDS:-1000}"
PROFILE="${PROFILE:-unoptimized}"
PORT="${PORT:-}"
if [ -z "${PORT}" ]; then
  # Ask the kernel for a port nothing is listening on.
  PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
fi
KAFKA_IMAGE="${KAFKA_IMAGE:-apache/kafka:3.9.0}"
KAFKA_SERVICE="chaos-kafka"
KAFKA_TOPIC="chaos-input"
KEEP="${KEEP:-0}"
# The P1 exit criterion for a crashed pod: serving again within two minutes.
# Only the kill-pod:L2 cell measures it; the others are not time-bounded.
RTO_LIMIT="${RTO_LIMIT:-120}"

FAULTS_ALL="kill-pod delete-pvc drop-postgres drop-storage drop-kafka"
if [ -n "${CELLS:-}" ]; then
  cells="${CELLS}"
elif [ -n "${FAULTS:-}" ]; then
  cells=""
  IFS=',' read -ra faults <<<"${FAULTS}"
  for fault in "${faults[@]}"; do
    cells="${cells}${cells:+,}${fault}:L1,${fault}:L2"
  done
else
  cells=""
  for fault in ${FAULTS_ALL}; do
    cells="${cells}${cells:+,}${fault}:L1,${fault}:L2"
  done
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Both write to stderr. Several helpers are called as `x="$(f ...)"`, and a
# progress line on stdout would silently become part of the captured value --
# `start_pipeline` returning "still starting (Provisioning)... <id>" turned the
# pod name into a string that never matched a pod, which read as a pipeline that
# consumed nothing.
say() { printf '\n=== %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

# Results, one line per cell, printed as a matrix at the end and used as the
# exit status: a cell that did not run is as much a failure as one that failed,
# because a matrix with holes cannot claim the property it stands for.
results=()
record() { results+=("$1|$2|$3"); }

t0=$(date +%s)
elapsed() { echo "$(( $(date +%s) - t0 ))s"; }

for tool in kind kubectl helm curl python3; do
  command -v "${tool}" >/dev/null || fail "${tool} is required"
done
[ "$(kind get clusters | grep -cx "${CLUSTER}")" = "1" ] \
  || fail "kind cluster '${CLUSTER}' does not exist"

# ---------------------------------------------------------------------------
# Cluster setup
# ---------------------------------------------------------------------------

say "loading images (manager ${MANAGER_TAG}, runner ${RUNNER_TAG}, compiler ${COMPILER_TAG})"
for ref in \
  "localhost:5001/feldera-manager:${MANAGER_TAG}" \
  "localhost:5001/feldera-runner:${RUNNER_TAG}" \
  "localhost:5001/feldera-compiler:${COMPILER_TAG}" \
  "postgres:17-alpine"; do
  docker image inspect "${ref}" >/dev/null 2>&1 \
    || docker pull "${ref}" >/dev/null \
    || fail "${ref} is neither local nor pullable"
  kind load docker-image --name "${CLUSTER}" "${ref}"
done

# A compiler or database StatefulSet is a single replica, so `OnDelete`-style
# drift leaves an old pod running the previous image forever and `helm upgrade`
# then waits for a rollout that never happens. Delete those pods before the
# upgrade rather than discovering it through a five-minute timeout.
say "recycling the single-replica control-plane pods so they pick up the images"
for sts in "${RELEASE}-compiler" "${RELEASE}-db"; do
  kubectl get statefulset --namespace "${NAMESPACE}" "${sts}" >/dev/null 2>&1 \
    && kubectl delete pod --namespace "${NAMESPACE}" "${sts}-0" --ignore-not-found
done

find charts -name '._*' -delete 2>/dev/null || true

template_file="${REPO_ROOT}/deploy/pipeline-template.example.yaml"
[ -f "${template_file}" ] || fail "${template_file} is missing"
template_body=/tmp/e2e-k8s-chaos-template.yaml
python3 - "${template_file}" "${template_body}" <<'PY'
import sys, yaml
example, out = sys.argv[1], sys.argv[2]
with open(example) as handle:
    manifest = yaml.safe_load(handle)
with open(out, "w") as handle:
    handle.write(manifest["data"]["pipelineTemplate"])
PY
# A grace period shorter than a checkpoint would make the kubelet SIGKILL the
# pod mid-write, which turns every L1 cell into an L2 cell by accident. Read the
# value the chart installs instead of restating it here.
template_grace="$(python3 -c '
import sys, yaml
with open(sys.argv[1]) as handle:
    template = yaml.safe_load(handle)
print(template["spec"]["template"]["spec"]["terminationGracePeriodSeconds"])
' "${template_body}")"
[ "${template_grace}" -ge 60 ] \
  || fail "${template_file} gives the pod ${template_grace}s, too short for an exit checkpoint"
note "the template gives the pod ${template_grace}s to exit"

kubectl create configmap e2e-pipeline-template \
  --namespace "${NAMESPACE}" \
  --from-file=pipelineTemplate="${template_body}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

say "installing release ${RELEASE}"
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" --create-namespace \
  --set "controlplane.image.tag=${MANAGER_TAG}" \
  --set "controlplane.kubernetesRunner.image.tag=${RUNNER_TAG}" \
  --set "compiler.image.tag=${COMPILER_TAG}" \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --set controlplane.compilationCache.enabled=true \
  --set controlplane.compilationCache.size=80Gi \
  --set controlplane.kubernetesRunner.template.configMap=e2e-pipeline-template \
  --set controlplane.kubernetesRunner.template.key=pipelineTemplate \
  --wait --timeout 10m
kubectl rollout status "deployment/${RELEASE}-controlplane-api-server" \
  --namespace "${NAMESPACE}" --timeout 5m

# ---------------------------------------------------------------------------
# API access
# ---------------------------------------------------------------------------

say "waiting for the API server"
api="http://127.0.0.1:${PORT}"
forward_pid=""

start_forward() {
  kubectl port-forward --namespace "${NAMESPACE}" "svc/${RELEASE}-controlplane-api-server" \
    "${PORT}:8080" >/tmp/e2e-k8s-chaos-port-forward.log 2>&1 &
  forward_pid=$!
  for _ in $(seq 1 60); do
    curl --silent --fail --max-time 3 "${api}/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

kafka_pid=""
cleanup() {
  for pid in "${forward_pid}" "${kafka_pid}"; do
    [ -n "${pid}" ] && { kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; }
  done
  kubectl delete deployment --namespace "${NAMESPACE}" "${KAFKA_SERVICE}" \
    --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete service --namespace "${NAMESPACE}" "${KAFKA_SERVICE}" \
    --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pod --namespace "${NAMESPACE}" chaos-storage-helper \
    --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT
start_forward || fail "the API server did not become healthy"

# One request against the API. A 4xx/5xx answer is an answer and is returned as
# a failure of this call; only a broken connection is retried, because the
# port-forward dies every time the manager pod is replaced. Retrying an HTTP
# error would turn a 404 into a minute of reconnecting and make callers that
# poll for a row to disappear look like they hung.
api_call() {
  local method="$1" path="$2"
  shift 2
  local status=0
  response="$(curl --silent --fail --max-time 120 -X "${method}" "${api}${path}" "$@")" || status=$?
  if [ "${status}" -eq 0 ] || [ "${status}" -eq 22 ]; then
    printf '%s' "${response}"
    return "${status}"
  fi
  echo "  (reconnecting to the API server)" >&2
  kill "${forward_pid}" 2>/dev/null || true
  start_forward || return 1
  curl --silent --fail --max-time 120 -X "${method}" "${api}${path}" "$@"
}

pipeline_json() {
  api_call GET "/v0/pipelines/$1" 2>/dev/null || true
}

field_of() {
  # `field_of <json> <name>`: the string value of a flat JSON field.
  sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1
}

# `deployment_status` is the automaton's state: Provisioning, Initializing,
# Running, Stopping, Stopped, Failed. It is the field an operator acts on, so
# every cell waits on it and nothing else.
deployment_status() { field_of "$(pipeline_json "$1")" deployment_status; }


wait_for_running() {
  local name="$1" seconds="$2" deadline=$(( $(date +%s) + $2 ))
  local retries=0
  while :; do
    status="$(deployment_status "${name}")"
    if [ "${status}" = "Running" ]; then
      return 0
    fi
    if [ "${status}" = "Failed" ]; then
      kubectl get pods --namespace "${NAMESPACE}" -o wide >&2 || true
      fail "pipeline ${name} did not become healthy: $(pipeline_json "${name}")"
    fi
    if [ "${status}" = "Stopped" ] && [ "${retries}" -lt "${MAX_START_RETRIES}" ]; then
      # The automaton gives up on a start that fails during initialization, and
      # a start fails when a connector cannot reach its input. That is a real
      # failure of this start rather than a slow one, so retry it here instead of
      # spending the rest of the budget polling a pipeline that is not going
      # anywhere. The retries are counted locally: the pipeline descriptor has
      # no start counter to read.
      retries=$(( retries + 1 ))
      note "start attempt ${retries} of ${MAX_START_RETRIES} failed; trying again"
      api_call POST "/v0/pipelines/${name}/start" >/dev/null 2>&1 || true
      sleep 10
    fi
    [ "$(date +%s)" -lt "${deadline}" ] \
      || fail "timed out waiting for pipeline ${name} to be Running (last status: ${status:-unknown}, ${retries} start retries)"
    elapsed=$(( deadline - $(date +%s) ))
    case $(( elapsed % 60 )) in
    [0-9]|[1-4][0-9]) note "still starting (${status:-none}); ${elapsed}s left" ;;
    esac
    sleep 5
  done
}

delete_pipeline() {
  local name="$1"
  api_call POST "/v0/pipelines/${name}/stop?force=true" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    # An empty answer means the row is already gone; asking for its status
    # would then poll a 404 until the budget ran out.
    if [ -z "$(pipeline_json "${name}")" ]; then return 0; fi
    [ "$(deployment_status "${name}")" = "Stopped" ] && break
    sleep 2
  done
  for _ in $(seq 1 30); do
    api_call POST "/v0/pipelines/${name}/clear" >/dev/null 2>&1 || true
    sleep 3
    api_call DELETE "/v0/pipelines/${name}" >/dev/null 2>&1 && return 0
    if [ -z "$(pipeline_json "${name}")" ]; then return 0; fi
  done
  fail "could not delete pipeline ${name}"
}

# ---------------------------------------------------------------------------
# Data-plane helpers
#
# Everything that reads the pipeline goes straight to the pod instead of
# through the manager. That is deliberate: one of the cells drops PostgreSQL,
# and the manager resolves a pipeline's address from the database before it
# proxies a request (`runner/interaction.rs`, `check_pipeline`), so
# going through it would measure the control plane rather than the pipeline
# that the cell is about.
# ---------------------------------------------------------------------------

pod_of() {
  local id="$1"
  echo "pipeline-${id}-0"
}

# Kill the process a pod runs, and leave the restart to the kubelet.
#
# `kubectl exec <pod> -- kill -9 1` does not do this. The kernel discards
# SIGKILL and SIGSTOP sent to the init process of a PID namespace from inside
# that namespace, so the command returns success and nothing dies -- a cell built
# on it passes without ever injecting the fault. The signal has to come from the
# node's namespace: on a kind cluster the node is a container, and on a plain node
# this has to run on the node itself with `crictl` on PATH.
crash_container_of_pod() {
  local pod="$1" node cid pid
  node="$(kubectl get pod --namespace "${NAMESPACE}" "${pod}" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  [ -n "${node}" ] || fail "the pod ${pod} has no node"

  if docker exec "${node}" true >/dev/null 2>&1; then
    cid="$(docker exec "${node}" crictl ps 2>/dev/null \
      | awk -v pod="${pod}" '!seen && index($0, pod) { print $1; seen = 1 }')"
    [ -n "${cid}" ] || fail "no container for ${pod} on node ${node}"
    pid="$(docker exec "${node}" crictl inspect "${cid}" 2>/dev/null \
      | python3 -c 'import json,sys; print((json.load(sys.stdin).get("info") or {}).get("pid") or 0)')"
    [ "${pid:-0}" -gt 0 ] || fail "container ${cid} has no init pid"
    docker exec "${node}" kill -9 "${pid}" >/dev/null 2>&1 \
      || fail "the process ${pid} of ${pod} could not be killed"
  elif command -v crictl >/dev/null 2>&1; then
    cid="$(crictl ps 2>/dev/null | awk -v pod="${pod}" '!seen && index($0, pod) { print $1; seen = 1 }')"
    [ -n "${cid}" ] || fail "no container for ${pod} on this node"
    pid="$(crictl inspect "${cid}" 2>/dev/null \
      | python3 -c 'import json,sys; print((json.load(sys.stdin).get("info") or {}).get("pid") or 0)')"
    [ "${pid:-0}" -gt 0 ] || fail "container ${cid} has no init pid"
    kill -9 "${pid}" || fail "the process ${pid} of ${pod} could not be killed"
  else
    fail "cannot reach node ${node} to kill the process of ${pod} (needs 'docker exec ${node}' or a local crictl)"
  fi
}

# The count the pipeline's own `/query` reports, read from inside the pod.
count_in_pod() {
  local pod="$1"
  kubectl exec --namespace "${NAMESPACE}" "${pod}" -- \
    curl --silent --fail --max-time 30 \
    'http://127.0.0.1:8080/query?sql=SELECT%20c%20FROM%20v&format=json' \
    2>/dev/null | python3 -c '
import json, sys
body = json.load(sys.stdin)
rows = body if isinstance(body, list) else [body]
assert len(rows) == 1, f"expected one row, got {body!r}"
values = list(rows[0].values())
assert len(values) == 1, f"expected one column, got {rows[0]!r}"
print(values[0])
'
}

# The count from whichever pod currently serves the pipeline. A restart through
# the manager recreates the StatefulSet's pod under the same name, but a scale
# to zero and back takes long enough that the caller would rather not guess:
# look the pod up by the labels the runner stamps on it.
total_count_in_pod() {
  local id="$1"
  local pod
  pod="$(kubectl get pods --namespace "${NAMESPACE}" \
    -l "feldera.com/pipeline-id=${id}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${pod}" ]; then
    # `%s` rather than `${id}` inside the shell's own quoting: an id has no
    # characters that need it, but a quoted match also reads as a mistake.
    pod="$(pod_of "${id}")"
    kubectl get pod --namespace "${NAMESPACE}" "${pod}" >/dev/null 2>&1 || return 1
  fi
  count_in_pod "${pod}"
}

# Newest checkpoint's `processed_records`, or nothing when no checkpoint is
# listed. This is the number an L2 recovery has to land on exactly: at-least-once
# may replay input, but the state it resumes from is the last completed
# checkpoint and nothing else.
last_checkpoint_records() {
  local name="$1"
  pipeline_json "${name}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("")
    raise SystemExit
pipeline = json.loads(raw)
details = pipeline.get("storage_status_details") or {}
checkpoints = details.get("checkpoints") or []
if not checkpoints:
    print("")
    raise SystemExit
newest = max(checkpoints, key=lambda c: c.get("processed_records") or 0)
print(newest.get("processed_records") or 0)
'
}

# Every checkpoint the manager lists, as `processed_records@identifier` pairs, so
# a recovery can be read against what was actually on disk.
checkpoint_summary() {
  pipeline_json "$1" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("none")
    raise SystemExit
pipeline = json.loads(raw)
checkpoints = (pipeline.get("storage_status_details") or {}).get("checkpoints") or []
if not checkpoints:
    print("none")
    raise SystemExit
rows = sorted(checkpoints, key=lambda c: c.get("processed_records") or 0)
print(", ".join("%s@%s" % (c.get("processed_records"), c.get("identifier")) for c in rows))
'
}

checkpoint_count() {
  local name="$1"
  pipeline_json "${name}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print(0)
    raise SystemExit
pipeline = json.loads(raw)
details = pipeline.get("storage_status_details") or {}
print(len(details.get("checkpoints") or []))
'
}

wait_for_checkpoint() {
  local name="$1" seconds="${2:-180}" deadline=$(( $(date +%s) + ${2:-180} ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    [ "$(checkpoint_count "${name}")" -ge 1 ] && return 0
    sleep 3
  done
  return 1
}

# The count the tier's assertions are about: the same query, read until it
# stops changing. The pipeline answers `/ingress` before its output views have
# folded the batch in, so a single read straight after a push can catch the view
# mid-flight.
settled_count_in_pod() {
  local pod="$1" previous="" current="" stable=0
  for _ in $(seq 1 60); do
    current="$(count_in_pod "${pod}" 2>/dev/null || true)"
    if [ -n "${current}" ] && [ "${current}" = "${previous}" ]; then
      stable=$(( stable + 1 ))
      [ "${stable}" -ge 2 ] && { printf '%s' "${current}"; return 0; }
    else
      stable=0
    fi
    previous="${current}"
    sleep 2
  done
  [ -n "${current}" ] && printf '%s' "${current}"
  return 0
}

# Wait for the view to reach an exact count. Used wherever the cell is about
# data that the pipeline should have processed completely.
wait_for_count_in_pod() {
  local pod="$1" expected="$2" seconds="${3:-120}" deadline=$(( $(date +%s) + ${3:-120} ))
  local current=""
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    current="$(count_in_pod "${pod}" 2>/dev/null || true)"
    [ "${current}" = "${expected}" ] && { printf '%s' "${current}"; return 0; }
    sleep 3
  done
  printf '%s' "${current}"
  return 1
}

push_records() {
  local name="$1" count="$2"
  seq 1 "${count}" >/tmp/e2e-k8s-chaos-records.csv
  api_call POST "/v0/pipelines/${name}/ingress/t?format=csv&force=true" \
    -H 'content-type: text/plain' \
    --data-binary @/tmp/e2e-k8s-chaos-records.csv >/dev/null
}

# ---------------------------------------------------------------------------
# Pipeline creation
# ---------------------------------------------------------------------------

# `create_pipeline <name> [kafka]`: a table `t` with a count view `v`.
#
# The HTTP-fed variant is used wherever the assertion is an exact count: a
# generator would produce a different number of rows after a restart, and
# "roughly the same" cannot distinguish a restored checkpoint from a fresh
# bootstrap.
create_pipeline() {
  local name="$1" source="${2:-http}"
  # Two statements separated by a real newline. Bash's `\n` in a double-quoted
  # string is a backslash and an `n`, which the SQL parser rejects, so the
  # separator comes from `$'...'`.
  local program newline=$'\n'
  if [ "${source}" = "kafka" ]; then
    # `kafka_options` is `#[serde(flatten)]`ed into the config, so librdkafka
    # settings sit at the top level of `config` rather than under a key of their
    # own, and `auto.offset.reset` is not one of them: the connector reads
    # `start_from` instead (see crates/feldera-types/src/transport/kafka.rs).
    # `update_format: raw` says each message *is* a table row; the default,
    # `insert_delete`, expects every message wrapped as `{"insert": {...}}`.
    program="CREATE TABLE t (i INT NOT NULL) WITH ('connectors' = '[{\"name\": \"c\", \"transport\": {\"name\": \"kafka_input\", \"config\": {\"topic\": \"${KAFKA_TOPIC}\", \"start_from\": \"earliest\", \"bootstrap.servers\": \"${KAFKA_SERVICE}.${NAMESPACE}.svc.cluster.local:9092\"}}, \"format\": {\"name\": \"json\", \"config\": {\"update_format\": \"raw\"}}}]');${newline}CREATE MATERIALIZED VIEW v AS SELECT COUNT(*) AS c FROM t;"
  else
    program="CREATE TABLE t (i INT NOT NULL);${newline}CREATE MATERIALIZED VIEW v AS SELECT COUNT(*) AS c FROM t;"
  fi

  if [ -n "$(pipeline_json "${name}")" ]; then
    note "removing pipeline ${name} left behind by an earlier run"
    delete_pipeline "${name}"
  fi
  python3 - "${name}" "${PROFILE}" "${program}" <<'PY' >/tmp/e2e-k8s-chaos-pipeline.json
import json, sys
name, profile, program = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "name": name,
    "program_code": program,
    "program_config": {"profile": profile},
    "runtime_config": {
        "resources": {"cpu_cores_min": 0, "memory_mb_min": 256, "memory_mb_max": 1024},
        # A short interval keeps the cells quick; the property under test is
        # which checkpoint a recovery lands on, not how far apart they are.
        "fault_tolerance": {"model": "at_least_once", "checkpoint_interval_secs": 10},
    },
}))
PY
  api_call POST "/v0/pipelines" \
    -H 'content-type: application/json' \
    --data @/tmp/e2e-k8s-chaos-pipeline.json >/dev/null
  # The manager stores a pipeline whose SQL does not parse and reports it only
  # through `program_status`; without this check the failure would surface much
  # later as "the program failed to compile" on start.
  local status
  for _ in $(seq 1 60); do
    status="$(field_of "$(pipeline_json "${name}")" program_status)"
    case "${status}" in
    Success) return 0 ;;
    SqlError|RustError|SystemError)
      fail "pipeline ${name} failed to compile: $(pipeline_json "${name}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("program_error"))')"
      ;;
    esac
    sleep 2
  done
  fail "pipeline ${name} did not finish compiling (status: ${status:-unknown})"
}

start_pipeline() {
  local name="$1" query="${2:-?bootstrap_policy=allow}"
  api_call POST "/v0/pipelines/${name}/start${query}" >/dev/null
  wait_for_running "${name}" "${START_TIMEOUT}"
  field_of "$(pipeline_json "${name}")" id
}

stop_pipeline_force() {
  local name="$1"
  api_call POST "/v0/pipelines/${name}/stop?force=true" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    [ "$(deployment_status "${name}")" = "Stopped" ] && return 0
    sleep 2
  done
  fail "pipeline ${name} did not stop"
}

# ---------------------------------------------------------------------------
# Kafka broker, for the cells that need one
# ---------------------------------------------------------------------------

kafka_ready=""
ensure_kafka() {
  [ -n "${kafka_ready}" ] && return 0
  say "starting a single-broker Kafka for the Kafka cells"
  # The kind node is its own container and cannot reach the public registry, so
  # the image has to be handed to it the same way the platform images are.
  # `kind load` is a no-op when the node already has it.
  docker image inspect "${KAFKA_IMAGE}" >/dev/null 2>&1 \
    || docker pull "${KAFKA_IMAGE}" >/dev/null \
    || fail "${KAFKA_IMAGE} is neither local nor pullable"
  kind load docker-image --name "${CLUSTER}" "${KAFKA_IMAGE}"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${KAFKA_SERVICE}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels: {app: ${KAFKA_SERVICE}}
  template:
    metadata:
      labels: {app: ${KAFKA_SERVICE}}
    spec:
      containers:
        - name: kafka
          image: ${KAFKA_IMAGE}
          ports: [{containerPort: 9092}]
          env:
            # KRaft single node: the broker and the controller are one process,
            # which is the smallest shape that still has real Kafka semantics
            # (offsets, transactions, consumer positions).
            - {name: CLUSTER_ID, value: chaos-matrix-cluster}
            - {name: KAFKA_NODE_ID, value: "1"}
            - {name: KAFKA_PROCESS_ROLES, value: "broker,controller"}
            - {name: KAFKA_LISTENERS, value: "PLAINTEXT://:9092,CONTROLLER://:9093"}
            - {name: KAFKA_ADVERTISED_LISTENERS, value: "PLAINTEXT://${KAFKA_SERVICE}.${NAMESPACE}.svc.cluster.local:9092"}
            - {name: KAFKA_CONTROLLER_LISTENER_NAMES, value: "CONTROLLER"}
            - {name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP, value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"}
            - {name: KAFKA_CONTROLLER_QUORUM_VOTERS, value: "1@localhost:9093"}
            - {name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR, value: "1"}
            - {name: KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR, value: "1"}
            - {name: KAFKA_TRANSACTION_STATE_LOG_MIN_ISR, value: "1"}
            - {name: KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS, value: "0"}
            # The log directory has to outlive the pod. Otherwise the broker's
            # logs sit in the container filesystem, and scaling it down deletes
            # the topic and every record in it -- which makes "the broker was
            # unreachable" indistinguishable from "the input was erased" and
            # quietly turns this cell into a test of nothing.
            - {name: KAFKA_LOG_DIRS, value: "/var/lib/kafka/data"}
          volumeMounts:
            - {name: data, mountPath: /var/lib/kafka/data}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${KAFKA_SERVICE}-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${KAFKA_SERVICE}-data
  namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ${KAFKA_SERVICE}
  namespace: ${NAMESPACE}
spec:
  selector: {app: ${KAFKA_SERVICE}}
  ports: [{port: 9092, targetPort: 9092}]
YAML
  kubectl rollout status deployment/"${KAFKA_SERVICE}" --namespace "${NAMESPACE}" --timeout 5m
  kafka_ready=1

  # The topic has to exist before the pipeline starts: the FT input reads the
  # partition count at startup and a missing topic is a provisioning error.
  for _ in $(seq 1 60); do
    if kubectl exec --namespace "${NAMESPACE}" "deploy/${KAFKA_SERVICE}" -- \
      /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
      --create --if-not-exists --topic "${KAFKA_TOPIC}" --partitions 1 \
      --replication-factor 1 >/dev/null 2>&1; then
      note "topic ${KAFKA_TOPIC} ready"
      return 0
    fi
    sleep 2
  done
  fail "the Kafka broker never accepted a topic creation"
}

kafka_produce() {
  local count="$1" first="${2:-1}"
  seq "${first}" "$(( first + count - 1 ))" \
    | sed 's/.*/{"i":&}/' \
    | kubectl exec --namespace "${NAMESPACE}" -i "deploy/${KAFKA_SERVICE}" -- \
        /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server 127.0.0.1:9092 --topic "${KAFKA_TOPIC}" >/dev/null
}

# Empty the topic between cells. A cell asserts an exact record count, and a
# topic still holding a previous cell's records would make the count start
# somewhere other than zero.
kafka_reset_topic() {
  kubectl exec --namespace "${NAMESPACE}" "deploy/${KAFKA_SERVICE}" -- \
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
    --delete --topic "${KAFKA_TOPIC}" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    kubectl exec --namespace "${NAMESPACE}" "deploy/${KAFKA_SERVICE}" -- \
      /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
      --create --if-not-exists --topic "${KAFKA_TOPIC}" --partitions 1 \
      --replication-factor 1 >/dev/null 2>&1 && return 0
    sleep 2
  done
  fail "could not recreate the Kafka topic"
}

kafka_broker_scale() {
  kubectl scale deployment --namespace "${NAMESPACE}" "${KAFKA_SERVICE}" --replicas="$1" >/dev/null
}

# Wait until the broker actually serves clients.
#
# A Running and Ready broker pod is not the same thing: a restarting broker has
# to recover its logs and re-elect its controller before it will answer a
# metadata request, and a connector that connects in that window fails its
# initialization. That failure is fatal for the whole pipeline (see
# `kafka_wait_serving`'s caller), so waiting on `rollout status` alone would
# turn this cell into a test of the broker's startup time rather than of the
# pipeline's recovery.
kafka_wait_serving() {
  local seconds="${1:-180}" deadline=$(( $(date +%s) + ${1:-180} ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    # Probe through the service name, not loopback: the connector dials the
    # service, so a broker that answers on its own loopback but not through the
    # service would still fail the connector's initialization. The topic has to
    # be listed as well, because a broker that recovered onto a fresh log
    # directory answers metadata requests perfectly well while holding no data.
    if kubectl exec --namespace "${NAMESPACE}" "deploy/${KAFKA_SERVICE}" -- \
      /opt/kafka/bin/kafka-topics.sh \
      --bootstrap-server "${KAFKA_SERVICE}.${NAMESPACE}.svc.cluster.local:9092" \
      --describe --topic "${KAFKA_TOPIC}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Storage, for the cells that take it away
#
# The pipeline runs as uid 1000 and the checkpoint directory it writes is owned
# by root (the runner creates it before dropping privileges), so neither the
# pipeline nor `kubectl exec` can make that directory unwritable. A throwaway
# pod that mounts the same claim as root can: it changes the mode of the
# directory the pipeline writes into, which is visible to the pipeline through
# the shared volume and makes every subsequent write fail. That is what a volume
# that has gone read-only or full looks like from inside the process.
# ---------------------------------------------------------------------------

storage_helper() {
  # `storage_helper <id> <mode>`: change the mode of the pipeline's storage
  # directory from a root pod that mounts the same claim.
  local id="$1" mode="$2"
  kubectl delete pod --namespace "${NAMESPACE}" chaos-storage-helper \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: chaos-storage-helper
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  # Root, because the directory belongs to root and the pipeline user cannot
  # change it. The claim is shared with the pipeline pod on the same node.
  securityContext:
    runAsUser: 0
    runAsGroup: 0
  containers:
    - name: helper
      image: ${RUNNER_IMAGE}
      # The claim is mounted where the pipeline keeps its storage root, so the
      # mount point on this side is the directory the pipeline writes into.
      command: ["sh", "-c", "chmod ${mode%%,*} /storage && find /storage -mindepth 1 -maxdepth 1 -exec chmod ${mode%%,*} {} + && echo done && sleep 3600"]
      volumeMounts:
        - name: storage
          mountPath: /storage
  volumes:
    - name: storage
      persistentVolumeClaim:
        claimName: pipeline-${id}-storage
YAML
  local deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local log
    log="$(kubectl logs --namespace "${NAMESPACE}" chaos-storage-helper 2>/dev/null || true)"
    [ "${log}" = "done" ] && { note "storage is now mode ${mode%%,*}"; return 0; }
    sleep 2
  done
  kubectl describe pod --namespace "${NAMESPACE}" chaos-storage-helper >&2 || true
  fail "the storage helper could not change the mode of pipeline-${id}-storage"
}

# ---------------------------------------------------------------------------
# PostgreSQL, for the cells that take it away
#
# The database breaks by having its process die, not by having its pod deleted.
# The chart mounts the database on an `emptyDir`, so deleting the pod would also
# delete the control plane's whole state -- that is a different fault (and one
# worth its own cell, see docs/self-hosted-chaos.md), while the cell here is
# about the data plane surviving while the control plane cannot reach its store.
# ---------------------------------------------------------------------------

postgres_pod() {
  kubectl get pod --namespace "${NAMESPACE}" \
    -l "app.kubernetes.io/name=postgres,app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}'
}

# Kill the postmaster. The kubelet restarts the container, the `emptyDir`
# survives (it is pod-scoped, not container-scoped), and the manager sees
# connection failures for as long as the restart takes.
break_postgres() {
  local pod; pod="$(postgres_pod)"
  [ -n "${pod}" ] || fail "no PostgreSQL pod to break"
  crash_container_of_pod "${pod}"
  note "killed the PostgreSQL process; the kubelet restarts the container"
}

restore_postgres() {
  local pod; pod="$(postgres_pod)"
  [ -n "${pod}" ] || fail "the PostgreSQL pod went away; the chart's database volume does not survive that"
  kubectl wait --namespace "${NAMESPACE}" --for=condition=Ready "pod/${pod}" --timeout 5m >/dev/null
  # Ready is the container being up; the schema has to be readable before the
  # manager can use it, and the manager retries on its own schedule rather than
  # on ours.
  for _ in $(seq 1 60); do
    if kubectl exec --namespace "${NAMESPACE}" "${pod}" -- \
      psql -U feldera -d feldera -tAc 'SELECT count(*) FROM pipeline' >/dev/null 2>&1; then
      note "PostgreSQL is serving again"
      return 0
    fi
    sleep 2
  done
  fail "PostgreSQL never came back with a readable schema"
}

# ---------------------------------------------------------------------------
# The cells
#
# Every cell runs the same skeleton: build a pipeline, fill it to a known
# count, inject the fault, recover, then assert what the tier promises. What
# differs is the injection and the expectation, so each function below says
# both in one place.
# ---------------------------------------------------------------------------

cell_name() { echo "chaos-$1-$2"; }

# L1 of every fault starts here: a graceful stop has to leave a checkpoint, and
# the count has to be exactly what it was.
expect_graceful_recovery() {
  local name="$1" before="$2" pod="$3"
  local after; after="$(settled_count_in_pod "${pod}")"
  [ "${after}" = "${before}" ] \
    || fail "L1: the pipeline came back with ${after} records, expected exactly ${before}"
  note "L1: ${after} records before and after, nothing lost"
}

run_cell() {
  local fault="$1" tier="$2"
  local name; name="$(cell_name "${fault}" "${tier}")"
  say "cell ${fault} / ${tier}"

  case "${fault}" in
  kill-pod)
    case "${tier}" in
    L1)
      # Graceful: the kubelet's SIGTERM path, which is what an operator's
      # rolling restart does too.
      create_pipeline "${name}"
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      push_records "${name}" "${RECORDS}"
      local before; before="$(wait_for_count_in_pod "${pod}" "${RECORDS}" 180 || true)"
      [ "${before}" = "${RECORDS}" ] \
        || fail "the view reports ${before} records after pushing ${RECORDS}"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared, nothing to resume from"

      local log=/tmp/e2e-k8s-chaos-${name}.log
      : >"${log}"
      kubectl logs --namespace "${NAMESPACE}" "${pod}" --follow >"${log}" 2>/dev/null &
      local log_pid=$!
      kubectl scale statefulset --namespace "${NAMESPACE}" "pipeline-${id}" --replicas=0 >/dev/null
      for _ in $(seq 1 "${template_grace}"); do
        grep -q 'exit checkpoint written' "${log}" && break
        sleep 1
      done
      wait "${log_pid}" 2>/dev/null || true
      grep -q 'exit checkpoint written' "${log}" \
        || fail "the shutdown handler did not finish its checkpoint (last lines: $(tail -5 "${log}"))"
      note "SIGTERM was answered by an exit checkpoint"

      stop_pipeline_force "${name}"
      note "checkpoints after the graceful stop: $(checkpoint_summary "${name}")"
      start_pipeline "${name}" "" >/dev/null
      note "checkpoints after the resume: $(checkpoint_summary "${name}")"
      expect_graceful_recovery "${name}" "${before}" "${pod}"
      ;;
    L2)
      # A crash: `kill -9` of the pipeline process. The container exits
      # non-zero and the kubelet's restart policy brings it back, so the tier
      # promises recovery to the last completed checkpoint and nothing more.
      create_pipeline "${name}"
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      push_records "${name}" "${RECORDS}"
      local before; before="$(wait_for_count_in_pod "${pod}" "${RECORDS}" 180 || true)"
      [ "${before}" = "${RECORDS}" ] \
        || fail "the view reports ${before} records after pushing ${RECORDS}"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared, nothing to resume from"
      local resume_at; resume_at="$(last_checkpoint_records "${name}")"
      note "the newest checkpoint holds ${resume_at} records"

      local crashed_at; crashed_at="$(date +%s)"
      crash_container_of_pod "${pod}"
      note "killed the pipeline process; the kubelet restarts the container"

      # Poll the view once a second for the first minute, then every five
      # seconds. The stopwatch ends when the restarted process answers with a
      # count, because that is the moment the platform is serving again; the
      # pod reports `Running` before the new process has read its checkpoint,
      # so that is not the end of the recovery. A five-second floor would have
      # reported this number as "under five" whatever it was.
      local after="" attempts=0
      while [ "${attempts}" -lt 300 ]; do
        attempts=$((attempts + 1))
        if [ "${attempts}" -le 60 ]; then sleep 1; else sleep 5; fi
        after="$(count_in_pod "${pod}" 2>/dev/null || true)"
        if [ -n "${after}" ]; then break; fi
      done
      [ -n "${after}" ] || fail "the restarted pipeline never answered a query"
      local rto=$(( $(date +%s) - crashed_at ))
      note "L2: the view answered ${rto}s after the crash"
      [ "${rto}" -lt "${RTO_LIMIT}" ] \
        || fail "L2: recovery took ${rto}s; the P1 exit criterion is under ${RTO_LIMIT}s"
      [ "$(deployment_status "${name}")" = "Running" ] \
        || fail "the pipeline answered but the manager does not report it Running: $(pipeline_json "${name}")"
      # At-least-once resumes from the checkpoint, so the state is exactly the
      # checkpoint's record count: a record ingested after it may be replayed or
      # lost, but the resume point itself is not approximate.
      [ "${after}" = "${resume_at}" ] \
        || fail "L2: resumed at ${after} records, expected the checkpoint's ${resume_at}"
      note "L2: resumed at exactly ${resume_at}, the last completed checkpoint"
      ;;
    esac
    ;;

  delete-pvc)
    case "${tier}" in
    L1)
      # The claim is the only copy of the state (there is no object-storage
      # backend in this tree: `crates/storage` registers only `default` and
      # `file`). Losing it must not lose the platform: the pipeline has to come
      # back from scratch and the operator has to be able to see that the data
      # is gone, because a silent replay of stale state would be worse.
      create_pipeline "${name}"
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      push_records "${name}" "${RECORDS}"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared"

      stop_pipeline_force "${name}"
      kubectl delete persistentvolumeclaim --namespace "${NAMESPACE}" \
        "pipeline-${id}-storage" --ignore-not-found >/dev/null
      note "deleted the storage claim"

      start_pipeline "${name}" "" >/dev/null
      local after; after="$(settled_count_in_pod "${pod}")"
      [ "${after}" = "0" ] \
        || fail "L1: after losing the claim the pipeline reports ${after} records; expected a fresh bootstrap (0)"
      note "L1: bootstrapped from scratch, and the loss is visible as 0 records"
      ;;
    L2)
      # Crash *and* lose the claim: the checkpoint the recovery would have used
      # is gone too. The pipeline must still reach a state an operator can act
      # on, and it must not silently claim the old state.
      create_pipeline "${name}"
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      push_records "${name}" "${RECORDS}"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared"

      kubectl scale statefulset --namespace "${NAMESPACE}" "pipeline-${id}" --replicas=0 >/dev/null
      sleep 5
      stop_pipeline_force "${name}"
      kubectl delete persistentvolumeclaim --namespace "${NAMESPACE}" \
        "pipeline-${id}-storage" --ignore-not-found >/dev/null
      note "stopped the pipeline and deleted the storage claim under it"

      start_pipeline "${name}" "" >/dev/null
      local after; after="$(settled_count_in_pod "${pod}")"
      [ "${after}" = "0" ] \
        || fail "L2: after losing both the pod and the claim the pipeline reports ${after}; expected 0"
      note "L2: recovered to a fresh bootstrap rather than to stale state"
      ;;
    esac
    ;;

  drop-postgres)
    case "${tier}" in
    L1)
      # The data plane must not depend on the control plane's database. The
      # manager cannot resolve a pipeline while PostgreSQL is down
      # (`check_pipeline` reads the pipeline row first), so the assertion is
      # made against the pod directly, and it is that the count keeps moving.
      create_pipeline "${name}"
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      push_records "${name}" "${RECORDS}"
      local before; before="$(wait_for_count_in_pod "${pod}" "${RECORDS}" 180 || true)"
      [ "${before}" = "${RECORDS}" ] || fail "expected ${RECORDS} records, got ${before}"

      break_postgres
      sleep 20

      # The pipeline is still there and still serving.
      local during; during="$(settled_count_in_pod "${pod}")"
      [ "${during}" = "${before}" ] \
        || fail "the data plane changed while PostgreSQL was down: ${before} -> ${during}"
      # More data still flows in, straight into the pod.
      kubectl exec --namespace "${NAMESPACE}" "${pod}" -- \
        curl --silent --fail --max-time 60 -X POST \
        'http://127.0.0.1:8080/ingress/t?format=csv&force=true' \
        -H 'content-type: text/plain' \
        --data-binary "$(seq 1 100 | tr '\n' '\n')" >/dev/null 2>&1 \
        || fail "the pipeline refused an ingress request while the database was down"
      local after; after="$(wait_for_count_in_pod "${pod}" "$(( before + 100 ))" 120 || true)"
      [ "${after}" = "$(( before + 100 ))" ] \
        || fail "L1: the pipeline reports ${after} records, expected $(( before + 100 )) with PostgreSQL down"
      note "L1: PostgreSQL down, the data plane kept ingesting (${before} -> ${after})"

      restore_postgres

      # The manager has to catch up without touching the running pipeline.
      local deadline=$(( $(date +%s) + 300 ))
      while [ "$(date +%s)" -lt "${deadline}" ]; do
        [ "$(deployment_status "${name}")" = "Running" ] && break
        sleep 5
      done
      [ "$(deployment_status "${name}")" = "Running" ] \
        || fail "the manager did not resume tracking the pipeline after PostgreSQL came back"
      [ "$(settled_count_in_pod "${pod}")" = "${after}" ] \
        || fail "the pipeline restarted when the manager reconnected; the data plane should not have moved"
      note "L1: the manager reattached to the same pod"
      ;;
    L2)
      # PostgreSQL down *while* the pod dies: the manager cannot record the
      # failure, so it has to reconcile from Kubernetes state alone once the
      # database is back. The operator-visible outcome is a pipeline that can be
      # restarted, not one stuck in Provisioning.
      create_pipeline "${name}"
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      push_records "${name}" "${RECORDS}"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared"
      local resume_at; resume_at="$(last_checkpoint_records "${name}")"

      break_postgres
      sleep 15
      crash_container_of_pod "${pod}"
      note "killed the pipeline process while the database was down"
      sleep 15

      restore_postgres

      # Whatever the automaton decides, it has to decide something: a pipeline
      # that stays in Provisioning forever is the failure this cell looks for.
      local deadline=$(( $(date +%s) + 600 )) settled=""
      while [ "$(date +%s)" -lt "${deadline}" ]; do
        settled="$(deployment_status "${name}")"
        case "${settled}" in Running|Stopped|Failed) break ;; esac
        sleep 5
      done
      case "${settled}" in
      Running|Stopped|Failed) note "L2: the manager settled the pipeline into ${settled}" ;;
      *) fail "L2: the pipeline is stuck in ${settled:-unknown} after the database came back" ;;
      esac

      # And it has to be restartable, which is the operator's actual recovery
      # path. Whatever it resumes at is the last completed checkpoint.
      stop_pipeline_force "${name}" || true
      start_pipeline "${name}" "" >/dev/null
      local after=""; local pod2; pod2="$(pod_of "${id}")"
      for _ in $(seq 1 120); do
        after="$(count_in_pod "${pod2}" 2>/dev/null || true)"
        [ -n "${after}" ] && break
        sleep 5
      done
      [ -n "${after}" ] || fail "the pipeline never answered after the operator restart"
      [ "${after}" = "${resume_at}" ] \
        || fail "L2: restarted at ${after} records, expected the checkpoint's ${resume_at}"
      note "L2: restarted by the operator at exactly ${resume_at} records"
      ;;
    esac
    ;;

  drop-storage)
    case "${tier}" in
    L1)
      # Storage refuses writes: no checkpoint can complete. The data plane must
      # keep running -- a pipeline that stops processing because it cannot
      # checkpoint has turned a durability problem into an availability one --
      # and the next checkpoint after the volume is writable again has to
      # succeed, with nothing lost in between.
      create_pipeline "${name}"
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      push_records "${name}" "${RECORDS}"
      local before; before="$(wait_for_count_in_pod "${pod}" "${RECORDS}" 180 || true)"
      [ "${before}" = "${RECORDS}" ] || fail "expected ${RECORDS} records, got ${before}"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared"
      local checkpoints_before; checkpoints_before="$(checkpoint_count "${name}")"

      storage_helper "${id}" 500

      # Pushing more data has to keep working: the pipeline holds the batch in
      # memory and writes it on the next checkpoint.
      kubectl exec --namespace "${NAMESPACE}" "${pod}" -- \
        curl --silent --fail --max-time 60 -X POST \
        'http://127.0.0.1:8080/ingress/t?format=csv&force=true' \
        -H 'content-type: text/plain' \
        --data-binary "$(seq 1 200)" >/dev/null 2>&1 \
        || fail "the pipeline refused data while storage was read-only"
      local during; during="$(wait_for_count_in_pod "${pod}" "$(( before + 200 ))" 120 || true)"
      [ "${during}" = "$(( before + 200 ))" ] \
        || fail "L1: the pipeline reports ${during} records, expected $(( before + 200 )) while storage was read-only"
      note "L1: kept ingesting with storage read-only (${before} -> ${during})"
      # Two checkpoint intervals is enough for a failed attempt to show up; the
      # point is not that it is counted precisely but that the pipeline is still
      # alive after one.
      sleep 25
      [ "$(deployment_status "${name}")" = "Running" ] \
        || fail "L1: the pipeline stopped running because a checkpoint could not be written"

      storage_helper "${id}" 777
      note "made the storage directory writable again"
      local deadline=$(( $(date +%s) + 180 )) recovered=""
      while [ "$(date +%s)" -lt "${deadline}" ]; do
        recovered="$(checkpoint_count "${name}")"
        [ "${recovered:-0}" -gt "${checkpoints_before}" ] && break
        sleep 5
      done
      [ "${recovered:-0}" -gt "${checkpoints_before}" ] \
        || fail "L1: no checkpoint succeeded after storage became writable again (${checkpoints_before} -> ${recovered:-0})"
      [ "$(settled_count_in_pod "${pod}")" = "${during}" ] \
        || fail "L1: the record count moved while recovering checkpoints"
      note "L1: checkpoints resumed (${checkpoints_before} -> ${recovered}) and no data was lost"
      ;;
    L2)
      # Crash while storage is unwritable: the recovery has to fall back to the
      # last checkpoint that *did* complete, which is older than the crash, and
      # it must not resume from a partially written one.
      create_pipeline "${name}"
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      push_records "${name}" "${RECORDS}"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared"
      local resume_at; resume_at="$(last_checkpoint_records "${name}")"
      note "the newest checkpoint holds ${resume_at} records"

      storage_helper "${id}" 500

      # The fault has to be shown to bite before the crash means anything: if a
      # checkpoint still completed while the volume was read-only, the crash
      # would be recovering from fresh state and the cell would prove nothing.
      local checkpoints_at_fault; checkpoints_at_fault="$(checkpoint_count "${name}")"
      sleep 25
      local checkpoints_after_fault; checkpoints_after_fault="$(checkpoint_count "${name}")"
      [ "${checkpoints_after_fault}" = "${checkpoints_at_fault}" ] \
        || fail "L2: a checkpoint completed while storage was read-only (${checkpoints_at_fault} -> ${checkpoints_after_fault}); the fault did not bite"
      note "L2: no checkpoint completed in 25s of a read-only volume (${checkpoints_at_fault} on disk)"

      crash_container_of_pod "${pod}"
      note "killed the pipeline while storage was read-only"
      # The volume has to come back before the restarted process can use it. A
      # start writes the checkpoint it resumes into, and a process that cannot
      # write answers 500 on /status -- which the manager treats as fatal and
      # stops the pipeline for. Restoring the volume is what an operator does
      # once the disk is put right, so the cell does it here and then measures
      # the recovery.
      sleep 3
      storage_helper "${id}" 777
      note "storage is writable again"

      # The pipeline may come back by itself, or the manager may have stopped it
      # when the start under the read-only volume failed. Starting it again is
      # the operator's second move, and the data promise is the same either way.
      local after="" restarted=no
      local deadline=$(( $(date +%s) + 300 ))
      while [ "$(date +%s)" -lt "${deadline}" ]; do
        after="$(total_count_in_pod "${id}" 2>/dev/null || true)"
        [ -n "${after}" ] && break
        case "$(deployment_status "${name}" || true)" in
          Stopped|Unavailable)
            if [ "${restarted}" = no ]; then
              restarted=yes
              note "the start under the read-only volume was fatal, so the pipeline is $(deployment_status "${name}") -- starting it again now that the volume is writable"
              start_pipeline "${name}" >/dev/null
            fi
            ;;
        esac
        sleep 5
      done
      [ -n "${after}" ] \
        || fail "the pipeline never answered after the crash (last status: $(deployment_status "${name}" || true))"
      # The recovery must find at least what the checkpoint promised. Whether it
      # finds more is not this cell's business: the crash lands at an arbitrary
      # point between checkpoints, and records the circuit committed since the
      # last one are lost by the definition of at-least-once. An earlier version
      # of this cell did observe a count above the checkpoint read here, and
      # that turned out to be the pipeline resuming from a later checkpoint than
      # the one read, not state surviving the crash -- so the assertion is the
      # promise, not the number.
      [ "${after}" -ge "${resume_at}" ] \
        || fail "L2: resumed at ${after} records, below the last completed checkpoint's ${resume_at}"
      note "L2: resumed at ${after} from a checkpoint that held ${resume_at}; nothing the checkpoint promised was lost"
      ;;
    esac
    ;;

  drop-kafka)
    # The Kafka cells use the broker as the input source, which is the only
    # configuration in this tree where exactly-once is available: the FT input
    # records consumer offsets in the checkpoint, so a recovery neither skips
    # nor replays records.
    ensure_kafka
    kafka_reset_topic
    case "${tier}" in
    L1)
      create_pipeline "${name}" kafka
      # Drain whatever a previous cell left in the topic.
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      kafka_produce "${RECORDS}"
      # `count_in_pod` is not used here: it fails the cell when the query fails,
      # and a pipeline that is still initializing has no views to query yet.
      # The window is generous because the consumer retries the broker with
      # backoff after a refused connection, and on one node that backoff can
      # outlast the pipeline's own start.
      local deadline=$(( $(date +%s) + 600 )) before=""
      while [ "$(date +%s)" -lt "${deadline}" ]; do
        before="$(settled_count_in_pod "${pod}" 2>/dev/null || true)"
        [ "${before:-0}" -ge "${RECORDS}" ] && break
        note "consumed ${before:-0} of ${RECORDS}"
        sleep 10
      done
      [ "${before:-0}" -ge "${RECORDS}" ] \
        || fail "the pipeline consumed ${before:-0} of ${RECORDS} records"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared"

      kafka_broker_scale 0
      note "stopped the Kafka broker"
      # Nothing to consume, but the pipeline must keep running: an input that is
      # unreachable is not a pipeline failure.
      sleep 20
      # The pod answering is the evidence, not the pipeline row: the manager's
      # view of a pipeline lags a failure by up to one poll interval, so a
      # `deployment_status` read of `Running` says nothing about whether the
      # pipeline is up right now.
      local stalled; stalled="$(settled_count_in_pod "${pod}")"
      note "L1: the pipeline stayed up with the broker down (${stalled} records)"

      kafka_broker_scale 1
      kubectl rollout status deployment/"${KAFKA_SERVICE}" --namespace "${NAMESPACE}" --timeout 5m
      kafka_wait_serving 240 \
        || fail "the broker never started serving clients again"
      note "the broker is back and serving clients"

      # Graceful restart with the offset in the checkpoint: no duplicates.
      stop_pipeline_force "${name}"
      start_pipeline "${name}" "" >/dev/null
      # The topic holds exactly RECORDS records and the checkpoint recorded the
      # offset just past the last one, so a resume must land on exactly the same
      # count: a duplicate shows up as a larger number, a skip as a smaller one.
      # The pod is recreated on a restart, so this is polled rather than read
      # once.
      local deadline2=$(( $(date +%s) + 300 )) after=""
      while [ "$(date +%s)" -lt "${deadline2}" ]; do
        after="$(settled_count_in_pod "${pod}" 2>/dev/null || true)"
        [ -n "${after}" ] && break
        sleep 5
      done
      [ -n "${after}" ] || fail "the restarted pipeline never answered a query"
      [ "${after}" = "${stalled}" ] \
        || fail "L1: resumed at ${after} records, expected exactly ${stalled} (the broker held no new data)"
      note "L1: resumed at exactly ${after}, no duplicates and no skips"
      ;;
    L2)
      create_pipeline "${name}" kafka
      local id; id="$(start_pipeline "${name}")"
      local pod; pod="$(pod_of "${id}")"
      kafka_produce "${RECORDS}"
      local deadline=$(( $(date +%s) + 300 )) before=""
      while [ "$(date +%s)" -lt "${deadline}" ]; do
        before="$(settled_count_in_pod "${pod}" 2>/dev/null || true)"
        [ "${before:-0}" -ge "${RECORDS}" ] && break
        sleep 5
      done
      [ "${before:-0}" -ge "${RECORDS}" ] \
        || fail "the pipeline consumed ${before:-0} of ${RECORDS} records"
      wait_for_checkpoint "${name}" || fail "no checkpoint appeared"
      local resume_at; resume_at="$(last_checkpoint_records "${name}")"
      note "the newest checkpoint holds ${resume_at} records"

      crash_container_of_pod "${pod}"
      note "killed the pipeline process; the kubelet restarts the container"
      sleep 5
      for _ in $(seq 1 240); do
        [ "$(deployment_status "${name}")" = "Running" ] && break
        sleep 5
      done
      local after="" deadline2=$(( $(date +%s) + 300 ))
      while [ "$(date +%s)" -lt "${deadline2}" ]; do
        after="$(total_count_in_pod "${id}" 2>/dev/null || true)"
        # The restarted process replays from the checkpointed offset and catches
        # up to the end of the topic, so it lands back on the full count.
        [ "${after:-0}" -ge "${RECORDS}" ] && break
        sleep 5
      done
      # Exactly RECORDS: the offset lives in the checkpoint, so the replay
      # starts where the checkpoint stopped and ends at the topic's end. A
      # larger number means the offset was not honoured (duplicates); a stuck
      # smaller number means the resume point was wrong.
      [ "${after:-0}" = "${RECORDS}" ] \
        || fail "L2: the pipeline reports ${after:-0} records after the crash, expected exactly ${RECORDS} (checkpoint held ${resume_at})"
      note "L2: replayed from the checkpoint to exactly ${RECORDS}, no duplicates"
      ;;
    esac
    ;;

  *)
    fail "unknown fault '${fault}'"
    ;;
  esac

  if [ "${KEEP}" != "1" ]; then
    delete_pipeline "${name}"
  fi
  record "${fault}" "${tier}" "pass"
}

# ---------------------------------------------------------------------------
# Drive the matrix
# ---------------------------------------------------------------------------

passed=0
failed=0
skipped=0
IFS=',' read -ra cell_list <<<"${cells}"
for cell in "${cell_list[@]}"; do
  [ -n "${cell}" ] || continue
  fault="${cell%%:*}"
  tier="${cell##*:}"
  case "${tier}" in
  L1|L2) ;;
  *) fail "cell '${cell}' must be <fault>:<L1|L2>" ;;
  esac
  # A failure in one cell must not hide the rest of the matrix: the whole point
  # of running it is to learn which cells hold and which do not. The failure is
  # recorded and the matrix moves on; the exit status at the end is non-zero.
  set +e
  ( set -e; run_cell "${fault}" "${tier}" )
  status=$?
  set -e
  if [ "${status}" -eq 0 ]; then
    passed=$(( passed + 1 ))
  else
    failed=$(( failed + 1 ))
    record "${fault}" "${tier}" "FAIL"
  fi
done

say "matrix"
for line in "${results[@]}"; do
  IFS='|' read -r fault tier verdict <<<"${line}"
  printf '  %-14s %-3s %s\n' "${fault}" "${tier}" "${verdict}"
done
printf '\n  %d passed, %d failed, in %s\n' "${passed}" "${failed}" "$(elapsed)"

[ "${failed}" -eq 0 ] || fail "${failed} cell(s) failed"
say "PASS"
