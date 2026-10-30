#!/usr/bin/env bash
#
# A Keycloak that signs a test user in, shared by the end-to-end tests that need
# one.
#
# Two tests start a manager with authentication enabled: P1-021 proves the OIDC
# login path itself, and P1-027 needs an authenticated principal before it can
# prove that requests are *attributed* to one. Both need the same fixture -- a
# realm, a public client with PKCE, a user with a password, and an audience
# mapper -- so it lives here rather than twice over.
#
# Sourced, not executed. The caller sets NAMESPACE, RELEASE and the Keycloak tag,
# then calls:
#
#   keycloak_ensure <workdir> <port>   # deploy (idempotent), wait, port-forward,
#                                      # create realm/client/user/mapper
#   keycloak_access_token <workdir> <port>   # print a token for USER_NAME
#
# `keycloak_ensure` leaves KEYCLOAK_URL and KEYCLOAK_HOST set for the caller.
#
# The fixture is deliberately left running between runs: it holds the realm that
# the next run reuses, and tearing it down would make every run pay Keycloak's
# startup again.

KEYCLOAK_TAG="${KEYCLOAK_TAG:-26.0}"
REALM="${REALM:-feldera}"
CLIENT_ID="${CLIENT_ID:-feldera-console}"
USER_NAME="${USER_NAME:-alice}"
USER_PASSWORD="${USER_PASSWORD:-alice-password}"
REDIRECT_URI="${REDIRECT_URI:-http://localhost:8080/}"

KEYCLOAK_SA="${RELEASE}-keycloak"
KEYCLOAK_HOST="${KEYCLOAK_SA}.${NAMESPACE}.svc.cluster.local:8080"
ISSUER="http://${KEYCLOAK_HOST}/realms/${REALM}"

# The admin calls below need a URL. They authenticate against the master realm,
# which exists before any realm this fixture creates.
_keycloak_admin_call() {
  local method="$1" path="$2" token="$3" body="${4:-}"
  if [ -n "${body}" ]; then
    curl -sf -X "${method}" -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" -d "${body}" "${KEYCLOAK_URL}${path}"
  else
    curl -sf -X "${method}" -H "Authorization: Bearer ${token}" \
      "${KEYCLOAK_URL}${path}"
  fi
}

# Deployment, Service, and admin credentials. `kubectl apply` makes this
# idempotent, so a second run reuses the running pod instead of replacing it.
_keycloak_apply() {
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
            # Every request reaches Keycloak through a Service or a port-forward,
            # so its own notion of its host has to be the one the tokens are
            # issued for.
            - name: KC_HOSTNAME
              value: http://${KEYCLOAK_HOST}
            - name: KC_HOSTNAME_BACKCHANNEL_DYNAMIC
              value: "true"
            - name: KC_HEALTH_ENABLED
              value: "true"
          ports:
            - containerPort: 8080
          readinessProbe:
            # Keycloak 26 exposes health on its management interface (9000), not
            # on the HTTP port; probing 8081 never answers and the pod stays
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
}

# Realm, client, user, and the audience mapper the manager needs to accept a
# token. Each step is a check followed by a create, because a realm created by
# an earlier run already holds them and re-creating would fail.
_keycloak_provision() {
  local workdir="$1"
  local admin_token user_id client_uuid

  admin_token="$(curl -sf -X POST \
    -d "client_id=admin-cli" -d "username=admin" -d "password=admin-password" \
    -d "grant_type=password" \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')" \
    || return 1

  if ! _keycloak_admin_call GET "/admin/realms/${REALM}" "${admin_token}" >/dev/null 2>&1; then
    _keycloak_admin_call POST "/admin/realms" "${admin_token}" \
      "{\"realm\":\"${REALM}\",\"enabled\":true,\"sslRequired\":\"none\"}" >/dev/null
    echo "   created realm ${REALM}"
  else
    echo "   reusing realm ${REALM}"
  fi

  if ! _keycloak_admin_call GET "/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
    "${admin_token}" \
    | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin) else 1)'; then
    _keycloak_admin_call POST "/admin/realms/${REALM}/clients" "${admin_token}" \
      "{\"clientId\":\"${CLIENT_ID}\",\"publicClient\":true,\"protocol\":\"openid-connect\",
        \"standardFlowEnabled\":true,\"redirectUris\":[\"${REDIRECT_URI}\"],
        \"webOrigins\":[\"+\"],\"attributes\":{\"pkce.code.challenge.method\":\"S256\"}}" >/dev/null
    echo "   created client ${CLIENT_ID}"
  fi

  if ! _keycloak_admin_call GET "/admin/realms/${REALM}/users?username=${USER_NAME}" \
    "${admin_token}" \
    | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin) else 1)'; then
    _keycloak_admin_call POST "/admin/realms/${REALM}/users" "${admin_token}" \
      "{\"username\":\"${USER_NAME}\",\"enabled\":true,\"email\":\"${USER_NAME}@acme.test\",
        \"emailVerified\":true,\"firstName\":\"Alice\",\"lastName\":\"Test\"}" >/dev/null
    user_id="$(_keycloak_admin_call GET "/admin/realms/${REALM}/users?username=${USER_NAME}" \
      "${admin_token}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
    _keycloak_admin_call PUT "/admin/realms/${REALM}/users/${user_id}/reset-password" \
      "${admin_token}" \
      "{\"type\":\"password\",\"value\":\"${USER_PASSWORD}\",\"temporary\":false}" >/dev/null
    echo "   created user ${USER_NAME}"
  fi

  # The access token the manager checks must carry the client id in `aud` (or a
  # matching `client_id`). Keycloak's default puts the client name in `azp` and,
  # for `aud`, whatever the audience mapper names, so add the mapper explicitly.
  client_uuid="$(_keycloak_admin_call GET "/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
    "${admin_token}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
  if ! _keycloak_admin_call GET \
    "/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" "${admin_token}" \
    | python3 -c 'import json,sys; sys.exit(0 if any(m["name"]=="feldera-audience" for m in json.load(sys.stdin)) else 1)'; then
    _keycloak_admin_call POST \
      "/admin/realms/${REALM}/clients/${client_uuid}/protocol-mappers/models" "${admin_token}" \
      "{\"name\":\"feldera-audience\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",
        \"config\":{\"included.client.audience\":\"${CLIENT_ID}\",\"access.token.claim\":\"true\",
        \"id.token.claim\":\"false\"}}" >/dev/null
    echo "   added the audience mapper"
  fi

  : "${workdir}"
}

# Deploy, wait, port-forward, provision. Sets KEYCLOAK_URL.
keycloak_ensure() {
  local workdir="$1" port="$2"

  _keycloak_apply
  kubectl -n "${NAMESPACE}" rollout status "deploy/${KEYCLOAK_SA}" --timeout=300s >/dev/null \
    || return 1

  kubectl -n "${NAMESPACE}" port-forward "svc/${KEYCLOAK_SA}" "${port}:8080" \
    >"${workdir}/keycloak-port-forward.log" 2>&1 &
  KEYCLOAK_PORT_FORWARD_PID=$!
  KEYCLOAK_URL="http://127.0.0.1:${port}"
  for _ in $(seq 1 30); do
    if curl -sf "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  curl -sf "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1 || return 1

  _keycloak_provision "${workdir}"
}

# A token for USER_NAME, obtained the way the console obtains one: an
# authorization-code login with PKCE.
keycloak_access_token() {
  local workdir="$1" port="$2"
  local auth_endpoint token_endpoint verifier challenge page cookies action redirect code
  KEYCLOAK_URL="http://127.0.0.1:${port}"
  auth_endpoint="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/auth"
  token_endpoint="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token"

  # Keycloak marks its session cookies `Secure`, and curl refuses to keep those
  # from an http origin. A browser accepts them on localhost, which is a
  # trustworthy origin, and that is exactly the case here; so this carries the
  # cookies itself instead of asking curl's jar to. The alternative -- serving
  # the test over TLS -- would only be testing Keycloak's cookie policy.
  _keycloak_cookie_header() {
    python3 - "$1" <<'PYCOOKIE'
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
  verifier="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  challenge="$(printf '%s' "${verifier}" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=')"

  page="$(
    curl -sf -D "${workdir}/login-headers.txt" -o "${workdir}/login-page.html" \
      --data-urlencode "client_id=${CLIENT_ID}" \
      --data-urlencode "response_type=code" \
      --data-urlencode "scope=openid profile email" \
      --data-urlencode "redirect_uri=${REDIRECT_URI}" \
      --data-urlencode "code_challenge_method=S256" \
      --data-urlencode "code_challenge=${challenge}" \
      -G "${auth_endpoint}" && cat "${workdir}/login-page.html"
  )" || return 1
  cookies="$(_keycloak_cookie_header "${workdir}/login-headers.txt")"
  action="$(printf '%s' "${page}" \
    | python3 -c '
import re, sys, html
page = sys.stdin.read()
m = re.search(r"action=\"([^\"]*login-actions/authenticate[^\"]*)\"", page)
sys.exit(1) if not m else print(html.unescape(m.group(1)))
')" || return 1
  action="${action//&amp;/&}"
  # Keycloak stamps its own KC_HOSTNAME into the form action, and that name is
  # the Service the pods use, not the address this host can reach. Rewrite only
  # the scheme and authority, keeping the session_code the form depends on: the
  # alternative (pointing KC_HOSTNAME at 127.0.0.1) would make the issuer in the
  # token wrong for the manager, which fetches discovery over the Service.
  action="$(printf '%s' "${action}" | sed -E "s#^https?://[^/]+#${KEYCLOAK_URL}#")"
  case "${action}" in
    "${KEYCLOAK_URL}"/*) ;;
    *) return 1 ;;
  esac

  redirect="$(curl -s -o /dev/null -w '%{redirect_url}' -H "Cookie: ${cookies}" \
    --data-urlencode "username=${USER_NAME}" \
    --data-urlencode "password=${USER_PASSWORD}" \
    "${action}")" || return 1
  code="$(printf '%s' "${redirect}" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
  [ -n "${code}" ] || return 1

  curl -sf -X POST \
    -d "grant_type=authorization_code" \
    -d "client_id=${CLIENT_ID}" \
    -d "code=${code}" \
    -d "redirect_uri=${REDIRECT_URI}" \
    -d "code_verifier=${verifier}" \
    "${token_endpoint}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}
