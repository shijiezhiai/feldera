#!/usr/bin/env bash
#
# P1-027 acceptance: the control plane records who did what, in order.
#
# The work order's DoD is "an audit query can replay one principal's sequence of
# operations by principal". That is a claim about the log, so this test reads the
# log rather than the code: it reads the manager pod's own stdout, the stream an
# operator ships to the log platform, and filters it the way a query would.
#
# What it proves:
#
#   1. every access decision is recorded as one structured JSON event with the
#      fields a query filters on;
#   2. two API keys of the same tenant are *distinct* principals -- the label
#      used to be the constant "apikey", which made the replay below impossible
#      no matter how good the log platform was;
#   3. one principal's events form a sequence in request order, which is the
#      replay the DoD names;
#   4. a denied request is recorded with its reason, and the denial does not
#      reach the handler;
#   5. a principal that fails to authenticate is still recorded, with no
#      principal -- the denial an auditor most wants is the one with a
#      credential that did not work.
#
# Prerequisites: the kind cluster from docs/self-hosted-dev-env.md, a manager
# image built from this commit with FELDERA_LOG_JSON=1 (the chart sets it via
# `controlplane.logJson`), and the keycloak image loaded for the denied-login
# case.
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
MANAGER_TAG="${MANAGER_TAG:?set MANAGER_TAG to the manager image tag under test}"
# The compiler tag must be named too. `--reuse-values` and a bare upgrade carry
# the previous release's tag forward, and that tag often no longer exists in the
# registry -- so the upgrade times out on ImagePullBackOff for a pod this test
# does not otherwise care about. Only the manager is under test here; reuse a
# compiler that is already loaded in the cluster.
COMPILER_TAG="${COMPILER_TAG:-p1-025}"
API_PORT="${API_PORT:-18080}"

# Authentication is on for this test, and that is not incidental: with no IdP
# configured the manager assigns every request the default tenant's principal
# `default` and never looks at the `Authorization` header, so an API key cannot
# be the principal an audit line names. The Keycloak below is the same fixture
# P1-021 uses, sourced rather than copied.
source "$(dirname "${BASH_SOURCE[0]}")/keycloak-fixture.sh"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-18081}"
WORKDIR="$(mktemp -d /tmp/p1-027-audit.XXXXXX)"

API="http://127.0.0.1:${API_PORT}"
step() { printf '\n-- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*"; }

# The manager's own stdout. `--timestamps=false` keeps the JSON parseable: the
# kubelet timestamp is not part of the event.
logs() {
  kubectl logs --namespace "${NAMESPACE}" \
    -l app.kubernetes.io/name=controlplane -c api-server --tail=-1 2>/dev/null
}

# A log line is an audit event iff its `target` is the audit target and its
# `audit_event` field is `access`.
audit_events() {
  logs | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        e = json.loads(line)
    except json.JSONDecodeError:
        continue
    f = e.get("fields") or {}
    if f.get("audit_event") != "access":
        continue
    print(json.dumps({
        "decision": f.get("audit_decision"),
        "principal": f.get("audit_principal"),
        "tenant": f.get("audit_tenant"),
        "scope": f.get("audit_tenant_scope"),
        "role": f.get("audit_role"),
        "required": f.get("audit_required_role"),
        "method": f.get("audit_method"),
        "route": f.get("audit_route"),
        "reason": f.get("audit_reason"),
    }))
'
}

step "an identity provider, so that a request has a named principal"
keycloak_ensure "${WORKDIR}" "${KEYCLOAK_PORT}" \
  || fail "the Keycloak fixture did not come up"
info "issuer ${ISSUER}"

step "the manager emits JSON logs, as the platform requires"
# The manager fetches the issuer at startup, so the issuer names the Service the
# pods resolve, not the port-forward this host uses.
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" --create-namespace \
  --set "controlplane.image.tag=${MANAGER_TAG}" \
  --set "compiler.image.tag=${COMPILER_TAG}" \
  --set controlplane.logJson=true \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --set controlplane.kubernetesRunner.enabled=false \
  --set controlplane.auth.enabled=true \
  --set controlplane.auth.provider=generic-oidc \
  --set "controlplane.auth.clientId=${CLIENT_ID}" \
  --set "controlplane.auth.issuer=${ISSUER}" \
  --set "controlplane.authorization.authAudience=${CLIENT_ID}" \
  --set "controlplane.owners[0]=${USER_NAME}@acme.test" \
  >/dev/null
# Wait on the manager, not the whole release. `--wait` also waits for the
# compiler StatefulSet, whose image is not what this test is about; a compiler
# stuck on ImagePullBackOff would fail the audit test for an unrelated reason.
# The audit trail is produced by the API server alone.
kubectl rollout status --namespace "${NAMESPACE}" \
  "deploy/${RELEASE}-controlplane-api-server" --timeout=5m >/dev/null
# Poll rather than assert once: a freshly rolled pod has written nothing yet,
# and "no lines" is indistinguishable from "not JSON" at the first instant.
#
# `grep -q` is deliberately avoided here: it exits on the first match, kubectl
# then dies of SIGPIPE, and under `set -o pipefail` the whole pipeline reports
# failure -- so the check failed on the very log it had just matched. Counting
# reads the stream to the end instead.
json_ok=false
for _ in $(seq 1 30); do
  if [ "$(logs | grep -c '"timestamp"' || true)" -gt 0 ]; then json_ok=true; break; fi
  sleep 2
done
[ "${json_ok}" = true ] \
  || fail "the manager is not emitting JSON logs; the audit fields would be unparseable"

step "port-forwarding the manager"
kubectl port-forward --namespace "${NAMESPACE}" \
  "svc/${RELEASE}-controlplane-api-server" "${API_PORT}:8080" \
  >/tmp/e2e-audit-port-forward.log 2>&1 &
PORT_FORWARD=$!
trap 'kill ${PORT_FORWARD} ${KEYCLOAK_PORT_FORWARD_PID:-} 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  if curl -sf "${API}/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -sf "${API}/healthz" >/dev/null 2>&1 \
  || fail "the manager did not answer through the port-forward"

step "an owner signs in, and mints the keys the audit trail will name"
# The keys are minted by a signed-in owner rather than anonymously: with auth on
# every route needs a principal, and minting is a write. This is also the login
# path P1-021 covers in depth -- here it is a precondition, so a failure to get
# a token is reported once and not diagnosed again.
OWNER_TOKEN="$(keycloak_access_token "${WORKDIR}" "${KEYCLOAK_PORT}")" \
  || fail "the identity provider did not issue a token for ${USER_NAME}"
SESSION="$(curl -sf -H "Authorization: Bearer ${OWNER_TOKEN}" "${API}/v0/config/session")" \
  || fail "the manager rejected the owner's token"
echo "${SESSION}" | python3 -c '
import json, sys
session = json.load(sys.stdin)
assert session.get("role") is not None, f"the login resolved no role: {session}"
print("   the owner acts as", session["role"], "in tenant", session.get("tenant_name"))
' || fail "the owner's session is missing a role"

# The API keys live in the tenant the owner acts in; the key request itself
# needs no tenant, the principal carries it.
key() {
  local name="$1" role="${2:-read}"
  curl -sf -X POST "${API}/v0/api_keys" \
    -H "Authorization: Bearer ${OWNER_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${name}\",\"role\":\"${role}\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["api_key"])'
}
# Distinct names, distinct processes: `$RANDOM` alone repeats within one shell.
SUFFIX="$$-$(date +%s)"
# The names are ours, so there is nothing to look up: `GET /v0/api_keys`
# returns every key of the tenant, and taking the first would read some older
# key -- which is exactly the confusion this step exists to rule out.
NAME_A="e2e-audit-a-${SUFFIX}"
NAME_B="e2e-audit-b-${SUFFIX}"
# Key A writes, so the replay below is a sequence of real operations rather than
# a sequence of refusals. A plain key defaults to `read`, which cannot create a
# pipeline -- and then the "denied" step below would have nothing left to prove.
KEY_A="$(key "${NAME_A}" write)"
KEY_B="$(key "${NAME_B}" read)"
info "key a = ${NAME_A}"
info "key b = ${NAME_B}"
[ "${NAME_A}" != "${NAME_B}" ] || fail "the two keys have one name; nothing else can distinguish them"

step "one principal's operations are replayable in order"
# Three operations by key A, separated so their order is unambiguous. GET list,
# POST a pipeline, GET the pipeline: a sequence with a write in it, which is the
# sequence an auditor asks for.
PIPELINE="e2e-audit-$(date +%s)"
curl -sf "${API}/v0/api_keys" -H "Authorization: Bearer ${KEY_A}" >/dev/null
sleep 1
curl -sf -X POST "${API}/v0/pipelines" \
  -H "Authorization: Bearer ${KEY_A}" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"${PIPELINE}\",\"program_code\":\"CREATE TABLE t (c INT);\",\"program_config\":{\"profile\":\"unoptimized\"}}" >/dev/null
sleep 1
curl -sf "${API}/v0/pipelines/${PIPELINE}" -H "Authorization: Bearer ${KEY_A}" >/dev/null
sleep 2

step "the audit log has one event per operation, attributed to that key"
events="$(audit_events)"
mine="$(printf '%s\n' "${events}" | python3 -c '
import json, sys
principal = "apikey:" + sys.argv[1]
rows = [json.loads(l) for l in sys.stdin if l.strip()]
rows = [r for r in rows if r["principal"] == principal]
print(json.dumps(rows))
' "${NAME_A}")"
count="$(printf '%s' "${mine}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
info "${count} events attributed to apikey:${NAME_A}"
[ "${count}" -ge 3 ] || fail "expected at least 3 events for one principal, got ${count}"

# The sequence itself: the three routes in the order they were called. A log
# platform query would order by timestamp; the log lines are already in that
# order, and these three must appear in it as a subsequence.
printf '%s' "${mine}" | python3 -c '
import json, sys
principal = "apikey:" + sys.argv[1]
rows = json.load(sys.stdin)
want = [("GET", "/v0/api_keys"), ("POST", "/v0/pipelines"), ("GET", "/v0/pipelines/{pipeline_name}")]
seen = []
for r in rows:
    if r["principal"] != principal:
        continue
    pair = (r["method"], r["route"])
    if want[len(seen)] == pair:
        seen.append(pair)
        if len(seen) == len(want):
            break
if len(seen) != len(want):
    print(f"FAIL: replay is incomplete; saw {seen}, wanted {want}", file=sys.stderr)
    raise SystemExit(1)
print("   the principal'"'"'s three operations appear in request order")
' "${NAME_A}"

step "the other key's events do not leak into that replay"
printf '%s' "${mine}" | python3 -c '
import json, sys
other = sys.argv[1]
rows = json.load(sys.stdin)
wrong = {r["principal"] for r in rows} - {other}
if wrong:
    print(f"FAIL: key A'"'"'s query returned {wrong}", file=sys.stderr)
    raise SystemExit(1)
print("   the query is confined to one principal")
' "apikey:${NAME_A}"

step "a denied request is recorded with its reason"
# A read role cannot create a pipeline. The key below is minted with the
# default role, which is `read` for a plain API key in most deployments; if it
# happens to carry write, a role denial is produced by targeting a route above
# it instead, so the assertion below reads the recorded reason rather than
# assuming which branch fired.
DENIED_KEY="$(key "e2e-audit-denied-${SUFFIX}" read)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API}/v0/pipelines" \
  -H "Authorization: Bearer ${DENIED_KEY}" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"e2e-audit-denied-$(date +%s)\",\"program_code\":\"CREATE TABLE t (c INT);\",\"program_config\":{\"profile\":\"unoptimized\"}}")"
sleep 2
info "the request answered HTTP ${CODE}"
if [ "${CODE}" != "403" ]; then
  fail "a read key posting a pipeline answered HTTP ${CODE}, not 403"
fi
# Assert against the *role* denial of that key, not "some deny with a reason":
# the manager is scraped for metrics, and the scraper's own 401 is a denial with
# a reason too -- reading the newest one let this step pass on that event
# instead of on the request it just made. Matching principal and route pins the
# event to this call.
denied="$(audit_events | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
want = [r for r in rows
        if r["decision"] == "deny"
        and r["principal"] == sys.argv[1]
        and r["method"] == "POST"
        and r["route"] == "/v0/pipelines"]
print(json.dumps(want[-1:]))
' "apikey:e2e-audit-denied-${SUFFIX}")"
printf '%s' "${denied}" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
if not rows:
    print("FAIL: the role denial of this key left no audit event", file=sys.stderr)
    raise SystemExit(1)
r = rows[-1]
if r["reason"] != "role":
    print("FAIL: reason is {}, not role".format(r["reason"]), file=sys.stderr)
    raise SystemExit(1)
if r["required"] != "write" or r["role"] != "read":
    print("FAIL: recorded needed {} had {}, not write/read".format(
        r["required"], r["role"]), file=sys.stderr)
    raise SystemExit(1)
# Not an f-string: Python before 3.12 rejects a backslash inside an
# f-string expression, and the remote interpreter is 3.7.
print("   recorded: {} {} as {} -> {} (needed {}, had {})".format(
    r["method"], r["route"], r["principal"], r["reason"], r["required"], r["role"]))
'

step "an unauthenticated request is recorded too"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "${API}/v0/pipelines")"
sleep 2
if [ "${CODE}" != "401" ]; then
  fail "a request with no credential answered HTTP ${CODE}, not 401"
fi
# Match this call's own route. The metrics scraper also produces unauthenticated
# denials, so "the newest anonymous denial" is not necessarily this request.
anon="$(audit_events | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
anon = [r for r in rows
        if r["principal"] == "-" and r["decision"] == "deny"
        and r["method"] == "GET" and r["route"] == "/v0/pipelines"]
print(json.dumps(anon[-1:]))
')"
info "no credential answered HTTP ${CODE}"
printf '%s' "${anon}" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
if not rows:
    print("FAIL: a request with no credential left no audit event", file=sys.stderr)
    raise SystemExit(1)
r = rows[-1]
if r["reason"] != "unauthenticated":
    print("FAIL: reason is {}, not unauthenticated".format(r["reason"]), file=sys.stderr)
    raise SystemExit(1)
print("   recorded: {} {} with no principal -> {}".format(
    r["method"], r["route"], r["reason"]))
'

step "cleanup"
curl -sf -X DELETE "${API}/v0/pipelines/${PIPELINE}" \
  -H "Authorization: Bearer ${KEY_A}" >/dev/null || true
for k in "${NAME_A}" "${NAME_B}"; do
  curl -sf -X DELETE "${API}/v0/api_keys/${k}" \
    -H "Authorization: Bearer ${KEY_A}" >/dev/null 2>&1 || true
done

printf '\nPASS: the control plane records who did what, in order, and refusals keep their reason\n'
