#!/usr/bin/env bash
# Start (or restart) the local image registry the bili builds push to.
#
#   deploy/registry.sh              # start it if it is not running
#   deploy/registry.sh --recreate   # throw the container away and start it again
#   deploy/registry.sh --status     # report what is running and where it keeps data
#   deploy/registry.sh --self-test  # prove that --recreate keeps the images
#
# Why a script rather than the `docker run` inside build-images.sh: that one
# removes the container and starts a new one *without* a volume, so the images it
# held live in the container's writable layer and disappear with it. Everything
# pushed there is re-pullable, but a `--prune-tags` run or a `kind load` that
# depends on the local tag would then find nothing. This script attaches a named
# volume, so a container can be replaced without losing a byte.
#
# Deletes need REGISTRY_STORAGE_DELETE_ENABLED: without it the registry answers
# 405 to DELETE and the only way to drop a bad tag is to wipe the volume, which
# takes the good images with it. That is exactly the situation this script
# exists to avoid.

set -euo pipefail

CONTAINER="${REGISTRY_CONTAINER:-bili-registry}"
# 5001 rather than 5000: macOS's AirPlay receiver listens on *:5000 and the bind
# fails. See the note in build-images.sh.
PORT="${REGISTRY_PORT:-5001}"
VOLUME="${REGISTRY_VOLUME:-bili-registry-data}"
IMAGE="${REGISTRY_IMAGE:-registry:2}"

step() { printf '\n-- %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }

registry_url() { printf 'http://localhost:%s' "${PORT}"; }

healthy() {
  curl -fsS "$(registry_url)/v2/_catalog" >/dev/null 2>&1
}

recreate() {
  if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    step "removing the existing container"
    # --volumes would delete an anonymous volume, but ours is named and passed
    # with -v here, so docker leaves it alone.
    docker rm -f "${CONTAINER}" >/dev/null
    info "removed ${CONTAINER}"
  fi

  if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    step "pulling ${IMAGE}"
    docker pull "${IMAGE}"
  fi

  step "starting ${CONTAINER} on port ${PORT} with volume ${VOLUME}"
  docker run -d \
    --name "${CONTAINER}" \
    -p "${PORT}:5000" \
    --restart=always \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -v "${VOLUME}:/var/lib/registry" \
    "${IMAGE}" >/dev/null

  for _ in $(seq 1 30); do
    if healthy; then
      info "registry is serving at $(registry_url)"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: the registry did not answer within 30s; check 'docker logs ${CONTAINER}'" >&2
  return 1
}

status() {
  if ! docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    info "${CONTAINER} does not exist"
    return 1
  fi
  docker inspect "${CONTAINER}" --format \
    '   running={{.State.Running}} started={{.State.StartedAt}} image={{.Config.Image}}'
  docker inspect "${CONTAINER}" --format '   env={{json .Config.Env}}'
  docker inspect "${CONTAINER}" --format '{{range .Mounts}}   mount {{.Type}} {{.Name}}{{if not .Name}}{{.Source}}{{end}} -> {{.Destination}}{{end}}'
  if healthy; then
    info "serving at $(registry_url)"
    info "repositories: $(curl -fsS "$(registry_url)/v2/_catalog")"
  else
    info "not answering at $(registry_url)"
    return 1
  fi
}

case "${1:-}" in
  --status)
    status
    ;;
  --recreate)
    recreate
    ;;
  --self-test)
    exec "$(dirname "${BASH_SOURCE[0]}")/registry-selftest.sh"
    ;;
  "")
    if healthy; then
      info "already serving at $(registry_url)"
      status
    else
      recreate
    fi
    ;;
  *)
    echo "usage: $(basename "$0") [--status|--recreate|--self-test]" >&2
    exit 2
    ;;
esac
