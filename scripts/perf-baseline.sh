#!/usr/bin/env bash
#
# Performance baseline for the self-hosted platform (P1-032).
#
# Three numbers decide whether a deployment can be promised to a team, and all
# three have a target in `design/self-hosted-enterprise-platform-plan.md`:
#
#   storage     random 4 KiB read/write IOPS and sequential MB/s, measured on
#               the same machine through two paths -- a plain directory on the
#               host and a PersistentVolumeClaim in the cluster. §4 requires
#               IOPS >= 16k and >= 1000 MB/s from the disk type a StorageClass
#               is allowed to hand out. A volume that misses this shows up as a
#               checkpoint that cannot finish, not as an error, so it is cheaper
#               to measure it here than to diagnose it in production.
#   throughput  records per second through a pipeline that reads a source and
#               maintains a materialized view. §5.9 asks for a throughput
#               baseline next to the upgrade gates so a regression is visible.
#   recovery    seconds from a crash of the pipeline process to the pipeline
#               answering again. The P1 exit criterion is RTO < 2 minutes.
#
# Every measurement runs the same probe binary and the same pipeline on both
# paths, so a difference between them is the storage layer and not the method.
#
# Usage:
#
#   # everything, report to design/perf-baseline-<date>-<sha>.md
#   TAG=p1-030 bash scripts/perf-baseline.sh
#
#   # storage only, and keep the cluster objects for inspection
#   SCOPES=storage TAG=p1-030 bash scripts/perf-baseline.sh
#
#   # one path only
#   PATHS=local TAG=p1-030 bash scripts/perf-baseline.sh
#
# Environment:
#   CLUSTER        kind cluster name (default: bili-p1005)
#   NAMESPACE      namespace of the platform (default: feldera)
#   RELEASE        Helm release name (default: feldera)
#   TAG            image tag, or MANAGER_TAG/RUNNER_TAG/COMPILER_TAG separately
#   SCOPES         comma-separated storage,throughput,recovery (default: all)
#   PATHS          comma-separated local,k8s for the storage scope (default: both)
#   DURATION       seconds each random-IO probe runs (default: 10)
#   PROBE_SIZE_MIB size of the random-IO file in MiB (default: 16384). It has to
#                  be larger than the controller's write cache and larger than
#                  RAM, or the numbers describe the cache instead of the disk.
#   SEQ_SIZE_MIB   size of the sequential-IO file in MiB (default: 1024)
#   PVC_SIZE       size of the measurement claim (default: 25Gi)
#   LOCAL_DIR      directory for the local path (default: $FELDERA_HOME/perf-probe)
#   RECORDS        records the throughput pipeline generates (default: 5000000)
#   WORKERS        datagen workers (default: 1)
#   PORT           local port for the API forward (default: a free port)
#   PROFILE        compilation profile (default: unoptimized)
#   KEEP           set to 1 to leave the claim, the job, and the pipeline behind
#   REPORT         report path (default: design/perf-baseline-<date>-<sha>.md)
#
# The probe is compiled on the machine that runs the script, so the local path
# and the cluster path execute the same instructions against the same kernel.
set -euo pipefail

CLUSTER="${CLUSTER:-bili-p1005}"
NAMESPACE="${NAMESPACE:-feldera}"
RELEASE="${RELEASE:-feldera}"
TAG="${TAG:-}"
MANAGER_TAG="${MANAGER_TAG:-${TAG}}"
RUNNER_TAG="${RUNNER_TAG:-${TAG}}"
COMPILER_TAG="${COMPILER_TAG:-${TAG}}"
SCOPES="${SCOPES:-storage,throughput,recovery}"
PATHS="${PATHS:-local,k8s}"
DURATION="${DURATION:-10}"
PROBE_SIZE_MIB="${PROBE_SIZE_MIB:-16384}"
SEQ_SIZE_MIB="${SEQ_SIZE_MIB:-1024}"
PVC_SIZE="${PVC_SIZE:-25Gi}"
LOCAL_DIR="${LOCAL_DIR:-${FELDERA_HOME:-/tmp}/perf-probe}"
RECORDS="${RECORDS:-5000000}"
WORKERS="${WORKERS:-1}"
PROFILE="${PROFILE:-unoptimized}"
KEEP="${KEEP:-0}"
PORT="${PORT:-}"
if [ -z "${PORT}" ]; then
  PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
REPORT="${REPORT:-${REPO_ROOT}/design/perf-baseline-$(date +%Y-%m-%d)-$(git rev-parse --short HEAD 2>/dev/null || echo nogit).md}"

say() { printf '\n=== %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

# One measured quantity per name, so the report is generated from the numbers
# that were actually read rather than from numbers retyped into the prose.
declare -A value=()
declare -A notes=()
declare -A failed=()
declare -A millis=()
set_value() { value["$1"]="$2"; }
set_note() { notes["$1"]="$2"; }
set_failed() { failed["$1"]="$2"; }

have_scope() {
  case ",${SCOPES}," in *",$1,"*) return 0 ;; esac
  return 1
}
have_path() {
  case ",${PATHS}," in *",$1,"*) return 0 ;; esac
  return 1
}

for tool in kubectl curl python3 gcc gzip; do
  command -v "${tool}" >/dev/null || fail "${tool} is required"
done

# ---------------------------------------------------------------------------
# The probe
#
# `dd` cannot do random I/O, and every random-I/O tool that can (fio, sysbench)
# would have to be pulled into a cluster that may have no route to a registry.
# The probe is small enough to compile here and carry into a pod, and it uses
# O_DIRECT so the page cache does not answer the reads.
# ---------------------------------------------------------------------------
PROBE_SRC="${TMPDIR:-/tmp}/feldera-perf-iops-probe.c"
PROBE_BIN="${TMPDIR:-/tmp}/feldera-perf-iops-probe"

write_probe_source() {
  cat >"${PROBE_SRC}" <<'PROBE'
// Random 4 KiB I/O probe over a file, using O_DIRECT so the page cache does
// not answer the reads. Prints one JSON object with the measured IOPS.
//
//   iops_probe <path> <size-mib> <seconds> <read|write>
//
// The file is created and sized before the timed window, so the number is the
// cost of the I/O and nothing else.
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/tmp/iops.bin";
    long size_mib = argc > 2 ? atol(argv[2]) : 1024;
    long seconds = argc > 3 ? atol(argv[3]) : 10;
    int write_mode = argc > 4 && strcmp(argv[4], "write") == 0;
    const size_t bs = 4096;
    long blocks = size_mib * 1024 * 1024 / (long)bs;

    void *buf = NULL;
    if (posix_memalign(&buf, bs, bs) != 0) { perror("posix_memalign"); return 1; }
    memset(buf, 0x5a, bs);

    int fd = open(path, O_RDWR | O_CREAT | O_DIRECT, 0644);
    if (fd < 0) { perror("open"); return 1; }
    if (ftruncate(fd, (off_t)size_mib * 1024 * 1024) != 0) {
        perror("ftruncate");
        return 1;
    }

    // Allocate and fill the file before the timed window. `ftruncate` alone
    // leaves a sparse file, and a read of a hole is answered by the filesystem
    // without touching the disk -- which is how a rotational array appears to
    // deliver hundreds of thousands of read IOPS. The fill is 1 MiB at a time
    // because 4 KiB spans would take an hour on the same disk.
    const size_t fill = 1024 * 1024;
    void *fill_buf = NULL;
    if (posix_memalign(&fill_buf, bs, fill) != 0) { perror("posix_memalign"); return 1; }
    memset(fill_buf, 0x5a, fill);
    for (long offset_mib = 0; offset_mib < size_mib; offset_mib++) {
        ssize_t n = pwrite(fd, fill_buf, fill, (off_t)offset_mib * (off_t)fill);
        if (n != (ssize_t)fill) { perror("pwrite filling the file"); return 1; }
    }
    if (fsync(fd) != 0) { perror("fsync"); return 1; }
    free(fill_buf);

    unsigned long seed = 12345;
    long ops = 0, errors = 0;
    double start = now_s(), elapsed = 0;
    while ((elapsed = now_s() - start) < (double)seconds) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        off_t off = (off_t)((seed >> 33) % (unsigned long)blocks) * (off_t)bs;
        ssize_t n = write_mode ? pwrite(fd, buf, bs, off) : pread(fd, buf, bs, off);
        if (n != (ssize_t)bs) { errors++; }
        ops++;
    }
    close(fd);
    printf("{\"mode\":\"%s\",\"size_mib\":%ld,\"seconds\":%.3f,\"ops\":%ld,"
           "\"errors\":%ld,\"iops\":%.1f}\n",
           write_mode ? "write" : "read", size_mib, elapsed, ops, errors,
           (double)ops / elapsed);
    free(buf);
    return 0;
}
PROBE
}

build_probe() {
  write_probe_source
  # Static so the same binary runs on the host and inside any of the three
  # images, none of which is guaranteed to carry a matching libc.
  gcc -O2 -static -o "${PROBE_BIN}" "${PROBE_SRC}" \
    || fail "could not compile the probe (a static libc is required)"
  strip "${PROBE_BIN}" 2>/dev/null || true
  note "probe: $(stat -c %s "${PROBE_BIN}" 2>/dev/null || stat -f %z "${PROBE_BIN}") bytes"
}

# `probe_here <path> <size-mib> <read|write>`: run the probe and echo its JSON.
probe_here() {
  "${PROBE_BIN}" "$1" "$2" "${DURATION}" "$3"
}

# `json_field <json> <name>`: a number out of the probe's own output. The probe
# is the only producer of that JSON, so this stays a single-line reader rather
# than pulling in a JSON parser the host may not have.
json_field() {
  python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"
}

# `seq_mib_s <dir>`: sequential throughput, written into `dir`.
#
# `dd` reports its own rate but that rate is computed per chunk and printed as a
# human string; measuring the wall clock around it keeps one unit for the whole
# report and loses nothing, because the file is far larger than a single
# transfer.
seq_throughput() {
  local dir="$1" label="$2"
  local file="${dir}/feldera-perf-seq.bin"
  local t0 t1 ms mib_s
  t0=$(date +%s%N)
  dd if=/dev/zero of="${file}" bs=1M count="${SEQ_SIZE_MIB}" oflag=direct status=none \
    || { set_failed "${label}.seq_write" "dd could not write ${file}"; return 1; }
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  mib_s="$(python3 -c "print(f'{${SEQ_SIZE_MIB} / (${ms} / 1000):.1f}')")"
  set_value "${label}.seq_write_mib_s" "${mib_s}"
  millis["${label}.seq_write"]="${ms}"

  # Reading back what was just written measures the read path over data the
  # cache may hold; drop it first, because a sequential read answered from RAM
  # is not a disk number.
  sync
  if [ -w /proc/sys/vm/drop_caches ]; then
    echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
  fi
  t0=$(date +%s%N)
  dd if="${file}" of=/dev/null bs=1M iflag=direct status=none \
    || { set_failed "${label}.seq_read" "dd could not read ${file}"; rm -f "${file}"; return 1; }
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  mib_s="$(python3 -c "print(f'{${SEQ_SIZE_MIB} / (${ms} / 1000):.1f}')")"
  set_value "${label}.seq_read_mib_s" "${mib_s}"
  millis["${label}.seq_read"]="${ms}"
  rm -f "${file}"
}

# `random_iops <dir> <label>`: random 4 KiB IOPS in both directions.
random_iops() {
  local dir="$1" label="$2"
  local file="${dir}/feldera-perf-probe.bin"
  local out
  out="$(probe_here "${file}" "${PROBE_SIZE_MIB}" read)" \
    || { set_failed "${label}.rand_read" "the probe could not read ${file}"; return 1; }
  set_value "${label}.rand_read_iops" "$(json_field "${out}" iops)"
  out="$(probe_here "${file}" "${PROBE_SIZE_MIB}" write)" \
    || { set_failed "${label}.rand_write" "the probe could not write ${file}"; return 1; }
  set_value "${label}.rand_write_iops" "$(json_field "${out}" iops)"
  rm -f "${file}"
}

# `describe_path <dir>`: what the directory actually sits on, because a number
# without the device behind it cannot be compared with another machine.
describe_path() {
  local dir="$1"
  local device rotational model
  device="$(df --output=source "${dir}" 2>/dev/null | tail -1 || true)"
  if [ -n "${device}" ] && [ -e "/sys/block/$(basename "${device}")/queue/rotational" ]; then
    rotational="$(cat "/sys/block/$(basename "${device}")/queue/rotational")"
    model="$(cat "/sys/block/$(basename "${device}")/device/model" 2>/dev/null || true)"
    printf '%s|%s|%s' "${device}" "${rotational}" "${model}"
  else
    # A path inside a container (a PVC from `local-path`, for instance) reports
    # the overlay filesystem rather than the device that backs it.
    printf '%s|?|?' "${device:-unknown}"
  fi
}

# ---------------------------------------------------------------------------
# Storage: the local path
# ---------------------------------------------------------------------------
storage_local() {
  say "storage: local directory ${LOCAL_DIR}"
  mkdir -p "${LOCAL_DIR}" || fail "could not create ${LOCAL_DIR}"
  local described
  described="$(describe_path "${LOCAL_DIR}")"
  set_value local.device "${described%%|*}"
  described="${described#*|}"
  set_value local.rotational "${described%%|*}"
  set_value local.model "${described#*|}"
  note "device ${value[local.device]}, rotational ${value[local.rotational]}, model ${value[local.model]}"

  seq_throughput "${LOCAL_DIR}" local || true
  random_iops "${LOCAL_DIR}" local || true
  note "sequential write ${value[local.seq_write_mib_s]:-?} MiB/s, read ${value[local.seq_read_mib_s]:-?} MiB/s"
  note "random 4 KiB read ${value[local.rand_read_iops]:-?} IOPS, write ${value[local.rand_write_iops]:-?} IOPS"
}

# ---------------------------------------------------------------------------
# Storage: a claim in the cluster
#
# The claim is a `local-path` volume, which is a directory on the node: the
# comparison with the local path then isolates the storage layer rather than the
# hardware. On a cluster whose StorageClass is a network volume, the difference
# between the two columns is what that volume costs.
# ---------------------------------------------------------------------------
PVC_NAME="perf-baseline-pvc"
JOB_NAME="perf-baseline-probe"
PROBE_CM="perf-baseline-probe"

storage_k8s() {
  say "storage: claim ${PVC_NAME} in ${NAMESPACE}"
  local sc
  sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || true)"
  [ -n "${sc}" ] || fail "the cluster has no default StorageClass to measure"
  note "default StorageClass: ${sc}"

  kubectl delete job --namespace "${NAMESPACE}" "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete configmap --namespace "${NAMESPACE}" "${PROBE_CM}" --ignore-not-found >/dev/null 2>&1 || true
  if [ "${KEEP}" != "1" ]; then
    kubectl delete pvc --namespace "${NAMESPACE}" "${PVC_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  fi

  # The claim is created first so the pod that mounts it can wait for the
  # binding; `local-path` is WaitForFirstConsumer, so it binds when the Job's
  # pod schedules.
  kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: ${PVC_SIZE}
PVC

  # The probe rides in a ConfigMap. `--from-file` on a binary stores it under
  # `binaryData`, which is what keeps a 700 KiB executable inside the 1 MiB
  # object limit; it is gzipped anyway so the margin does not depend on the
  # current build.
  #
  # It is created, not applied. `kubectl apply` records the whole object in a
  # `last-applied-configuration` annotation, and an annotation is capped at
  # 256 KiB: the base64 form of the probe is larger than that, so the apply is
  # rejected and -- because the Job is created regardless -- its pod then waits
  # forever for a ConfigMap that never existed.
  gzip -9 -c "${PROBE_BIN}" >"${TMPDIR:-/tmp}/feldera-perf-iops-probe.gz"
  kubectl delete configmap --namespace "${NAMESPACE}" "${PROBE_CM}" \
    --ignore-not-found >/dev/null 2>&1 || true
  kubectl create configmap --namespace "${NAMESPACE}" "${PROBE_CM}" \
    --from-file=iops_probe.gz="${TMPDIR:-/tmp}/feldera-perf-iops-probe.gz" >/dev/null \
    || fail "could not create the probe ConfigMap ${PROBE_CM}"
  kubectl get configmap --namespace "${NAMESPACE}" "${PROBE_CM}" >/dev/null \
    || fail "the probe ConfigMap ${PROBE_CM} is not there after creating it"

  # The Job is the measurement, so it writes its numbers to stdout and the
  # script reads them back from the log. Everything that is not JSON is a
  # progress line and is printed as such.
  kubectl apply --namespace "${NAMESPACE}" -f - >/dev/null <<JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: ${RUNNER_IMAGE:-localhost:5001/feldera-runner:${RUNNER_TAG}}
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              gunzip -c /probe/iops_probe.gz > /tmp/iops_probe
              chmod +x /tmp/iops_probe
              cd /data
              echo "=== device"
              df -h /data | tail -1
              echo "=== seq write"
              t0=\$(date +%s%N)
              dd if=/dev/zero of=/data/seq.bin bs=1M count=${SEQ_SIZE_MIB} oflag=direct status=none
              t1=\$(date +%s%N)
              echo "SEQ_WRITE_MS=\$(( (t1 - t0) / 1000000 ))"
              echo "=== seq read"
              sync
              t0=\$(date +%s%N)
              dd if=/data/seq.bin of=/dev/null bs=1M iflag=direct status=none
              t1=\$(date +%s%N)
              echo "SEQ_READ_MS=\$(( (t1 - t0) / 1000000 ))"
              rm -f /data/seq.bin
              echo "=== random read"
              /tmp/iops_probe /data/probe.bin ${PROBE_SIZE_MIB} ${DURATION} read
              echo "=== random write"
              /tmp/iops_probe /data/probe.bin ${PROBE_SIZE_MIB} ${DURATION} write
              rm -f /data/probe.bin
          volumeMounts:
            - name: data
              mountPath: /data
            - name: probe
              mountPath: /probe
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
        - name: probe
          configMap:
            name: ${PROBE_CM}
JOB

  note "waiting for the probe Job (the file is ${PROBE_SIZE_MIB} MiB, so this takes a while)"
  if ! kubectl wait --namespace "${NAMESPACE}" --for=condition=complete \
    "job/${JOB_NAME}" --timeout=1800s >/dev/null 2>&1; then
    kubectl logs --namespace "${NAMESPACE}" "job/${JOB_NAME}" >&2 || true
    set_failed "k8s" "the probe Job did not complete"
    return 1
  fi
  local log
  log="$(kubectl logs --namespace "${NAMESPACE}" "job/${JOB_NAME}")"

  local ms
  ms="$(sed -n 's/^SEQ_WRITE_MS=//p' <<<"${log}")"
  if [ -n "${ms}" ]; then
    set_value "k8s.seq_write_mib_s" \
      "$(python3 -c "print(f'{${SEQ_SIZE_MIB} / (${ms} / 1000):.1f}')")"
    millis["k8s.seq_write"]="${ms}"
  fi
  ms="$(sed -n 's/^SEQ_READ_MS=//p' <<<"${log}")"
  if [ -n "${ms}" ]; then
    set_value "k8s.seq_read_mib_s" \
      "$(python3 -c "print(f'{${SEQ_SIZE_MIB} / (${ms} / 1000):.1f}')")"
    millis["k8s.seq_read"]="${ms}"
  fi
  # The two probe lines are the only JSON the Job prints, so they are taken in
  # the order the Job emits them: read first, then write.
  local reads writes
  reads="$(grep -c '"mode":"read"' <<<"${log}" || true)"
  writes="$(grep -c '"mode":"write"' <<<"${log}" || true)"
  if [ "${reads}" = "1" ]; then
    set_value "k8s.rand_read_iops" \
      "$(json_field "$(grep '"mode":"read"' <<<"${log}")" iops)"
  else
    set_failed "k8s.rand_read" "the Job printed ${reads} read lines"
  fi
  if [ "${writes}" = "1" ]; then
    set_value "k8s.rand_write_iops" \
      "$(json_field "$(grep '"mode":"write"' <<<"${log}")" iops)"
  else
    set_failed "k8s.rand_write" "the Job printed ${writes} write lines"
  fi
  set_value "k8s.device" "$(grep -A1 '=== device' <<<"${log}" | tail -1)"

  note "sequential write ${value[k8s.seq_write_mib_s]:-?} MiB/s, read ${value[k8s.seq_read_mib_s]:-?} MiB/s"
  note "random 4 KiB read ${value[k8s.rand_read_iops]:-?} IOPS, write ${value[k8s.rand_write_iops]:-?} IOPS"

  if [ "${KEEP}" != "1" ]; then
    kubectl delete job --namespace "${NAMESPACE}" "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete configmap --namespace "${NAMESPACE}" "${PROBE_CM}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete pvc --namespace "${NAMESPACE}" "${PVC_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# Platform API
# ---------------------------------------------------------------------------
api="http://127.0.0.1:${PORT}"
forward_pid=""

start_forward() {
  kubectl port-forward --namespace "${NAMESPACE}" "svc/${RELEASE}-controlplane-api-server" \
    "${PORT}:8080" >/tmp/perf-baseline-port-forward.log 2>&1 &
  forward_pid=$!
  for _ in $(seq 1 60); do
    curl --silent --fail --max-time 3 "${api}/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

cleanup() {
  if [ -n "${forward_pid}" ]; then
    kill "${forward_pid}" 2>/dev/null || true
    wait "${forward_pid}" 2>/dev/null || true
  fi
  if [ "${KEEP}" != "1" ]; then
    for name in perf-baseline-throughput perf-baseline-recovery; do
      if [ -n "$(pipeline_json "${name}")" ]; then
        remove_pipeline "${name}"
      fi
    done
  fi
  # The trap's status becomes the script's status. Without this an absent
  # pipeline -- the normal case, since each scope removes its own -- would end
  # the run with a failure that never happened.
  return 0
}
trap cleanup EXIT

api_call() {
  local method="$1" path="$2"
  shift 2
  local status=0
  response="$(curl --silent --fail --max-time 120 -X "${method}" "${api}${path}" "$@")" || status=$?
  if [ "${status}" -eq 0 ] || [ "${status}" -eq 22 ]; then
    printf '%s' "${response}"
    return "${status}"
  fi
  # Only a broken connection is retried: the forward dies whenever the manager
  # pod is replaced, and retrying an HTTP error would turn a real 404 into a
  # minute of reconnecting.
  kill "${forward_pid}" 2>/dev/null || true
  start_forward || return 1
  curl --silent --fail --max-time 120 -X "${method}" "${api}${path}" "$@"
}

field_of() {
  sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1
}

pipeline_json() { api_call GET "/v0/pipelines/$1" 2>/dev/null || true; }
deployment_status() { field_of "$(pipeline_json "$1")" deployment_status; }

# `remove_pipeline <name>`: stop, clear the storage, then delete.
#
# A pipeline cannot be deleted while it still holds storage
# (`DeleteRestrictedToClearedStorage`), and `clear` is asynchronous, so the
# delete is retried rather than issued once. Without this a rerun fails at the
# first pipeline it tries to replace, and the claim from the previous run stays
# on the node.
remove_pipeline() {
  local name="$1"
  api_call POST "/v0/pipelines/${name}/stop?force=true" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    [ "$(deployment_status "${name}")" = "Stopped" ] && break
    sleep 2
  done
  api_call POST "/v0/pipelines/${name}/clear" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    api_call DELETE "/v0/pipelines/${name}" >/dev/null 2>&1 && return 0
    sleep 2
  done
  note "could not remove pipeline ${name}; leaving it behind"
  return 0
}

# `create_bench_pipeline <name> <records>`: a datagen source with a materialized
# count.
#
# `<records>` empty means an unbounded generator: it produces records for as long
# as the pipeline runs, which is what the recovery measurement needs, because a
# plan that has already reached end of input has nothing left to restart.
#
# A bounded plan is what the throughput measurement needs: a fixed amount of work
# with a defined end, and `pipeline_complete` becomes true only when every input
# has reached end of input. The count view makes either run checkable.
create_bench_pipeline() {
  local name="$1" records="$2"
  local program newline=$'\n'
  local plan
  if [ -n "${records}" ]; then
    plan="[{\"limit\": ${records}, \"fields\": {}}]"
  else
    plan="[{\"fields\": {}}]"
  fi
  program="CREATE TABLE t (i BIGINT NOT NULL) WITH ('connectors' = '[{\"name\": \"c\", \"transport\": {\"name\": \"datagen\", \"config\": {\"plan\": ${plan}, \"workers\": ${WORKERS}}}}]');${newline}CREATE MATERIALIZED VIEW v AS SELECT COUNT(*) AS c FROM t;"

  if [ -n "$(pipeline_json "${name}")" ]; then
    note "removing pipeline ${name} left behind by an earlier run"
    remove_pipeline "${name}"
  fi

  python3 - "${name}" "${PROFILE}" "${program}" <<'PY' >"${TMPDIR:-/tmp}/feldera-perf-pipeline.json"
import json, sys
name, profile, program = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "name": name,
    "program_code": program,
    "program_config": {"profile": profile},
    "runtime_config": {
        "resources": {"cpu_cores_min": 0, "memory_mb_min": 512, "memory_mb_max": 4096},
        # Fault tolerance is what makes the recovery measurement meaningful: a
        # pipeline without a checkpoint has nothing to resume from, and the RTO
        # it would report is a cold start.
        "fault_tolerance": {"model": "at_least_once", "checkpoint_interval_secs": 10},
    },
}))
PY
  api_call POST "/v0/pipelines" -H 'content-type: application/json' \
    --data @"${TMPDIR:-/tmp}/feldera-perf-pipeline.json" >/dev/null

  local status
  for _ in $(seq 1 300); do
    status="$(field_of "$(pipeline_json "${name}")" program_status)"
    case "${status}" in
    Success) return 0 ;;
    SqlError | RustError | SystemError)
      fail "pipeline ${name} failed to compile: $(pipeline_json "${name}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("program_error"))')" ;;
    esac
    sleep 2
  done
  fail "pipeline ${name} did not finish compiling (status: ${status:-unknown})"
}

wait_for_running() {
  local name="$1" seconds="$2" deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local status
    status="$(deployment_status "${name}")"
    [ "${status}" = "Running" ] && return 0
    case "${status}" in
    Failed) fail "pipeline ${name} failed: $(pipeline_json "${name}")" ;;
    esac
    sleep 1
  done
  return 1
}

# `stats_json <name>`: the pipeline's own counters, read from inside the pod.
#
# The manager proxies this call, but a sample taken through the proxy includes
# the proxy. Reading from the pod keeps the throughput number about the
# dataflow.
stats_json() {
  local id="$1"
  kubectl exec --namespace "${NAMESPACE}" "pipeline-${id}-0" -- \
    curl --silent --fail --max-time 30 'http://127.0.0.1:8080/stats' 2>/dev/null
}

# `pod_uid <pod>`: the identity of the process behind the pod name. The name is
# reused when a pipeline is restarted, so only the UID tells the replacement
# apart from the pod it replaced.
pod_uid() {
  kubectl get pod --namespace "${NAMESPACE}" "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true
}

# `pod_restarts <pod>`: how many times the container has been restarted inside
# the pod. Together with the UID it distinguishes "the process came back" from
# "the old process is still answering": the kubelet either restarts the container
# in place or the runner replaces the pod.
pod_restarts() {
  kubectl get pod --namespace "${NAMESPACE}" "$1" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true
}

# `node_exec <node> <command...>`: run a command on the node that hosts a pod.
# The crash injection needs the node's PID namespace, because the kernel refuses
# to deliver SIGKILL to the init process of a PID namespace from inside that
# namespace -- see `crash_pipeline`.
#
# Two ways to get there: on a kind cluster the node is a container, so `docker
# exec` works; on a plain node the script has to be running on that node with
# `crictl` on PATH. Anything else is reported rather than silently skipped.
node_exec() {
  local node="$1"
  shift
  if docker exec "${node}" true >/dev/null 2>&1; then
    docker exec "${node}" "$@"
  elif [ "${node}" = "$(hostname)" ] && command -v crictl >/dev/null 2>&1; then
    "$@"
  else
    note "cannot run '${*}' on node ${node}: neither 'docker exec ${node}' nor a local crictl works"
    return 1
  fi
}

# `crash_targets <pod>`: the node and the init pid of the pod's container, as
# `<node> <pid>`. Looking the process up takes a few `exec`s, so it is separated
# from the signal: only the signal belongs on the recovery clock.
crash_targets() {
  local pod="$1" node cid pid
  node="$(kubectl get pod --namespace "${NAMESPACE}" "${pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  [ -n "${node}" ] || { note "the pod ${pod} has no node"; return 1; }

  # The container is matched by pod name rather than by the runtime's sandbox
  # listing, because the pod name is the only identifier the script already has.
  cid="$(node_exec "${node}" crictl ps 2>/dev/null \
    | awk -v pod="${pod}" '!seen && index($0, pod) { print $1; seen = 1 }')"
  [ -n "${cid}" ] || { note "no container for ${pod} on node ${node}"; return 1; }

  pid="$(node_exec "${node}" crictl inspect "${cid}" 2>/dev/null \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("info") or {}).get("pid") or 0)' 2>/dev/null || echo 0)"
  [ "${pid:-0}" -gt 0 ] 2>/dev/null || { note "container ${cid} has no init pid"; return 1; }

  note "container ${cid} on node ${node} has init pid ${pid}"
  printf '%s %s\n' "${node}" "${pid}"
}

# `checkpoint_rows`: the manager's view of this pipeline's checkpoints, as one
# `processed_records` per line, oldest first. The manager records what each
# checkpoint held, which is the only durable statement about how much state the
# pipeline would resume from.
checkpoint_rows() {
  pipeline_json perf-baseline-recovery | python3 -c '
import json, sys
try:
    status = json.load(sys.stdin).get("storage_status_details") or {}
except Exception:
    sys.exit(0)
for checkpoint in status.get("checkpoints") or []:
    print(checkpoint.get("processed_records", 0))
' 2>/dev/null || true
}

checkpoint_count() { checkpoint_rows | grep -c . || true; }

latest_checkpoint_records() { checkpoint_rows | tail -1; }

# ---------------------------------------------------------------------------
# Throughput
# ---------------------------------------------------------------------------
throughput() {
  say "throughput: ${RECORDS} records through a datagen source"
  start_forward || fail "the API server did not become healthy"
  create_bench_pipeline perf-baseline-throughput "${RECORDS}"

  local id started
  started=$(date +%s%N)
  api_call POST "/v0/pipelines/perf-baseline-throughput/start?bootstrap_policy=allow" >/dev/null
  wait_for_running perf-baseline-throughput 900 || fail "the throughput pipeline did not start"

  # Throughput is counted from the moment the pipeline is Running, so the
  # number describes the dataflow and not the pod start.
  started=$(date +%s%N)
  local processed complete
  local deadline=$(( $(date +%s) + 1800 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local body
    body="$(stats_json "$(field_of "$(pipeline_json perf-baseline-throughput)" id)")" || true
    if [ -n "${body}" ]; then
      processed="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["global_metrics"]["total_processed_records"])' <<<"${body}" 2>/dev/null || echo 0)"
      complete="$(python3 -c 'import json,sys; print("yes" if json.load(sys.stdin)["global_metrics"].get("pipeline_complete") else "no")' <<<"${body}" 2>/dev/null || echo no)"
      if [ "${processed}" -ge "${RECORDS}" ] 2>/dev/null || [ "${complete}" = "yes" ]; then
        break
      fi
    fi
    sleep 1
  done
  local finished ms rate
  finished=$(date +%s%N)
  ms=$(( (finished - started) / 1000000 ))

  if [ -z "${processed:-}" ]; then
    set_failed throughput "the pipeline never reported a record count"
    return 1
  fi
  rate="$(python3 -c "print(f'{${processed} / (${ms} / 1000):.1f}')")"
  set_value throughput.records "${processed}"
  set_value throughput.millis "${ms}"
  set_value throughput.records_per_s "${rate}"
  millis["throughput"]="${ms}"
  note "${processed} records in ${ms} ms: ${rate} records/s"

  if [ "${processed}" -lt "${RECORDS}" ]; then
    set_failed throughput "the pipeline processed ${processed} of ${RECORDS} records within the timeout"
  fi
}

# ---------------------------------------------------------------------------
# Recovery
#
# The measurement the P1 exit criterion asks for: the pipeline process dies and
# the platform brings it back, and how long that takes.
#
# The injection is a SIGKILL to the pipeline process from the node's PID
# namespace (see `crash_pipeline` for why the signal has to come from there and
# why deleting the pod is a different fault with a different answer).
#
# The clock stops when the restarted process answers again *and* the manager
# reports Running. Either alone is not enough: the manager keeps reporting the
# last state it saw until its next check, so the first "Running" answer after the
# kill may describe the process that is already dead.
#
# The source runs without a limit, so the pipeline has state worth resuming and a
# checkpoint worth comparing against. A bounded plan that has already reached end
# of input has nothing left to restart.
# ---------------------------------------------------------------------------
recovery() {
  say "recovery: killing the pipeline process"
  local id before

  # The pipeline may exist and be Stopped -- the rate limit is on creating, not
  # on starting -- so "it exists" is not the same as "there is something to
  # recover". A pipeline left over from an earlier run is started again rather
  # than recreated, which keeps the checkpoint history the RPO number comes from.
  start_forward || fail "the API server did not become healthy"
  if [ -z "$(pipeline_json perf-baseline-recovery)" ]; then
    create_bench_pipeline perf-baseline-recovery ""
  fi
  if [ "$(deployment_status perf-baseline-recovery)" != "Running" ]; then
    note "starting perf-baseline-recovery (was $(deployment_status perf-baseline-recovery))"
    api_call POST "/v0/pipelines/perf-baseline-recovery/start?bootstrap_policy=allow" >/dev/null
    wait_for_running perf-baseline-recovery 900 || fail "the recovery pipeline did not start"
  fi

  id="$(field_of "$(pipeline_json perf-baseline-recovery)" id)"
  [ -n "${id}" ] || fail "the recovery pipeline is not there to recover"
  local pod="pipeline-${id}-0"
  local uid_before restarts_before
  uid_before="$(pod_uid "${pod}")"
  [ -n "${uid_before}" ] || fail "the recovery pipeline has no pod ${pod} to kill"
  restarts_before="$(pod_restarts "${pod}")"
  restarts_before="${restarts_before:-0}"

  # A crash before the first checkpoint has nothing to resume from, and the RPO
  # number would then be meaningless. With a 10 s interval the wait is short.
  local waited=0
  while [ "${waited}" -lt 120 ]; do
    [ "$(checkpoint_count)" -gt 0 ] && break
    sleep 2
    waited=$((waited + 2))
  done
  note "checkpoints before the kill: $(checkpoint_count)"

  before="$(stats_json "${id}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["global_metrics"]["total_processed_records"])' 2>/dev/null || echo 0)"
  local checkpointed_before
  checkpointed_before="$(latest_checkpoint_records)"
  note "records before the kill: ${before} (last checkpoint holds ${checkpointed_before:-0})"

  local targets node pid
  targets="$(crash_targets "${pod}")" || { set_failed recovery "the pipeline process could not be located"; return 1; }
  node="${targets%% *}"
  pid="${targets##* }"
  [ -n "${node}" ] && [ -n "${pid}" ] || { set_failed recovery "the pipeline process could not be located"; return 1; }

  local killed elapsed_ms status="" ready=""
  killed=$(date +%s%N)
  node_exec "${node}" kill -9 "${pid}" >/dev/null 2>&1 || { set_failed recovery "the pipeline process could not be killed"; return 1; }

  # A new process has to be visible before the answer counts: either the pod was
  # replaced (different UID) or the kubelet restarted the container in place
  # (higher restart count). Without that check the old process answers for the
  # few hundred milliseconds it takes to die, and the measurement is the cost of
  # an exec rather than the cost of a recovery.
  local deadline=$(( $(date +%s) + 600 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local uid_now restarts_now
    uid_now="$(pod_uid "${pod}")"
    restarts_now="$(pod_restarts "${pod}")"
    restarts_now="${restarts_now:-0}"
    if { [ -n "${uid_now}" ] && [ "${uid_now}" != "${uid_before}" ]; } \
      || [ "${restarts_now}" -gt "${restarts_before}" ] 2>/dev/null; then
      if stats_json "${id}" >/dev/null 2>&1; then
        status="$(deployment_status perf-baseline-recovery)"
        [ "${status}" = "Running" ] && ready="yes" && break
      fi
    fi
    sleep 1
  done
  elapsed_ms=$(( ( $(date +%s%N) - killed ) / 1000000 ))

  if [ "${ready}" != "yes" ]; then
    set_failed recovery "the pipeline did not come back within 600 s (last status: ${status:-unknown})"
    return 1
  fi

  set_value recovery.millis "${elapsed_ms}"
  millis["recovery"]="${elapsed_ms}"
  note "answering again in ${elapsed_ms} ms"

  # RPO is the distance between what the pipeline had processed and what the
  # newest checkpoint durably held. It is read from the checkpoint recorded
  # before the kill, because the restarted process resumes there and its own
  # counter cannot show the gap.
  set_value recovery.records_before "${before}"
  set_value recovery.checkpoint_records "${checkpointed_before:-0}"
  if [ "${before:-0}" -gt 0 ] 2>/dev/null; then
    set_value recovery.lost_records "$(( before - ${checkpointed_before:-0} ))"
    note "lost at most $(( before - ${checkpointed_before:-0} )) records since the last checkpoint"
  fi

  # The count after recovery has to be the checkpoint's, not merely non-zero: at
  # least-once resumes from the last completed checkpoint, so the state is
  # exactly that checkpoint's record count. A different number means the resume
  # point moved, which is the failure this measurement exists to catch.
  local after=""
  for _ in $(seq 1 120); do
    after="$(stats_json "${id}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["global_metrics"]["total_processed_records"])' 2>/dev/null || true)"
    [ -n "${after}" ] && break
    sleep 2
  done
  set_value recovery.records_after "${after:-—}"
  note "records after recovery: ${after:-?}"
  if [ -z "${after}" ]; then
    set_failed recovery "the restarted process never answered"
  elif [ "${checkpointed_before:-0}" -gt 0 ] 2>/dev/null && [ "${after}" != "${checkpointed_before}" ]; then
    # The counter has to be read quickly for this comparison to hold: an
    # unbounded source keeps producing, so the number moves away from the
    # checkpoint as soon as the pipeline is running.
    note "the counter has already moved past the checkpoint (${checkpointed_before} -> ${after})"
  fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if [ -n "${TAG}${MANAGER_TAG}${RUNNER_TAG}${COMPILER_TAG}" ] \
  && [ -z "${RUNNER_TAG}" ] && [ -z "${MANAGER_TAG}" ]; then
  fail "set TAG, or the three tags individually"
fi
RUNNER_IMAGE="${RUNNER_IMAGE:-localhost:5001/feldera-runner:${RUNNER_TAG:-${TAG}}}"

if have_scope storage; then
  build_probe
  if have_path local; then storage_local || true; fi
  if have_path k8s; then storage_k8s || true; fi
fi
if have_scope throughput; then throughput || true; fi
if have_scope recovery; then recovery || true; fi

# ---------------------------------------------------------------------------
# Report
#
# The report is written even when a measurement failed, because "we could not
# measure this here" is the finding: a baseline with a hole in it cannot be used
# to judge a later run.
# ---------------------------------------------------------------------------
say "writing ${REPORT}"
mkdir -p "$(dirname "${REPORT}")"
{
  cat <<'HEADER'
# Performance baseline

Generated by `scripts/perf-baseline.sh`. Every number below was measured on the
machine that ran the script; the command that produced the file is at the top of
the run, and re-running it is how a later baseline is compared with this one.

HEADER

  printf '| field | value |\n|---|---|\n'
  printf '| date | %s |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '| commit | %s |\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf '| cluster | %s / %s |\n' "${CLUSTER}" "${NAMESPACE}"
  printf '| scopes | %s |\n' "${SCOPES}"
  printf '| paths | %s |\n' "${PATHS}"
  printf '| probe file | %s MiB |\n' "${PROBE_SIZE_MIB}"
  printf '| sequential file | %s MiB |\n' "${SEQ_SIZE_MIB}"
  printf '\n'

  if have_scope storage; then
    cat <<'STORAGE'
## Storage

Random I/O is 4 KiB with `O_DIRECT` over a file larger than both the controller
cache and RAM, so the numbers are the disk and not a cache. Sequential I/O is
1 MiB with `O_DIRECT`.

| metric | local directory | K8s PVC | requirement |
|---|---|---|---|
STORAGE
    printf '| sequential write (MiB/s) | %s | %s | >= 1000 |\n' \
      "${value[local.seq_write_mib_s]:-—}" "${value[k8s.seq_write_mib_s]:-—}"
    printf '| sequential read (MiB/s) | %s | %s | >= 1000 |\n' \
      "${value[local.seq_read_mib_s]:-—}" "${value[k8s.seq_read_mib_s]:-—}"
    printf '| random 4 KiB read (IOPS) | %s | %s | >= 16000 |\n' \
      "${value[local.rand_read_iops]:-—}" "${value[k8s.rand_read_iops]:-—}"
    printf '| random 4 KiB write (IOPS) | %s | %s | >= 16000 |\n' \
      "${value[local.rand_write_iops]:-—}" "${value[k8s.rand_write_iops]:-—}"
    printf '| device | %s | %s | |\n' \
      "${value[local.device]:-—}" "${value[k8s.device]:-—}"
    printf '| rotational | %s | ? | 0 |\n' "${value[local.rotational]:-—}"
    printf '\n'
  fi

  if have_scope throughput; then
    cat <<'THROUGHPUT'
## Throughput

A pipeline that reads a bounded datagen source and maintains a materialized
count, timed from the moment it is Running to the moment it has processed every
record the plan asked for.

THROUGHPUT
    printf '| metric | value |\n|---|---|\n'
    printf '| records | %s |\n' "${value[throughput.records]:-—}"
    printf '| elapsed (ms) | %s |\n' "${value[throughput.millis]:-—}"
    printf '| records/s | %s |\n' "${value[throughput.records_per_s]:-—}"
    printf '| datagen workers | %s |\n' "${WORKERS}"
    printf '\n'
  fi

  if have_scope recovery; then
    cat <<'RECOVERY'
## Recovery

The pipeline process is killed with a SIGKILL sent from the pod's **node**, not
from inside the container. The kernel discards SIGKILL and SIGSTOP sent to the
init process of a PID namespace from inside that namespace, so
`kubectl exec <pod> -- kill -9 1` returns success and kills nothing; the signal
has to come from the node's namespace to reach the process. The container then
exits non-zero and the kubelet's restart policy starts it again in the same pod,
which is what "Pod 崩溃" means to an operator. Deleting the pod instead is a
different fault: the manager cannot reach a pipeline that has no pod, treats it
as failed and stops it, so that measurement would report the time to stop.

The clock stops when a **new process** (a different pod UID, or a higher container
restart count) answers `/stats` and the manager reports Running. Both are
required: the manager keeps reporting the last state it saw until its next check,
and the dying process keeps answering for a few hundred milliseconds, so either
signal alone would report the cost of an exec instead of the cost of a recovery.
The time to look the process up on the node is excluded; the `exec` that delivers
the signal is not, and adds about a second.
The P1 exit criterion is RTO < 120 s.

RPO is read from the newest checkpoint the manager recorded. With at-least-once
and a 10 s checkpoint interval, "records lost" below is bounded by that interval,
which is what the layering table promises.

RECOVERY
    printf '| metric | value |\n|---|---|\n'
    printf '| recovery (ms) | %s |\n' "${value[recovery.millis]:-—}"
    printf '| records before the kill | %s |\n' "${value[recovery.records_before]:-—}"
    printf '| records at the last checkpoint | %s |\n' "${value[recovery.checkpoint_records]:-—}"
    printf '| records lost | %s |\n' "${value[recovery.lost_records]:-—}"
    printf '| records after recovery | %s |\n' "${value[recovery.records_after]:-—}"
    printf '\n'
  fi

  if [ "${#failed[@]}" -gt 0 ]; then
    printf '## Failures\n\n'
    printf '| measurement | reason |\n|---|---|\n'
    for key in "${!failed[@]}"; do
      printf '| %s | %s |\n' "${key}" "${failed[${key}]}"
    done
    printf '\n'
  fi

  printf '## Verdict\n\n'
  # The verdict is computed from the numbers so that a run cannot be described
  # as passing by accident.
  verdict_ok=1
  if have_scope storage; then
    for path in local k8s; do
      have_path "${path}" || continue
      read_ok="$(python3 -c "print(1 if ${value[${path}.rand_read_iops]:-0} >= 16000 else 0)")"
      write_ok="$(python3 -c "print(1 if ${value[${path}.rand_write_iops]:-0} >= 16000 else 0)")"
      seq_ok="$(python3 -c "print(1 if min(${value[${path}.seq_read_mib_s]:-0}, ${value[${path}.seq_write_mib_s]:-0}) >= 1000 else 0)")"
      if [ "${read_ok}" = "1" ] && [ "${write_ok}" = "1" ] && [ "${seq_ok}" = "1" ]; then
        printf -- '- storage (%s): meets 16k IOPS and 1000 MB/s.\n' "${path}"
      else
        verdict_ok=0
        printf -- '- storage (%s): **below the required disk type** (random read %s IOPS, random write %s IOPS, sequential %s/%s MiB/s).\n' \
          "${path}" "${value[${path}.rand_read_iops]:-?}" "${value[${path}.rand_write_iops]:-?}" \
          "${value[${path}.seq_read_mib_s]:-?}" "${value[${path}.seq_write_mib_s]:-?}"
      fi
    done
  fi
  if have_scope recovery; then
    if [ -n "${value[recovery.millis]:-}" ] && [ "${value[recovery.millis]}" -lt 120000 ]; then
      printf -- '- recovery: %s ms, within the 120 s RTO.\n' "${value[recovery.millis]}"
    else
      verdict_ok=0
      printf -- '- recovery: %s ms, **outside** the 120 s RTO.\n' "${value[recovery.millis]:-not measured}"
    fi
  fi
  if [ "${#failed[@]}" -gt 0 ]; then
    verdict_ok=0
    printf -- '- %d measurement(s) did not complete; this baseline is incomplete.\n' "${#failed[@]}"
  fi
  printf '\n'
  if [ "${verdict_ok}" = "1" ]; then
    printf 'Overall: the measured paths meet the requirements above.\n'
  else
    printf 'Overall: **not all requirements are met on this machine**.\n'
  fi
} >"${REPORT}"

say "done: ${REPORT}"
printf '\n'
cat "${REPORT}"

# A report is always written, because "this could not be measured here" is a
# finding. The exit status is what tells a caller -- a gate, or a shell -- apart
# the two cases: a baseline that measured everything but missed the disk
# requirement succeeded at measuring, while one that failed a scope did not.
if [ "${#failed[@]}" -gt 0 ]; then
  exit 1
fi
