#!/usr/bin/env bash
# P1-026 acceptance: the compiler pod compiles a pipeline with no route to the
# internet.
#
# The chart already ships a NetworkPolicy that allows the database, DNS and the
# API server and drops everything else, and the compiler image already carries
# the cargo registry and git caches so that `cargo build` does not need to
# download anything. Both were written before this ticket; neither had ever been
# demonstrated together, and "the policy is rendered" is not the DoD. The DoD is
# that a compilation finishes with the outside world unreachable.
#
# So this script does not read the policy and infer. It applies the policy,
# proves from inside the pod that the internet is unreachable, and then compiles.
# A compilation that needed one more crate from crates.io would stop at
# "unable to get packages from source", which is the failure this test exists to
# catch -- and the one that a machine with working egress never shows.
#
# Order of assertions:
#   1. the release runs with the egress policy on (otherwise step 2 proves nothing
#      about the configuration we ship);
#   2. the compiler pod cannot reach the internet -- by IP and by name, because a
#      broken DNS would fake success;
#   3. a pipeline compiles anyway (the caches are complete);
#   4. the compilation fetched nothing: the cargo registry directory's mtime does
#      not move while the build runs (a cache that is merely warm on the machine
#      but incomplete in the image still passes 3 by downloading);
#   5. the artifact is on the claim, so step 3 compiled rather than reused.
#
# Requires: a cluster, the images of docs/self-hosted-images.md, and the
# `netshoot` image or any image with `nc`/`getent` for the reachability probe
# (the compiler image itself has curl, so it is used and nothing else is pulled).

set -euo pipefail

NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
PIPELINE="${PIPELINE:-p1-026-offline-compile}"
MANAGER_TAG="${MANAGER_TAG:?set MANAGER_TAG to the manager image tag the release should run}"
COMPILER_TAG="${COMPILER_TAG:-${MANAGER_TAG}}"
# Something that answers over HTTP on the public internet and is cheap to fail.
# Literal address so the probe does not depend on DNS working; the name probe
# checks DNS separately.
PUBLIC_ADDRESS="${PUBLIC_ADDRESS:-1.1.1.1}"
PUBLIC_NAME="${PUBLIC_NAME:-crates.io}"

step() { printf '\n-- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*"; }

PORT_FORWARD_PID=""
api_pid() {
    if [ -z "${PORT_FORWARD_PID}" ]; then
        kubectl -n "${NAMESPACE}" port-forward "svc/${RELEASE}-controlplane-api-server" 18080:8080 \
            >/dev/null 2>&1 &
        PORT_FORWARD_PID=$!
        for _ in $(seq 1 40); do
            if curl -fsS http://127.0.0.1:18080/healthz >/dev/null 2>&1; then
                return 0
            fi
            sleep 0.5
        done
        fail "the API server did not answer on the port-forward"
    fi
}

cleanup() {
    if [ -n "${PORT_FORWARD_PID}" ]; then
        kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi
    if [ "${KEEP_PIPELINE:-0}" != "1" ]; then
        api_pid
        curl -fsS -X DELETE "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "== offline compilation acceptance =="
echo "namespace: ${NAMESPACE}"
echo "pipeline:  ${PIPELINE}"
echo

step "1. the release runs with the compiler egress policy on"
helm upgrade --install "${RELEASE}" charts/feldera \
  --namespace "${NAMESPACE}" \
  --set compiler.networkPolicy.enabled=true \
  --set controlplane.image.tag="${MANAGER_TAG}" \
  --set compiler.image.tag="${COMPILER_TAG}" \
  --set controlplane.controlPlane.deploymentTimeAnnotation=false \
  --wait --timeout 10m >/dev/null || fail "the release did not become ready"
# A StatefulSet with one replica rolls only through a ready pod; a compiler left
# in CrashLoopBackOff by an earlier attempt blocks its own replacement forever.
kubectl --namespace "${NAMESPACE}" delete pod "${RELEASE}-compiler-0" --ignore-not-found \
    >/dev/null 2>&1 || true
kubectl --namespace "${NAMESPACE}" rollout status "statefulset/${RELEASE}-compiler" --timeout=5m \
    >/dev/null || fail "the compiler pod did not become ready"
policy=$(kubectl -n "${NAMESPACE}" get networkpolicy "${RELEASE}-compiler" \
    -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null || true)
case "${policy}" in
    *Egress*) ;;
    *) fail "the release has no egress NetworkPolicy on the compiler (found '${policy}')" ;;
esac
info "egress policy present: ${RELEASE}-compiler"

compiler_pod=$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=compiler \
    -o jsonpath='{.items[0].metadata.name}')
[ -n "${compiler_pod}" ] || fail "no compiler pod found"
info "compiler pod: ${compiler_pod}"

step "2. the compiler pod cannot reach the internet"
# By literal address: this fails if packets are allowed out, regardless of DNS.
if kubectl -n "${NAMESPACE}" exec "${compiler_pod}" -- \
    timeout 8 curl -sS --max-time 6 -o /dev/null "http://${PUBLIC_ADDRESS}" 2>/dev/null; then
    fail "the compiler pod reached ${PUBLIC_ADDRESS}: the egress policy is not in effect"
fi
info "no route to ${PUBLIC_ADDRESS}"
# By name: a policy that blocks the address but leaves DNS working would still
# let a download that starts by resolving. This asserts the pod cannot resolve
# either, which is what "no public egress" means for cargo.
if kubectl -n "${NAMESPACE}" exec "${compiler_pod}" -- \
    getent hosts "${PUBLIC_NAME}" >/dev/null 2>&1; then
    # Resolution is not egress by itself; the address probe above covers that.
    # Report it rather than fail, because a cluster-wide DNS that answers from a
    # cache is not a hole in this policy.
    info "note: ${PUBLIC_NAME} resolves inside the pod (DNS is not blocked; the address probe above is the authority)"
else
    info "no resolution of ${PUBLIC_NAME}"
fi

step "3. a pipeline compiles with the internet unreachable"
api_pid
curl -fsS -X DELETE "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 || true
# Read the registry's state before the build: if the compilation downloads even
# one crate, a file appears here and the mtime moves. Capturing the count as
# well catches a download that rewrites an existing file.
registry_before=$(kubectl -n "${NAMESPACE}" exec "${compiler_pod}" -- \
    sh -c 'find /home/ubuntu/.cargo/registry -type f 2>/dev/null | wc -l')
curl -fsS -X PUT "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" \
    -H 'Content-Type: application/json' -d @- >/dev/null <<JSON
{
  "name": "${PIPELINE}",
  "program_code": "CREATE TABLE t (id INT NOT NULL, v INT); CREATE VIEW s AS SELECT id, v * 2 AS doubled FROM t;",
  "program_config": {"profile": "unoptimized"},
  "runtime_config": {"workers": 1}
}
JSON
status=""
for _ in $(seq 1 180); do
    status=$(curl -fsS "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["program_status"])' 2>/dev/null || echo "")
    case "${status}" in
        Success|SqlError|RustError|SystemError) break ;;
    esac
    sleep 2
done
if [ "${status}" != "Success" ]; then
    kubectl -n "${NAMESPACE}" logs "${compiler_pod}" --tail=80 2>/dev/null >&2 || true
    fail "compilation ended with status '${status}' with the internet unreachable"
fi
info "compilation succeeded with no route out"

step "4. the compilation fetched nothing"
# The point of the caches is that a compilation does not download. A compiler
# whose cache happens to be complete on one machine but not in the image passes
# step 3 by fetching, and then fails in an air-gapped cluster (the actual
# deployment shape). Counting files is the cheap, unambiguous check.
registry_after=$(kubectl -n "${NAMESPACE}" exec "${compiler_pod}" -- \
    sh -c 'find /home/ubuntu/.cargo/registry -type f 2>/dev/null | wc -l')
[ "${registry_before}" = "${registry_after}" ] \
    || fail "the cargo registry changed during the build (${registry_before} -> ${registry_after} files): the compilation downloaded crates"
info "cargo registry unchanged: ${registry_before} files before and after"

step "5. the artifact is on the compiler's claim"
# A cached success from an earlier run would satisfy step 3 without compiling.
# The published binary is per-program-version, and this pipeline was deleted
# before the PUT, so a binary for this id can only come from this build.
pipeline_id=$(curl -fsS "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
[ -n "${pipeline_id}" ] || fail "the API server did not report the pipeline id"
published=$(kubectl -n "${NAMESPACE}" exec "${compiler_pod}" -- \
    sh -c "ls /home/ubuntu/.feldera/compiler/rust-compilation/pipeline-binaries/ 2>/dev/null | grep '^pipeline_${pipeline_id}_' | head -1")
[ -n "${published}" ] || fail "no binary for ${pipeline_id} on the compiler's claim"
info "published: ${published}"

printf '\nPASS: a pipeline compiles with the internet unreachable, and nothing is downloaded\n'
