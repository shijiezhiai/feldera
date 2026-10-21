#!/usr/bin/env bash
# Apply, or dry-run, the fork's patch stack onto the current HEAD.
#
# Each patch is an edit to an upstream file that we carry instead of an ordinary commit; see
# docs/upstream-sync.md and patches/README.md. Patches are applied in file-name order with
# `git apply --3way`, so a partially merged result is left in the index for manual resolution.
#
# Usage:
#   scripts/apply-patches.sh [--check] [patch-dir]
#
#   --check     verify every patch applies, change nothing
#   patch-dir   defaults to <repo>/patches
#
# Exit status: 0 when every patch applied (or applies, with --check), 1 otherwise.

set -euo pipefail

check=0
if [[ ${1:-} == "--check" || ${1:-} == "-n" ]]; then
  check=1
  shift
fi

repo_root=$(git rev-parse --show-toplevel)
patch_dir=${1:-$repo_root/patches}

if [[ ! -d $patch_dir ]]; then
  echo "no patch directory at $patch_dir" >&2
  exit 1
fi

shopt -s nullglob
patches=("$patch_dir"/[0-9][0-9][0-9][0-9]-*.patch)

if (( ${#patches[@]} == 0 )); then
  echo "patch stack is empty ($patch_dir)"
  exit 0
fi

max_lines=2000
for patch in "${patches[@]}"; do
  name=$(basename "$patch")
  changed=$(grep -cE '^[+-]' "$patch" || true)
  if (( changed > max_lines )); then
    echo "warning: $name changes $changed lines (limit $max_lines, see docs/upstream-sync.md §2)" >&2
  fi

  if (( check == 1 )); then
    git apply --check --3way "$patch"
    echo "ok      $name ($changed lines)"
  else
    git apply --3way "$patch"
    echo "applied $name ($changed lines)"
  fi
done
