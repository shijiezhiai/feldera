#!/bin/bash
# P1-012: download the trivy Java index and seed the local trivy cache.
#
# The Java index is a 942 MiB OCI artifact on ghcr.io. trivy's own OCI client
# drops the connection part way through on this network ("stream error: stream
# ID 1; PROTOCOL_ERROR; received from peer") and every retry starts from zero,
# so a scan that needs the Java database either never finishes or downloads
# most of a gigabyte many times.
#
# The artifact blob advertises `Accept-Ranges: bytes`, so this script fetches it
# with curl and resumes across retries, then unpacks it into the directory that
# trivy reads (`$TRIVY_CACHE_DIR/java-db`). Once seeded, scans use
# `--skip-java-db-update` and never talk to the registry again.
#
# Usage: fetch-java-db.sh [TAG]     (default tag: 1)
set -euo pipefail

REPOSITORY="${TRIVY_JAVA_DB_REPOSITORY:-ghcr.io/aquasecurity/trivy-java-db}"
TAG="${1:-1}"
CACHE_DIR="${TRIVY_CACHE_DIR:-${HOME}/.cache/trivy}"
DEST="${CACHE_DIR}/java-db"
WORK="${CACHE_DIR}/downloads"
ARCHIVE="${WORK}/trivy-java-db.tar.gz"

registry="${REPOSITORY%%/*}"
repo="${REPOSITORY#*/}"

note() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# ghcr.io hands out anonymous pull tokens; they are short lived, so every
# retry fetches a fresh one.
token() {
  curl -fsS "https://${registry}/token?scope=repository:${repo}:pull&service=${registry}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

manifest_field() {
  curl -fsS -H "Authorization: Bearer $(token)" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "https://${registry}/v2/${repo}/manifests/${TAG}" |
    python3 -c "import json,sys; print(json.load(sys.stdin)['layers'][0]['$1'])"
}

digest=$(manifest_field digest)
size=$(manifest_field size)
[ -n "${digest}" ] && [ -n "${size}" ] || die "unable to read the manifest of ${REPOSITORY}:${TAG}"

mkdir -p "${WORK}" "${DEST}"
note "java index: ${REPOSITORY}:${TAG} ${digest} (${size} bytes)"

# Resume until the file has the size the manifest promised. A stalled transfer
# is aborted by --speed-limit/--speed-time and retried, which is what makes
# this work on a link that dies every few hundred megabytes.
attempt=0
while :; do
  have=$(stat -c %s "${ARCHIVE}" 2>/dev/null || echo 0)
  if [ "${have}" -ge "${size}" ]; then
    break
  fi
  attempt=$((attempt + 1))
  if [ "${attempt}" -gt 100 ]; then
    die "giving up after ${attempt} attempts at ${have}/${size} bytes"
  fi
  note "attempt ${attempt}: resuming at ${have}/${size}"
  curl -sS -L -C - --max-time 900 --speed-time 60 --speed-limit 8192 \
    -H "Authorization: Bearer $(token)" -o "${ARCHIVE}" \
    "https://${registry}/v2/${repo}/blobs/${digest}" || true
  sleep 3
done

have=$(stat -c %s "${ARCHIVE}")
[ "${have}" -eq "${size}" ] || die "size mismatch: ${have} != ${size}"

# The layer holds exactly the two files trivy expects in its java-db directory.
tar -xzf "${ARCHIVE}" -C "${DEST}" trivy-java.db metadata.json
note "seeded ${DEST}/trivy-java.db ($(stat -c %s "${DEST}/trivy-java.db") bytes)"
