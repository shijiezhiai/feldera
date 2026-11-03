#!/usr/bin/env bash
#
# P1-031: the post-rebase gates, in one command, with a record of what happened.
#
# `docs/upstream-sync.md` §5 lists seven gates that a rebased branch must pass
# before it replaces a working branch. Until now they existed as prose: each was
# run by hand, in whatever order and whatever subset the person doing the rebase
# remembered, and the result lived in that person's scrollback. This script
# makes the list executable, and makes the run itself an artifact: it writes a
# timing table and a failure list to a file that the rehearsal record links to.
#
# Two scopes, because the gates differ by two orders of magnitude in cost:
#
#   --scope rebase-check   gates 1-4 plus the invariants (~10 min warm, no images)
#   --scope release        all seven (~hours cold: three images, a kind smoke)
#
# The default is rebase-check: it is the set the policy calls sufficient before a
# pilot, and the one a developer can afford after every upstream tag.
#
# Every gate runs even when an earlier one fails. A rebase that breaks the
# compile gate usually also breaks the unit tests, and knowing that the tests
# failed *because* the build was broken saves a round trip; stopping at the
# first red line hides the rest of the picture.
#
# Usage:
#   scripts/post-rebase-gates.sh                       # rebase-check scope
#   scripts/post-rebase-gates.sh --scope release
#   scripts/post-rebase-gates.sh --only 1,2,5          # a subset, by gate number
#   scripts/post-rebase-gates.sh --report out.md       # where the record goes
#   scripts/post-rebase-gates.sh --dry-run             # print the plan only
#
# Environment:
#   CARGO           cargo binary (default: `cargo +1.96.1` — the pin matters,
#                   see docs/upstream-sync.md §4)
#   CARGO_CONFIG    extra `--config` arguments for the online gates, so a
#                   registry mirror can be supplied without editing this file
#   REGISTRY        registry the images are pushed to (gate 5)
#   PUSH=0          build the images without pushing (gate 5)
#   K8S_SMOKE_ARGS  extra arguments for the kind smoke (gate 6)
#
# Exit status: 0 when every selected gate passed, 1 when any failed, 2 on a
# usage error. The report is written in both cases — a failed run is the one
# that most needs a record.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CARGO="${CARGO:-cargo +1.96.1}"

scope=rebase-check
only=""
report=""
dry_run=0
report_given=0

usage() {
  cat >&2 <<'EOF'
usage: scripts/post-rebase-gates.sh [options]

  --scope rebase-check|release   which gate set to run (default: rebase-check)
  --only 1,2,5                   run only these gate numbers, in this order
  --report <file>                write the record here
                                 (default: design/rebase-gates-<date>-<sha>.md)
  --dry-run                      print what would run and exit
  -h, --help                     this message

Gates (docs/upstream-sync.md §5):
  1 lockfile resolves      2 workspace compiles     3 manager unit tests
  4 FT e2e (local)         5 three images           6 kind smoke
  7 enterprise print
EOF
  exit 2
}

while (( $# > 0 )); do
  case $1 in
    --scope)
      scope=${2:?--scope needs a value}
      shift 2
      ;;
    --only)
      only=${2:?--only needs a value}
      shift 2
      ;;
    --report)
      report=${2:?--report needs a path}
      report_given=1
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

case $scope in
  rebase-check | release) ;;
  *)
    echo "unknown scope: $scope (expected rebase-check or release)" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# The gate table. Order is the policy's order, and the expensive gates come
# last so a fast failure is a fast failure.
# ---------------------------------------------------------------------------

GATE_NUMBERS=(1 2 3 4 5 6 7)
GATE_NAMES=(
  "lockfile resolves"
  "workspace compiles"
  "manager unit tests"
  "FT e2e (local)"
  "three images"
  "kind smoke"
  "enterprise print"
)
# Which scope each gate belongs to: `both`, `rebase-check`, or `release`.
GATE_SCOPES=(both both both both release release release)
GATE_CATCHES=(
  "upstream moved a dependency to a source we cannot resolve"
  "API drift between upstream and our adapters"
  "behavioural drift in runner and config code"
  "the checkpoint/restore contract the platform layer relies on"
  "Dockerfile drift: paths, toolchain pins, base image"
  "chart and values drift against renamed settings"
  "the two stub crates no longer satisfy generated code"
)

selected=()
for n in "${GATE_NUMBERS[@]}"; do
  idx=$((n - 1))
  want=0
  if [[ -n $only ]]; then
    case ",$only," in
      *",$n,"*) want=1 ;;
    esac
  elif [[ ${GATE_SCOPES[$idx]} == both || ${GATE_SCOPES[$idx]} == $scope ]]; then
    want=1
  fi
  ((want)) && selected+=("$n")
done

if ((${#selected[@]} == 0)); then
  echo "no gates selected; check --only and --scope" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

declare -a RESULT_NUMBER=() RESULT_NAME=() RESULT_STATUS=() RESULT_SECONDS=() RESULT_DETAIL=()

run_started=$(date +%s)

if ((!report_given)); then
  sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
  report="design/rebase-gates-$(date +%Y-%m-%d)-$sha.md"
fi

step() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
gate_failed=0

# Run one gate: `gate <number> <command...>`. The command's output goes to a log
# file next to the report, so a failure can be read back without scrolling, and
# the report links to it.
gate() {
  local number=$1
  shift
  local idx=$((number - 1))
  local name=${GATE_NAMES[$idx]}
  local log="${TMPDIR:-/tmp}/rebase-gate-$number.log"
  local started finished status detail

  step "gate $number: $name"
  note "$*"
  started=$(date +%s)
  set +e
  ( "$@" ) >"$log" 2>&1
  status=$?
  set -e
  finished=$(date +%s)

  local seconds=$((finished - started))
  RESULT_NUMBER+=("$number")
  RESULT_NAME+=("$name")
  RESULT_SECONDS+=("$seconds")

  if ((status == 0)); then
    RESULT_STATUS+=("pass")
    RESULT_DETAIL+=("")
    note "pass in ${seconds}s"
  else
    RESULT_STATUS+=("FAIL")
    # The last few lines of a failing log are the ones that name the cause;
    # keeping them in the report is what makes the record useful a month later.
    detail=$(tail -n 6 "$log" | tr '\n' ' ' | sed 's/  */ /g')
    detail=${detail:0:400}
    RESULT_DETAIL+=("$detail")
    gate_failed=1
    note "FAIL after ${seconds}s; log: $log"
    tail -n 12 "$log" | sed 's/^/   | /' >&2
  fi
}

write_report() {
  local finished total
  finished=$(date +%s)
  total=$((finished - run_started))
  {
    printf '# Post-rebase gates: %s on `%s`\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [[ -n $only ]]; then
      printf 'Gates `%s`, selected with `--only`' "$only"
    else
      printf 'Scope `%s`' "$scope"
    fi
    printf ', produced by `scripts/post-rebase-gates.sh` (P1-031).\n\n'
    printf 'The gate list is `docs/upstream-sync.md` §5; this section is the record of one run.\n\n'
    printf '| # | Gate | Result | Seconds |\n| --- | --- | --- | --- |\n'
    local i
    for i in "${!RESULT_NUMBER[@]}"; do
      printf '| %s | %s | %s | %s |\n' \
        "${RESULT_NUMBER[$i]}" "${RESULT_NAME[$i]}" "${RESULT_STATUS[$i]}" "${RESULT_SECONDS[$i]}"
    done
    printf '| | **total** | | **%s** |\n\n' "$total"

    local failed=0
    for i in "${!RESULT_STATUS[@]}"; do
      [[ ${RESULT_STATUS[$i]} == pass ]] || failed=$((failed + 1))
    done
    if ((failed == 0)); then
      printf 'Every selected gate passed.\n'
    else
      printf '## Failures\n\n'
      for i in "${!RESULT_STATUS[@]}"; do
        [[ ${RESULT_STATUS[$i]} == pass ]] && continue
        printf '### Gate %s: %s\n\n' "${RESULT_NUMBER[$i]}" "${RESULT_NAME[$i]}"
        printf '```\n%s\n```\n\n' "${RESULT_DETAIL[$i]}"
      done
    fi
  } >"$report"
  printf '\nwrote %s\n' "$report"
}

# The report is written even when a gate aborts the script unexpectedly. A dry
# run has nothing to record, so it exits before this is installed.
if ((!dry_run)); then
  trap 'write_report' EXIT
fi

# ---------------------------------------------------------------------------
# Invariants: cheap checks from §4 that no gate above performs
# ---------------------------------------------------------------------------
#
# These are not in §5 because they are not about compiling anything; they are
# about the rebase having been *completed* correctly. Each one has caught a real
# mistake: a migration number reused from upstream, a negation line lost in a
# .gitignore merge, a lockfile left on our side.

invariants() {
  local problems=0

  step "invariants (§4)"

  # The lock must be on the upstream version plus our two members, not on our
  # own older lock: see §4 "the two-sided dance".
  if git diff --quiet HEAD -- Cargo.lock 2>/dev/null; then
    note "Cargo.lock is committed and quiet"
  else
    note "FAIL Cargo.lock has uncommitted changes"
    problems=$((problems + 1))
  fi

  # A duplicate migration number makes Refinery abort on startup, and the
  # failure presents as a connection error.
  local dup
  dup=$(ls crates/pipeline-manager/migrations/V*.sql 2>/dev/null |
    sed 's|.*/V\([0-9]*\)__.*|\1|' | sort -n | uniq -d || true)
  if [[ -n $dup ]]; then
    note "FAIL duplicate migration version(s): $dup"
    problems=$((problems + 1))
  else
    note "migration versions are unique ($(ls crates/pipeline-manager/migrations/V*.sql | wc -l | tr -d ' ') files)"
  fi

  # Upstream ignores our stub crates; our negation lines must survive the merge.
  if git check-ignore -q crates/dbsp-enterprise/src/lib.rs 2>/dev/null; then
    note "FAIL crates/dbsp-enterprise is ignored (.gitignore negation lost)"
    problems=$((problems + 1))
  elif [[ $(git ls-files crates/dbsp-enterprise crates/sync-checkpoint | wc -l | tr -d ' ') -eq 0 ]]; then
    note "FAIL the stub crates are not tracked at all"
    problems=$((problems + 1))
  else
    note "the stub crates are tracked and not ignored"
  fi

  # Conflict markers that survived a hand resolution compile badly or, worse,
  # compile fine inside a string literal.
  # git grep exits 1 when nothing matches, and this script runs under set -e, so
  # the "clean" case must not be allowed to look like an abort.
  local markers
  markers=$(git grep -l -e '^<<<<<<< ' -e '^>>>>>>> ' -- crates deploy charts scripts docs 2>/dev/null | wc -l | tr -d ' ' || true)
  if [[ $markers -ne 0 ]]; then
    note "FAIL conflict markers in $markers file(s)"
    problems=$((problems + 1))
  else
    note "no conflict markers"
  fi

  if ((problems > 0)); then
    note "invariants: $problems problem(s)"
    gate_failed=1
  fi
}

# ---------------------------------------------------------------------------
# The gates
# ---------------------------------------------------------------------------

gate_1_lockfile() {
  # Online, always: upstream moves dependencies to new sources between
  # releases (v0.367.0 pinned deltalake to a git rev), so an offline resolve
  # only proves the cache is warm, not that the lock is right.
  # shellcheck disable=SC2086
  $CARGO metadata --format-version 1 ${CARGO_CONFIG:-} >/dev/null
}

gate_2_compiles() {
  # shellcheck disable=SC2086
  $CARGO check --all-targets ${CARGO_CONFIG:-}
}

gate_3_unit_tests() {
  # The database-backed tests contend for one embedded Postgres: at the default
  # thread count they overflow the stack and hang (see the rehearsal record).
  # shellcheck disable=SC2086
  $CARGO test -p pipeline-manager --lib -- --test-threads=4 --skip db_impl_behaves_like_model
}

gate_4_ft_e2e() {
  # Opt-in upstream too: it builds the enterprise manager and compiles a
  # pipeline, which needs the SQL jar, a JDK 19+, and librdkafka.
  FELDERA_SELFHOSTED_ENTERPRISE_E2E=1 \
    UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/feldera-uv-cache}" \
    uv run --locked python -m pytest -n0 tests/platform/test_selfhosted_ft_e2e.py
}

gate_5_images() {
  # Builds and pushes the three images; PUSH=0 builds only.
  REGISTRY="${REGISTRY:-localhost:5001}" PUSH="${PUSH:-1}" deploy/build-images.sh
}

gate_6_kind_smoke() {
  # shellcheck disable=SC2086
  scripts/e2e-k8s-chart.sh ${K8S_SMOKE_ARGS:-}
}

gate_7_enterprise() {
  # The two stub crates stand in for the closed-source enterprise crates; a
  # pipeline compiled with the feature proves they still satisfy what the
  # compiler generates.
  # shellcheck disable=SC2086
  $CARGO build -p pipeline-manager --features feldera-enterprise ${CARGO_CONFIG:-}
}

gate_command() {
  case $1 in
    1) echo "gate_1_lockfile" ;;
    2) echo "gate_2_compiles" ;;
    3) echo "gate_3_unit_tests" ;;
    4) echo "gate_4_ft_e2e" ;;
    5) echo "gate_5_images" ;;
    6) echo "gate_6_kind_smoke" ;;
    7) echo "gate_7_enterprise" ;;
  esac
}

for n in "${selected[@]}"; do
  idx=$((n - 1))
  if ((dry_run)); then
    printf 'gate %s: %-20s [%s] catches: %s\n' \
      "$n" "${GATE_NAMES[$idx]}" "${GATE_SCOPES[$idx]}" "${GATE_CATCHES[$idx]}"
  fi
done
if ((dry_run)); then
  printf '\n(dry run: nothing executed, no report written)\n'
  exit 0
fi

invariants

for n in "${selected[@]}"; do
  gate "$n" "$(gate_command "$n")"
done

if ((gate_failed)); then
  printf '\nresult: FAILED\n' >&2
  exit 1
fi
printf '\nresult: every selected gate passed\n'
