#!/bin/sh
# Entrypoint of a pipeline pod started by the Kubernetes runner.
#
# The runner passes the pipeline's program arguments through; this script only
# fetches the program binary that the compiler service built (the URL is in
# FELDERA_PROGRAM_BINARY_URL, a short-lived endpoint of the compiler service)
# and then `exec`s it, so the pipeline process receives signals from the kubelet
# directly and can write its exit checkpoint on a graceful stop.
#
# The binary is cached in the work directory: the work volume survives container
# restarts within one pod, so a crash loop does not re-download the binary.
set -eu

if [ -z "${FELDERA_PROGRAM_BINARY_URL:-}" ]; then
  echo "error: FELDERA_PROGRAM_BINARY_URL is not set; the pipeline runner must pass the" >&2
  echo "       program binary URL of the compiler service" >&2
  exit 1
fi

work_dir="${FELDERA_WORK_DIR:-/var/feldera/work}"
binary="${work_dir}/pipeline"

if [ ! -x "${binary}" ]; then
  # Retry: the compiler service may still be starting, and a transient network
  # error should not fail an otherwise healthy deployment.
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 2 \
    --connect-timeout 10 \
    --max-time 600 \
    --output "${binary}.tmp" \
    "${FELDERA_PROGRAM_BINARY_URL}"
  chmod +x "${binary}.tmp"
  mv "${binary}.tmp" "${binary}"
fi

exec "${binary}" "$@"
