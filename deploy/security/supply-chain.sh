#!/usr/bin/env bash
# P1-012: 镜像供应链工具链（签名 / 验签 / 漏洞扫描 / CVE 门禁）。
#
# 子命令：
#   keygen            生成自托管 cosign 密钥对（私钥不进 git，见 deploy/security/keys/）
#   sign  IMAGE...    cosign 签名（key-based，离线，不传 Rekor）
#   verify IMAGE...   cosign 验签；未签名/签名不匹配 -> 非零退出
#   scan  IMAGE...    trivy 扫描，报告写到 deploy/security/reports/<name>.json
#   gate  IMAGE...    扫描 + 按 allowlist 判定，未豁免的 CRITICAL/HIGH -> 非零退出
#   summary           打印已有报告的汇总表
#
# 环境变量：
#   REGISTRY               默认 localhost:5001
#   COSIGN_KEY             cosign 私钥路径，默认 deploy/security/keys/cosign.key
#   COSIGN_PASSWORD        私钥口令（sign 必填；不要写进仓库）
#   COSIGN_PUB             cosign 公钥路径，默认 deploy/security/cosign.pub
#   FAIL_ON                默认 "CRITICAL,HIGH"
#   ALLOWLIST              默认 deploy/security/vulnerability-allowlist.json
#   INSECURE_REGISTRY=1    本地 http 制品库，给 cosign 加 --allow-insecure-registry

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SEC_DIR="${REPO_ROOT}/deploy/security"
REGISTRY="${REGISTRY:-localhost:5001}"
COSIGN_KEY="${COSIGN_KEY:-${SEC_DIR}/keys/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-${SEC_DIR}/cosign.pub}"
FAIL_ON="${FAIL_ON:-CRITICAL,HIGH}"
ALLOWLIST="${ALLOWLIST:-${SEC_DIR}/vulnerability-allowlist.json}"

REPORTS_DIR="${SEC_DIR}/reports"

# trivy falls back to mirror.gcr.io when its default repository is slow, and in
# a network where mirror.gcr.io is unreachable that turns into a hard failure
# halfway through a scan. Pin both databases to ghcr.io; override the variables
# to point at an internal mirror instead.
export TRIVY_DB_REPOSITORY="${TRIVY_DB_REPOSITORY:-ghcr.io/aquasecurity/trivy-db}"
export TRIVY_JAVA_DB_REPOSITORY="${TRIVY_JAVA_DB_REPOSITORY:-ghcr.io/aquasecurity/trivy-java-db:1}"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "--- $*"; }

INSECURE_ARGS=()
if [ "${INSECURE_REGISTRY:-0}" = "1" ]; then
  INSECURE_ARGS=(--allow-insecure-registry)
fi

# cosign 的私钥口令只在签名时需要；不设时用空口令（仅限本地演示）。
require_cosign() { command -v cosign >/dev/null 2>&1 || die "cosign 未安装（见 design/p1-012-image-supply-chain.md 的安装一段）"; }
require_trivy() { command -v trivy >/dev/null 2>&1 || die "trivy 未安装（见 design/p1-012-image-supply-chain.md 的安装一段）"; }

image_to_report() {
  # feldera-manager:v1 -> feldera-manager-v1.json
  local image="$1"
  printf '%s\n' "${image}" | sed 's#[/:]#-#g' | sed 's#[^A-Za-z0-9._-]#_#g'
}

cmd_keygen() {
  require_cosign
  mkdir -p "${SEC_DIR}/keys"
  chmod 700 "${SEC_DIR}/keys"
  if [ -f "${COSIGN_KEY}" ]; then
    note "私钥已存在，跳过生成：${COSIGN_KEY}"
  else
    COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign generate-key-pair \
      --output-key-prefix "${SEC_DIR}/keys/cosign"
    chmod 600 "${SEC_DIR}/keys/cosign.key"
  fi
  cp "${SEC_DIR}/keys/cosign.pub" "${COSIGN_PUB}"
  note "公钥已复制到 ${COSIGN_PUB}（这个文件要提交）"
}

cmd_sign() {
  require_cosign
  [ -f "${COSIGN_KEY}" ] || die "找不到私钥 ${COSIGN_KEY}，先跑 supply-chain.sh keygen"
  [ -f "${COSIGN_PUB}" ] || die "找不到公钥 ${COSIGN_PUB}"
  [ "$#" -gt 0 ] || die "用法：supply-chain.sh sign IMAGE..."
  for image in "$@"; do
    note "签名 ${image}"
    # --tlog-upload=false：自托管环境没有 Rekor，签名留在制品库里由公钥验证。
    COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign --yes \
      --key "${COSIGN_KEY}" --tlog-upload=false "${INSECURE_ARGS[@]}" "${image}"
  done
}

cmd_verify() {
  require_cosign
  [ -f "${COSIGN_PUB}" ] || die "找不到公钥 ${COSIGN_PUB}"
  [ "$#" -gt 0 ] || die "用法：supply-chain.sh verify IMAGE..."
  local failed=0
  for image in "$@"; do
    if cosign verify --key "${COSIGN_PUB}" --insecure-ignore-tlog=true \
        "${INSECURE_ARGS[@]}" "${image}" >/dev/null 2>&1; then
      note "OK      ${image}（签名有效）"
    else
      note "REJECT  ${image}（未签名或签名不匹配）"
      failed=1
    fi
  done
  return "${failed}"
}

cmd_scan() {
  require_trivy
  [ "$#" -gt 0 ] || die "用法：supply-chain.sh scan IMAGE..."
  mkdir -p "${REPORTS_DIR}"
  for image in "$@"; do
    local report="${REPORTS_DIR}/$(image_to_report "${image}").json"
    note "扫描 ${image} -> ${report}"
    trivy image --quiet --scanners vuln --format json --output "${report}" \
      --severity "${FAIL_ON}" --timeout 20m "${image}"
  done
}

cmd_gate() {
  require_trivy
  [ "$#" -gt 0 ] || die "用法：supply-chain.sh gate IMAGE..."
  cmd_scan "$@"
  local reports=()
  for image in "$@"; do
    reports+=("${REPORTS_DIR}/$(image_to_report "${image}").json")
  done
  python3 "${SEC_DIR}/gate.py" \
    --allowlist "${ALLOWLIST}" --fail-on "${FAIL_ON}" "${reports[@]}"
}

cmd_summary() {
  python3 "${SEC_DIR}/gate.py" --allowlist "${ALLOWLIST}" --fail-on "${FAIL_ON}" \
    --summary "${REPORTS_DIR}"/*.json 2>/dev/null || true
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    keygen)  cmd_keygen "$@" ;;
    sign)    cmd_sign "$@" ;;
    verify)  cmd_verify "$@" ;;
    scan)    cmd_scan "$@" ;;
    gate)    cmd_gate "$@" ;;
    summary) cmd_summary "$@" ;;
    *) die "用法：supply-chain.sh {keygen|sign|verify|scan|gate|summary} [IMAGE...]" ;;
  esac
}

main "$@"
