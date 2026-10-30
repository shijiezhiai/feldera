#!/usr/bin/env bash
# P1-004: 一条命令构建并推送三张自建（bili）镜像：
#   feldera-manager / feldera-compiler / feldera-runner，标签 <ver>-bili.N
#
# 用法（仓库根目录）：
#   deploy/build-images.sh                     # 构建+推送+逐镜像清理
#   REGISTRY=reg.corp.example:5000 deploy/build-images.sh   # 推真内网制品库
#   PUSH=0 deploy/build-images.sh              # 只构建不推送
#   ONLY=runner deploy/build-images.sh         # 只重建一张（manager/compiler/runner）
#   BILI_CARGO_JOBS=4 deploy/build-images.sh   # manager 构建降并行（OOM 降级阶梯②）
#
# 版本约定：
#   ver = git describe --tags --always（如 v0.357.0-8-ge6fa32720）
#   tag = <ver>-bili.N，N 从 1 起，同名标签已存在（本地）则自动 +1
#
# 磁盘纪律（工单红线）：构建顺序=逐镜像 build→push→docker builder prune -f，
# 再下一个镜像；绝不使用 docker image prune -a / docker system prune。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# 默认 5001 而非 5000：本机 macOS 的 AirPlay 接收器（ControlCenter）开机即监听
# *:5000，docker -p 5000:5000 必然 bind 失败。若宿主已关闭 AirPlay 接收器，
# 可 REGISTRY=localhost:5000 切回工单原始端口。
REGISTRY="${REGISTRY:-localhost:5001}"
# DOCKER_BUILD_NETWORK=host lets build steps use the host network namespace.
# Needed on hosts whose container bridge cannot reach GitHub reliably (the
# librdkafka stage clones aws-lc from GitHub).
BUILD_NETWORK_ARGS=()
if [ -n "${DOCKER_BUILD_NETWORK:-}" ]; then
  BUILD_NETWORK_ARGS=(--network "${DOCKER_BUILD_NETWORK}")
fi

PUSH="${PUSH:-1}"
PRUNE="${PRUNE:-1}"
# P1-012：推上去之后可以顺手签名/过 CVE 门禁。默认关，CI 里打开。
# 第一次开 SCAN 时门禁几乎必然红——要先做一次基线扫描，把确认可接受的条目
# 写进 deploy/security/vulnerability-allowlist.json（带 reason 与 expires）。
SIGN="${SIGN:-0}"
SCAN="${SCAN:-0}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-feldera-local-registry}"
REGISTRY_HOST="${REGISTRY%%:*}"
REGISTRY_PORT="${REGISTRY##*:}"

# docker CLI 语义：DOCKER_TLS_VERIFY 非空（哪怕 "0"）即启用 TLS 校验，会去找
# ~/.docker/ca.pem，导致 buildx 直接失败。本机历史 shell 配置里存在
# DOCKER_TLS_VERIFY="0" 的误用（本意是关闭），在此归一化为关闭。
if [[ "${DOCKER_TLS_VERIFY:-}" == "0" || "${DOCKER_TLS_VERIFY:-}" == "false" ]]; then
  unset DOCKER_TLS_VERIFY
fi

# VER can be pinned explicitly, which is what a build host without the git
# history (a remote builder fed by rsync) has to do.
VER="${VER:-$(git describe --tags --always)}"
echo "=== feldera bili images: ver=${VER} registry=${REGISTRY} push=${PUSH} prune=${PRUNE}"

ensure_registry() {
  if curl -fsS "http://${REGISTRY}/v2/_catalog" >/dev/null 2>&1; then
    return 0
  fi
  case "${REGISTRY_HOST}" in
    localhost|127.0.0.1) ;;  # 本地 registry：自动拉起
    *)
      echo "ERROR: registry ${REGISTRY} 不可达；请确认内网制品库地址与凭据" >&2
      return 1
      ;;
  esac
  echo "--- 本地 registry 未就绪，启动 ${REGISTRY_CONTAINER} (registry:2, host port ${REGISTRY_PORT})"
  docker rm -f "${REGISTRY_CONTAINER}" >/dev/null 2>&1 || true
  if ! docker image inspect registry:2 >/dev/null 2>&1; then
    docker pull registry:2
  fi
  docker run -d --name "${REGISTRY_CONTAINER}" -p "${REGISTRY_PORT}:5000" --restart=always registry:2
  for _ in $(seq 1 30); do
    if curl -fsS "http://${REGISTRY}/v2/_catalog" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: 本地 registry 30s 内未就绪" >&2
  return 1
}

# 已有同名镜像（本地）则 N 递增
next_n() {
  local image="$1" n=1
  while docker image inspect "${image}:${VER}-bili.${n}" >/dev/null 2>&1; do
    n=$((n + 1))
  done
  echo "${n}"
}

# P1-012：签名与 CVE 门禁都只对已推送的镜像有意义（cosign 把签名作为
# 制品库里的另一个 tag 保存）。本地 http 制品库给 cosign 加 --allow-insecure-registry。
supply_chain() {
  local image="$1"
  local -a extra=()
  case "${REGISTRY_HOST}" in
    localhost|127.0.0.1) extra=(INSECURE_REGISTRY=1) ;;
  esac

  if [[ "${SIGN}" == "1" ]]; then
    echo "--- signing ${image}"
    env "${extra[@]+"${extra[@]}"}" deploy/security/supply-chain.sh sign "${image}"
  fi
  if [[ "${SCAN}" == "1" ]]; then
    echo "--- scanning ${image} (report under deploy/security/reports/)"
    env "${extra[@]+"${extra[@]}"}" deploy/security/supply-chain.sh gate "${image}"
  fi
}

# 构建成功后的收尾：报告体积、可选推送、可选清 build cache。
finish_image() {
  local tag="$1"
  echo "=== [$(date '+%H:%M:%S')] built ${tag} $(docker image inspect "${tag}" --format '{{.Size}}' | awk '{printf "%.1fMB", $1/1024/1024}')"

  if [[ "${PUSH}" == "1" ]]; then
    ensure_registry
    echo "--- pushing ${REGISTRY}/${tag}"
    docker tag "${tag}" "${REGISTRY}/${tag}"
    docker push "${REGISTRY}/${tag}"
    supply_chain "${REGISTRY}/${tag}"
  fi

  if [[ "${PRUNE}" == "1" ]]; then
    # 只清 build cache（悬空层），绝不动他项目镜像
    docker builder prune -f >/dev/null
  fi
}

build_one() {
  local name="$1" dockerfile="$2"
  shift 2
  local n tag
  n="$(next_n "${name}")"
  tag="${name}:${VER}-bili.${n}"
  echo "=== [$(date '+%H:%M:%S')] building ${tag} (dockerfile=deploy/${dockerfile})"
  docker build -f "deploy/${dockerfile}" -t "${tag}" "${BUILD_NETWORK_ARGS[@]+"${BUILD_NETWORK_ARGS[@]}"}" \
    --build-arg GITHUB_MIRROR="${GITHUB_MIRROR:-}" \
    --build-arg APT_MIRROR="${APT_MIRROR:-}" "$@" .
  finish_image "${tag}"
}

# manager 迭代快速路径。
#
# 全量构建 manager 要在 build 阶段重新编译整个 workspace（60-90 分钟），因为
# crates/ 一变，cargo target 所在的层就失效。迭代期间用已经构建好的 manager
# 镜像当底座、只替换二进制（deploy/Dockerfile.manager.overlay），秒级出镜像：
#
#   docker cp bili-cargo-builder:/target/release/pipeline-manager /tmp/pm
#   BILI_MANAGER_BINARY=/tmp/pm deploy/build-images.sh
#
# 发布镜像必须走 Dockerfile.manager 全量构建；本路径只用于本地验证循环。
build_manager() {
  if [[ -z "${BILI_MANAGER_BINARY:-}" ]]; then
    build_one feldera-manager Dockerfile.manager \
      --build-arg BILI_CARGO_JOBS="${BILI_CARGO_JOBS:-4}" \
      --build-arg GITHUB_MIRROR="${GITHUB_MIRROR:-}" \
      --build-arg APT_MIRROR="${APT_MIRROR:-}" "${BUILD_NETWORK_ARGS[@]+"${BUILD_NETWORK_ARGS[@]}"}"
    return
  fi

  local base_n base_image n tag
  # 取本地最新的 feldera-manager:<ver>-bili.N 作为 overlay 底座
  base_n="$(for i in $(seq 1 99); do
    docker image inspect "feldera-manager:${VER}-bili.${i}" >/dev/null 2>&1 && echo "${i}"
  done | tail -1)"
  if [[ -z "${base_n}" ]]; then
    echo "ERROR: BILI_MANAGER_BINARY 需要已存在的 feldera-manager:${VER}-bili.N 作为底座；先跑一次全量构建" >&2
    return 1
  fi
  base_image="feldera-manager:${VER}-bili.${base_n}"

  mkdir -p deploy/.build
  install -m 0755 "${BILI_MANAGER_BINARY}" deploy/.build/pipeline-manager

  n="$(next_n feldera-manager)"
  tag="feldera-manager:${VER}-bili.${n}"
  echo "=== [$(date '+%H:%M:%S')] building ${tag} (overlay on ${base_image})"
  docker build -f deploy/Dockerfile.manager.overlay \
    --build-arg BASE_IMAGE="${base_image}" -t "${tag}" .
  finish_image "${tag}"
}

# 注意：不得用 `docker build --target=<stage>` 做 "warmup 预烤"——本机 Docker 4.x
# buildkit 对含 RUN bun 大层（webconsole）的 target 构建 export 会死锁（132s 后
# CPU 0% 永久挂，见 MEMORY 教训）。buildkit 缓存本就按层留存：同一 Dockerfile
# 的中间层随全量构建缓存，不必预烤。

# The compiler image is the manager image plus a service selection (P1-018), so
# it is built from a manager tag rather than through its own toolchain stack.
build_compiler() {
  local base_image
  base_image="$(docker image ls --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^feldera-manager:${VER}-bili\\.[0-9]+$" | sort -t. -k5 -n | tail -1)"
  if [[ -z "${base_image}" ]]; then
    echo "ERROR: no feldera-manager:${VER}-bili.N image to derive the compiler image from" >&2
    return 1
  fi
  build_one feldera-compiler Dockerfile.compiler --build-arg BASE_IMAGE="${base_image}"
}

build_runner() {
  build_one feldera-runner Dockerfile.runner
}

# ONLY keeps the iteration loop honest: a change to one image should rebuild
# that image, not all three. Unset builds the whole set in dependency order.
prepare_registry() {
  # Every image is pushed to ${REGISTRY}, so the registry has to exist before the
  # first push, not inside finish_image, or ONLY=compiler fails on a cold host.
  if [[ "${PUSH}" == "1" ]]; then ensure_registry; fi
}

prepare_registry
case "${ONLY:-}" in
  "")        build_manager; build_compiler; build_runner ;;
  manager)   build_manager ;;
  compiler)  build_compiler ;;
  runner)    build_runner ;;
  *)
    echo "ERROR: ONLY must be manager, compiler or runner (got '${ONLY}')" >&2
    exit 2
    ;;
esac

echo
echo "=== done. local images:"
docker image ls --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E "feldera-(manager|compiler|runner):${VER}-bili" || true
if [[ "${PUSH}" == "1" ]]; then
  echo "=== registry catalog (${REGISTRY}):"
  curl -fsS "http://${REGISTRY}/v2/_catalog" && echo
  for repo in feldera-manager feldera-compiler feldera-runner; do
    curl -fsS "http://${REGISTRY}/v2/${repo}/tags/list" 2>/dev/null && echo
  done
fi
