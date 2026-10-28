#!/usr/bin/env bash
#
# P1-021 acceptance: a real OIDC provider in front of the chart.
#
# The chart's auth values are only worth what a token flow proves, so this
# stands up Keycloak in the cluster, points the manager at it through the
# chart, and then walks the flow a browser walks:
#
#   1. `/config/authentication` advertises the configured issuer and client id
#      *before* anyone logs in — the console reads this to build its login
#      request, so a wrong value here breaks every login with no server-side
#      error;
#   2. an authorization-code login with PKCE yields a token the manager
#      accepts (the discovery fetch, JWKS resolution and audience check all
#      have to agree for this to work);
#   3. that token acts as the configured owner (`FELDERA_OWNERS`), so a write
#      that requires `admin` succeeds — a user who merely got in, but with the
#      default role, would fail here;
#   4. a request with no token is refused, and a request with a token signed by
#      someone else is refused: proving the accept path did not simply open up.
#
# Everything runs against the manager's own HTTPS surface if `HTTPS_SECRET` is
# set, because that is what a console served over https requires; without it
# the test uses the port-forward over http, which the manager accepts for an
# operator-configured issuer.
#
# Prerequisites: the kind cluster from docs/self-hosted-dev-env.md, the
# `quay.io/keycloak/keycloak:26.0` image loaded into it, and a manager image
# built from this commit.
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
MANAGER_TAG="${MANAGER_TAG:?set MANAGER_TAG to the manager image tag under test}"
KEYCLOAK_TAG="${KEYCLOAK_TAG:-26.0}"
REALM="${REALM:-feldera}"
CLIENT_ID="${CLIENT_ID:-feldera-console}"
USER_NAME="${USER_NAME:-alice}"
USER_PASSWORD="${USER_PASSWORD:-alice-password}"
# The console's redirect URI. It is registered on the client and requested by
# the login below, exactly as the web console would.
REDIRECT_URI="${REDIRECT_URI:-http://localhost:8080/}"

KEYCLOAK_SA="${RELEASE}-keycloak"
KEYCLOAK_HOST="${KEYCLOAK_SA}.${NAMESPACE}.svc.cluster.local:8080"
ISSUER="http://${KEYCLOAK_HOST}/realms/${REALM}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-18081}"
API_PORT="${API_PORT:-18080}"
WORKDIR="$(mktemp -d /tmp/p1-021-keycloak.XXXXXX)"

step() { printf '\n-- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*"; }

cleanup() {
  local pid
  for pid in ${PORT_FORWARD_PIDS:-}; do kill "${pid}" 2>/dev/null || true; done
  # Leave the Keycloak deployment in place: it holds the realm the next run
  # reuses, and tearing it down would make every run pay its startup again.
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Keycloak
# ---------------------------------------------------------------------------
step "Keycloak ${KEYCLOAK_TAG} serves realm '${REALM}'"

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${KEYCLOAK_SA}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  admin-password: admin-password
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${KEYCLOAK_SA}
  namespace: ${NAMESPACE}
  labels:
    app: ${KEYCLOAK_SA}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${KEYCLOAK_SA}
  template:
    metadata:
      labels:
        app: ${KEYCLOAK_SA}
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:${KEYCLOAK_TAG}
          imagePullPolicy: IfNotPresent
          args: ["start-dev", "--http-port=8080"]
          env:
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              value: admin
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${KEYCLOAK_SA}
                  key: admin-password
            # Every request reaches Keycloak through a Service or a
            # port-forward, so its own notion of its host has to be the one
            # the tokens are issued for.
            - name: KC_HOSTNAME
              value: http://${KEYCLOAK_HOST}
            - name: KC_HOSTNAME_BACKCHANNEL_DYNAMIC
              value: "true"
            - name: KC_HEALTH_ENABLED
              value: "true"
          ports:
            - containerPort: 8080
          readinessProbe:
            # Keycloak 26 exposes health on its management interface (9000),
            # not on the HTTP port; probing 8081 never answers and the pod stays
            # NotReady forever.
            httpGet:
              path: /health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 5
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ${KEYCLOAK_SA}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${KEYCLOAK_SA}
  ports:
    - port: 8080
      targetPort: 8080
EOF

kubectl -n "${NAMESPACE}" rollout status "deploy/${KEYCLOAK_SA}" --timeout=300s >/dev/null \
  || fail "Keycloak did not become ready"

kubectl -n "${NAMESPACE}" port-forward "svc/${KEYCLOAK_SA}" "${KEYCLOAK_PORT}:8080" \
  >"${WORKDIR}/keycloak-port-forward.log" 2>&1 &
PORT_FORWARD_PIDS="$!"
KEYCLOAK_URL="http://127.0.0.1:${KEYCLOAK_PORT}"
for _ in $(seq 1 30); do
  if curl -sf "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -sf "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1 \
  || fail "Keycloak did not answer through the port-forward"
info "reachable at ${KEYCLOAK_URL}"

admin_call() {
  local method="$1" path="$2" token="$3" body="${4:-}"
  if [ -n "${body}" ]; then
    curl -sf -X "${method}" -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" -d "${body}" "${KEYCLOAK_URL}${path}"
  else
    curl -sf -X "${method}" -H "Authorization: Bearer ${token}" \
      "${KEYCLOAK_URL}${path}"
  fi
}

ADMIN_TOKEN="$(curl -sf -X POST \
  -d "client_id=admin-cli" -d "username=admin" -d "password=admin-password" \
  -d "grant_type=password" "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')" \
  || fail "the admin token request failed"

# A realm created by an earlier run already holds the client and user, and
# re-creating them would fail; the state below is asserted, not just created.
if ! admin_call GET "/admin/realms/${REALM}" "${ADMIN_TOKEN}" >/dev/null 2>&1; then
  admin_call POST "/admin/realms" "${ADMIN_TOKEN}" \
    "{\"realm\":\"${REALM}\",\"enabled\":true,\"sslRequired\":\"none\"}" >/dev/null
  info "created realm ${REALM}"
else
  info "reusing realm ${REALM}"
fi

if ! admin_call GET "/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" "${ADMIN_TOKEN}" \
  | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin) else 1)'; then
  admin_call POST "/admin/realms/${REALM}/clients" "${ADMIN_TOKEN}" \
    "{\"clientId\":\"${CLIENT_ID}\",\"publicClient\":true,\"protocol\":\"openid-connect\",
      \"standardFlowEnabled\":true,\"redirectUris\":[\"${REDIRECT_URI}\"],
      \"webOrigins\":[\"+\"],\"attributes\":{\"pkce.code.challenge.method\":\"S256\"}}" >/dev/null
  info "created client ${CLIENT_ID}"
fi

if ! admin_call GET "/admin/realms/${REALM}/users?username=${USER_NAME}" "${ADMIN_TOKEN}" \
  | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin) else 1)'; then
  admin_call POST "/admin/realms/${REALM}/users" "${ADMIN_TOKEN}" \
    "{\"username\":\"${USER_NAME}\",\"enabled\":true,\"email\":\"${USER_NAME}@acme.test\",
      \"emailVerified\":true,\"firstName\":\"Alice\",\"lastName\":\"Test\"}" >/dev/null
  USER_ID="$(admin_call GET "/admin/realms/${REALM}/users?username=${USER_NAME}" "${ADMIN_TOKEN}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
  admin_call PUT "/admin/realms/${REALM}/users/${USER_ID}/reset-password" "${ADMIN_TOKEN}" \
    "{\"type\":\"password\",\"value\":\"${USER_PASSWORD}\",\"temporary\":false}" >/dev/null
  info "created user ${USER_NAME}"
fi

# The access token the manager checks must carry the client id in `aud` (or a
# matching `client_id`). Keycloak's default puts the client name in `azp` and,
# for `aud`, whatever the audience mapper names, so add the mapper explicitly.
CLIENT_UUID="$(admin_call GET "/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" "${ADMIN_TOKEN}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
if ! admin_call GET "/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" "${ADMIN_TOKEN}" \
  | python3 -c 'import json,sys; sys.exit(0 if any(m["name"]=="feldera-audience" for m in json.load(sys.stdin)) else 1)'; then
  admin_call POST "/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" "${ADMIN_TOKEN}" \
    "{\"name\":\"feldera-audience\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",
      \"config\":{\"included.client.audience\":\"${CLIENT_ID}\",\"access.token.claim\":\"true\",
      \"id.token.claim\":\"false\"}}" >/dev/null
  info "added the audience mapper"
fi

# ---------------------------------------------------------------------------
# Manager pointed at it through the chart
# ---------------------------------------------------------------------------
step "the chart configures the manager from auth.* values"

CHART_ARGS=(
  --set controlplane.auth.enabled=true
  --set controlplane.auth.provider=generic-oidc
  --set "controlplane.auth.clientId=${CLIENT_ID}"
  --set "controlplane.auth.issuer=${ISSUER}"
  --set "controlplane.authorization.authAudience=${CLIENT_ID}"
  --set "controlplane.owners[0]=${USER_NAME}@acme.test"
)
if [ -n "${HTTPS_SECRET:-}" ]; then
  CHART_ARGS+=(--set "controlplane.httpsSecretRef=${HTTPS_SECRET}")
  BASE_URL="https://127.0.0.1:${API_PORT}"
  CURL_TLS=(--cacert "${HTTPS_CA_CERT:?set HTTPS_CA_CERT with HTTPS_SECRET}")
else
  BASE_URL="http://127.0.0.1:${API_PORT}"
  CURL_TLS=()
fi

# The manager fetches the issuer at startup, so the Keycloak Service has to be
# reachable from inside the pod: that is why the issuer names the Service DNS
# and not the port-forward the test uses.
#
# The chart owns the manager's environment, so the auth settings arrive through
# a `helm upgrade` rather than `kubectl set env`: setting them outside Helm
# would be reverted by the next chart change and would leave the values.yaml
# path unexercised, which is the thing this test is here to validate.
helm upgrade "${RELEASE}" charts/feldera -n "${NAMESPACE}" --reuse-values "${CHART_ARGS[@]}" >/dev/null
kubectl -n "${NAMESPACE}" rollout status \
  "deploy/${RELEASE}-controlplane-api-server" --timeout=180s >/dev/null \
  || fail "the manager did not become ready with auth enabled (it exits when the issuer is unreachable)"

kubectl -n "${NAMESPACE}" port-forward \
  "deploy/${RELEASE}-controlplane-api-server" "${API_PORT}:8080" \
  >"${WORKDIR}/api-port-forward.log" 2>&1 &
PORT_FORWARD_PIDS="${PORT_FORWARD_PIDS} $!"
for _ in $(seq 1 30); do
  if curl -sfk "${CURL_TLS[@]}" "${BASE_URL}/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -sfk "${CURL_TLS[@]}" "${BASE_URL}/healthz" >/dev/null 2>&1 \
  || fail "the manager did not answer through the port-forward"

# `/config/authentication` is the one unauthenticated route and sits outside
# the `/v0` base path; everything else the console calls is under it.
ADVERTISED="$(curl -sfk "${CURL_TLS[@]}" "${BASE_URL}/config/authentication")" \
  || fail "/config/authentication is not served"
echo "${ADVERTISED}" | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
provider = cfg.get("GenericOidc") or {}
assert provider, f"no generic-oidc provider advertised: {cfg}"
assert provider.get("issuer") == sys.argv[1], provider
assert provider.get("client_id") == sys.argv[2], provider
print("   the console is told to log in to", provider["issuer"], "as", provider["client_id"])
' "${ISSUER}" "${CLIENT_ID}" || fail "the advertised provider does not match the chart values"

step "an authorization-code login with PKCE yields a token the manager accepts"

# The token endpoint lives behind the Service name, which this host cannot
# resolve, so the code exchange goes through the port-forward while the
# browser-visible authorization step goes through the same Keycloak.
AUTH_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/auth"
TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token"

# Keycloak marks its session cookies `Secure`, and curl refuses to keep those
# from an http origin. A browser accepts them on localhost, which is a
# trustworthy origin, and that is exactly the case here; so this script carries
# the cookies itself instead of asking curl's jar to. The alternative — serving
# the test over TLS — would only be testing Keycloak's cookie policy.
cookie_header() {
  python3 - "${1}" <<'PYCOOKIE'
import sys
cookies = []
for line in open(sys.argv[1]):
    if not line.lower().startswith("set-cookie:"):
        continue
    pair = line.split(":", 1)[1].strip().split(";", 1)[0]
    name, _, value = pair.partition("=")
    if name.strip() and value.strip():
        cookies.append(f"{name.strip()}={value.strip()}")
print("; ".join(cookies))
PYCOOKIE
}

# RFC 7636 requires the verifier to be 43 characters or more; a shorter value
# is not a weak verifier so much as a malformed request, and Keycloak rejects
# the exchange with an opaque 400.
CODE_VERIFIER="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
CODE_CHALLENGE="$(printf '%s' "${CODE_VERIFIER}" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=')"

LOGIN_PAGE="$(
  curl -sf -D "${WORKDIR}/login-headers.txt" -o "${WORKDIR}/login-page.html" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "response_type=code" \
    --data-urlencode "scope=openid profile email" \
    --data-urlencode "redirect_uri=${REDIRECT_URI}" \
    --data-urlencode "code_challenge_method=S256" \
    --data-urlencode "code_challenge=${CODE_CHALLENGE}" \
    -G "${AUTH_ENDPOINT}" && cat "${WORKDIR}/login-page.html"
)" || fail "the authorization endpoint did not answer"
LOGIN_COOKIES="$(cookie_header "${WORKDIR}/login-headers.txt")"
LOGIN_ACTION="$(printf '%s' "${LOGIN_PAGE}" \
  | python3 -c '
import re, sys, html
page = sys.stdin.read()
m = re.search(r"action=\"([^\"]*login-actions/authenticate[^\"]*)\"", page)
sys.exit(1) if not m else print(html.unescape(m.group(1)))
')" || fail "the login form action was not found (realm or client misconfigured)"
LOGIN_ACTION="${LOGIN_ACTION//&amp;/&}"
# Keycloak stamps its own KC_HOSTNAME into the form action, and that name is
# the Service the pods use, not the address this host can reach. Rewrite only
# the scheme and authority, keeping the session_code the form depends on: the
# alternative (pointing KC_HOSTNAME at 127.0.0.1) would make the issuer in the
# token wrong for the manager, which fetches discovery over the Service.
LOGIN_ACTION="$(printf '%s' "${LOGIN_ACTION}" | sed -E "s#^https?://[^/]+#${KEYCLOAK_URL}#")"
case "${LOGIN_ACTION}" in
  "${KEYCLOAK_URL}"/*) ;;
  *) fail "the login form action is not on the reachable host: ${LOGIN_ACTION}" ;;
esac

REDIRECT="$(curl -s -o /dev/null -w '%{redirect_url}' -H "Cookie: ${LOGIN_COOKIES}" \
  --data-urlencode "username=${USER_NAME}" \
  --data-urlencode "password=${USER_PASSWORD}" \
  "${LOGIN_ACTION}")" || fail "the login POST did not answer"
CODE="$(printf '%s' "${REDIRECT}" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
[ -n "${CODE}" ] || fail "no authorization code in the redirect: ${REDIRECT}"

ACCESS_TOKEN="$(curl -sf -X POST \
  -d "grant_type=authorization_code" \
  -d "client_id=${CLIENT_ID}" \
  -d "code=${CODE}" \
  -d "redirect_uri=${REDIRECT_URI}" \
  -d "code_verifier=${CODE_VERIFIER}" \
  "${TOKEN_ENDPOINT}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')" \
  || fail "the code exchange failed"
info "the provider issued a token for ${USER_NAME}"

SESSION="$(curl -sfk "${CURL_TLS[@]}" -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/v0/config/session")" || fail "the manager rejected a token from the configured issuer"
echo "${SESSION}" | python3 -c '
import json, sys
session = json.load(sys.stdin)
assert session.get("role") is not None, f"the login resolved no role: {session}"
print("   the login acts as", session["role"], "in tenant", session.get("tenant_name"))
' || fail "the session is missing a role"

step "the token carries the owner role, so a write that needs admin succeeds"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json" \
  "${BASE_URL}/v0/pipelines" -d '{"name":"p1-021-owner-check","program_code":"","udf_rust":"","udf_toml":""}')"
[ "${STATUS}" = "201" ] || fail "creating a pipeline as the configured owner returned ${STATUS}, not 201"
curl -sfk "${CURL_TLS[@]}" -X DELETE -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/v0/pipelines/p1-021-owner-check" >/dev/null || true
info "a pipeline was created and deleted as the owner"

step "requests without a valid token are still refused"

ANONYMOUS="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/v0/pipelines")"
[ "${ANONYMOUS}" = "401" ] || fail "an unauthenticated request got ${ANONYMOUS}, not 401"

# A token this issuer would never sign: same claims, different key. The
# signature check is the only thing standing between a forged token and
# `owner`, so it is worth asserting rather than assuming.
FORGED="$(python3 - "${USER_NAME}" "${ISSUER}" "${CLIENT_ID}" <<'PY'
import base64, json, sys
def b64(obj):
    raw = json.dumps(obj, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")
header = b64({"alg": "RS256", "typ": "JWT", "kid": "forged"})
claims = b64({
    "iss": sys.argv[2], "sub": "forged-subject", "aud": sys.argv[3],
    "email": "attacker@acme.test", "email_verified": True,
    "exp": 9999999999, "iat": 0,
})
print(f"{header}.{claims}.c2lnbmF0dXJl")
PY
)"
FORGED_STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${FORGED}" "${BASE_URL}/v0/pipelines")"
[ "${FORGED_STATUS}" = "401" ] || fail "a forged token got ${FORGED_STATUS}, not 401"

printf '\nPASS: an OIDC provider signs a user in, the manager honours the owner list, and refuses everyone else\n'
