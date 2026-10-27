#!/usr/bin/env bash
#
# P1-018 acceptance: the compiler pod compiles a pipeline and the API server pod
# serves that program to the runner, over HTTP rather than over a shared
# filesystem.
#
# The order of assertions follows the artifact's life, because each step fails
# in a way the next one hides:
#
#   1. the two pods run different services (the split is real, not cosmetic);
#   2. the compiler pod writes the binary into its claim (compilation happened
#      where the chart says it did);
#   3. the API server can fetch that binary over HTTP (the two agree on where
#      the artifacts are);
#   4. the binary the API server serves is byte-identical to the one on the
#      claim (they agree on the content, not merely on the path);
#   5. a failing SQL compilation returns the compiler's own message through the
#      API (errors travel the same path as artifacts, instead of turning into a
#      generic 500 at the pod boundary).
#
# The hash in step 4 is the DoD's "kind 上远程编译产物 == 本地编译产物": both
# sides compute SHA-256 over the same bytes, one in the compiler pod and one in
# the API server pod, and neither is trusted to be the other's source.
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
NAMESPACE="${NAMESPACE:-feldera}"
API_DEPLOYMENT="${API_DEPLOYMENT:-feldera-controlplane-api-server}"
# The compiler pod mounts the claim here; the manager's default working
# directory, which `--compiler-working-directory` would have to change for a
# compiler to write somewhere else.
WORKDIR="${WORKDIR:-/home/ubuntu/.feldera/compiler}"
PIPELINE="${PIPELINE:-p1-018-remote-compile}"

step() { printf '\n-- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*"; }

# Port-forwards the API server and leaves the tunnel for the caller to kill.
PORT_FORWARD_PID=""
api_pid() {
    if [ -z "${PORT_FORWARD_PID}" ]; then
        kubectl -n "${NAMESPACE}" port-forward "deploy/${API_DEPLOYMENT}" 18080:8080 \
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
    # A failed run should not leave a pipeline holding a claim, which makes the
    # next run's PVC assertion pass for the wrong reason.
    if [ "${KEEP_PIPELINE:-0}" != "1" ]; then
        api_pid
        curl -fsS -X DELETE "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "== remote compiler acceptance =="
echo "namespace: ${NAMESPACE}"
echo "pipeline:  ${PIPELINE}"
echo

step "1. the API server and the compiler run different services"
api_services=$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=api-server \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="FELDERA_SERVICES")].value}')
[ "${api_services}" = "api" ] \
    || fail "the API server pod selects services '${api_services}', expected 'api'"
compiler_pod=$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=compiler \
    -o jsonpath='{.items[0].metadata.name}')
[ -n "${compiler_pod}" ] || fail "no compiler pod found"
compiler_services=$(kubectl -n "${NAMESPACE}" get pod "${compiler_pod}" \
    -o jsonpath='{.spec.containers[0].env[?(@.name=="FELDERA_SERVICES")].value}')
case "${compiler_services}" in
    *compiler*) ;;
    *) fail "the compiler pod selects '${compiler_services}', which does not include compiler" ;;
esac
info "api-server: ${api_services}"
info "compiler:   ${compiler_services} (${compiler_pod})"

step "2. the API server does not serve compilation itself"
# The point of the split is that compilation is not happening in this pod. Its
# log is where a process that still ran `compiler_main` would say so.
if kubectl -n "${NAMESPACE}" logs "deploy/${API_DEPLOYMENT}" --tail=2000 2>/dev/null \
    | grep -qE "Running compiler 0/1"; then
    fail "the API server pod is still running compilation tasks"
fi
info "the API server log shows no compilation worker"

step "3. the API server can reach the compiler over HTTP"
# The manager's own /config carries the URL it will use; the compiler's service
# must resolve to the pod that serves it.
compiler_port=$(kubectl -n "${NAMESPACE}" get svc -l app.kubernetes.io/name=compiler \
    -o jsonpath='{.items[0].spec.ports[0].port}')
[ -n "${compiler_port}" ] || fail "the compiler service exposes no port"
kubectl -n "${NAMESPACE}" exec "deploy/${API_DEPLOYMENT}" -- \
    curl -fsS "http://$(kubectl -n "${NAMESPACE}" get svc -l app.kubernetes.io/name=compiler \
        -o jsonpath='{.items[0].metadata.name}').${NAMESPACE}.svc.cluster.local:${compiler_port}/healthz" \
    >/dev/null || fail "the API server cannot reach the compiler's health endpoint"
info "the compiler answers /healthz on port ${compiler_port} from the API server pod"

step "4. a pipeline compiles in the compiler pod"
api_pid
curl -fsS -X DELETE "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" >/dev/null 2>&1 || true
curl -fsS -X PUT "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" \
    -H 'Content-Type: application/json' -d @- >/dev/null <<'JSON'
{
  "name": "p1-018-remote-compile",
  "program_code": "CREATE TABLE t (id INT NOT NULL, v INT); CREATE VIEW s AS SELECT id, v * 2 AS doubled FROM t;",
  "program_config": {"profile": "unoptimized"},
  "runtime_config": {"workers": 1}
}
JSON
status=""
for _ in $(seq 1 180); do
    # `program_status` is a plain string in this API version, not an object; an
# empty read means the pipeline is not there yet.
    status=$(curl -fsS "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["program_status"])' 2>/dev/null || echo "")
    case "${status}" in
        Success|SqlError|RustError|SystemError) break ;;
    esac
    sleep 2
done
[ "${status}" = "Success" ] || fail "compilation ended with status '${status}'"
info "compilation succeeded through the split"

step "5. the artifact lives on the compiler's claim"
# The compiler publishes into `<workdir>/rust-compilation/pipeline-binaries/` with
# a self-describing name: pipeline id, program version, the SQL source checksum
# and the binary's checksum, all as full sha256 digests. The file name is
# therefore the artifact's identity, and the digest it names must be the digest
# of the bytes — the compiler truncates the values it logs to 12 hex digits, so
# the name is the only full-strength record.
api_pid
pipeline_id=$(curl -fsS "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
program_version=$(curl -fsS "http://127.0.0.1:18080/v0/pipelines/${PIPELINE}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["program_version"])')
[ -n "${pipeline_id}" ] || fail "the API server did not report the pipeline id"
binary_prefix="pipeline_${pipeline_id}_v${program_version}_sc_"
binary_name=$(kubectl -n "${NAMESPACE}" exec "${compiler_pod}" -- \
    sh -c "ls ${WORKDIR}/rust-compilation/pipeline-binaries/ | grep '^${binary_prefix}'" | head -1)
[ -n "${binary_name}" ] || fail "no published binary named ${binary_prefix}* in ${compiler_pod}"
binary_path="${WORKDIR}/rust-compilation/pipeline-binaries/${binary_name}"
named_checksum=$(echo "${binary_name}" | sed -n 's/.*_ic_\([0-9a-f]*\)$/\1/p')
[ "${#named_checksum}" = "64" ] || fail "the name carries no full sha256: ${binary_name}"
actual_checksum=$(kubectl -n "${NAMESPACE}" exec "${compiler_pod}" -- \
    sha256sum "${binary_path}" | awk '{print $1}')
info "published: ${binary_name}"
[ "${named_checksum}" = "${actual_checksum}" ] \
    || fail "the name says ${named_checksum} but the bytes hash to ${actual_checksum}"
info "the name's digest is the file's sha256: ${named_checksum}"

step "6. the API server serves the same bytes"
# The compiler's log names the checksums a successful compilation produced, but
# truncates them to 12 hex digits. Those prefixes must be prefixes of the full
# digests in the file name, or the artifact on disk belongs to another attempt.
log_line=$(kubectl -n "${NAMESPACE}" logs "${compiler_pod}" --tail=4000 2>/dev/null \
    | grep "Rust compilation success" | grep "pipeline-id=${pipeline_id}" | tail -1)
[ -n "${log_line}" ] || fail "the compiler logged no success for ${pipeline_id}"
logged_binary_prefix=$(echo "${log_line}" | sed -n 's/.*binary integrity checksum: \([0-9a-f]*\).*/\1/p')
case "${named_checksum}" in
    "${logged_binary_prefix}"*) ;;
    *) fail "the logged binary checksum ${logged_binary_prefix} is not the artifact's ${named_checksum}" ;;
esac
source_checksum=$(echo "${binary_name}" | sed -n 's/.*_sc_\([0-9a-f]\{64\}\)_ic_.*/\1/p')
[ -n "${source_checksum}" ] || fail "the name carries no full source checksum: ${binary_name}"
info "the log's truncation agrees with the artifact: ${logged_binary_prefix}..."

# Fetch the artifact the way the runner does: from the API server pod, over the
# compiler's HTTP surface, at /binary/<id>/<version>/<source>/<binary-checksum>.
# Hashing the response proves the two pods agree on the bytes rather than on a
# path — the API server pod cannot see this claim.
compiler_service=$(kubectl -n "${NAMESPACE}" get svc -l app.kubernetes.io/name=compiler \
    -o jsonpath='{.items[0].metadata.name}')
binary_url="http://${compiler_service}.${NAMESPACE}.svc.cluster.local:${compiler_port}/binary/${pipeline_id}/${program_version}/${source_checksum}/${named_checksum}"
served_hash=$(kubectl -n "${NAMESPACE}" exec "deploy/${API_DEPLOYMENT}" -- \
    sh -c "curl -fsS '${binary_url}' | sha256sum | cut -d' ' -f1")
[ -n "${served_hash}" ] || fail "the API server pod fetched nothing from ${binary_url}"
[ "${served_hash}" = "${actual_checksum}" ] \
    || fail "the bytes served over HTTP (${served_hash}) differ from the claim's file (${actual_checksum})"
info "fetched over HTTP from the API server pod: ${served_hash}"
info "PASS: same bytes, two pods, no shared filesystem"

step "7. a failing program reports the compiler's message through the API"
api_pid
curl -fsS -X DELETE "http://127.0.0.1:18080/v0/pipelines/p1-018-broken" >/dev/null 2>&1 || true
curl -fsS -X PUT "http://127.0.0.1:18080/v0/pipelines/p1-018-broken" \
    -H 'Content-Type: application/json' -d @- >/dev/null <<'JSON'
{
  "name": "p1-018-broken",
  "program_code": "CREATE TABLE t (id INT NOT NULL); CREATE VIEW s AS SELECT nonexistent_column FROM t;",
  "program_config": {"profile": "unoptimized"},
  "runtime_config": {"workers": 1}
}
JSON
broken_error=""
for _ in $(seq 1 90); do
    broken_status=$(curl -fsS "http://127.0.0.1:18080/v0/pipelines/p1-018-broken" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["program_status"])' 2>/dev/null || echo "")
    if [ "${broken_status}" = "SqlError" ]; then
        broken_error=$(curl -fsS "http://127.0.0.1:18080/v0/pipelines/p1-018-broken" \
            | python3 -c 'import json,sys; d=json.load(sys.stdin)["program_error"]["sql_compilation"]; print(" ".join(m["message"] for m in (d.get("messages") or [])))' 2>/dev/null || echo "")
        break
    fi
    sleep 2
done
[ "${broken_status}" = "SqlError" ] || fail "the broken program ended with '${broken_status}', expected SqlError"
echo "${broken_error}" | grep -qi "nonexistent_column.*not found" \
    || fail "the error does not name the bad column, so it did not come from the SQL compiler: ${broken_error}"
info "the SQL compiler's diagnostic survived the hop: ${broken_error:0:120}..."
curl -fsS -X DELETE "http://127.0.0.1:18080/v0/pipelines/p1-018-broken" >/dev/null 2>&1 || true

echo
echo "== e2e passed: compiled remotely, served from the claim =="
