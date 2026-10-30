#!/usr/bin/env bash
#
# P1-025 acceptance: a pipeline reads a Kubernetes Secret, and the platform
# does not.
#
# The claim under test is not "a connector can read a secret" — that is the
# resolver's job and it already worked. It is that the value reaches the pod
# without passing through anything the platform stores:
#
#   1. a Secret outside the allowlist is refused when the pipeline starts, with
#      an error naming the Secret, before any object is created;
#   2. a Secret on the allowlist is mounted, and only the keys the
#      configuration uses are projected — a key the configuration never names
#      must not appear in the pod's filesystem;
#   3. the resolved value never appears in the database: the configuration row
#      still holds the reference, and no column of the pipeline row contains the
#      marker value.
#
# The pipeline under test is a Kafka input, which is the connector the feature
# exists for: `kafka_options` is a free-form map, so a reference there is
# indistinguishable from a broker address until it is resolved. Nothing tries to
# connect to Kafka, so no broker is needed; the pipeline is expected to reach
# Running and then fail its connector, which happens after the secret is read.
#
# Prerequisites: the kind cluster from docs/self-hosted-dev-env.md and a manager
# image built from this commit.
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
MANAGER_TAG="${MANAGER_TAG:?set MANAGER_TAG to the manager image tag under test}"
# The pipeline executor image is built from deploy/Dockerfile.runner and carries
# `pipeline-entrypoint`; a manager image does not. Point this at a runner tag
# that was actually built from that Dockerfile: the runner and manager images
# share a version string but differ in content, and using the manager image
# makes every pipeline pod fail with `RunContainerError` before it starts.
DEFAULT_RUNNER_TAG="v0.357.0-20-g7a5128651-bili.8"
API_PORT="${API_PORT:-18082}"
TIMEOUT="${TIMEOUT:-240}"
WORKDIR="$(mktemp -d /tmp/p1-025-secrets.XXXXXX)"

# Two Secrets with the same shape: one the allowlist names, one it does not.
ALLOWED_SECRET="kafka-creds"
UNLISTED_SECRET="other-creds"
ALLOWED_VALUE="allowed-marker-$$-$(date +%s)"
UNLISTED_VALUE="unlisted-marker-$$-$(date +%s)"
UNUSED_KEY="unused-key-marker-$$"

step() { printf '\n-- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*"; }

PIPELINE=""
PORT_FORWARD=""
cleanup() {
  [ -n "${PORT_FORWARD}" ] && kill "${PORT_FORWARD}" 2>/dev/null || true
  if [ -n "${PIPELINE}" ]; then
    # A refused provision leaves the pipeline Stopped with a worker error the
    # API reports through /clear before it will delete; loop like the other
    # scripts so a failure does not need manual cleanup.
    for _ in $(seq 1 5); do
      curl -sf -X POST "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}/clear" >/dev/null 2>&1 || true
      curl -sf -X DELETE "http://127.0.0.1:${API_PORT}/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 && break
      sleep 2
    done
  fi
  kubectl --namespace "${NAMESPACE}" delete secret "${ALLOWED_SECRET}" "${UNLISTED_SECRET}" \
    --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

step "creating the Secrets"
kubectl --namespace "${NAMESPACE}" create secret generic "${ALLOWED_SECRET}" \
  --from-literal=username=alice \
  --from-literal=password="${ALLOWED_VALUE}" \
  --from-literal="${UNUSED_KEY}=never-referenced" >/dev/null
kubectl --namespace "${NAMESPACE}" create secret generic "${UNLISTED_SECRET}" \
  --from-literal=password="${UNLISTED_VALUE}" >/dev/null
info "created ${ALLOWED_SECRET} and ${UNLISTED_SECRET}"

step "installing the chart with ${ALLOWED_SECRET} on the allowlist"
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" \
  --set controlplane.kubernetesRunner.enabled=true \
  --set controlplane.kubernetesRunner.connectorKubernetesSecrets.enableAllowlist=true \
  --set "controlplane.kubernetesRunner.connectorKubernetesSecrets.allowlist={${ALLOWED_SECRET}}" \
  --set controlplane.image.tag="${MANAGER_TAG}" \
  --set compiler.image.tag="${COMPILER_TAG:-${MANAGER_TAG}}" \
  --set controlplane.kubernetesRunner.image.tag="${RUNNER_TAG:-${DEFAULT_RUNNER_TAG}}" \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --wait --timeout 10m >/dev/null || fail "the release did not become ready"
info "release ready"

# A StatefulSet with one replica rolls only through a ready pod: a compiler
# stuck in CrashLoopBackOff from an earlier image blocks its own replacement
# forever. Delete it so the new template is applied.
kubectl --namespace "${NAMESPACE}" delete pod "${RELEASE}-compiler-0" --ignore-not-found \
  >/dev/null 2>&1 || true

# The manager reads the allowlist at start-up, so a pod that predates this
# upgrade would refuse every reference.
MANAGER_DEPLOYMENT="${RELEASE}-controlplane-api-server"
kubectl --namespace "${NAMESPACE}" rollout restart deployment/"${MANAGER_DEPLOYMENT}" >/dev/null \
  || fail "could not restart the manager"
kubectl --namespace "${NAMESPACE}" rollout status deployment/"${MANAGER_DEPLOYMENT}" --timeout=5m >/dev/null \
  || fail "the manager did not come back"

kubectl --namespace "${NAMESPACE}" port-forward "svc/${RELEASE}-controlplane-api-server" "${API_PORT}:8080" \
  >"${WORKDIR}/port-forward.log" 2>&1 &
PORT_FORWARD=$!
API="http://127.0.0.1:${API_PORT}"
for _ in $(seq 1 30); do
  curl -sf "${API}/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "${API}/healthz" >/dev/null || fail "the API did not answer on ${API}"

# The allowlist has to be in the pod's environment; a chart key that renders
# nothing would leave the manager on its "nothing allowed" default and the
# first assertion below would pass for the wrong reason.
manager_pod="$(kubectl --namespace "${NAMESPACE}" get pod \
  -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${manager_pod}" ] || fail "could not find the manager pod"
if ! kubectl --namespace "${NAMESPACE}" exec "${manager_pod}" -- \
  printenv FELDERA_KUBERNETES_RUNNER_CONNECTOR_KUBERNETES_SECRETS_ALLOWLIST \
  | grep -q "${ALLOWED_SECRET}"; then
  fail "the manager did not receive the allowlist"
fi
info "the manager sees the allowlist"

# The connectors travel inside `program_code`, not in `runtime_config`.
# `generate_pipeline_config` builds the deployment configuration out of the
# compiled program's schema and leaves `inputs`/`outputs` empty, so a
# `runtime_config.inputs` block is accepted by the API and then dropped: the
# pipeline comes up with no connector, and an allowlist that only ever inspects
# connectors has nothing to refuse.
create_pipeline() {
  local name="$1" secret="$2"
  local connectors
  connectors=$(cat <<CONNECTORS
[{
  "transport": {
    "name": "kafka_input",
    "config": {
      "topic": "orders",
      "bootstrap.servers": "localhost:19092",
      "security.protocol": "SASL_PLAINTEXT",
      "sasl.mechanism": "PLAIN",
      "sasl.username": "\${secret:kubernetes:${secret}/username}",
      "sasl.password": "\${secret:kubernetes:${secret}/password}"
    }
  },
  "format": {"name": "json", "config": {"update_format": "raw", "array": false}}
}]
CONNECTORS
)
  # The connector JSON sits inside a SQL string literal, which itself sits
  # inside a JSON string. Three levels of escaping is more than a heredoc can
  # carry readably, so Python builds the payload.
  python3 - "$name" "$connectors" >"${WORKDIR}/${name}.json" <<'PY'
import json, sys
name, connectors = sys.argv[1], sys.argv[2]
program_code = (
    "CREATE TABLE orders (id BIGINT NOT NULL) WITH ("
    "'materialized' = 'true', "
    "'connectors' = '" + connectors.replace("'", "''") + "');"
)
json.dump(
    {
        "name": name,
        "program_code": program_code,
        "program_config": {"profile": "unoptimized"},
        "runtime_config": {
            "workers": 1,
            "resources": {
                "cpu_cores_min": 0,
                "memory_mb_min": 256,
                "memory_mb_max": 1024,
            },
        },
    },
    sys.stdout,
)
PY
  curl -sf -X POST "${API}/v0/pipelines" \
    -H 'content-type: application/json' --data @"${WORKDIR}/${name}.json" >/dev/null \
    || fail "could not create pipeline ${name}"
}

# Prints "state<TAB>error". The two values travel on one line because a
# `while ... read` consumer cannot tell tabs from spaces in a two-line result,
# and because an empty error is common: a two-line form would leave the second
# `read` at EOF, which `set -e` turns into a silent exit.
describe_state() {
  curl -sf "${API}/v0/pipelines/$1" | python3 -c '
import json, sys
body = json.load(sys.stdin)
error = body.get("deployment_error")
if isinstance(error, dict):
    error = error.get("message") or json.dumps(error)
print("%s\t%s" % (body.get("deployment_status") or "none", error or ""))
'
}

step "a Secret outside the allowlist is refused"
PIPELINE="e2e-secret-unlisted-$(date +%s)"
create_pipeline "${PIPELINE}" "${UNLISTED_SECRET}"
curl -sf -X POST "${API}/v0/pipelines/${PIPELINE}/start" \
  -H 'content-type: application/json' -d '{}' >/dev/null || fail "start was refused outright"

refusal=""
for _ in $(seq 1 "${TIMEOUT}"); do
  # `|| true` keeps a failed GET from ending the loop: a pipeline the manager
  # is still creating answers 404, which is not a refusal.
  state_error="$(describe_state "${PIPELINE}" 2>/dev/null || true)"
  state="${state_error%%$'\t'*}"
  error="${state_error#*$'\t'}"
  case "${state}" in
    # `[ ... ] && break` in tail position would make `set -e` end the script
    # when the error is empty, with no message.
    Stopped|Failed) refusal="${error}"; if [ -n "${refusal}" ]; then break; fi ;;
  esac
  sleep 1
done
[ -n "${refusal}" ] || fail "the unlisted Secret was not refused within ${TIMEOUT}s (state ${state:-unknown})"
printf '%s' "${refusal}" | grep -q "${UNLISTED_SECRET}" \
  || fail "the refusal does not name the Secret: ${refusal}"
printf '%s' "${refusal}" | grep -q "not on the allowlist" \
  || fail "the refusal does not mention the allowlist: ${refusal}"
info "refused, naming the Secret: ${refusal}"

# The refused pipeline must not have been deployed at all.
if kubectl --namespace "${NAMESPACE}" get statefulset "pipeline-$(curl -sf "${API}/v0/pipelines/${PIPELINE}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" >/dev/null 2>&1; then
  fail "the refused pipeline was deployed anyway"
fi
info "nothing was deployed for it"

step "a Secret on the allowlist is mounted, and only the referenced keys are"
pipeline_id="$(curl -sf "${API}/v0/pipelines/${PIPELINE}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
curl -sf -X POST "${API}/v0/pipelines/${PIPELINE}/clear" >/dev/null 2>&1 || true
curl -sf -X DELETE "${API}/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 || fail "could not delete the refused pipeline"
PIPELINE="e2e-secret-listed-$(date +%s)"
create_pipeline "${PIPELINE}" "${ALLOWED_SECRET}"
curl -sf -X POST "${API}/v0/pipelines/${PIPELINE}/start" \
  -H 'content-type: application/json' -d '{}' >/dev/null || fail "start was refused outright"
pipeline_id="$(curl -sf "${API}/v0/pipelines/${PIPELINE}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
pod="pipeline-${pipeline_id}-0"

for _ in $(seq 1 "${TIMEOUT}"); do
  kubectl --namespace "${NAMESPACE}" get pod "${pod}" >/dev/null 2>&1 && break
  state_error="$(describe_state "${PIPELINE}" 2>/dev/null || true)"
  state="${state_error%%$'\t'*}"
  error="${state_error#*$'\t'}"
  # The automaton reports `Stopped` for a pipeline that has not been picked up
  # yet, so only an error makes it terminal. Without this test the loop fails
  # on the first tick, before provisioning has even started.
  case "${state}" in
    Stopped|Failed) if [ -n "${error}" ]; then fail "the allowed Secret did not provision: ${error}"; fi ;;
  esac
  sleep 1
done
kubectl --namespace "${NAMESPACE}" get pod "${pod}" >/dev/null 2>&1 \
  || fail "the runner did not create ${pod}"
info "pod ${pod} exists"

secret_dir="/etc/feldera-secrets/kubernetes/${ALLOWED_SECRET}"
for _ in $(seq 1 60); do
  kubectl --namespace "${NAMESPACE}" exec "${pod}" -- test -f "${secret_dir}/password" >/dev/null 2>&1 && break
  sleep 1
done
value="$(kubectl --namespace "${NAMESPACE}" exec "${pod}" -- cat "${secret_dir}/password" 2>/dev/null || true)"
[ "${value}" = "${ALLOWED_VALUE}" ] \
  || fail "the pipeline pod did not see the Secret value at ${secret_dir}/password"
info "the pod reads the value the resolver expects"

kubectl --namespace "${NAMESPACE}" exec "${pod}" -- cat "${secret_dir}/username" 2>/dev/null \
  | grep -q '^alice$' || fail "the second referenced key was not projected"
# The unused key must not be there: projecting the whole Secret would give the
# pod every credential in it, which is more than the configuration asked for.
if kubectl --namespace "${NAMESPACE}" exec "${pod}" -- test -e "${secret_dir}/${UNUSED_KEY}" 2>/dev/null; then
  fail "an unreferenced key of the Secret was projected into the pod"
fi
info "only the referenced keys are projected"

# Wait until the pipeline has read the secret. A Kafka connector that cannot
# reach the broker reports the connection failure, not a secret-resolution
# failure: that is the proof the reference resolved.
for _ in $(seq 1 "${TIMEOUT}"); do
  logs="$(kubectl --namespace "${NAMESPACE}" logs "${pod}" 2>/dev/null || true)"
  case "${logs}" in
    *"secret"*"${ALLOWED_SECRET}"*) break ;;
    *unable*resolve*) fail "the reference did not resolve: $(printf '%s' "${logs}" | tail -3)" ;;
  esac
  printf '%s' "${logs}" | grep -qiE 'connection refused|broker|Failed to resolve' && break
  sleep 2
done
info "the pipeline started its connector"

step "the value is nowhere in the database"
# Read the pipeline row through psql in the database pod. The column that could
# hold the value is `runtime_config` (the configuration as submitted); the
# assertion covers the whole row so a future column cannot reintroduce it.
db_pod="$(kubectl --namespace "${NAMESPACE}" get pod -l app.kubernetes.io/name=postgres \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${db_pod}" ] || db_pod="${RELEASE}-db-0"
db_user="$(kubectl --namespace "${NAMESPACE}" get secret "${RELEASE}-db-insecure-secret" \
  -o jsonpath='{.data.\.user}' | base64 -d)"
db_name="feldera"

dump_pipeline_row() {
  kubectl --namespace "${NAMESPACE}" exec "${db_pod}" -- \
    psql -U "${db_user}" -d "${db_name}" -At -c \
    "SELECT to_jsonb(p)::text FROM pipeline p WHERE p.id = '${pipeline_id}'"
}
row="$(dump_pipeline_row)"
[ -n "${row}" ] || fail "could not read the pipeline row"

# The reference must still be there: a platform that resolved the value into
# the configuration would have replaced it.
printf '%s' "${row}" | grep -q "secret:kubernetes:${ALLOWED_SECRET}" \
  || fail "the stored configuration no longer holds the reference"
info "the stored configuration holds the reference, not the value"

if printf '%s' "${row}" | grep -qF "${ALLOWED_VALUE}"; then
  fail "the secret value appears in the pipeline row"
fi
# A whole-database scan, not just the row: resolved values could land in a
# worker, a log table, or a future column the pipeline row does not cover.
leaked_tables="$(kubectl --namespace "${NAMESPACE}" exec "${db_pod}" -- \
  psql -U "${db_user}" -d "${db_name}" -At -c "
    SELECT table_name FROM information_schema.columns
    WHERE table_schema = 'public' AND data_type IN ('text','character varying','jsonb','json')
  " | while read -r table; do
    hits="$(kubectl --namespace "${NAMESPACE}" exec "${db_pod}" -- \
      psql -U "${db_user}" -d "${db_name}" -At -c \
      "SELECT count(*) FROM \"${table}\" WHERE to_jsonb(\"${table}\")::text LIKE '%${ALLOWED_VALUE}%'")"
    [ "${hits}" != "0" ] && echo "${table}"
  done)"
[ -z "${leaked_tables}" ] || fail "the secret value appears in: ${leaked_tables}"
info "no table in the database contains the value"

printf '\nPASS: a listed Secret reaches the pipeline, an unlisted one is refused, and the value never enters the database\n'
