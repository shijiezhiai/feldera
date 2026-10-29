#!/usr/bin/env bash
#
# End-to-end check for per-tenant namespaces and quotas (P1-022).
#
# It installs the chart with one tenant mapped to its own namespace and a quota
# too small for a pipeline, then creates a pipeline and asserts that the manager
# reports the quota refusal straight away, with the API server's numbers and an
# actionable next step, instead of sitting in Provisioning until the timeout.
#
# Usage (on the machine that holds the cluster):
#
#   TAG=p1-022 scripts/e2e-k8s-tenant-quota.sh
#
# Environment:
#   CLUSTER    kind cluster name (default: bili-p1005)
#   NAMESPACE  namespace the manager itself runs in (default: feldera)
#   RELEASE    Helm release name (default: feldera)
#   TAG        manager image tag (required)
#   COMPILER_TAG / RUNNER_TAG
#              compiler and executor image tags; an iteration loop usually
#              rebuilds only the manager, and the other two stay on the last
#              release build (default: the value of TAG)
#   TIMEOUT    seconds to wait for a terminal state (default: 900)
set -euo pipefail

CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
TAG="${TAG:?TAG must be set, for example p1-022}"
TIMEOUT="${TIMEOUT:-900}"
COMPILER_TAG="${COMPILER_TAG:-${TAG}}"
RUNNER_TAG="${RUNNER_TAG:-${TAG}}"

# The tenant every unauthenticated pipeline lands in: the manager's default,
# which is the nil UUID (`crates/pipeline-manager/src/auth.rs`).
TENANT="00000000-0000-0000-0000-000000000000"
TENANT_NAMESPACE="tenant-acme"
API="http://localhost:8080"

say() { printf '\n== %s\n' "$*"; }
elapsed() { echo "$(( $(date +%s) - START ))s"; }
START=$(date +%s)

say "loading images into kind"
kind load docker-image --name "${CLUSTER}" "localhost:5001/feldera-manager:${TAG}"
kind load docker-image --name "${CLUSTER}" "localhost:5001/feldera-runner:${RUNNER_TAG}"
kind load docker-image --name "${CLUSTER}" "localhost:5001/feldera-compiler:${COMPILER_TAG}"

say "installing release ${RELEASE} in namespace ${NAMESPACE}"
# The quota is deliberately smaller than one pipeline pod, so the very first
# pipeline is refused. `requests.cpu=1m` admits the pod's other requirements and
# still leaves no room for a real one.
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" --create-namespace \
  --set "controlplane.image.tag=${TAG}" \
  --set "controlplane.kubernetesRunner.image.tag=${RUNNER_TAG}" \
  --set "compiler.image.tag=${COMPILER_TAG}" \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --set controlplane.kubernetesRunner.enabled=true \
  --set controlplane.kubernetesRunner.tenantNamespaceAutomation=true \
  --set-string "controlplane.kubernetesRunner.tenantQuotas.${TENANT}=${TENANT_NAMESPACE}: requests.cpu=1m" \
  --wait --timeout 10m

say "the tenant's namespace exists and carries the quota"
kubectl get namespace "${TENANT_NAMESPACE}" -o name
kubectl get namespace "${TENANT_NAMESPACE}" \
  -o jsonpath='{.metadata.labels.feldera\.com/managed-by}{"\n"}' | grep -qx feldera-manager
kubectl get resourcequota --namespace "${TENANT_NAMESPACE}" -o name
kubectl get limitrange --namespace "${TENANT_NAMESPACE}" -o name

say "port-forwarding the manager"
kubectl port-forward --namespace "${NAMESPACE}" \
  "svc/${RELEASE}-controlplane-api-server" 8080:8080 >/tmp/e2e-tenant-port-forward.log 2>&1 &
PORT_FORWARD=$!
trap 'kill ${PORT_FORWARD} 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  if curl -sf "${API}/v0/config/authentication" >/dev/null 2>&1; then break; fi
  sleep 1
done

PIPELINE="e2e-tenant-quota-$(date +%s)"
say "creating pipeline ${PIPELINE}"
curl -sf -X POST "${API}/v0/pipelines" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"${PIPELINE}\",\"program_code\":\"CREATE TABLE t (c INT);\",\
\"program_config\":{\"profile\":\"unoptimized\"}}" >/dev/null

say "starting pipeline ${PIPELINE} in the quota-bound namespace"
# The pipeline has to land in the tenant namespace to be counted against the
# quota; `runtime_config.namespace` is how an operator overrides it.
curl -sf -X POST "${API}/v0/pipelines/${PIPELINE}/start" \
  -H 'Content-Type: application/json' \
  -d "{\"runtime_config\":{\"namespace\":\"${TENANT_NAMESPACE}\"}}" >/dev/null

say "waiting for the quota refusal (up to ${TIMEOUT}s)"
failure=""
for _ in $(seq 1 "${TIMEOUT}"); do
  body="$(curl -sf "${API}/v0/pipelines/${PIPELINE}" || true)"
  state="$(printf '%s' "${body}" | python3 -c \
    'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print(d.get("deployment_status",""))')"
  # A refused provision is not a terminal *status*: the pipeline goes back to
  # `Stopped` (there is no `Failed` in the status enum) and the reason is
  # recorded in `deployment_error`. Stop as soon as that field is set.
  # `deployment_status` and `deployment_error` are written by separate updates,
  # so the status can read `Stopped` one poll before the reason appears. Wait for
  # the reason itself rather than treating an absent one as the refusal.
  if [ "${state}" = "Stopped" ] || [ "${state}" = "Shutdown" ] || [ "${state}" = "Failed" ]; then
    failure="$(printf '%s' "${body}" | python3 -c \
      'import json,sys
d=json.load(sys.stdin)
e=d.get("deployment_error")
print(json.dumps(e) if e is not None else "")')"
    if [ -n "${failure}" ]; then break; fi
  fi
  sleep 1
done

say "asserting the refusal is actionable"
if [ -z "${failure}" ]; then
  kubectl get statefulset --namespace "${TENANT_NAMESPACE}" -o yaml >&2 || true
  kubectl get events --namespace "${TENANT_NAMESPACE}" --sort-by=.lastTimestamp >&2 || true
  echo "FAIL: the pipeline never reached a terminal state within ${TIMEOUT}s" >&2
  exit 1
fi
printf 'deployment error: %s\n' "${failure}"
case "${failure}" in
  *"no room for this pipeline"*) : ;;
  *) echo "FAIL: the error does not explain the quota: ${failure}" >&2; exit 1 ;;
esac
case "${failure}" in
  *"requests.cpu"*) : ;;
  *) echo "FAIL: the error dropped the API server's numbers: ${failure}" >&2; exit 1 ;;
esac
case "${failure}" in
  *"raise the tenant's quota"*) : ;;
  *) echo "FAIL: the error gives no next step: ${failure}" >&2; exit 1 ;;
esac

say "no pod was ever created"
if kubectl get pods --namespace "${TENANT_NAMESPACE}" -o name | grep -q .; then
  echo "FAIL: a pod was created despite the quota" >&2
  kubectl get pods --namespace "${TENANT_NAMESPACE}" >&2
  exit 1
fi

curl -sf -X DELETE "${API}/v0/pipelines/${PIPELINE}" >/dev/null || true

say "PASS: the quota refused the pipeline with an actionable error in $(elapsed)"
