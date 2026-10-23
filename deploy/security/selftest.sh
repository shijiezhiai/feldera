#!/usr/bin/env bash
# P1-012 self-test: proves that both gates fail on a bad input.
#
#   1. signature gate  -- a signed image verifies, an unsigned one is rejected
#   2. CVE gate        -- a deliberately vulnerable image blocks, and an
#                         allowlist entry is what unblocks it (nothing else)
#
# Run it after `deploy/build-images.sh` pushed and signed the Feldera images:
#   REGISTRY=localhost:5001 deploy/security/selftest.sh
#
# It needs network access to pull the vulnerable reference image used by the
# CVE case; that image is intentionally *not* one of ours, because our own
# images should never be used to demonstrate a failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SEC_DIR="${REPO_ROOT}/deploy/security"
REGISTRY="${REGISTRY:-localhost:5001}"
TAG="${SIGNED_TAG:?set SIGNED_TAG to a pushed and signed image tag, e.g. v0.357.0-20-g7a5128651-bili.1}"
VULNERABLE_IMAGE="${VULNERABLE_IMAGE:-debian:9}"

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }
expected_failure() {
  local what="$1"
  shift
  if "$@" >/tmp/p1-012-selftest.log 2>&1; then
    echo "--- command unexpectedly succeeded: $*" >&2
    sed -n '1,20p' /tmp/p1-012-selftest.log >&2
    fail "${what}（本应被拦住，却通过了）"
  fi
  pass "${what}（被拦住，符合预期）"
}

export INSECURE_REGISTRY="${INSECURE_REGISTRY:-1}"

echo "=== 1. signature gate"
"${SEC_DIR}/supply-chain.sh" verify "${REGISTRY}/feldera-runner:${TAG}"
pass "已签名镜像验签"
expected_failure "未签名镜像被拒" \
  "${SEC_DIR}/supply-chain.sh" verify "${REGISTRY}/feldera-runner:unsigned-demo"

echo "=== 2. CVE gate"
expected_failure "故意有漏洞的镜像被 CVE 门禁拦住" \
  "${SEC_DIR}/supply-chain.sh" gate "${VULNERABLE_IMAGE}"

# The same report must pass once every blocking finding is allowlisted: that is
# the only knob the gate has, so it proves the allowlist path works and that
# nothing else is silently suppressing findings.
python3 - "${SEC_DIR}/reports" "${VULNERABLE_IMAGE}" <<'PY'
import json, os, re, sys

reports_dir, image = sys.argv[1], sys.argv[2]
name = re.sub(r"[^A-Za-z0-9._-]", "-", image.replace("/", "-").replace(":", "-"))
report_path = os.path.join(reports_dir, name + ".json")
report = json.load(open(report_path, encoding="utf-8"))
entries = []
for result in report.get("Results") or []:
    for finding in result.get("Vulnerabilities") or []:
        if finding.get("Severity", "").upper() in {"CRITICAL", "HIGH"}:
            entries.append({
                "id": finding["VulnerabilityID"],
                "image": image,
                "reason": "self-test: everything is allowlisted on purpose",
                "expires": "2999-12-31",
            })
json.dump(entries, open(os.path.join(reports_dir, "selftest-allowlist.json"), "w"), indent=2)
print(f"--- wrote {len(entries)} allowlist entries for {image}")
PY
ALLOWLIST="${SEC_DIR}/reports/selftest-allowlist.json" \
  "${SEC_DIR}/supply-chain.sh" gate "${VULNERABLE_IMAGE}" \
  || fail "allowlist 未生效（同一份报告在全部豁免后仍未通过）"
pass "全部豁免后 CVE 门禁放行"

echo "=== OK: both gates reject a bad input and admit a good one"
