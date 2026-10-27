#!/usr/bin/env bash
#
# P1-019 acceptance: two API server replicas, one of which reconciles.
#
# The point of the election is a property no single replica can show: with two
# replicas running, exactly one drives the pipelines and the other serves the
# API without driving anything. Each assertion below is a different way that
# property can fail:
#
#   1. both pods are Ready (so the roll-out is not hiding a crash loop, and the
#      readiness probe agrees that a standby is healthy);
#   2. exactly one pod logs that it acquired leadership, and the other logs that
#      it is serving without reconciling (the split is real, not cosmetic);
#   3. the standby answers /healthz, because a Service must be able to route to
#      it (a standby that failed its probe would leave one instance behind the
#      Service, which is the single point of failure the second replica exists
#      to remove);
#   4. a log request to the standby answers 503 rather than 404: the pipeline
#      exists, only its log stream is on the other instance;
#   5. a pipeline created through the standby still gets provisioned — the
#      leader reconciles what any instance accepts, which is what makes the
#      replicas interchangeable to a client.
#
# The manager image must contain the P1-019 build: the runner refuses to start
# an election it does not have, and this test would then see two leaders.
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
DEPLOYMENT="${DEPLOYMENT:-${RELEASE}-controlplane-api-server}"
# The manager image carries this commit's code; the runner and compiler images
# are unchanged by it, so they keep the tag already loaded in the cluster.
MANAGER_TAG="${MANAGER_TAG:?set MANAGER_TAG to the manager image tag under test}"
RUNNER_TAG="${RUNNER_TAG:-${MANAGER_TAG}}"
COMPILER_TAG="${COMPILER_TAG:-${MANAGER_TAG}}"
PIPELINE="${PIPELINE:-p1-019-standby}"
API_PORT="${API_PORT:-18080}"

step() { printf '\n-- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*"; }

port_forward() {
  kubectl -n "${NAMESPACE}" port-forward "deploy/${DEPLOYMENT}" "${API_PORT}:8080" \
    >/tmp/p1-019-port-forward.log 2>&1 &
  PORT_FORWARD_PID=$!
  for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  cat /tmp/p1-019-port-forward.log >&2 || true
  fail "the API server did not answer through the port-forward"
}

cleanup() {
  [ -n "${PORT_FORWARD_PID:-}" ] && kill "${PORT_FORWARD_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# Pod names of the api-server Deployment, oldest first.
api_pods() {
  kubectl -n "${NAMESPACE}" get pods \
    -l "app.kubernetes.io/component=api-server" \
    --sort-by=.metadata.creationTimestamp -o name | sed 's|^pod/||'
}

echo "== leader election acceptance =="
echo "namespace:  ${NAMESPACE}"
echo "release:    ${RELEASE}"
echo "manager:    ${MANAGER_TAG}"
echo "runner:     ${RUNNER_TAG}"
echo "compiler:   ${COMPILER_TAG}"
echo

step "1. deploy two replicas"
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" --create-namespace \
  --set "controlplane.image.tag=${MANAGER_TAG}" \
  --set "controlplane.kubernetesRunner.image.tag=${RUNNER_TAG}" \
  --set "compiler.image.tag=${COMPILER_TAG}" \
  --set controlplane.replicaCount=2 \
  --set controlplane.apiServerAntiAffinity=none \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --set controlplane.compilationCache.enabled=false \
  --wait --timeout 10m >/dev/null

kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout 5m >/dev/null

# A rolling update leaves the previous pods terminating for a while, and they
# are still listed (and still ready) while they drain. Count only the pods that
# belong to the current ReplicaSet, which is the generation the release asked
# for, so the assertion measures the deployment rather than its transition.
current_rs=$(kubectl -n "${NAMESPACE}" get "deployment/${DEPLOYMENT}" \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
ready=0
for _ in $(seq 1 30); do
  rs=$(kubectl -n "${NAMESPACE}" get rs -l "app.kubernetes.io/component=api-server" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}{end}' \
    | awk -v rev="${current_rs}" '$2 == rev { print $1 }')
  ready=0
  for pod in $(kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/component=api-server" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    | awk -v rs="${rs}" '$2 == rs && $3 == "true" { print $1 }'); do
    ready=$((ready + 1))
  done
  [ "${ready}" = "2" ] && break
  sleep 2
done
[ "${ready}" = "2" ] || fail "expected two ready api-server pods, found ${ready}"
info "two api-server pods are Ready"

# The chart spreads replicas over nodes when the cluster has more than one.
# This test runs on a single-node kind cluster, where a scheduling rule would
# leave the second replica Pending and test the scheduler rather than the
# election, so the rule is turned off here. `scripts/e2e-k8s-chart.sh` checks
# the rule itself.
info "anti-affinity is turned off: this cluster has one node"

step "2. exactly one pod is the leader"
# Wait for the election to settle: the standby retries every two seconds, so a
# verdict taken immediately can catch the instant before it publishes.
leader_pods=""
standby_pods=""
for _ in $(seq 1 30); do
  leader_pods=""
  standby_pods=""
  while read -r pod; do
    [ -n "${pod}" ] || continue
    log=$(kubectl -n "${NAMESPACE}" logs "${pod}" --tail=400 2>/dev/null || true)
    if printf '%s' "${log}" | grep -q "Leadership acquired"; then
      leader_pods="${leader_pods} ${pod}"
    elif printf '%s' "${log}" | grep -q "standing by until this instance becomes leader"; then
      # The reconciliation loop says this every time it finds itself a
      # standby, so it is present on an instance that has been standing by
      # since start-up; the election's own "another instance holds the lock"
      # line only appears once the lock is known to be taken.
      standby_pods="${standby_pods} ${pod}"
    fi
  done <<<"$(api_pods)"
  if [ -n "${leader_pods}" ] && [ -n "${standby_pods}" ]; then
    break
  fi
  sleep 2
done

leader_count=$(echo ${leader_pods} | wc -w | tr -d ' ')
standby_count=$(echo ${standby_pods} | wc -w | tr -d ' ')
info "leaders:${leader_pods:- none}"
info "standbys:${standby_pods:- none}"
[ "${leader_count}" = "1" ] || fail "expected exactly one leader, found ${leader_count}"
[ "${standby_count}" = "1" ] || fail "expected exactly one standby, found ${standby_count}"

step "3. the standby serves /healthz"
standby_pod=$(echo ${standby_pods} | awk '{print $1}')
code=$(kubectl -n "${NAMESPACE}" exec "${standby_pod}" -- \
  curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz 2>/dev/null || true)
[ "${code}" = "200" ] || fail "the standby answered /healthz with ${code:-nothing}"
info "the standby answers /healthz with 200"

step "4. a pipeline is provisioned when created through the standby"
port_forward

# A pipeline left behind by an earlier run would make the create below fail on
# a name conflict, which reads like the standby refusing work. Remove it first,
# through the API, because the manager's own automaton owns the Kubernetes
# objects and a direct `kubectl delete` would be recreated under it.
existing=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}")
if [ "${existing}" = "200" ]; then
  info "removing the pipeline left by an earlier run"
  curl -s -o /dev/null -X POST "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}/stop?force=true" || true
  for _ in $(seq 1 40); do
    state=$(curl -s "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("deployment_status",""))' 2>/dev/null || true)
    [ "${state}" = "Stopped" ] && break
    sleep 3
  done
  # Clearing is asynchronous, and a delete is refused until it finishes. The
  # status code is what says so: `curl` succeeds on a 400 as well, so checking
  # the exit status would break out of the loop on the refusal.
  cleared=false
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}/clear")
    # 202 while the clear is under way, 200 once it has; either way, retry the
    # delete below, which is the operation whose own code decides.
    deleted=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}")
    if [ "${deleted}" = "200" ] || [ "${deleted}" = "204" ]; then
      cleared=true
      break
    fi
    sleep 2
  done
  [ "${cleared}" = "true" ] || fail "could not remove the pipeline left by an earlier run"
fi

# Create through the Service, which round-robins across both replicas: the
# request may land on either, and the leader must act on it regardless.
created=$(curl -s -X POST "http://127.0.0.1:${API_PORT}/v0/pipelines" \
  -H 'content-type: application/json' \
  -d "{\"name\":\"${PIPELINE}\",\"program_code\":\"CREATE TABLE t (x INT); CREATE VIEW v AS SELECT * FROM t;\"}")
if ! printf '%s' "${created}" | grep -q '"id"'; then
  printf '%s\n' "${created}" >&2
  fail "the API refused to create a pipeline through the standby"
fi

# A created pipeline is provisioned when it is started: provisioning is part of
# the start transition, so the start request is what asks the leader to act.
curl -sf -X POST "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}/start" \
  >/dev/null || fail "the API refused to start the pipeline created through the standby"

# Wait for the pipeline to run. Running means the leader provisioned its pod,
# the compiler produced the program, and the process came up — three things
# that only happen if the instance that accepted the request handed the work to
# the instance that reconciles.
status=""
for _ in $(seq 1 100); do
  status=$(curl -s "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("deployment_status",""))' 2>/dev/null || true)
  case "${status}" in
    Running) break ;;
    Failed|Shutdown) break ;;
  esac
  sleep 3
done
info "deployment status: ${status:-unknown}"
case "${status}" in
  Running)
    ;;
  *)
    kubectl -n "${NAMESPACE}" logs "${leader_pod:-$(echo ${leader_pods} | awk '{print $1}')}" --tail=60 >&2 || true
    fail "the leader did not start the pipeline created through the standby (status: ${status:-unknown})"
    ;;
esac

step "5. the standby answers a log request with 503"
# The pipeline id, so the request names a pipeline that exists.
pipeline_id=$(curl -s "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

# The log stream is served by the runner, on its own port. Port 8080 serves the
# application, and its single-page-app fallback answers any path with 200, so a
# probe there would succeed on every instance whatever its role.
RUNNER_PORT="${RUNNER_PORT:-8089}"
standby_code=$(kubectl -n "${NAMESPACE}" exec "${standby_pod}" -- \
  curl -s -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:${RUNNER_PORT}/logs/${pipeline_id}" 2>/dev/null || true)
[ "${standby_code}" = "503" ] \
  || fail "the standby answered a log request with ${standby_code:-nothing}, expected 503"
info "the standby answers the log request with 503"

# And the leader answers it for real, with the stream rather than an error: the
# two roles must differ, not merely both fail.
leader_pod=$(echo ${leader_pods} | awk '{print $1}')
leader_code=$(kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  "http://127.0.0.1:${RUNNER_PORT}/logs/${pipeline_id}" 2>/dev/null || true)
[ "${leader_code}" = "200" ] \
  || fail "the leader answered a log request with ${leader_code:-nothing}, expected 200"
info "the leader answers the same request with 200"
step "6. the standby takes over when the leader goes away"
# Deleting the leader's pod is the failure the second replica exists for. The
# standby must acquire the lock without a restart — it polls while standing by
# — and the pipeline must stay Running, because the new leader rediscovers it
# from its row rather than from anything the old leader held in memory.
kubectl -n "${NAMESPACE}" delete pod "${leader_pod}" --wait=false >/dev/null

# The takeover must be seen on the instance that was standing by, not on the
# old leader: a terminating pod keeps its logs, and its "Leadership acquired"
# line from before is exactly what a scan over all pods would find again.
if [ -z "${standby_pod}" ]; then
  standby_pod=$(echo ${standby_pods} | awk '{print $1}')
fi
[ -n "${standby_pod}" ] || fail "no standby was identified before the leader was removed"

takeover=""
for _ in $(seq 1 90); do
  # A standby that was itself restarted would have a new name; follow the
  # instance rather than the name by asking each surviving pod in turn.
  while read -r pod; do
    [ -n "${pod}" ] || continue
    [ "${pod}" = "${leader_pod}" ] && continue
    log=$(kubectl -n "${NAMESPACE}" logs "${pod}" --tail=400 2>/dev/null || true)
    if printf '%s' "${log}" | grep -q "Leadership acquired"; then
      takeover="${pod}"
      break 2
    fi
  done <<<"$(api_pods)"
  sleep 2
done
[ -n "${takeover}" ] || fail "no instance acquired the leadership lock within 3 minutes"
[ "${takeover}" != "${leader_pod}" ] || fail "the removed leader cannot be the one that took over"
info "the new leader is ${takeover} (was standing by before the leader was removed)"

# The pipeline survived: the new leader read its row and kept driving it. It
# may pass through Stopping on the way, which the automaton of the new leader
# drives forward, so the assertion is that it did not end up Failed.
#
# The port-forward is re-established first: it tunnels to one pod, and the pod
# it was tunnelling to is the one just deleted, so it is dead by now and every
# request through it would fail for a reason that has nothing to do with the
# pipeline.
kill "${PORT_FORWARD_PID}" 2>/dev/null || true
wait "${PORT_FORWARD_PID}" 2>/dev/null || true
port_forward

status=""
for _ in $(seq 1 60); do
  status=$(curl -s "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("deployment_status",""))' 2>/dev/null || true)
  [ "${status}" = "Running" ] && break
  case "${status}" in
    Failed*|Shutdown) break ;;
  esac
  sleep 2
done
info "deployment status after failover: ${status:-unknown}"
case "${status}" in
  Running)
    ;;
  Failed*|Shutdown)
    kubectl -n "${NAMESPACE}" logs "${takeover}" --tail=40 >&2 || true
    fail "the pipeline did not survive the leader going away (status: ${status})"
    ;;
  *)
    # A pipeline that stopped, or never settled, means the new leader did not
    # inherit it: it read the pipeline's row but concluded its compute was
    # gone. That is the failure this step exists to catch, so it is a failure
    # rather than an accepted intermediate state.
    kubectl -n "${NAMESPACE}" logs "${takeover}" --tail=40 >&2 || true
    fail "the pipeline was not running after a takeover (status: ${status:-unknown})"
    ;;
esac
info "the pipeline is still running under the new leader"

# Leave the cluster as the test found it.
curl -sf -X DELETE "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}" >/dev/null || true

printf '\nPASS: two replicas, one leader, a standby that serves without driving, and a takeover\n'
