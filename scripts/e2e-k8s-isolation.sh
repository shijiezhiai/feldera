#!/usr/bin/env bash
#
# P1-033 acceptance: two tenants cannot reach each other.
#
# P1-022 through P1-025 each added one mechanism that keeps tenants apart — a
# namespace with a quota, a route table that names the acting tenant, group
# roles, a Secret allowlist — and each was tested from the inside: one tenant
# against its own quota, one tenant's Secrets, one tenant's roles. Nothing put
# two tenants against each other, so "they cannot hit each other" rested on
# reading the code.
#
# This script attacks the boundaries with the credentials an ordinary tenant
# holds — a `write` API key of its own and nothing else:
#
#   1. network   A's pipeline cannot open a connection to B's pipeline, while
#                the manager still can, so the refusal is the policy and not a
#                pod that cannot talk to anything;
#   2. quota     A's namespace being full does not stop B from running;
#   3. secrets   A cannot mount a Secret that exists only in B's namespace,
#                while A mounts its own and B mounts that one;
#   4. access    A's key cannot read, start, delete or list B's pipelines, keys,
#                members or tenants, and the answers reveal nothing;
#   5. escape    A cannot place a pipeline inside B's namespace by naming it,
#                which is how P1-033's audit found the namespaces escapable.
#
# The install has two phases, because the quota map is keyed by tenant UUID and
# a UUID only exists once the tenant does: the release comes up without quotas,
# the tenants are created through the API, and the release is upgraded with the
# ids the API reported.
#
# Prerequisites: the kind cluster from docs/self-hosted-dev-env.md with the
# Keycloak image loaded, and manager, compiler and runner images built from this
# commit.
#
# Usage:
#
#   MANAGER_TAG=p1-033 RUNNER_TAG=<runner tag> scripts/e2e-k8s-isolation.sh
#
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
MANAGER_TAG="${MANAGER_TAG:?set MANAGER_TAG to the manager image tag under test}"
COMPILER_TAG="${COMPILER_TAG:-${MANAGER_TAG}}"
RUNNER_TAG="${RUNNER_TAG:?set RUNNER_TAG to a feldera-runner image tag built from deploy/Dockerfile.runner}"
API_PORT="${API_PORT:-18083}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-18084}"
TIMEOUT="${TIMEOUT:-600}"
WORKDIR="$(mktemp -d /tmp/p1-033-isolation.XXXXXX)"

TENANT_A="acme"
TENANT_B="beta"
NS_A="tenant-acme"
NS_B="tenant-beta"
# Two Secrets: one that exists only in B's namespace and one that exists in A's.
# "A cannot mount B's Secret" proves nothing unless A can mount a Secret of its
# own, otherwise a pipeline that mounts nothing at all would pass the step.
SECRET_ONLY_IN_B="iso-only-in-beta"
SECRET_IN_A="iso-in-acme"
SECRET_VALUE_A="acme-marker-$$-$(date +%s)"
SECRET_VALUE_B="beta-marker-$$"

# Both tenants get the same quota, so a difference in what they can run cannot be
# explained by a difference in what they were given.
#
# The quota caps `requests.cpu` only, and the namespace gets a default request of
# 100m with it. The default is what makes a quota entry usable at all: a
# `requests.cpu` quota makes the API server require a CPU request on *every* pod
# in the namespace, and a pipeline that asks for none is refused outright rather
# than ignored. With the default in place such a pipeline costs 100m against the
# quota instead, so it is small but countable, and the arithmetic below holds.
#
# A's first pipeline asks for the whole core, which is what fills A; the request
# both tenants then make is half a core, which A has no room for and B does.
#
# `limits.cpu` is deliberately absent for the same reason: it would make a CPU
# limit mandatory on every pod, and the runner sets a limit only when a pipeline
# asks for one. `limits.memory` is safe because every pipeline sets both memory
# bounds.
QUOTA="requests.cpu=1,defaultRequest.cpu=100m,limits.memory=8Gi"
NORMAL_MEMORY_MB=1024
FULL_CPU_CORES=1.0
HALF_CPU_CORES=0.5

say() { printf '\n== %s\n' "$*"; }
step() { printf '\n-- %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
elapsed() { echo "$(( $(date +%s) - START ))s"; }
START=$(date +%s)

API="http://127.0.0.1:${API_PORT}"
MANAGER_DEPLOYMENT="${RELEASE}-controlplane-api-server"
COMPILER_STATEFUL_SET="${RELEASE}-compiler"
PORT_FORWARD=""
PIPELINES=()
KEY_A=""
KEY_B=""
OWNER_TOKEN=""

cleanup() {
  local pipeline key
  [ -n "${PORT_FORWARD}" ] && kill "${PORT_FORWARD}" 2>/dev/null || true
  [ -n "${KEYCLOAK_PORT_FORWARD_PID:-}" ] && kill "${KEYCLOAK_PORT_FORWARD_PID}" 2>/dev/null || true
  # Each pipeline is deleted through a key of the tenant that owns it: the
  # manager refuses to delete a pipeline whose storage is not cleared, and it
  # will not clear storage for a caller that cannot see the pipeline.
  for pipeline in "${PIPELINES[@]:-}"; do
    [ -n "${pipeline}" ] || continue
    for key in "${KEY_A}" "${KEY_B}" "${OWNER_TOKEN}"; do
      [ -n "${key}" ] || continue
      curl -sf -X POST "${API}/v0/pipelines/${pipeline}/clear" \
        -H "Authorization: Bearer ${key}" >/dev/null 2>&1 || true
      curl -sf -X DELETE "${API}/v0/pipelines/${pipeline}" \
        -H "Authorization: Bearer ${key}" >/dev/null 2>&1 && break
    done
  done
  kubectl --namespace "${NS_A}" delete secret "${SECRET_IN_A}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --namespace "${NS_B}" delete secret "${SECRET_ONLY_IN_B}" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# The HTTP status of a request, without failing the script on a 4xx: the refusals
# here are the results, so a helper that exited on them would turn every pass
# into a crash.
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

# The body of a GET, so an assertion can look for a leaked name inside it.
body_of() {
  curl -s -H "Authorization: Bearer ${2}" "${API}${1}"
}

# A top-level field of a JSON body, empty when absent.
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
# travel together because the caller has to read them together: a refused
# provision goes back to `Stopped`, which is also the state of a pipeline that
# was never started, so the error is what makes the state mean anything.
describe_state() {
  # A body that is not JSON means the request never reached the manager -- a
  # port-forward outlives neither a rollout nor a long idle wait. Reporting that
  # as `unreachable` keeps it distinguishable from a pipeline that is merely not
  # running yet, and keeps a dead forward out of the log as a traceback per poll.
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
print("%s\t%s" % (body.get("deployment_status") or "none", error or ""))
'
}

# Waits for a pipeline to run, returning the error when it settles on one.
# The value a Secret reference resolves to inside the pipeline's pod.
#
# The pipeline is not required to reach `Running` for this: the mount happens
# before the program starts, and what this suite asks is which Secrets a tenant
# can reach, not what its connector does with them. The programs here point a
# Kafka input at an address that does not exist, so a pipeline that stays up
# would be the surprising outcome -- and a pipeline that dies after mounting
# still proves where the file came from, which is the whole property. P1-025's
# own suite asserts the mount the same way.
secret_value_in_pod() {
  local namespace="$1" name="$2" key="$3" secret="$4"
  local id pod value=""
  id="$(pipeline_id "${name}" "${key}")" || { printf 'the pipeline has no id'; return 1; }
  pod="pipeline-${id}-0"
  for _ in $(seq 1 120); do
    kubectl --namespace "${namespace}" get pod "${pod}" >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl --namespace "${namespace}" get pod "${pod}" >/dev/null 2>&1 \
    || { printf 'the runner never created %s in %s' "${pod}" "${namespace}"; return 1; }
  for _ in $(seq 1 60); do
    value="$(kubectl --namespace "${namespace}" exec "${pod}" -- \
      cat "/etc/feldera-secrets/kubernetes/${secret}/password" 2>/dev/null || true)"
    [ -n "${value}" ] && break
    sleep 2
  done
  [ -n "${value}" ] \
    || { printf '%s has no %s/password in %s (pod %s)' \
           "${pod}" "${secret}" "${namespace}" \
           "$(kubectl --namespace "${namespace}" get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || true)"; return 1; }
  printf '%s' "${value}"
}

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

# Waits until a pipeline has been refused, leaving the refusal in `REFUSAL` and
# the state it was refused in in `REFUSAL_STATE`.
#
# The refusal is read from `deployment_error` rather than from the status: a
# refused provision is not a terminal *status* — it goes back to `Stopped`, which
# is also where a pipeline that was never started sits. The two are written by
# separate updates, so the status can read `Stopped` a poll before the reason
# appears, and waiting on the status alone would call an accepted request
# refused.
#
# It sets globals instead of printing the refusal because the callers assert on
# it twice, and a command substitution would run `fail` in a subshell, where it
# would exit the subshell and leave the suite going.
expect_refused() {
  local name="$1" key="$2" what="$3" deadline=$(( $(date +%s) + TIMEOUT ))
  local state error
  REFUSAL=""
  REFUSAL_STATE=""
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    IFS=$'\t' read -r state error < <(describe_state "${name}" "${key}")
    if [ "${state}" = "Running" ] && [ -z "${error}" ]; then
      fail "${what}: ${name} is Running, so the request was not refused"
    fi
    if [ -n "${error}" ]; then
      REFUSAL="${error}"
      REFUSAL_STATE="${state}"
      return 0
    fi
    sleep 2
  done
  # Neither refused nor running: the suite cannot tell an accepted request from
  # a slow one. Calling that a pass is how the chaos matrix spent a release
  # reporting green over a fault it never injected.
  fail "${what}: ${name} was neither refused nor running after ${TIMEOUT}s (state ${state})"
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
  # Wait on the manager alone: the compiler is a StatefulSet whose image this
  # test does not exercise, and `--wait` would fail the run on a slow compiler
  # rather than on anything this test is about.
  kubectl --namespace "${NAMESPACE}" rollout status "deploy/${MANAGER_DEPLOYMENT}" \
    --timeout=5m >/dev/null || return 1
  # The compiler is not incidental: a pipeline reports `Pending` until the
  # compiler pod has built it, so a compiler that cannot start looks exactly like
  # a pipeline that will not start, ten minutes later. Wait for it here, where
  # the message can name the cause.
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
  # A port-forward outlives neither a rollout nor a long idle wait, so every
  # install is followed by a fresh one.
  local _
  for _ in $(seq 1 60); do
    if curl -sf "${API}/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

tenant_id_of() {
  printf '%s' "${TENANTS}" | python3 -c '
import json, sys
tenants = json.load(sys.stdin)
name = sys.argv[1]
print(next((str(t["id"]) for t in tenants if t.get("name") == name), ""))
' "$1"
}

# Creates a pipeline whose table is empty: the point is a live pod with a port,
# not any data flowing through it.
#
# `cpu_cores` is how the quota step spends A's request budget: a pipeline that
# asks for no CPU request (the default) is invisible to a `requests.cpu` quota,
# so the rest of the suite cannot be refused by it.
create_pipeline() {
  local name="$1" key="$2" namespace="${3:-}"
  local memory_mb="${4:-${NORMAL_MEMORY_MB}}" cpu_cores="${5:-0}"
  python3 - "$name" "$namespace" "$memory_mb" "$cpu_cores" \
    >"${WORKDIR}/create-${name}.json" <<'PY'
import json, sys
name, namespace, memory_mb, cpu_cores = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]))
resources = {
    "cpu_cores_min": cpu_cores,
    "memory_mb_min": memory_mb,
    "memory_mb_max": memory_mb,
}
if namespace:
    resources["namespace"] = namespace
json.dump({
    "name": name,
    "program_code": "CREATE TABLE t (c BIGINT NOT NULL) WITH ('materialized' = 'false');",
    "program_config": {"profile": "unoptimized"},
    "runtime_config": {"workers": 1, "resources": resources},
}, sys.stdout)
PY
  local code
  code="$(curl -s -o "${WORKDIR}/create-${name}.out" -w '%{http_code}' \
    -X POST "${API}/v0/pipelines" \
    -H "Authorization: Bearer ${key}" -H 'content-type: application/json' \
    --data @"${WORKDIR}/create-${name}.json")"
  [ "${code}" = "200" ] || [ "${code}" = "201" ] \
    || fail "creating ${name} answered ${code}: $(cat "${WORKDIR}/create-${name}.out")"
  PIPELINES+=("${name}")
}

pipeline_id() {
  body_of "/v0/pipelines/$1" "$2" | field_of id
}

start_pipeline() {
  curl -sf -X POST "${API}/v0/pipelines/$1/start" \
    -H "Authorization: Bearer $2" -H 'content-type: application/json' -d '{}' >/dev/null
}

# Deletes a pipeline and waits until its pod is gone, which is when the quota it
# held is back. A later step that needs room in the tenant depends on that, so
# the wait is part of the helper: the manager answers the deletion before the
# StatefulSet controller has finished tearing the pod down.
delete_pipeline() {
  local name="$1" key="$2" id status
  id="$(pipeline_id "${name}" "${key}")" || id=""
  curl -s -o /dev/null -X POST "${API}/v0/pipelines/${name}/stop?force=true" \
    -H "Authorization: Bearer ${key}" || true
  for _ in $(seq 1 30); do
    status="$(field_of deployment_status <<<"$(body_of "/v0/pipelines/${name}" "${key}")")"
    [ "${status}" = "Stopped" ] && break
    sleep 2
  done
  # The manager refuses to delete a pipeline whose storage is not cleared.
  curl -s -o /dev/null -X POST "${API}/v0/pipelines/${name}/clear" \
    -H "Authorization: Bearer ${key}" || true
  for _ in $(seq 1 30); do
    [ "$(status_of DELETE "/v0/pipelines/${name}" "${key}")" = "200" ] && break
    sleep 2
  done
  [ -n "${id}" ] || return 0
  for _ in $(seq 1 30); do
    kubectl --namespace "${NS_A}" get pod "pipeline-${id}-0" >/dev/null 2>&1 \
      || kubectl --namespace "${NS_B}" get pod "pipeline-${id}-0" >/dev/null 2>&1 \
      || return 0
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# Phase 1: the release, without any tenant mapping
# ---------------------------------------------------------------------------
# The quota map is keyed by tenant UUID, and a tenant has no UUID until it
# exists. Auth is on from the start because the tenants are created through the
# API and that needs a principal.
export NAMESPACE RELEASE
# shellcheck source=scripts/keycloak-fixture.sh
source scripts/keycloak-fixture.sh
KEYCLOAK_TAG="${KEYCLOAK_TAG:-26.0}"

say "P1-033: two tenants, five boundaries"
info "workdir ${WORKDIR}"

step "the identity provider is up"
keycloak_ensure "${WORKDIR}" "${KEYCLOAK_PORT}" \
  || fail "Keycloak did not come up; see ${WORKDIR}"
info "issuer ${ISSUER}"

step "the release comes up with authentication on and no tenant mapping"
install_release phase1 || fail "the release did not become ready"
port_forward_manager || fail "the manager did not answer on ${API}"
info "manager ready"

step "an owner signs in"
OWNER_TOKEN="$(keycloak_access_token "${WORKDIR}" "${KEYCLOAK_PORT}")" \
  || fail "the identity provider did not issue a token for ${USER_NAME}"
session="$(curl -sf -H "Authorization: Bearer ${OWNER_TOKEN}" "${API}/v0/config/session")" \
  || fail "the manager rejected the owner's token"
[ "$(printf '%s' "${session}" | field_of role)" = "owner" ] \
  || fail "the owner's session does not carry the owner role: ${session}"
info "the owner acts as owner"

step "two tenants exist"
for tenant in "${TENANT_A}" "${TENANT_B}"; do
  code="$(curl -s -o "${WORKDIR}/tenant-${tenant}.json" -w '%{http_code}' \
    -X POST "${API}/v0/tenants" \
    -H "Authorization: Bearer ${OWNER_TOKEN}" -H 'content-type: application/json' \
    --data "{\"name\":\"${tenant}\"}")"
  # 409 is a second run of this suite reusing the tenants it created before.
  case "${code}" in
    200 | 201 | 409) ;;
    *) fail "creating tenant ${tenant} answered ${code}: $(cat "${WORKDIR}/tenant-${tenant}.json")" ;;
  esac
done
TENANTS="$(curl -sf -H "Authorization: Bearer ${OWNER_TOKEN}" "${API}/v0/tenants")" \
  || fail "could not list the tenants"
TENANT_A_ID="$(tenant_id_of "${TENANT_A}")"
TENANT_B_ID="$(tenant_id_of "${TENANT_B}")"
[ -n "${TENANT_A_ID}" ] || fail "tenant ${TENANT_A} has no id; the quota map cannot be keyed"
[ -n "${TENANT_B_ID}" ] || fail "tenant ${TENANT_B} has no id; the quota map cannot be keyed"
[ "${TENANT_A_ID}" != "${TENANT_B_ID}" ] || fail "both tenants resolved to one id"
info "${TENANT_A} = ${TENANT_A_ID}"
info "${TENANT_B} = ${TENANT_B_ID}"

# ---------------------------------------------------------------------------
# Phase 2: give each tenant a namespace, a quota and a Secret allowlist
# ---------------------------------------------------------------------------
step "the release is upgraded with a namespace and a quota per tenant"
# The commas inside the quota are escaped because Helm treats an unescaped one
# as the separator between two `--set` assignments.
install_release phase2 \
  --set controlplane.kubernetesRunner.tenantNamespaceAutomation=true \
  --set-string "controlplane.kubernetesRunner.tenantQuotas.${TENANT_A_ID}=${NS_A}: ${QUOTA//,/\\,}" \
  --set-string "controlplane.kubernetesRunner.tenantQuotas.${TENANT_B_ID}=${NS_B}: ${QUOTA//,/\\,}" \
  --set controlplane.kubernetesRunner.connectorKubernetesSecrets.enableAllowlist=true \
  --set "controlplane.kubernetesRunner.connectorKubernetesSecrets.allowlist={${SECRET_ONLY_IN_B},${SECRET_IN_A}}" \
  || fail "the release did not become ready with the tenant mapping"
port_forward_manager || fail "the manager did not answer after the upgrade"

step "each tenant got its own namespace, quota and limit range"
for ns in "${NS_A}" "${NS_B}"; do
  for _ in $(seq 1 60); do
    kubectl get namespace "${ns}" >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl get namespace "${ns}" >/dev/null 2>&1 \
    || fail "the manager did not create ${ns}"
  label="$(kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.feldera\.com/managed-by}')"
  [ "${label}" = "feldera-manager" ] \
    || fail "${ns} is not labelled as platform-managed (managed-by='${label}')"
  kubectl get resourcequota --namespace "${ns}" -o name | grep -q . \
    || fail "${ns} has no ResourceQuota"
  # The LimitRange is what carries the default CPU request, so it has to exist:
  # without it the quota's `requests.cpu` entry would refuse every pipeline that
  # does not ask for CPU, which is all of them but one.
  kubectl get limitrange --namespace "${ns}" -o name | grep -q . \
    || fail "${ns} has no LimitRange, so its quota refuses pipelines that ask for no CPU"
  # A namespace that exists but has no binding is the state P1-022 called out:
  # the manager creates the namespace and then cannot create a pipeline in it.
  kubectl get rolebinding --namespace "${ns}" feldera-pipeline-runner -o name >/dev/null 2>&1 \
    || fail "${ns} has no runner RoleBinding, so no pipeline can be provisioned there"
  info "${ns}: namespace, quota and runner binding"
done

# A run that died before its cleanup can leave pipeline objects behind. The
# database that owned them is gone, so nothing will ever delete them, and their
# pods keep holding the quota this suite is about to spend -- which the quota
# step would then read as "somebody else is using A's namespace" and fail on the
# first pipeline it creates. Clearing the pipelines is not part of what is being
# tested here; the namespace, the quota and the binding stay.
for ns in "${NS_A}" "${NS_B}"; do
  left="$(kubectl get statefulset,pod --namespace "${ns}" -o name 2>/dev/null | wc -l)"
  if [ "${left}" -gt 0 ]; then
    info "${ns}: clearing ${left} object(s) a previous run left behind"
    kubectl delete statefulset,pod,service,secret,persistentvolumeclaim --namespace "${ns}" \
      --all --ignore-not-found --wait=false >/dev/null 2>&1
    for _ in $(seq 1 60); do
      [ "$(kubectl get pod --namespace "${ns}" -o name 2>/dev/null | wc -l)" -eq 0 ] && break
      sleep 2
    done
  fi
done

step "each tenant holds a write key of its own"
# An owner acts in whichever tenant the header names, so the owner mints the
# keys. These keys are the only credentials every step below attacks with.
mint_key() {
  curl -sf -X POST "${API}/v0/api_keys" \
    -H "Authorization: Bearer ${OWNER_TOKEN}" \
    -H "Feldera-Tenant: $1" \
    -H 'content-type: application/json' \
    --data "{\"name\":\"$2\",\"role\":\"write\"}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["api_key"] if d.get("api_key") else sys.exit("the mint returned no api_key"))'
}
SUFFIX="$$-$(date +%s)"
KEY_NAME_A="iso-a-${SUFFIX}"
KEY_NAME_B="iso-b-${SUFFIX}"
KEY_A="$(mint_key "${TENANT_A_ID}" "${KEY_NAME_A}")" || fail "could not mint a key in ${TENANT_A}"
KEY_B="$(mint_key "${TENANT_B_ID}" "${KEY_NAME_B}")" || fail "could not mint a key in ${TENANT_B}"
[ -n "${KEY_A}" ] && [ -n "${KEY_B}" ] && [ "${KEY_A}" != "${KEY_B}" ] \
  || fail "the two keys are not distinct"
info "both keys minted"

step "each key resolves to its own tenant and to no other"
# A key that resolved to the wrong tenant would make every refusal below pass for
# the wrong reason, so the scope is proven before anything is created.
#
# The key is `apikey:<secret>`: it carries a colon of its own, so packing one into
# a `side:key:name` field splits the secret and the request then fails as
# unauthenticated, which looks like a platform refusal. Each side is passed as an
# argument instead, and an empty key is a bug in this script rather than a result.
check_key_scope() {
  local side="$1" key="$2" own="$3" listed
  [ -n "${key}" ] || fail "the ${side} key is empty; minting it failed silently"
  listed="$(body_of /v0/api_keys "${key}")" || fail "the ${side} key cannot list its own keys"
  case "${listed}" in
    *"${own}"*) ;;
    *) fail "the ${side} key does not list the key it was minted as: ${listed}" ;;
  esac
  case "${listed}" in
    *"iso-a-"*"iso-b-"* | *"iso-b-"*"iso-a-"*) fail "the ${side} key lists both tenants' keys: ${listed}" ;;
  esac
}
check_key_scope A "${KEY_A}" "${KEY_NAME_A}"
check_key_scope B "${KEY_B}" "${KEY_NAME_B}"
info "each key sees its own tenant's keys and only them"

# ---------------------------------------------------------------------------
# Boundary 1: network
# ---------------------------------------------------------------------------
step "a pipeline per tenant, both running"
PIPELINE_A="e2e-iso-a-${SUFFIX}"
PIPELINE_B="e2e-iso-b-${SUFFIX}"
# A's pipeline asks for the whole CPU quota, which is what makes A full for the
# quota step below. Everything else in this suite asks for no CPU request, so it
# is invisible to that quota.
create_pipeline "${PIPELINE_A}" "${KEY_A}" "" "${NORMAL_MEMORY_MB}" "${FULL_CPU_CORES}"
create_pipeline "${PIPELINE_B}" "${KEY_B}"
start_pipeline "${PIPELINE_A}" "${KEY_A}" || fail "starting ${PIPELINE_A} was refused"
start_pipeline "${PIPELINE_B}" "${KEY_B}" || fail "starting ${PIPELINE_B} was refused"

# The key is `apikey:<secret>` and therefore carries a colon, so the tuple is
# passed as arguments rather than packed into a `key:name:ns` field: splitting on
# `:` cuts the secret down to the literal `apikey`, and the resulting request is
# rejected as unauthenticated instead of reporting the pipeline's state.
await_tenant_pipeline() {
  local key="$1" name="$2" ns="$3" error id
  error="$(wait_running "${name}" "${key}")" || fail "${name} did not start: ${error}"
  id="$(pipeline_id "${name}" "${key}")"
  [ -n "${id}" ] || fail "${name} reports no id"
  kubectl --namespace "${ns}" get pod "pipeline-${id}-0" -o name >/dev/null 2>&1 \
    || fail "${name} is Running but its pod is not in ${ns}"
  info "${name} runs in ${ns} as pipeline-${id}-0"
}
await_tenant_pipeline "${KEY_A}" "${PIPELINE_A}" "${NS_A}"
await_tenant_pipeline "${KEY_B}" "${PIPELINE_B}" "${NS_B}"
PIPELINE_A_ID="$(pipeline_id "${PIPELINE_A}" "${KEY_A}")"
PIPELINE_B_ID="$(pipeline_id "${PIPELINE_B}" "${KEY_B}")"
B_URI="pipeline-${PIPELINE_B_ID}.${NS_B}.svc.cluster.local:8080"

step "A's pipeline cannot reach B's pipeline"
# The probe judges reachability, not the answer: `/stats` on a pipeline that is
# running answers 200, and a packet the policy drops never leaves curl, which
# reports `000`. Asking for exit status would conflate the two -- a 404 or a 401
# also exits non-zero, and either of those means the request *arrived*.
# `--max-time` bounds the check: a dropped packet looks like a hang.
probe_of() {
  local namespace="$1" pod="$2" stderr_file="$3"
  kubectl --namespace "${namespace}" exec "${pod}" -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${B_URI}/stats" \
    2>"${stderr_file}" || true
}
probe="$(probe_of "${NS_A}" "pipeline-${PIPELINE_A_ID}-0" "${WORKDIR}/cross-tenant.txt")"
case "${probe}" in
  000) ;;
  "") fail "the probe from A's pipeline printed nothing: kubectl exec failed" ;;
  *) fail "A's pipeline reached B's pipeline at ${B_URI}: the probe answered '${probe}'" ;;
esac
info "A's pipeline cannot reach ${B_URI}"
# The refusal has to be the policy's, not a missing Service or a bad name: the
# positive control below separates the two, and this keeps a typo from passing.
if grep -qi "could not resolve\|Name or service not known" "${WORKDIR}/cross-tenant.txt"; then
  fail "the cross-tenant attempt failed on name resolution rather than on the policy: $(cat "${WORKDIR}/cross-tenant.txt")"
fi

step "the manager can still reach B's pipeline"
# Without this the step above proves only that the pod cannot reach anything.
manager_pod="$(kubectl --namespace "${NAMESPACE}" get pod \
  -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].metadata.name}')"
[ -n "${manager_pod}" ] || fail "could not find the manager pod for the positive control"
manager_probe="$(probe_of "${NAMESPACE}" "${manager_pod}" "${WORKDIR}/manager-probe.txt")"
[ "${manager_probe}" = "200" ] \
  || fail "the manager cannot reach B's pipeline either (probe answered '${manager_probe}'), so the refusal above proves nothing"
info "the manager reaches ${B_URI}, so the policy is what refuses A"

# ---------------------------------------------------------------------------
# Boundary 2: quota
# ---------------------------------------------------------------------------
step "A's namespace is full; B's is not"
# `used` is read instead of assumed: if A's own pipeline had not spent the quota,
# the request below would be accepted and this step would report a pass for a
# quota that does nothing.
quota_used() {
  kubectl get resourcequota --namespace "$1" -o json | python3 -c '
import json, sys
quotas = json.load(sys.stdin)["items"]
for quota in quotas:
    used = (quota.get("status") or {}).get("used") or {}
    if "requests.cpu" in used:
        print(used["requests.cpu"])
        raise SystemExit
print("")
'
}
used_a="$(quota_used "${NS_A}")"
[ -n "${used_a}" ] || fail "A's quota records no CPU request, so the quota is not counting anything"
# A full core in use out of one allowed.
case "${used_a}" in
  1 | 1000m | 1.0) ;;
  *) fail "A's quota has ${used_a} of 1 CPU used, so it is not full: the refusal below would prove nothing" ;;
esac
info "A has ${used_a} of 1 CPU requested"
info "B has $(quota_used "${NS_B}" || echo nothing) of 1 CPU requested"

step "the same request is refused in A and accepted in B"
PIPELINE_QUOTA_A="e2e-iso-quota-a-${SUFFIX}"
PIPELINE_QUOTA_B="e2e-iso-quota-b-${SUFFIX}"
create_pipeline "${PIPELINE_QUOTA_A}" "${KEY_A}" "" "${NORMAL_MEMORY_MB}" "${HALF_CPU_CORES}"
create_pipeline "${PIPELINE_QUOTA_B}" "${KEY_B}" "" "${NORMAL_MEMORY_MB}" "${HALF_CPU_CORES}"
start_pipeline "${PIPELINE_QUOTA_A}" "${KEY_A}" \
  || fail "starting A's half-core pipeline was refused outright rather than at provisioning"
start_pipeline "${PIPELINE_QUOTA_B}" "${KEY_B}" \
  || fail "starting B's half-core pipeline was refused outright"

expect_refused "${PIPELINE_QUOTA_A}" "${KEY_A}" "A's namespace is full"
case "${REFUSAL}" in
  *"no room for this pipeline"*) ;;
  *) fail "the refusal is not the actionable quota message: ${REFUSAL}" ;;
esac
info "A refused it in state '${REFUSAL_STATE}': $(printf '%s' "${REFUSAL}" | head -c 160)"

# The same request in B must run, so the refusal above was A's namespace being
# full and not the shape of the request.
error="$(wait_running "${PIPELINE_QUOTA_B}" "${KEY_B}")" \
  || fail "the request A was refused ran nowhere: B refused it too (${error})"
info "B ran it"

# A stays full until this point, which is what makes the refusal above A's
# namespace rather than the request. The steps after this one need room in A
# again, so the two pipelines that filled it go; B's stay, because the step
# further down reaches for B's pipeline.
delete_pipeline "${PIPELINE_QUOTA_A}" "${KEY_A}"
delete_pipeline "${PIPELINE_A}" "${KEY_A}"
info "A's pipelines are gone, so A has room again"

# ---------------------------------------------------------------------------
# Boundary 3: secrets
# ---------------------------------------------------------------------------
step "a Secret that exists only in B's namespace"
kubectl --namespace "${NS_B}" create secret generic "${SECRET_ONLY_IN_B}" \
  --from-literal=password="${SECRET_VALUE_B}" >/dev/null \
  || fail "could not create the Secret in ${NS_B}"
kubectl --namespace "${NS_A}" create secret generic "${SECRET_IN_A}" \
  --from-literal=password="${SECRET_VALUE_A}" >/dev/null \
  || fail "could not create the Secret in ${NS_A}"
info "${SECRET_ONLY_IN_B} is in ${NS_B}; ${SECRET_IN_A} is in ${NS_A}"

# The connector travels inside `program_code`: the deployment configuration is
# built from the compiled program's schema and drops a `runtime_config.inputs`
# block, which would leave the allowlist nothing to inspect. Nothing connects to
# Kafka, so no broker is needed — the Secret is resolved as the pod starts.
secret_pipeline() {
  local name="$1" key="$2" secret="$3"
  python3 - "$name" "$secret" >"${WORKDIR}/secret-${name}.json" <<'PY'
import json, sys
name, secret = sys.argv[1], sys.argv[2]
connector = [{
    "transport": {"name": "kafka_input", "config": {
        "topic": "orders",
        "bootstrap.servers": "127.0.0.1:19092",
        "security.protocol": "SASL_PLAINTEXT",
        "sasl.mechanism": "PLAIN",
        "sasl.username": "alice",
        "sasl.password": "${secret:kubernetes:%s/password}" % secret,
    }},
    "format": {"name": "json", "config": {"update_format": "raw", "array": False}},
}]
program = (
    "CREATE TABLE orders (id BIGINT NOT NULL) WITH ('materialized' = 'true', "
    "'connectors' = '%s');" % json.dumps(connector).replace("'", "''")
)
json.dump({
    "name": name,
    "program_code": program,
    "program_config": {"profile": "unoptimized"},
    "runtime_config": {"workers": 1, "resources": {
        "cpu_cores_min": 0, "memory_mb_min": 256, "memory_mb_max": 512}},
}, sys.stdout)
PY
  local code
  code="$(curl -s -o "${WORKDIR}/secret-${name}.out" -w '%{http_code}' \
    -X POST "${API}/v0/pipelines" \
    -H "Authorization: Bearer ${key}" -H 'content-type: application/json' \
    --data @"${WORKDIR}/secret-${name}.json")"
  [ "${code}" = "200" ] || [ "${code}" = "201" ] \
    || fail "creating ${name} answered ${code}: $(cat "${WORKDIR}/secret-${name}.out")"
  PIPELINES+=("${name}")
}

PIPELINE_SELF="e2e-iso-self-${SUFFIX}"
PIPELINE_THEFT="e2e-iso-theft-${SUFFIX}"
PIPELINE_B_SECRET="e2e-iso-bsecret-${SUFFIX}"
secret_pipeline "${PIPELINE_SELF}" "${KEY_A}" "${SECRET_IN_A}"
secret_pipeline "${PIPELINE_THEFT}" "${KEY_A}" "${SECRET_ONLY_IN_B}"
secret_pipeline "${PIPELINE_B_SECRET}" "${KEY_B}" "${SECRET_ONLY_IN_B}"

step "A mounts the Secret it owns"
start_pipeline "${PIPELINE_SELF}" "${KEY_A}" || fail "starting ${PIPELINE_SELF} was refused"
value="$(secret_value_in_pod "${NS_A}" "${PIPELINE_SELF}" "${KEY_A}" "${SECRET_IN_A}")" \
  || fail "A could not mount its own Secret, so the refusal below would prove nothing: ${value}"
[ "${value}" = "${SECRET_VALUE_A}" ] \
  || fail "A's pod carries '${value}' for ${SECRET_IN_A}, not the value the Secret holds"
info "A mounts ${SECRET_IN_A} from its own namespace"

step "A cannot mount B's Secret"
start_pipeline "${PIPELINE_THEFT}" "${KEY_A}" \
  || fail "starting the stealing pipeline was refused outright"
# Waiting for the provisioner to give up would say only that the pipeline did not
# start, and it would spend the whole timeout saying it. The reason is the
# property: the kubelet resolves the reference against A's own namespace, does
# not find the Secret there, and never starts the container -- so the pod sits
# without a container status and the message lives in its events. B's Secret is
# still perfectly usable in B (the next step proves that), so nothing is broken
# about the reference: it is looked up in the wrong tenant.
THEFT_ID="$(pipeline_id "${PIPELINE_THEFT}" "${KEY_A}" || true)"
[ -n "${THEFT_ID}" ] || fail "the stealing pipeline has no id, so nothing can be checked"
gap=""
for _ in $(seq 1 120); do
  gap="$(kubectl --namespace "${NS_A}" get events \
    --field-selector "involvedObject.name=pipeline-${THEFT_ID}-0" \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null || true)"
  case "${gap}" in
    *"${SECRET_ONLY_IN_B}"*) break ;;
  esac
  state="$(body_of "/v0/pipelines/${PIPELINE_THEFT}" "${KEY_A}" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("deployment_status") or "")' 2>/dev/null)"
  [ "${state}" = "Running" ] \
    && fail "A's pipeline is Running with a Secret it found in ${NS_B}"
  sleep 2
done
case "${gap}" in
  *"${SECRET_ONLY_IN_B}"*) ;;
  *) fail "nothing in ${NS_A} reports ${SECRET_ONLY_IN_B} as missing for pod pipeline-${THEFT_ID}-0 (events: '${gap}')" ;;
esac
# Only the lines that name the Secret say anything; the rest of the pod's events
# are the schedule and the pull, which look identical for any pipeline.
info "the kubelet refuses to start it: $(printf '%s\n' "${gap}" \
  | grep -F -- "${SECRET_ONLY_IN_B}" | head -1 | cut -c1-160)"
# Nothing may be left in B's namespace under A's pipeline id either: a pod there
# would be the escalation regardless of what the status says.
THEFT_ID="$(pipeline_id "${PIPELINE_THEFT}" "${KEY_A}" || true)"
if [ -n "${THEFT_ID}" ] \
  && kubectl --namespace "${NS_B}" get pod "pipeline-${THEFT_ID}-0" -o name >/dev/null 2>&1; then
  fail "A's pipeline created a pod in ${NS_B}"
fi
info "nothing of A's appeared in ${NS_B}"

step "B mounts that Secret, so it is usable at all"
start_pipeline "${PIPELINE_B_SECRET}" "${KEY_B}" \
  || fail "starting B's secret pipeline was refused outright"
value="$(secret_value_in_pod "${NS_B}" "${PIPELINE_B_SECRET}" "${KEY_B}" "${SECRET_ONLY_IN_B}")" \
  || fail "B cannot mount its own Secret, so this step is not about isolation: ${value}"
[ "${value}" = "${SECRET_VALUE_B}" ] \
  || fail "B's pod carries '${value}' for ${SECRET_ONLY_IN_B}, not the value the Secret holds"
info "B mounts ${SECRET_ONLY_IN_B}"

# ---------------------------------------------------------------------------
# Boundary 4: authorization
# ---------------------------------------------------------------------------
step "A's key cannot reach B's pipeline"
# The row filter hides another tenant's pipeline before any role check runs, so
# the answer is 404. Pinning the exact code is the point: a later change to 403,
# or to 500, would confirm the pipeline exists and has to be noticed here.
code="$(status_of GET "/v0/pipelines/${PIPELINE_B}" "${KEY_A}")"
body="$(body_of "/v0/pipelines/${PIPELINE_B}" "${KEY_A}")"
[ "${code}" = "404" ] \
  || fail "reading B's pipeline answered ${code}, not 404: ${body}"
# The answer necessarily echoes the name the caller asked for -- the caller chose
# it, so repeating it tells them nothing. What must not leak is anything else:
# not B's pipeline id, not its status, not the fact that it exists. So the answer
# for B's pipeline is compared with the answer for a name that never existed
# anywhere. Only the name may differ; if anything else does, A has learned
# something about B's pipeline.
missing="e2e-iso-never-existed-${SUFFIX}"
code_missing="$(status_of GET "/v0/pipelines/${missing}" "${KEY_A}")"
body_missing="$(body_of "/v0/pipelines/${missing}" "${KEY_A}")"
[ "${code_missing}" = "404" ] \
  || fail "reading a name that does not exist answered ${code_missing}, not 404, so the comparison below means nothing"
[ "${body//${PIPELINE_B}/${missing}}" = "${body_missing}" ] \
  || fail "B's pipeline answers differently from a name that never existed, so the answer tells A that it exists: ${body} vs ${body_missing}"
case "${body}" in
  *"${PIPELINE_B_ID}"*) fail "the 404 body carries B's pipeline id, which A must not learn: ${body}" ;;
esac
info "GET B's pipeline -> 404, indistinguishable from a name that never existed"

for method in "POST /v0/pipelines/${PIPELINE_B}/start" "DELETE /v0/pipelines/${PIPELINE_B}"; do
  read -r verb path <<<"${method}"
  body=""
  [ "${verb}" = "POST" ] && body='{}'
  code="$(status_of "${verb}" "${path}" "${KEY_A}" "${body}")"
  case "${code}" in
    403 | 404) ;;
    *) fail "${verb} ${path} answered ${code}, not 403 or 404" ;;
  esac
  info "${verb} ${path} -> ${code}"
done

# A refusal that deleted the pipeline would be worse than one that admitted it.
code="$(status_of GET "/v0/pipelines/${PIPELINE_B}" "${KEY_B}")"
[ "${code}" = "200" ] || fail "B's pipeline is gone after A attacked it (${code})"
info "B's pipeline survives"

step "A's key cannot reach B's keys, members or tenants"
theirs="$(body_of /v0/api_keys "${KEY_B}")" || fail "B's key cannot list its own keys"
case "${theirs}" in
  *"${KEY_NAME_B}"*) ;;
  *) fail "B's key list does not contain B's own key: ${theirs}" ;;
esac
mine="$(body_of /v0/api_keys "${KEY_A}")"
case "${mine}" in
  *"${KEY_NAME_B}"*) fail "A's key list contains B's key '${KEY_NAME_B}'" ;;
esac
case "${mine}" in
  *"${KEY_NAME_A}"*) ;;
  *) fail "A's key list does not contain its own key: ${mine}" ;;
esac
info "A's key list contains A's key and not B's"

code="$(status_of GET "/v0/api_keys/${KEY_NAME_B}" "${KEY_A}")"
case "${code}" in
  403 | 404) ;;
  *) fail "reading B's key answered ${code}, not 403 or 404" ;;
esac
info "GET B's key -> ${code}"

# The header is how an owner moves between tenants; for a tenant key it must be
# refused, never silently ignored, because an ignored header would let A act in A
# while believing it acted in B.
code="$(curl -s -o /dev/null -w '%{http_code}' "${API}/v0/api_keys" \
  -H "Authorization: Bearer ${KEY_A}" -H "Feldera-Tenant: ${TENANT_B_ID}")"
[ "${code}" = "403" ] \
  || fail "A's key naming tenant B answered ${code}, not 403"
info "A's key with Feldera-Tenant: <B> -> 403"

code="$(curl -s -o /dev/null -w '%{http_code}' "${API}/v0/tenant/users" \
  -H "Authorization: Bearer ${KEY_A}" -H "Feldera-Tenant: ${TENANT_B_ID}")"
case "${code}" in
  403 | 404) ;;
  *) fail "A's key listing B's members answered ${code}, not 403 or 404" ;;
esac
info "A's key listing B's members -> ${code}"

code="$(status_of POST /v0/tenants "${KEY_A}" "{\"name\":\"iso-escape-${SUFFIX}\"}")"
[ "${code}" = "403" ] \
  || fail "A's key creating a tenant answered ${code}, not 403; tenant management is owner-only"
info "A's key creating a tenant -> 403"

# ---------------------------------------------------------------------------
# Boundary 5: the namespace escape P1-033 found
# ---------------------------------------------------------------------------
step "A cannot place a pipeline inside B's namespace"
# Before this work order the runner honoured the name as given, and the pod then
# mounted whatever Secret of that name existed in B's namespace while running a
# connector configuration A wrote.
PIPELINE_ESCAPE="e2e-iso-escape-${SUFFIX}"
create_pipeline "${PIPELINE_ESCAPE}" "${KEY_A}" "${NS_B}"
start_pipeline "${PIPELINE_ESCAPE}" "${KEY_A}" \
  || fail "starting the escaping pipeline was refused outright rather than at provisioning"

expect_refused "${PIPELINE_ESCAPE}" "${KEY_A}" "a pipeline naming ${NS_B}"
case "${REFUSAL}" in
  *"${NS_B}"*) ;;
  *) fail "the refusal does not name the namespace that was asked for: ${REFUSAL}" ;;
esac
case "${REFUSAL}" in
  *"${NS_A}"*) ;;
  *) fail "the refusal does not name the namespace the tenant is provisioned in: ${REFUSAL}" ;;
esac
info "the escape was refused, naming both namespaces"

ESCAPE_ID="$(pipeline_id "${PIPELINE_ESCAPE}" "${KEY_A}" || true)"
if [ -n "${ESCAPE_ID}" ]; then
  for object in "pod/pipeline-${ESCAPE_ID}-0" "statefulset/pipeline-${ESCAPE_ID}" \
    "service/pipeline-${ESCAPE_ID}" "secret/pipeline-${ESCAPE_ID}-config"; do
    if kubectl --namespace "${NS_B}" get "${object}" >/dev/null 2>&1; then
      fail "A's refused pipeline left ${object} in ${NS_B}"
    fi
  done
fi
info "nothing was created in ${NS_B}"

say "PASS: two tenants, five boundaries, in $(elapsed)"
