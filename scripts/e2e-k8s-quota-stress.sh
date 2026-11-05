#!/usr/bin/env bash
#
# P1-034 acceptance: three pilot teams on one platform, and a quota that holds
# under pressure.
#
# P1-022 gave each tenant a namespace with a quota and made a full quota fail
# fast. P1-033 proved two tenants cannot reach each other — by network,
# namespace, Secret or API — with one pipeline each. Neither ever pressed a
# quota: with one pipeline per tenant, a quota that admits one is never asked for
# two, and a refusal is never raced.
#
# This script onboards three teams (two pipelines each, the "3 teams online"
# half), then asks every tenant for more than it is allowed, all at once, and
# holds the result to six properties:
#
#   L1  a tenant never runs more pipelines than its quota fits;
#   L2  `ResourceQuota.status.used` never exceeds `hard`, on every axis;
#   L3  a refused pipeline settles as Stopped *with the quota message* — not a
#       provisioning timeout, not a crash;
#   L4  one tenant's pressure does not move another tenant's numbers, and does
#       not disturb the pipelines already running;
#   L5  no object of one tenant appears in another tenant's namespace, under
#       load;
#   L6  a refusal is final: the manager never restarts, and nothing asks the API
#       server to create the refused pod again.
#
# The arithmetic is exact, so a difference in outcomes cannot be explained by a
# difference in requests: every pipeline asks for 1.0 CPU and 4Gi, every tenant
# is given `requests.cpu=4` and `requests.memory=16Gi`, so exactly four
# pipelines fit — two onboarded, two free, four contenders per tenant. Storage is
# deliberately given three times the room the CPU quota allows, so a storage
# claim left behind by a refused pipeline is visible as a number instead of
# hiding inside a refusal on every axis at once.
#
# The install has two phases: the quota map is keyed by tenant UUID, and a UUID
# exists only once the tenant does.
#
# Prerequisites: the kind cluster from docs/self-hosted-dev-env.md with the
# Keycloak image loaded, and manager, compiler and runner images built from this
# commit.
#
# Usage:
#
#   MANAGER_TAG=p1-034 RUNNER_TAG=<runner tag> scripts/e2e-k8s-quota-stress.sh
#
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "this script needs bash 4 or newer (associative arrays); found ${BASH_VERSION}" >&2
  exit 1
fi

: "${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
MANAGER_TAG="${MANAGER_TAG:?set MANAGER_TAG to the manager image tag under test}"
COMPILER_TAG="${COMPILER_TAG:-${MANAGER_TAG}}"
RUNNER_TAG="${RUNNER_TAG:?set RUNNER_TAG to a feldera-runner image tag built from deploy/Dockerfile.runner}"
API_PORT="${API_PORT:-18084}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-18085}"
TIMEOUT="${TIMEOUT:-900}"
WORKDIR="$(mktemp -d /tmp/p1-034-quota.XXXXXX)"

TEAMS=(pilot-stream pilot-risk pilot-recsys)

# What one pipeline asks for, and what one tenant may have. Both are exact
# multiples of each other on purpose.
PIPELINE_CPU="1.0"
PIPELINE_MEMORY="4Gi"
PIPELINE_STORAGE="4Gi"
CAPACITY=4      # pipelines that fit in one tenant's CPU and memory quota
ONBOARD=2       # pipelines each team keeps running, out of that capacity
ATTEMPTS=4      # pipelines each team asks for beyond the two it already runs
QUOTA="requests.cpu=4,requests.memory=16Gi,persistentvolumeclaims=12,requests.storage=48Gi,defaultRequest.cpu=100m"

export NAMESPACE RELEASE
# shellcheck source=scripts/keycloak-fixture.sh
source scripts/keycloak-fixture.sh

declare -A TEAM_ID TEAM_KEY TEAM_NS
declare -a P_TEAM P_NAME
START=$(date +%s)

say() { printf '\n== %s\n' "$*"; }
step() { printf '\n-- %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
elapsed() { echo "$(( $(date +%s) - START ))s"; }

API="http://127.0.0.1:${API_PORT}"
MANAGER_DEPLOYMENT="${RELEASE}-controlplane-api-server"
COMPILER_STATEFUL_SET="${RELEASE}-compiler"
PORT_FORWARD=""
OWNER_TOKEN=""
SAMPLER=""

for team in "${TEAMS[@]}"; do
  TEAM_NS["${team}"]="tenant-${team}"
done

cleanup() {
  local index team name key pass remaining
  [ -n "${PORT_FORWARD}" ] && kill "${PORT_FORWARD}" 2>/dev/null || true
  [ -n "${SAMPLER}" ] && kill "${SAMPLER}" 2>/dev/null || true
  [ -n "${KEYCLOAK_PORT_FORWARD_PID:-}" ] && kill "${KEYCLOAK_PORT_FORWARD_PID}" 2>/dev/null || true
  # Every pipeline is deleted through a key of the tenant that owns it: the
  # manager refuses to delete one whose storage is not cleared, and it will not
  # clear storage for a caller that cannot see the pipeline. The three calls are
  # repeated rather than issued once, because each one is refused until the
  # previous one has taken effect — a single pass leaves the pipeline behind.
  for pass in $(seq 1 30); do
    remaining=0
    for index in "${!P_NAME[@]}"; do
      team="${P_TEAM[${index}]}"
      name="${P_NAME[${index}]}"
      key="${TEAM_KEY[${team}]:-}"
      [ -n "${key}" ] || continue
      remaining=1
      curl -s -o /dev/null -X POST "${API}/v0/pipelines/${name}/stop?force=true" \
        -H "Authorization: Bearer ${key}" 2>/dev/null || true
      curl -s -o /dev/null -X POST "${API}/v0/pipelines/${name}/clear" \
        -H "Authorization: Bearer ${key}" 2>/dev/null || true
      curl -s -o /dev/null -X DELETE "${API}/v0/pipelines/${name}" \
        -H "Authorization: Bearer ${key}" 2>/dev/null || true
    done
    [ "${remaining}" -eq 1 ] || break
    sleep 2
  done
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# The HTTP status of a request, without failing on a 4xx: the refusals here are
# results, so a helper that exited on them would turn a pass into a crash.
status_of() {
  local method="$1" path="$2" key="$3" body="${4:-}"
  if [ -n "${body}" ]; then
    curl -s -o /dev/null -w '%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${key}" -H 'content-type: application/json' \
      --data "${body}" "${API}${path}"
  else
    curl -s -o /dev/null -w '%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${key}" "${API}${path}"
  fi
}

body_of() { curl -s -H "Authorization: Bearer ${2}" "${API}${1}"; }

field_of() {
  python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
value = body.get(sys.argv[1]) if isinstance(body, dict) else None
print("" if value is None else value)
' "$1"
}

# The manager's own report of a pipeline's state and error, on one line. The two
# travel together because a refused provision goes back to `Stopped`, which is
# also the state of a pipeline that was never started.
describe_state() {
  body_of "/v0/pipelines/$1" "$2" | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except Exception:
    print("unreachable\tthe manager did not answer for this pipeline")
    raise SystemExit
error = body.get("deployment_error")
if isinstance(error, dict):
    error = error.get("message") or json.dumps(error)
print("%s\t%s" % (body.get("deployment_status") or "none", (error or "").replace("\n", " ")))
'
}

install_release() {
  local phase="$1"
  shift
  helm upgrade --install "${RELEASE}" charts/feldera \
    --namespace "${NAMESPACE}" --create-namespace \
    --set "controlplane.image.tag=${MANAGER_TAG}" \
    --set "compiler.image.tag=${COMPILER_TAG}" \
    --set controlplane.controlPlane.deploymentTimeAnnotation=false \
    --set controlplane.kubernetesRunner.enabled=true \
    --set "controlplane.kubernetesRunner.image.tag=${RUNNER_TAG}" \
    --set controlplane.auth.enabled=true \
    --set controlplane.auth.provider=generic-oidc \
    --set "controlplane.auth.clientId=${CLIENT_ID}" \
    --set "controlplane.auth.issuer=${ISSUER}" \
    --set "controlplane.authorization.authAudience=${CLIENT_ID}" \
    --set "controlplane.owners[0]=${USER_NAME}@acme.test" \
    "$@" >"${WORKDIR}/helm-${phase}.log" 2>&1 \
    || { sed -n '1,40p' "${WORKDIR}/helm-${phase}.log" >&2; return 1; }
  kubectl --namespace "${NAMESPACE}" rollout status "deploy/${MANAGER_DEPLOYMENT}" \
    --timeout=5m >/dev/null || return 1
  # A pipeline reports `Pending` until the compiler pod has built it, so a
  # compiler that cannot start looks exactly like a pipeline that will not start,
  # ten minutes later. Wait for it here, where the message can name the cause.
  if kubectl --namespace "${NAMESPACE}" get statefulset "${COMPILER_STATEFUL_SET}" \
    >/dev/null 2>&1; then
    kubectl --namespace "${NAMESPACE}" rollout status "sts/${COMPILER_STATEFUL_SET}" \
      --timeout=5m >/dev/null || return 1
  fi
}

port_forward_manager() {
  [ -n "${PORT_FORWARD}" ] && kill "${PORT_FORWARD}" 2>/dev/null || true
  PORT_FORWARD=""
  kubectl --namespace "${NAMESPACE}" port-forward \
    "svc/${RELEASE}-controlplane-api-server" "${API_PORT}:8080" \
    >"${WORKDIR}/port-forward.log" 2>&1 &
  PORT_FORWARD=$!
  local _
  for _ in $(seq 1 60); do
    curl -sf "${API}/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

key_of() { printf '%s' "${TEAM_KEY[$1]:-}"; }
ns_of() { printf '%s' "${TEAM_NS[$1]:-}"; }

# One pipeline body: a table and one materialized view over it, no connector.
#
# Nothing external is involved on purpose. The question is admission, and a
# connector that cannot reach Kafka would turn a quota result into a connector
# result — the failure the operator would then be told about is the wrong one.
pipeline_body() {
  local name="$1" program="$2"
  python3 - "${name}" "${program}" "${PIPELINE_CPU}" "${PIPELINE_MEMORY}" "${PIPELINE_STORAGE}" <<'PY'
import json, sys
name, program, cpu, memory, storage = sys.argv[1:6]
json.dump({
    "name": name,
    "program_code": program,
    "program_config": {"profile": "unoptimized"},
    "runtime_config": {
        "workers": 1,
        "resources": {
            "cpu_cores_min": float(cpu),
            "memory_min": memory,
            "memory_max": memory,
            "storage_min": storage,
        },
    },
}, sys.stdout)
PY
}

# The three teams' workloads, two shapes each so they are not the same pipeline
# three times: a filter and a grouped rollup for one team, distinct values and a
# count for the next, and so on.
program_for() {
  case "$1" in
    onboard-stream-1)
      cat <<'SQL'
CREATE TABLE orders (id BIGINT NOT NULL, amount BIGINT NOT NULL) WITH ('materialized' = 'true');
CREATE MATERIALIZED VIEW big_orders AS SELECT id, amount FROM orders WHERE amount > 100;
SQL
      ;;
    onboard-stream-2)
      cat <<'SQL'
CREATE TABLE orders (id BIGINT NOT NULL, amount BIGINT NOT NULL) WITH ('materialized' = 'true');
CREATE MATERIALIZED VIEW amount_rollup AS SELECT amount, COUNT(*) AS n FROM orders GROUP BY amount;
SQL
      ;;
    onboard-risk-1)
      cat <<'SQL'
CREATE TABLE events (kind VARCHAR NOT NULL) WITH ('materialized' = 'true');
CREATE MATERIALIZED VIEW event_kinds AS SELECT DISTINCT kind FROM events;
SQL
      ;;
    onboard-risk-2)
      cat <<'SQL'
CREATE TABLE events (kind VARCHAR NOT NULL, score BIGINT NOT NULL) WITH ('materialized' = 'true');
CREATE MATERIALIZED VIEW scored AS SELECT kind, SUM(score) AS total FROM events GROUP BY kind;
SQL
      ;;
    onboard-recsys-1)
      cat <<'SQL'
CREATE TABLE clicks (user_id BIGINT NOT NULL, item_id BIGINT NOT NULL) WITH ('materialized' = 'true');
CREATE MATERIALIZED VIEW click_pairs AS SELECT user_id, item_id FROM clicks WHERE user_id > 0;
SQL
      ;;
    onboard-recsys-2)
      cat <<'SQL'
CREATE TABLE clicks (user_id BIGINT NOT NULL, item_id BIGINT NOT NULL) WITH ('materialized' = 'true');
CREATE MATERIALIZED VIEW per_item AS SELECT item_id, COUNT(*) AS n FROM clicks GROUP BY item_id;
SQL
      ;;
    *)
      # The contenders only have to compete for a slot; what they compute is
      # irrelevant to that, so they all compute the same trivial thing.
      cat <<'SQL'
CREATE TABLE t (c BIGINT NOT NULL) WITH ('materialized' = 'false');
CREATE MATERIALIZED VIEW counted AS SELECT COUNT(*) AS n FROM t;
SQL
      ;;
  esac
}

register_pipeline() {
  P_TEAM+=("$1")
  P_NAME+=("$2")
}

create_and_start() {
  local team="$1" name="$2" kind="$3"
  local key code
  key="$(key_of "${team}")"
  [ -n "${key}" ] || fail "team ${team} has no key"
  pipeline_body "${name}" "$(program_for "${kind}")" >"${WORKDIR}/body-${name}.json"
  code="$(curl -s -o "${WORKDIR}/create-${name}.out" -w '%{http_code}' \
    -X POST "${API}/v0/pipelines" \
    -H "Authorization: Bearer ${key}" -H 'content-type: application/json' \
    --data @"${WORKDIR}/body-${name}.json")"
  # 409 is a previous run of this suite reusing the name; the pipeline is still
  # the one this run intends to use.
  case "${code}" in
    200 | 201 | 409) ;;
    *) fail "creating ${name} in ${team} answered ${code}: $(cat "${WORKDIR}/create-${name}.out")" ;;
  esac
  register_pipeline "${team}" "${name}"
  code="$(status_of POST "/v0/pipelines/${name}/start" "${key}" '{}')"
  case "${code}" in
    200 | 202) ;;
    *) fail "starting ${name} in ${team} answered ${code}" ;;
  esac
}

pipeline_id() { body_of "/v0/pipelines/$1" "$2" | field_of id; }

wait_running() {
  local name="$1" key="$2" deadline=$(( $(date +%s) + TIMEOUT ))
  local state error
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    IFS=$'\t' read -r state error < <(describe_state "${name}" "${key}")
    case "${state}" in
      Running) return 0 ;;
      Failed | Shutdown) printf '%s' "${error}"; return 1 ;;
      Stopped) [ -n "${error}" ] && { printf '%s' "${error}"; return 1; } ;;
    esac
    sleep 2
  done
  printf 'timed out after %ss in state %s' "${TIMEOUT}" "${state}"
  return 1
}

# A namespace's quota, one line per axis: `<axis> <used> <hard>`.
#
# Kubernetes quantities are not numbers (`3700m`, `16Gi`, `4`), so everything
# that compares or sums them goes through one parser instead of `test -gt` on
# strings, which gets exactly the interesting cases wrong.
QUOTA_PY='
import json, sys

SCALE = {"": 1.0, "n": 1e-9, "u": 1e-6, "m": 1e-3, "k": 1e3, "M": 1e6, "G": 1e9,
         "T": 1e12, "Ki": 1024.0, "Mi": 1024.0**2, "Gi": 1024.0**3, "Ti": 1024.0**4}

def number(quantity):
    quantity = str(quantity).strip()
    for suffix in ("Ki", "Mi", "Gi", "Ti", "k", "M", "G", "T", "m", "n", "u"):
        if quantity.endswith(suffix):
            return float(quantity[: -len(suffix)]) * SCALE[suffix]
    return float(quantity)

def quotas():
    try:
        return json.load(sys.stdin)["items"]
    except Exception:
        return []

mode = sys.argv[1]
axes = ("requests.cpu", "requests.memory", "requests.storage", "persistentvolumeclaims")

if mode == "axes":
    for quota in quotas():
        status = quota.get("status") or {}
        hard = status.get("hard") or {}
        used = status.get("used") or {}
        for axis in axes:
            if axis in hard:
                print("%s %s %s" % (axis, used.get(axis, "0"), hard[axis]))
elif mode == "used":
    axis = sys.argv[2]
    total = 0.0
    for quota in quotas():
        used = (quota.get("status") or {}).get("used") or {}
        total += number(used.get(axis, "0"))
    print("%g" % total)
elif mode == "over":
    problems = []
    for quota in quotas():
        status = quota.get("status") or {}
        hard = status.get("hard") or {}
        used = status.get("used") or {}
        for axis in axes:
            if axis in hard and number(used.get(axis, "0")) > number(hard[axis]) + 1e-6:
                problems.append("%s used %s of %s" % (axis, used.get(axis, "0"), hard[axis]))
    print("; ".join(problems))
'

quota_axes() { kubectl get resourcequota --namespace "$1" -o json 2>/dev/null | python3 -c "${QUOTA_PY}" axes; }
quota_used() { kubectl get resourcequota --namespace "$1" -o json 2>/dev/null | python3 -c "${QUOTA_PY}" used "$2"; }
quota_over() { kubectl get resourcequota --namespace "$1" -o json 2>/dev/null | python3 -c "${QUOTA_PY}" over; }
quota_snapshot() { quota_axes "$1" | awk '{ printf "%s=%s/%s ", $1, $2, $3 }'; }
# The two axes a deleted pipeline must give back: CPU (what admitted it) and
# volume claims (what the StatefulSet controller creates before the pod, so a
# refusal can strand one).
quota_held() { printf '%s %s' "$(quota_used "$1" requests.cpu)" "$(quota_used "$1" persistentvolumeclaims)"; }

# Everything a previous run of this suite created for a tenant, deleted through
# the owner acting in that tenant. The pipelines live in the database and survive
# a failed run, so they are cleared here rather than by dropping the schema
# between runs.
#
# It deletes nothing itself. A pipeline's Kubernetes objects belong to the
# manager: deleting them behind its back leaves the row saying `provisioned`
# forever, and then stop, clear and delete are all permanently refused. So this
# asks the manager to stop the pipeline and lets it remove what it owns.
#
# Deleting a pipeline takes three calls in order — stop, clear the storage, then
# delete — because the manager refuses each one before its precondition holds.
# The passes are interleaved rather than run per pipeline: with twenty-one of
# them, waiting out one pipeline's transitions before starting the next is the
# difference between a minute and a quarter of an hour.
clear_pipelines() {
  local team="$1" pass name names stuck
  for pass in $(seq 1 60); do
    names="$(curl -s -H "Authorization: Bearer ${OWNER_TOKEN}" -H "Feldera-Tenant: ${team}" \
      -w '\n%{http_code}' "${API}/v0/pipelines" | python3 -c '
import json, sys
raw = sys.stdin.read()
body, _, code = raw.rpartition("\n")
if code != "200":
    print("status " + code)
    raise SystemExit(1)
for pipeline in json.loads(body):
    print(pipeline["name"])
')" || {
      case "${names}" in
        "status 401") fail "the owner's token was rejected while clearing ${team}; it expired during the run" ;;
        *) return 1 ;;
      esac
    }
    [ -n "${names}" ] || return 0
    [ "${pass}" -eq 1 ] && info "${team}: $(printf '%s\n' "${names}" | wc -l) pipeline(s) a previous run left behind"
    while IFS= read -r name; do
      [ -n "${name}" ] || continue
      curl -s -o /dev/null -X POST "${API}/v0/pipelines/${name}/stop?force=true" \
        -H "Authorization: Bearer ${OWNER_TOKEN}" -H "Feldera-Tenant: ${team}" || true
      curl -s -o /dev/null -X POST "${API}/v0/pipelines/${name}/clear" \
        -H "Authorization: Bearer ${OWNER_TOKEN}" -H "Feldera-Tenant: ${team}" || true
      curl -s -o /dev/null -X DELETE "${API}/v0/pipelines/${name}" \
        -H "Authorization: Bearer ${OWNER_TOKEN}" -H "Feldera-Tenant: ${team}" || true
    done <<<"${names}"
    sleep 2
  done
  # Still here after two minutes means the manager cannot finish a stop, which
  # means a row says `provisioned` for objects that are already gone — only
  # something outside the API can do that. Say so instead of timing out obscurely.
  stuck="$(printf '%s' "${names}" | tr '\n' ' ')"
  fail "${team}: these pipelines will not stop or delete (${stuck}). A row left holding resources that no longer exist cannot be cleared through the API; reset the database with: kubectl -n ${NAMESPACE} scale deploy/${RELEASE}-controlplane-api-server --replicas=0; kubectl -n ${NAMESPACE} exec ${RELEASE}-db-0 -- psql -U feldera -d feldera -c 'DELETE FROM pipeline;'; kubectl -n ${NAMESPACE} scale deploy/${RELEASE}-controlplane-api-server --replicas=1"
}

ids_of_team() {
  curl -sf -H "Authorization: Bearer $(key_of "$1")" "${API}/v0/pipelines" \
    | python3 -c '
import json, sys
for pipeline in json.load(sys.stdin):
    print(pipeline["id"])
'
}

# ---------------------------------------------------------------------------
# Phase 1: authentication, three tenants, their ids
# ---------------------------------------------------------------------------
say "loading images into kind"
# A load is seven gigabytes through the node's containerd and takes minutes, so an
# image the node already has is left alone.
load_image() {
  local image="$1" node="${CLUSTER}-control-plane"
  if docker exec "${node}" crictl images 2>/dev/null | grep -qF "${image}"; then
    info "${image} is already in the node"
    return 0
  fi
  kind load docker-image --name "${CLUSTER}" "${image}"
}
load_image "localhost:5001/feldera-manager:${MANAGER_TAG}"
load_image "localhost:5001/feldera-runner:${RUNNER_TAG}"
load_image "localhost:5001/feldera-compiler:${COMPILER_TAG}"

step "the identity provider is up"
keycloak_ensure "${WORKDIR}" "${KEYCLOAK_PORT}" \
  || fail "Keycloak did not come up; see ${WORKDIR}"
info "issuer ${ISSUER}"

step "the release comes up with authentication and no tenant mapping"
install_release phase1 || fail "the release did not become ready"
port_forward_manager || fail "the manager did not answer"

step "the platform owner creates the three teams"
OWNER_TOKEN="$(keycloak_access_token "${WORKDIR}" "${KEYCLOAK_PORT}")" \
  || fail "the identity provider did not issue a token for ${USER_NAME}"
[ -n "${OWNER_TOKEN}" ] || fail "the identity provider issued an empty token"
session="$(curl -sf -H "Authorization: Bearer ${OWNER_TOKEN}" "${API}/v0/config/session")" \
  || fail "the manager rejected the owner's token"
[ "$(printf '%s' "${session}" | field_of role)" = "owner" ] \
  || fail "the owner's session does not carry the owner role: ${session}"
info "the owner acts as owner"
for team in "${TEAMS[@]}"; do
  code="$(curl -s -o "${WORKDIR}/tenant-${team}.json" -w '%{http_code}' \
    -X POST "${API}/v0/tenants" \
    -H "Authorization: Bearer ${OWNER_TOKEN}" -H 'content-type: application/json' \
    --data "{\"name\":\"${team}\"}")"
  case "${code}" in
    200 | 201 | 409) ;;
    *) fail "creating tenant ${team} answered ${code}: $(cat "${WORKDIR}/tenant-${team}.json")" ;;
  esac
done
TENANTS="$(curl -sf -H "Authorization: Bearer ${OWNER_TOKEN}" "${API}/v0/tenants")" \
  || fail "could not list the tenants"
for team in "${TEAMS[@]}"; do
  TEAM_ID["${team}"]="$(printf '%s' "${TENANTS}" | python3 -c '
import json, sys
name = sys.argv[1]
print(next((str(t["id"]) for t in json.load(sys.stdin) if t.get("name") == name), ""))
' "${team}")"
  [ -n "${TEAM_ID[${team}]}" ] || fail "tenant ${team} has no id; the quota map cannot be keyed"
  info "${team} = ${TEAM_ID[${team}]}"
done

# ---------------------------------------------------------------------------
# Phase 2: a namespace and a quota per team
# ---------------------------------------------------------------------------
step "the release is upgraded with a namespace and a quota per team"
# The commas inside the quota are escaped because Helm treats an unescaped one
# as the separator between two `--set` assignments.
quota_args=()
for team in "${TEAMS[@]}"; do
  quota_args+=(--set-string \
    "controlplane.kubernetesRunner.tenantQuotas.${TEAM_ID[${team}]}=$(ns_of "${team}"): ${QUOTA//,/\\,}")
done
install_release phase2 \
  --set controlplane.kubernetesRunner.tenantNamespaceAutomation=true \
  "${quota_args[@]}" \
  || fail "the release did not become ready with the tenant mapping"
port_forward_manager || fail "the manager did not answer after the upgrade"

step "each team got its own namespace, quota and runner binding"
for team in "${TEAMS[@]}"; do
  ns="$(ns_of "${team}")"
  for _ in $(seq 1 60); do
    kubectl get namespace "${ns}" >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl get namespace "${ns}" >/dev/null 2>&1 || fail "the manager did not create ${ns}"
  label="$(kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.feldera\.com/managed-by}')"
  [ "${label}" = "feldera-manager" ] \
    || fail "${ns} is not labelled as platform-managed (managed-by='${label}')"
  kubectl get resourcequota --namespace "${ns}" -o name | grep -q . \
    || fail "${ns} has no ResourceQuota"
  # The LimitRange carries the default CPU request. Without it the quota's
  # `requests.cpu` entry refuses every pod that does not ask for CPU.
  kubectl get limitrange --namespace "${ns}" -o name | grep -q . \
    || fail "${ns} has no LimitRange, so its quota refuses pipelines that ask for no CPU"
  kubectl get rolebinding --namespace "${ns}" feldera-pipeline-runner -o name >/dev/null 2>&1 \
    || fail "${ns} has no runner RoleBinding, so no pipeline can be provisioned there"
  left="$(kubectl get statefulset,pod --namespace "${ns}" -o name 2>/dev/null | wc -l)"
  [ "${left}" -eq 0 ] || info "${ns}: ${left} object(s) left by an earlier run; they go after its pipelines do"
  info "${ns}: namespace, quota, limit range and runner binding"
done

step "each team starts with no pipelines"
# The token the owner got before the upgrade is minutes old by now, and Keycloak
# access tokens are short-lived. The clearing below is the first thing in the run
# that uses it late enough for that to matter, so it is renewed here; a 401 in
# the middle of a delete loop looks exactly like a pipeline that will not delete.
OWNER_TOKEN="$(keycloak_access_token "${WORKDIR}" "${KEYCLOAK_PORT}")" \
  || fail "could not renew the owner's token"
for team in "${TEAMS[@]}"; do
  clear_pipelines "${team}" || fail "could not clear ${team}'s pipelines from a previous run"
done

step "each team holds a write key of its own"
SUFFIX="$$-$(date +%s)"
for team in "${TEAMS[@]}"; do
  TEAM_KEY["${team}"]="$(curl -sf -X POST "${API}/v0/api_keys" \
    -H "Authorization: Bearer ${OWNER_TOKEN}" \
    -H "Feldera-Tenant: ${team}" \
    -H 'content-type: application/json' \
    --data "{\"name\":\"${team}-stress-${SUFFIX}\",\"role\":\"write\"}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["api_key"] if d.get("api_key") else sys.exit("the mint returned no api_key"))')" \
    || fail "could not mint a write key for ${team}"
  [ -n "$(key_of "${team}")" ] || fail "the ${team} key is empty; minting it failed silently"
done
# A key that acted in the wrong tenant would make every number below a lie, so
# the binding is checked before anything is measured: each key sees its own
# tenant's (empty) pipeline list and a header naming another tenant is refused.
for team in "${TEAMS[@]}"; do
  count="$(curl -sf -H "Authorization: Bearer $(key_of "${team}")" "${API}/v0/pipelines" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  [ "${count}" = "0" ] || fail "${team}'s key already sees ${count} pipeline(s); is it another tenant's key?"
  for other in "${TEAMS[@]}"; do
    [ "${other}" = "${team}" ] && continue
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $(key_of "${team}")" -H "Feldera-Tenant: ${other}" \
      "${API}/v0/pipelines")"
    [ "${code}" = "403" ] \
      || fail "${team}'s key naming ${other} answered ${code}, expected 403"
  done
done
info "three keys, each bound to its own team and refused elsewhere"

# ---------------------------------------------------------------------------
# Phase 3: onboarding — two pipelines per team, running
# ---------------------------------------------------------------------------
say "onboarding: two non-critical pipelines per team"
declare -A ONBOARD_SECONDS
for team in "${TEAMS[@]}"; do
  started=$(date +%s)
  shape="${team#pilot-}"
  for n in $(seq 1 "${ONBOARD}"); do
    create_and_start "${team}" "onboard-${shape}-${n}-${SUFFIX}" "onboard-${shape}-${n}"
  done
  for n in $(seq 1 "${ONBOARD}"); do
    error="$(wait_running "onboard-${shape}-${n}-${SUFFIX}" "$(key_of "${team}")")" \
      || fail "${team}'s onboard-${shape}-${n} did not start: ${error}"
  done
  ONBOARD_SECONDS["${team}"]=$(( $(date +%s) - started ))
  info "${team}: ${ONBOARD} pipelines Running after ${ONBOARD_SECONDS[${team}]}s"
done

step "a team with two pipelines running holds exactly two pipelines' worth of quota"
for team in "${TEAMS[@]}"; do
  ns="$(ns_of "${team}")"
  problems="$(quota_over "${ns}")"
  [ -z "${problems}" ] || fail "${team} is already over quota: ${problems}"
  used="$(quota_used "${ns}" requests.cpu)"
  # 2 pipelines x 1.0 CPU. The number matters: it is what proves the request the
  # pipeline asked for is the request the quota counted, so the arithmetic in
  # the pressure phase below rests on two, not on something close to it.
  [ "${used}" = "2" ] \
    || fail "${team} counts ${used} CPUs with ${ONBOARD} pipelines of ${PIPELINE_CPU} each; the request is not landing as declared"
  info "${team}: $(quota_snapshot "${ns}")"
done

# ---------------------------------------------------------------------------
# Phase 4: pressure — every team asks for more than it fits
# ---------------------------------------------------------------------------
say "pressure: ${ATTEMPTS} concurrent requests per team, two slots free each"

# L2 is sampled while all of this is happening, not only afterwards: a quota
# that is exceeded for two seconds is exceeded, and a single reading after
# everything settled cannot tell that apart from one that never was.
SAMPLES="${WORKDIR}/quota-samples.txt"
: >"${SAMPLES}"
sampler() {
  local t ns
  while [ ! -f "${WORKDIR}/stop-sampler" ]; do
    for t in "${TEAMS[@]}"; do
      ns="$(ns_of "${t}")"
      printf '%s %s\n' "${t}" "$(quota_snapshot "${ns}" | tr '\n' ' ')" >>"${SAMPLES}"
    done
    sleep 2
  done
}
sampler &
SAMPLER=$!

PRESS_START=$(date +%s)
declare -a PRESS_PIDS=()
for team in "${TEAMS[@]}"; do
  shape="${team#pilot-}"
  for n in $(seq 1 "${ATTEMPTS}"); do
    name="press-${shape}-${n}-${SUFFIX}"
    key="$(key_of "${team}")"
    pipeline_body "${name}" "$(program_for press)" >"${WORKDIR}/body-${name}.json"
    register_pipeline "${team}" "${name}"
    # Create and start both happen in the background: the point is to have all
    # of a team's contenders in the provisioning queue at once, not to make the
    # queue longer by serialising the requests.
    (
      code="$(curl -s -o "${WORKDIR}/create-${name}.out" -w '%{http_code}' \
        -X POST "${API}/v0/pipelines" \
        -H "Authorization: Bearer ${key}" -H 'content-type: application/json' \
        --data @"${WORKDIR}/body-${name}.json")"
      printf '%s' "${code}" >"${WORKDIR}/code-${name}"
      case "${code}" in
        200 | 201) ;;
        *) printf '%s' "${code}" >"${WORKDIR}/start-failed-${name}"; exit 0 ;;
      esac
      code="$(status_of POST "/v0/pipelines/${name}/start" "${key}" '{}')"
      printf '%s' "${code}" >"${WORKDIR}/start-${name}"
    ) &
    PRESS_PIDS+=("$!")
  done
done
# By pid: a bare `wait` would also wait on the port-forward and the sampler, which
# run for the rest of the test.
for pid in "${PRESS_PIDS[@]}"; do wait "${pid}" || true; done
for team in "${TEAMS[@]}"; do
  shape="${team#pilot-}"
  for n in $(seq 1 "${ATTEMPTS}"); do
    name="press-${shape}-${n}-${SUFFIX}"
    [ -f "${WORKDIR}/start-failed-${name}" ] \
      && fail "creating ${name} in ${team} failed: $(cat "${WORKDIR}/create-${name}.out")"
    start_code="$(cat "${WORKDIR}/start-${name}" 2>/dev/null || echo missing)"
    case "${start_code}" in
      200 | 202) ;;
      *) fail "starting ${name} in ${team} answered ${start_code}" ;;
    esac
  done
done
info "all ${#TEAMS[@]} teams asked; waiting for every request to settle"

# ---------------------------------------------------------------------------
# Phase 5: settle, then assert L1–L6
# ---------------------------------------------------------------------------
declare -A RUNNING REFUSED REFUSAL_SECONDS
for team in "${TEAMS[@]}"; do
  RUNNING["${team}"]=0
  REFUSED["${team}"]=0
  REFUSAL_SECONDS["${team}"]=""
done
disturbed=""

pending=1
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  pending=0
  for index in "${!P_NAME[@]}"; do
    team="${P_TEAM[${index}]}"
    name="${P_NAME[${index}]}"
    case "${name}" in onboard-*) continue ;; esac
    [ -f "${WORKDIR}/settled-${name}" ] && continue
    IFS=$'\t' read -r state error < <(describe_state "${name}" "$(key_of "${team}")")
    case "${state}" in
      Running)
        RUNNING["${team}"]=$(( RUNNING[${team}] + 1 ))
        : >"${WORKDIR}/settled-${name}"
        ;;
      Failed | Stopped)
        if [ -n "${error}" ]; then
          REFUSED["${team}"]=$(( REFUSED[${team}] + 1 ))
          printf '%s' "${error}" >"${WORKDIR}/refusal-${name}"
          REFUSAL_SECONDS["${team}"]+="$(( $(date +%s) - PRESS_START )),"
          : >"${WORKDIR}/settled-${name}"
        else
          pending=$(( pending + 1 ))
        fi
        ;;
      *) pending=$(( pending + 1 )) ;;
    esac
  done
  # A pipeline that a team already had running and that died is a hard failure
  # whether or not the contenders have settled, so it is recorded as soon as it
  # is seen rather than waited on.
  for team in "${TEAMS[@]}"; do
    shape="${team#pilot-}"
    for n in $(seq 1 "${ONBOARD}"); do
      IFS=$'\t' read -r state _ < <(describe_state "onboard-${shape}-${n}-${SUFFIX}" "$(key_of "${team}")")
      case "${state}" in
        Failed | Shutdown) disturbed="${disturbed}${team}/onboard-${shape}-${n} went to ${state}; " ;;
      esac
    done
  done
  [ "${pending}" -eq 0 ] && break
  sleep 3
done
[ "${pending}" -eq 0 ] \
  || fail "${pending} request(s) neither ran nor were refused after ${TIMEOUT}s"
info "every request settled after $(( $(date +%s) - PRESS_START ))s"

# L4, observed rather than inferred: the pipelines each team already had running
# must still be running now that its contenders have been refused. A quota that
# were enforced by evicting the tenant's previous work would pass every other
# check here and fail this one.
for team in "${TEAMS[@]}"; do
  shape="${team#pilot-}"
  for n in $(seq 1 "${ONBOARD}"); do
    IFS=$'\t' read -r state error < <(describe_state "onboard-${shape}-${n}-${SUFFIX}" "$(key_of "${team}")")
    [ "${state}" = "Running" ] \
      || disturbed="${disturbed}${team}/onboard-${shape}-${n} is ${state} (${error}); "
  done
done

step "L1: a team runs exactly what its quota fits, and no more"
for team in "${TEAMS[@]}"; do
  expected_running=$(( CAPACITY - ONBOARD ))
  [ "${RUNNING[${team}]}" -eq "${expected_running}" ] \
    || fail "${team} runs ${RUNNING[${team}]} of the ${ATTEMPTS} it asked for beyond ${ONBOARD}; the quota fits ${expected_running}"
  [ "${REFUSED[${team}]}" -eq $(( ATTEMPTS - expected_running )) ] \
    || fail "${team} had ${REFUSED[${team}]} refusals, expected $(( ATTEMPTS - expected_running ))"
  info "${team}: ${RUNNING[${team}]} accepted, ${REFUSED[${team}]} refused"
done

step "L2: no namespace ever exceeded its quota, at any sample"
: >"${WORKDIR}/stop-sampler"
wait "${SAMPLER}" 2>/dev/null || true
SAMPLER=""
python3 - "${SAMPLES}" <<'PY' || fail "a namespace exceeded its quota"
import sys

SCALE = {"": 1.0, "n": 1e-9, "u": 1e-6, "m": 1e-3, "k": 1e3, "M": 1e6, "G": 1e9,
         "T": 1e12, "Ki": 1024.0, "Mi": 1024.0**2, "Gi": 1024.0**3, "Ti": 1024.0**4}

def number(quantity):
    quantity = str(quantity).strip()
    for suffix in ("Ki", "Mi", "Gi", "Ti", "k", "M", "G", "T", "m", "n", "u"):
        if quantity.endswith(suffix):
            return float(quantity[: -len(suffix)]) * SCALE[suffix]
    return float(quantity)

peaks, problems, samples = {}, [], 0
for line in open(sys.argv[1]):
    fields = line.split()
    if len(fields) < 2:
        continue
    samples += 1
    team = fields[0]
    for entry in fields[1:]:
        axis, quantities = entry.split("=", 1)
        used, hard = quantities.split("/", 1)
        if not hard.strip() or hard == "0":
            continue
        key = (team, axis)
        if key not in peaks or number(used) > peaks[key][0]:
            peaks[key] = (number(used), used)
        if number(used) > number(hard) + 1e-6:
            problems.append("%s %s used %s of %s" % (team, axis, used, hard))
if not samples:
    print("no quota samples were taken")
    raise SystemExit(1)
for (team, axis), (_, raw) in sorted(peaks.items()):
    print("   %-14s %-24s peak %s" % (team, axis, raw))
if problems:
    print("FAIL: " + "; ".join(sorted(set(problems))))
    raise SystemExit(1)
PY

step "L3: every refusal is the quota's verdict, not a timeout"
for index in "${!P_NAME[@]}"; do
  team="${P_TEAM[${index}]}"
  name="${P_NAME[${index}]}"
  case "${name}" in onboard-*) continue ;; esac
  [ -f "${WORKDIR}/refusal-${name}" ] || continue
  message="$(cat "${WORKDIR}/refusal-${name}")"
  case "${message}" in
    *"no room for this pipeline"*) ;;
    *) fail "${name} in ${team} was refused with '${message}', which is not the quota's verdict" ;;
  esac
  # The message has to name the numbers, or the operator cannot tell how far over
  # the request was.
  case "${message}" in
    *requested:*used:*) ;;
    *) fail "${name} was refused without the API server's numbers: ${message}" ;;
  esac
done
for team in "${TEAMS[@]}"; do
  info "${team}: refusals settled after ${REFUSAL_SECONDS[${team}]%,}s (one figure per refusal)"
done

step "L4: a team's pressure does not move another team's numbers"
# Every team is given the same quota and asks for the same thing, so every team
# must end with the same numbers. A tenant whose pressure leaked into another
# tenant's admission — a shared accounting bug, a shared provisioning queue that
# drops work — would show up as one team holding fewer pipelines than another.
[ -z "${disturbed}" ] \
  || fail "the pressure disturbed pipelines that were already running: ${disturbed}"
for team in "${TEAMS[@]}"; do
  ns="$(ns_of "${team}")"
  problems="$(quota_over "${ns}")"
  [ -z "${problems}" ] || fail "${team} is over quota after the pressure: ${problems}"
  held="$(quota_used "${ns}" requests.cpu)"
  [ "${held}" = "${CAPACITY}" ] \
    || fail "${team} holds ${held} CPUs, expected ${CAPACITY} (the quota's whole allowance)"
  info "${team}: $(quota_snapshot "${ns}")"
done

# A saturated tenant keeps refusing rather than letting one more through: the
# refusal path is still there once everything has settled, which a first-round
# refusal alone does not show.
declare -A BEFORE_LATE
for team in "${TEAMS[@]}"; do
  BEFORE_LATE["${team}"]="$(quota_snapshot "$(ns_of "${team}")")"
done
late="press-late-${SUFFIX}"
create_and_start "${TEAMS[0]}" "${late}" press
error="$(wait_running "${late}" "$(key_of "${TEAMS[0]}")" || true)"
[ -n "${error}" ] || fail "${TEAMS[0]} admitted ${late} with its quota already full"
case "${error}" in
  *"no room for this pipeline"*) ;;
  *) fail "${late} was refused with '${error}', which is not the quota's verdict" ;;
esac
# The other tenants must be untouched, on every axis.
for team in "${TEAMS[@]}"; do
  [ "${team}" = "${TEAMS[0]}" ] && continue
  [ "$(quota_snapshot "$(ns_of "${team}")")" = "${BEFORE_LATE[${team}]}" ] \
    || fail "${team}'s usage moved while ${TEAMS[0]} was refused again: before '${BEFORE_LATE[${team}]}', now '$(quota_snapshot "$(ns_of "${team}")")'"
done
# The pressured tenant's admission axes must not move either: the request was
# refused, so it cannot have taken CPU or memory. Its storage axes *may* move and
# that is worth a line of their own: the StatefulSet controller creates a volume
# claim before it creates the pod the quota refuses, so a refused pipeline holds a
# claim until it is deleted. That is why storage is given three times the room
# here, and why the cleanup deletes every pipeline rather than only the running
# ones.
ns="$(ns_of "${TEAMS[0]}")"
before_cpu="$(printf '%s' "${BEFORE_LATE[${TEAMS[0]}]}" | tr ' ' '\n' | grep '^requests.cpu=')"
after_cpu="$(quota_snapshot "${ns}" | tr ' ' '\n' | grep '^requests.cpu=')"
[ "${before_cpu}" = "${after_cpu}" ] \
  || fail "${TEAMS[0]}'s CPU moved from ${before_cpu} to ${after_cpu} although the request was refused"
claims_before="$(printf '%s' "${BEFORE_LATE[${TEAMS[0]}]}" | tr ' ' '\n' | grep '^persistentvolumeclaims=' | cut -d= -f2 | cut -d/ -f1)"
claims_after="$(quota_snapshot "${ns}" | tr ' ' '\n' | grep '^persistentvolumeclaims=' | cut -d= -f2 | cut -d/ -f1)"
info "${TEAMS[0]}: refused again once saturated; no other team's numbers moved"
if [ "${claims_after}" -gt "${claims_before}" ]; then
  info "${TEAMS[0]}: the refused pipeline holds a volume claim (${claims_before} -> ${claims_after}); it is released when the pipeline is deleted"
fi

step "L5: no tenant's pipeline objects appear in another tenant's namespace"
# Each object the runner creates is named after the pipeline id, so the ids a
# tenant can see are the ids that may appear in its namespace. Anything else is a
# pipeline placed somewhere it does not belong.
declare -A OWN_IDS
for team in "${TEAMS[@]}"; do
  OWN_IDS["${team}"]="$(ids_of_team "${team}" | sort)"
done
for team in "${TEAMS[@]}"; do
  ns="$(ns_of "${team}")"
  foreign=0
  for other in "${TEAMS[@]}"; do
    [ "${other}" = "${team}" ] && continue
    while IFS= read -r id; do
      [ -n "${id}" ] || continue
      case "${OWN_IDS[${team}]}" in
        *"${id}"*) continue ;;
      esac
      found="$(kubectl get statefulset,pod,service,secret,persistentvolumeclaim,pvc \
        --namespace "${ns}" -o name 2>/dev/null | grep -F "pipeline-${id}" || true)"
      if [ -n "${found}" ]; then
        foreign=$(( foreign + 1 ))
        info "${ns} holds ${other}'s objects: ${found}"
      fi
    done <<<"${OWN_IDS[${other}]}"
  done
  [ "${foreign}" -eq 0 ] || fail "${ns} holds ${foreign} object(s) belonging to another tenant"
  info "${ns}: only its own tenant's objects"
done

step "L6: a refusal is final, and the control plane stayed up"
restarts=0
for pod in $(kubectl --namespace "${NAMESPACE}" get pod \
  -l "app.kubernetes.io/component=api-server" -o name 2>/dev/null); do
  n="$(kubectl --namespace "${NAMESPACE}" get "${pod}" \
    -o jsonpath='{range .status.containerStatuses[*]}{.restartCount}{"\n"}{end}' 2>/dev/null \
    | awk '{ total += $1 } END { print total + 0 }')"
  restarts=$(( restarts + n ))
done
[ "${restarts}" -eq 0 ] || fail "the manager restarted ${restarts} time(s) during the test"
# A refused pod is created by the StatefulSet controller, not by the manager, so
# the number of FailedCreate attempts says nothing about the manager: the
# controller retries with backoff and the API server aggregates those attempts
# into one event with a count of about eight. What is worth asserting is that
# the retrying has stopped by now — a controller still asking would mean the
# StatefulSet is still there, and the manager should have removed it.
refusal_attempts() {
  local total=0 n
  for team in "${TEAMS[@]}"; do
    n="$(kubectl get events --namespace "$(ns_of "${team}")" -o json 2>/dev/null | python3 -c '
import json, sys
total = 0
for event in json.load(sys.stdin)["items"]:
    message = event.get("message") or ""
    if event.get("reason") == "FailedCreate" and "exceeded quota" in message:
        total += int(event.get("count") or 1)
print(total)
')"
    total=$(( total + n ))
  done
  printf '%s' "${total}"
}
events="$(refusal_attempts)"
refusals_total=0
for team in "${TEAMS[@]}"; do
  refusals_total=$(( refusals_total + REFUSED[${team}] ))
done
[ "${events}" -ge "${refusals_total}" ] \
  || fail "only ${events} pod creation attempts were refused for ${refusals_total} refused pipelines"
sleep 30
settled="$(refusal_attempts)"
[ "${settled}" -eq "${events}" ] \
  || fail "pod creation was still being attempted 30s later (${events} -> ${settled} attempts); the refused pipelines were not taken away"
info "manager restarts 0; ${events} refused pod creation attempt(s) for ${refusals_total} refused pipelines, and none in the 30s after"

# Kept for the summary: after cleanup the numbers are all zero, which says
# nothing about what the quotas actually held while they were being pressed.
declare -A PRESSED
for team in "${TEAMS[@]}"; do
  PRESSED["${team}"]="$(quota_snapshot "$(ns_of "${team}")")"
done

# ---------------------------------------------------------------------------
# Phase 6: give the capacity back
# ---------------------------------------------------------------------------
say "cleanup: deleting every pipeline gives its quota back"
# Twenty-one pipelines through stop, clear and delete, each with its own poll,
# would spend minutes waiting on controllers that all drain at the same time. The
# deletes are issued per pipeline and the draining is waited on per namespace.
for index in "${!P_NAME[@]}"; do
  team="${P_TEAM[${index}]}"
  name="${P_NAME[${index}]}"
  key="$(key_of "${team}")"
  curl -s -o /dev/null -X POST "${API}/v0/pipelines/${name}/stop?force=true" \
    -H "Authorization: Bearer ${key}" || true
done
for index in "${!P_NAME[@]}"; do
  team="${P_TEAM[${index}]}"
  name="${P_NAME[${index}]}"
  key="$(key_of "${team}")"
  for _ in $(seq 1 30); do
    [ "$(field_of deployment_status <<<"$(body_of "/v0/pipelines/${name}" "${key}")")" = "Stopped" ] && break
    sleep 2
  done
  # Deleting a pipeline whose storage is not cleared is refused, and the clear
  # itself is refused while the pipeline is still stopping, so both are retried
  # together rather than in sequence.
  for _ in $(seq 1 60); do
    curl -s -o /dev/null -X POST "${API}/v0/pipelines/${name}/clear" \
      -H "Authorization: Bearer ${key}" || true
    code="$(status_of DELETE "/v0/pipelines/${name}" "${key}")"
    case "${code}" in 200 | 404) break ;; esac
    sleep 2
  done
done
for team in "${TEAMS[@]}"; do
  ns="$(ns_of "${team}")"
  # The pod and its claim are what the quota counts, and the manager answers the
  # deletion before the controller has finished tearing them down.
  for _ in $(seq 1 90); do
    [ "$(kubectl get pod,statefulset --namespace "${ns}" -o name 2>/dev/null \
      | grep -c 'pipeline-')" -eq 0 ] && break
    sleep 2
  done
  held=""
  for _ in $(seq 1 60); do
    held="$(quota_held "${ns}")"
    [ "${held}" = "0 0" ] && break
    sleep 2
  done
  [ "${held}" = "0 0" ] \
    || fail "${ns} still holds '${held}' (requests.cpu persistentvolumeclaims) after every pipeline was deleted"
  info "${ns}: gave everything back"
done

say "PASS: 3 teams online, ${#TEAMS[@]} quotas pressed, zero penetration, in $(elapsed)"
printf '\n   team             onboarded  admitted  refused  quota under pressure\n'
for team in "${TEAMS[@]}"; do
  printf '   %-16s %-10s %-9s %-8s %s\n' "${team}" "${ONBOARD_SECONDS[${team}]}s" \
    "${RUNNING[${team}]}" "${REFUSED[${team}]}" "${PRESSED[${team}]}"
done
