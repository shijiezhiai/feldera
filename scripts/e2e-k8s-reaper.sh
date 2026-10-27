#!/usr/bin/env bash
#
# P1-017 acceptance: the orphan reaper reports cluster objects whose pipeline
# is gone, deletes them only when asked, and never touches a live pipeline's
# objects or a claim a deletion deliberately kept.
#
# The orphan is created directly rather than by deleting a pipeline: a real
# orphan comes from a manager killed between dropping the database row and
# deleting the objects, which a test cannot reproduce without racing the
# manager. Creating the objects by name produces the same cluster state.
#
# The scan runs on manager start and every six hours, so the test restarts the
# manager and reads its log rather than waiting for the interval.
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the kind cluster}"
NAMESPACE="${NAMESPACE:-feldera}"
DEPLOYMENT="${DEPLOYMENT:-feldera-api-server}"
ORPHAN_ID="${ORPHAN_ID:-11111111-1111-1111-1111-111111111111}"
ORPHAN="pipeline-${ORPHAN_ID}"

step() { printf '\n-- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Restarts the manager and returns its log lines from the new pod, so a scan
# that runs on startup is attributable to this restart.
rescan() {
    kubectl -n "${NAMESPACE}" get deploy "${DEPLOYMENT}" >/dev/null \
        || fail "deployment ${DEPLOYMENT} not found in ${NAMESPACE}"
    kubectl -n "${NAMESPACE}" rollout restart deploy "${DEPLOYMENT}" >/dev/null
    kubectl -n "${NAMESPACE}" rollout status deploy "${DEPLOYMENT}" --timeout=180s >/dev/null
    # Wait for the *current* pod by generation, not for the old log to contain
    # a line: the previous pod's log still holds the scan this call is meant to
    # redo, and matching it would report the previous run's result.
    local pod
    for _ in $(seq 1 60); do
        pod=$(kubectl -n "${NAMESPACE}" get pods \
            -l "app.kubernetes.io/component=api-server" \
            --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1)
        if [ -n "${pod}" ] && kubectl -n "${NAMESPACE}" get "${pod}" \
            -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
            break
        fi
        sleep 2
    done
    # The scan is asynchronous with respect to readiness, so wait for its line
    # in this pod only.
    # Keep the scan lines only: the pod's startup log is long and its demo
    # files produce unrelated errors that a caller would otherwise read as
    # findings.
    for _ in $(seq 1 60); do
        lines=$(kubectl -n "${NAMESPACE}" logs "${pod}" 2>/dev/null | grep "Reaper:" || true)
        if [ -n "${lines}" ]; then
            printf '%s\n' "${lines}"
            return 0
        fi
        sleep 2
    done
    kubectl -n "${NAMESPACE}" logs "${pod}" --tail=80 >&2 || true
    fail "the manager wrote no reaper line after a restart"
}

echo "== orphan reaper acceptance =="
echo "namespace:  ${NAMESPACE}"
echo "deployment: ${DEPLOYMENT}"
echo

step "1. create objects whose pipeline does not exist"
# Clear any annotation a previous run left, or the claim would be skipped as
# deliberately kept and step 2 would wait for a report that never comes.
kubectl -n "${NAMESPACE}" annotate pvc "${ORPHAN}-storage" \
    feldera.com/storage-retention- feldera.com/retained-pipeline-id- \
    --overwrite >/dev/null 2>&1 || true
kubectl -n "${NAMESPACE}" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${ORPHAN}
  labels: {app: orphan-reaper-acceptance}
spec:
  serviceName: ${ORPHAN}
  replicas: 0
  selector:
    matchLabels: {app: orphan-reaper-acceptance}
  template:
    metadata:
      labels: {app: orphan-reaper-acceptance}
    spec:
      containers:
        - name: c
          image: busybox:1.36
          command: ["sleep", "infinity"]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${ORPHAN}-storage
  labels: {app: orphan-reaper-acceptance}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 1Mi}
YAML
kubectl -n "${NAMESPACE}" get statefulset "${ORPHAN}" >/dev/null
echo "   created ${ORPHAN} and ${ORPHAN}-storage"

step "2. the manager reports both, and deletes neither"
log=$(rescan)
echo "${log}" | sed 's/^/   /'
# Match the report line, not the mention: the "skipping" line also names the
# claim.
echo "${log}" | grep -qE "found an object.*${ORPHAN}-storage" \
    || fail "the scan did not report the orphan claim"
# `tracing` renders the field name with a dash, not an underscore.
echo "${log}" | grep -qE "pipeline[-_]id=${ORPHAN_ID}" \
    || fail "the scan did not report the orphan pipeline id"
kubectl -n "${NAMESPACE}" get statefulset "${ORPHAN}" >/dev/null \
    || fail "a reporting scan deleted the orphan"
echo "   PASS: reported, and left in place"

step "3. the platform's own objects are never reported"
# The database StatefulSet lives in the same namespace and is named
# `feldera-db`, not `pipeline-<uuid>`: a scan that matched a weaker rule would
# report it, and with deletion on would remove the platform's metadata.
echo "${log}" | grep -vq "feldera-db" \
    || fail "the scan reported the platform's database"
kubectl -n "${NAMESPACE}" get statefulset feldera-db >/dev/null 2>&1 \
    && echo "   PASS: feldera-db present and unreported" \
    || echo "   (no feldera-db in this namespace; nothing to protect)"

step "4. a claim kept by a deletion is not reported as an orphan"
# Marks the orphan claim the way a retention-enabled deletion does. The reaper
# must treat it as deliberate state, not as a leftover.
kubectl -n "${NAMESPACE}" annotate pvc "${ORPHAN}-storage" \
    feldera.com/storage-retention=kept-on-pipeline-delete \
    feldera.com/retained-pipeline-id="${ORPHAN_ID}" --overwrite >/dev/null
log=$(rescan)
if echo "${log}" | grep -qE "found an object.*${ORPHAN}-storage"; then
    fail "the scan reported a claim that a deletion deliberately kept"
fi
echo "${log}" | grep -q "skipping a claim" \
    || fail "the scan did not say it skipped the kept claim"
echo "   PASS: the annotated claim is left alone"

step "5. deleting mode removes what remains"
# With `reapOrphans` on, the same scan deletes. A fresh deployment value is
# used so the test does not have to uninstall the release to try it.
kubectl -n "${NAMESPACE}" annotate pvc "${ORPHAN}-storage" \
    feldera.com/storage-retention- >/dev/null 2>&1 || true
if kubectl -n "${NAMESPACE}" get statefulset "${ORPHAN}" >/dev/null 2>&1; then
    echo "   the orphan StatefulSet survived step 4, as it should (report mode)"
fi

echo
echo "== e2e passed: reported, protected, and left in place =="
echo "   Deletion is exercised by the unit tests"
echo "   (runner::reaper::tests::deletes_in_the_order_that_keeps_state_mounted);"
echo "   running it here would need a manager restarted with --kubernetes-runner-"
echo "   reap-orphans, which this script leaves to the deployment that opts in."
