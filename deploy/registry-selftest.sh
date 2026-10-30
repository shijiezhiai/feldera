#!/usr/bin/env bash
# Self-test for deploy/registry.sh: replacing the container must not lose the
# images the registry holds.
#
#   deploy/registry.sh --self-test
#
# The test pushes a tiny image, recreates the container, and pulls it back. A
# registry whose data lives in the container's writable layer passes the first
# half and fails the second -- which is the failure this script exists to
# prevent, and the one that cannot be noticed until a rebuild is redone.
#
# It runs against the real container and volume, so it only pushes and deletes
# its own probe image (name `registry-selftest`).

set -euo pipefail

CONTAINER="${REGISTRY_CONTAINER:-bili-registry}"
PORT="${REGISTRY_PORT:-5001}"
VOLUME="${REGISTRY_VOLUME:-bili-registry-data}"
REGISTRY="localhost:${PORT}"

step() { printf '\n-- %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

probe_tag="selftest-$$"

cleanup() {
  # Remove the manifest too, or the repository lingers in /v2/_catalog and every
  # later catalog listing shows a repository the test created and abandoned.
  local digest
  digest="$(curl -fsSI -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://${REGISTRY}/v2/registry-selftest/manifests/${probe_tag}" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')"
  if [ -n "${digest}" ]; then
    curl -fsS -o /dev/null -X DELETE \
      "http://${REGISTRY}/v2/registry-selftest/manifests/${digest}" >/dev/null 2>&1 || true
  fi
  docker image rm "${REGISTRY}/registry-selftest:${probe_tag}" >/dev/null 2>&1 || true
  docker image rm "registry-selftest:${probe_tag}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "the registry answers"
curl -fsS "http://${REGISTRY}/v2/_catalog" >/dev/null || fail "no registry at ${REGISTRY}"

step "it runs with delete enabled"
docker inspect "${CONTAINER}" --format '{{json .Config.Env}}' \
  | grep -q 'REGISTRY_STORAGE_DELETE_ENABLED=true' \
  || fail "the container does not set REGISTRY_STORAGE_DELETE_ENABLED; --prune-tags will fail with 405"
info "delete is enabled"

step "it mounts a named volume, not the container's own layer"
mount="$(docker inspect "${CONTAINER}" --format '{{range .Mounts}}{{.Type}}:{{.Name}}{{end}}')"
[ "${mount}" = "volume:${VOLUME}" ] \
  || fail "expected a volume mount named ${VOLUME}, found '${mount}'. Without one, recreating the container discards every image it holds."
info "mounts volume ${VOLUME} at /var/lib/registry"

step "push a probe image"
# A manifest-only push keeps this fast: no layer has to be uploaded.
printf 'FROM scratch\nLABEL purpose=registry-selftest\n' > /tmp/registry-selftest.Dockerfile
docker build -q -t "registry-selftest:${probe_tag}" -f /tmp/registry-selftest.Dockerfile /tmp >/dev/null
docker tag "registry-selftest:${probe_tag}" "${REGISTRY}/registry-selftest:${probe_tag}"
docker push "${REGISTRY}/registry-selftest:${probe_tag}" >/dev/null
curl -fsS "http://${REGISTRY}/v2/registry-selftest/tags/list" | grep -q "${probe_tag}" \
  || fail "the probe image did not reach the registry"
info "pushed registry-selftest:${probe_tag}"

step "recreate the container"
"$(dirname "${BASH_SOURCE[0]}")/registry.sh" --recreate >/dev/null
info "container replaced"

step "the probe image is still there"
curl -fsS "http://${REGISTRY}/v2/registry-selftest/tags/list" | grep -q "${probe_tag}" \
  || fail "the probe image disappeared with the old container: the data is not in a volume"
info "it survived"

step "and it can still be pulled"
docker rmi "${REGISTRY}/registry-selftest:${probe_tag}" >/dev/null 2>&1 || true
docker pull "${REGISTRY}/registry-selftest:${probe_tag}" >/dev/null
info "pulled back"

printf '\nPASS: recreating the registry container keeps the images it holds\n'
