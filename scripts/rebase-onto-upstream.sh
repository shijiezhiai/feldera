#!/usr/bin/env bash
# Rebase the fork's commits onto an upstream tag, then refresh the derived state.
#
# Steps (docs/upstream-sync.md §3):
#   1. refuse a dirty tree;
#   2. make sure the tag exists locally (fetch tags if not);
#   3. create sync/<tag> from <from> (default: the current branch);
#   4. replay our commits, auto-resolving a Cargo.lock stop (upstream marks the lock
#      merge=binary, so git cannot merge it);
#   5. apply the patch stack (patches/, see patches/README.md);
#   6. put the lockfile back on the upstream version and regenerate it once, online.
# Any conflict other than Cargo.lock stops the run with the file list and exit status 2.
#
# Usage:
#   scripts/rebase-onto-upstream.sh <upstream-tag> [--from <ref>] [--skip-lock]
#
# The rebase result is left checked out on sync/<tag>; the verification gates in §5 of the policy
# document have not been run when the script exits successfully.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/rebase-onto-upstream.sh <upstream-tag> [--from <ref>] [--skip-lock]

  <upstream-tag>  tag to replay our commits onto, e.g. v0.367.0
  --from <ref>    ref holding our commits (default: HEAD)
  --skip-lock     do not regenerate Cargo.lock (it then stays on the upstream version)
EOF
  exit 1
}

tag=${1:-}
[[ -n $tag && $tag != -* ]] || usage
shift

from=HEAD
skip_lock=0
while (( $# > 0 )); do
  case $1 in
    --from)
      from=${2:?--from needs a ref}
      shift 2
      ;;
    --skip-lock)
      skip_lock=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "working tree is not clean; commit or stash first" >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  echo "tag $tag not found locally, fetching tags from origin" >&2
  git fetch origin --tags
fi

target=$(git rev-parse --verify --quiet "$tag^{commit}") || {
  echo "cannot resolve $tag to a commit" >&2
  exit 1
}
from_sha=$(git rev-parse --verify --quiet "$from^{commit}") || {
  echo "cannot resolve $from to a commit" >&2
  exit 1
}

branch="sync/$tag"
if git show-ref --verify --quiet "refs/heads/$branch"; then
  echo "branch $branch already exists; delete it or choose another target" >&2
  exit 1
fi

ours=$(git rev-list --count "$target".."$from_sha")
drift=$(git rev-list --count "$from_sha".."$target")
echo "replaying $ours commit(s) from $from_sha onto $tag ($drift upstream commit(s) of drift)"

git switch -c "$branch" "$from_sha"

# git stops the rebase on each conflict; resolve the mechanical one (Cargo.lock) and continue, any
# other conflict is a human decision.
#
# The lock is resolved to OUR side (--theirs during a rebase, where HEAD is the upstream commit).
# That keeps our own commit chain self-consistent, so only the first commit that touches the lock
# conflicts instead of every one of them. Step 6 then resets the lock to the upstream version and
# regenerates it, which is the only correct end state.
git_dir=$(git rev-parse --git-dir)
set +e
git rebase "$target"
set -e
for (( i = 0; i < 500; i++ )); do
  [[ -d $git_dir/rebase-merge || -d $git_dir/rebase-apply ]] || break
  conflicted=$(git diff --name-only --diff-filter=U)
  if [[ -z $conflicted ]]; then
    GIT_EDITOR=true git rebase --continue || true
    continue
  fi
  if [[ $conflicted == "Cargo.lock" ]]; then
    echo "Cargo.lock: keeping our side (merge=binary), reset to upstream before the lock gate"
    git checkout --theirs -- Cargo.lock
    git add Cargo.lock
    GIT_EDITOR=true git rebase --continue || true
    continue
  fi
  echo "conflict needs a human (exit 2):" >&2
  printf '%s\n' "$conflicted" | sed 's/^/  /' >&2
  exit 2
done

if [[ -d $git_dir/rebase-merge || -d $git_dir/rebase-apply ]]; then
  echo "rebase still in progress after 500 steps; resolve it by hand" >&2
  exit 1
fi

echo "rebase done on $branch"

if compgen -G "$repo_root/patches/[0-9][0-9][0-9][0-9]-*.patch" >/dev/null; then
  "$repo_root/scripts/apply-patches.sh"
else
  echo "patch stack is empty, nothing to re-apply"
fi

# The lock must end on the upstream version plus our workspace members: upstream moves dependencies
# between releases (v0.367.0 moved deltalake to a git source), so our older lock is not "almost
# right", it is wrong.
git checkout "$target" -- Cargo.lock

if (( skip_lock == 1 )); then
  echo "Cargo.lock reset to $tag and left uncommitted (--skip-lock)"
  echo "run 'cargo metadata --format-version 1', then commit the lock, before the compile gate"
  exit 0
fi

echo "refreshing Cargo.lock (needs network)"
if ! cargo metadata --format-version 1 > /dev/null; then
  echo "warning: Cargo.lock refresh failed; it is on the upstream version but lacks our workspace" >&2
  echo "         members. Fix the network or the registry mirror, run" >&2
  echo "         'cargo metadata --format-version 1', then commit the lock." >&2
  exit 0
fi

if ! git diff --quiet -- Cargo.lock; then
  git add Cargo.lock
  git commit --quiet -m "chore(lock): refresh Cargo.lock after rebase onto $tag"
  echo "committed the refreshed Cargo.lock"
fi

echo "rebase complete: $branch is ready for the gates in docs/upstream-sync.md §5"
