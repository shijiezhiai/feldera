# 自建镜像流水线 v1（P1-004）

Feldera 自建企业平台的源码镜像流水线 v1：一条命令从仓库源码构建
manager / compiler / runner 三张镜像并推送到制品库。母文档见
`design/self-hosted-enterprise-platform-plan.md` §4，工单见
`design/p1-work-orders.md` P1-004。

## 三镜像形态

| 镜像 | Dockerfile | 内容 | 用途 |
|---|---|---|---|
| `feldera-manager` | `deploy/Dockerfile.manager` | pipeline-manager 二进制（`--features feldera-enterprise`）+ sql2dbsp jar + web console + rust 工具链 + 源码树 + 离线 cargo 缓存 | `--services=all` 时是整套平台；`--services=api` 时是分离部署的控制面 |
| `feldera-compiler` | `deploy/Dockerfile.compiler`（基于上一行的 manager 镜像） | 与 manager 镜像同一份内容 | `--services=compiler,artifact-server`：P1-018 的编译服务与制品存储 |
| `feldera-runner` | `deploy/Dockerfile.runner` | ubuntu:24.04 + librdkafka(AWS-LC) + 运行时动态库 | 生成的 pipeline 程序运行镜像 |

三者均基于 `ubuntu:24.04`（镜像自带 `ubuntu` 用户 uid 1000），当前仅
arm64/linux（本机 Docker Desktop 为 aarch64；amd64 交叉构建见文末后续项）。
librdkafka 一律按上游约定从源码构建（AWS-LC，构建期 `readelf` 校验不链系统
OpenSSL）。

## 版本标签约定

```
ver = git describe --tags --always        # 例：v0.357.0-8-ge6fa32720
tag = <ver>-bili.N                        # N 从 1 起
```

N 由 `deploy/build-images.sh` 自动计算：本地已存在同名标签则 +1，不手打。
升级上游代码（ver 变化）后 N 重新从 1 起算。

## 构建、推送与磁盘纪律

```bash
deploy/build-images.sh                    # 本地默认：推 localhost:5000
REGISTRY=reg.corp.example:5000 deploy/build-images.sh   # 推真内网制品库
PUSH=0 deploy/build-images.sh             # 只构建不推送
BILI_CARGO_JOBS=4 deploy/build-images.sh  # manager 构建降并行（见下）
```

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `REGISTRY` | `localhost:5000` | 制品库地址；`localhost:5000` 不可达时脚本自动起 `registry:2` 容器（容器名 `feldera-local-registry`，`--restart=always`） |
| `PUSH` | `1` | 构建后推送 |
| `PRUNE` | `1` | 每张镜像构建后 `docker builder prune -f` |
| `BILI_CARGO_JOBS` | 空（全核） | 传给 manager 构建的 `CARGO_BUILD_JOBS`，OOM 时降并行 |

**磁盘红线**：脚本按「逐镜像 build→push→`docker builder prune -f`」推进，
镜像总量控制在 15G 内。本机如有他项目镜像与运行数据，**严禁**
`docker image prune -a` 与 `docker system prune`（只允许 builder prune 与
悬空层 `docker image prune -f`）。

## 内网制品库待接位置（占位）

真内网 registry 本机不可达，接线点已收敛为环境变量，无需改脚本：

1. 推送目标：`REGISTRY=<内网 registry 地址>`（脚本内 `docker push ${REGISTRY}/...`）。
2. 凭据：待内网 registry 确认认证方式后在宿主 `docker login`（脚本不管理凭据）。
3. CI 出镜像：本机构建是 v1 等价替代；CI 侧复用同一脚本，仅需 runners
   具备 docker 与上述 `REGISTRY`。

## manager 镜像

与上游 `deploy/Dockerfile` 的关键差异——上游要求 CI 先在宿主 Linux 编译出
`build/pipeline-manager` 与 `build/sql2dbsp-jar-with-dependencies.jar` 再
COPY 进镜像；本机宿主是 macOS，无法产出 linux 二进制，因此 v1 全部在镜像内构建：

1. **librdkafka 阶段**：与上游逐字一致。
2. **webconsole 阶段**：bun v1.3.14 构建 SvelteKit（版本与 CI dev 镜像一致，
   `check-bun-version` 校验）。
3. **sql-compiler-jar 阶段**：maven 构建 sql2dbsp jar（纯 Java）。
4. **builder 阶段**：容器内 `cargo build --release --locked -p pipeline-manager
   --features feldera-enterprise`（enterprise stub 为仓库内
   `crates/dbsp-enterprise`、`crates/sync-checkpoint`）。steps 使用
   `--mount=type=cache,target=/home/ubuntu/.cargo-target`（BuildKit 持久
   cache)：cargo RUN 一旦失败，层不提交、传统缓存会全丢（60-90min 全损）；
   cache mount 在步骤失败后内容保留，重跑从断点续编（见下「构建提速」）。
5. **base/release 阶段**：形态对齐上游 base——保留 rust 工具链 + 源码树
   （in-process compiler 编译 pipeline 需要），二进制与 jar 落位
   `/home/ubuntu/feldera/build/` 与上游完全一致，ENTRYPOINT 逐字对齐。

**不执行 `--precompile`**（上游 release 阶段会把预编译产物烤进镜像）：v1 控
制镜像体积，代价是每条 pipeline 首次编译需冷启动完整 cargo 流程（慢）。
预编译层计划随 P1-018 编译服务一起做（母文档 §5.2）。

**构建资源要求**（本机实测）：

- Docker Desktop VM 内存 ≥ 12GB：`settings-store.json` 设
  `MemoryMiB: 12288` 后重启 Docker（pipeline-manager 链接阶段内存峰值高，
  默认 8GB 会 OOM）。改前备份原值。
- 仍 OOM 的降级阶梯：① `BILI_CARGO_JOBS=4` + `CARGO_INCREMENTAL=0` 重试
  ② VM 内存提到 14GB ③ 出无 enterprise feature 版本并如实标注（不允许私改
  feature 接线）。

**构建提速**（本机实测，2026-10-19）：

- `deploy/build-images.sh` 在整张 manager 构建前，先用 `--target` 单独预
  烤 webconsole / sql-compiler-jar / librdkafka 三个长 stage 的 BuildKit 缓存
  （warmup 阶段，不产 tag）。任一镜像构建失败时，其余 stage 缓存原子留存，
  避免「webconsole 先挂 → 整个 manager build 连坐 → jar 33min 永远没机会入
  缓存」的老问题。
- webconsole 的 bun 依赖走 `registry.npmmirror.com`（Dockerfile.manager
  webconsole 阶段写 `$HOME/.bunfig.toml`）：bun ci 从 840s 失败收敛到 ~92s
  通过；svelte+vite 构建 ~30s，stage 全量 ~123s。
- 各长 RUN 会在日志中**静默数十分钟**（bun ci / gradle / cargo 完成前不输出
  进度行）——这是预期，不是卡死；bun.sh 安装脚本偶发长时间无下载进度，
  会把一次构建拖到「超时被杀」也不报错。若需眼见为实：`docker stats` 或
  给各阶段加 `--progress=plain` 逐行实时输出。
- 历次构建失败的根因记录与防再犯改动：`design/p1-build-iteration-log.md`。

内嵌 PostgreSQL 用 `postgresql_embedded`，manager 首次启动需联网下载 PG
二进制（与上游一致；替换为外接 PG 属后续项）。

## compose 冒烟

```bash
export MANAGER_IMAGE=feldera-manager:<ver>-bili.N
export COMPILER_IMAGE=feldera-compiler:<ver>-bili.N
export RUNNER_IMAGE=feldera-runner:<ver>-bili.N
docker compose -f deploy/docker-compose.bili-smoke.yml up -d
docker compose -f deploy/docker-compose.bili-smoke.yml ps   # manager 应 healthy
```

1. `curl http://localhost:8080/healthz` → 200。
2. `POST /v0/pipelines` 建最小 pipeline（`CREATE TABLE` + 1 个 `SELECT`），
   轮询 program status 至 Success（manager in-process 调 compiler 编译出产物）。
3. runner 冒烟：把第 2 步编译出的 pipeline 二进制 `docker cp` 进 runner 容器
   执行，验证动态链接闭环（镜像内预置二进制的 runner 协议属 P1-018+）。

compiler 镜像冒烟：`docker compose exec compiler` 验证
`java -version` / `mvn -version` / `cargo --version` / `mold --version` /
`pkg-config --modversion rdkafka`。

## 后续项（不在 P1-004 范围）

- **distroless 基座**：与「镜像内编译」冲突（需要完整工具链），待 P1-018
  编译分离后按组件评估（manager 去 rust 工具链后可大幅瘦身）。
- **预编译层（--precompile）**：随 P1-018 编译服务落地（母文档 §5.2）。
- **amd64 / 多架构**：本机为 arm64；CI 侧用 buildx 出多架构镜像。
- **真内网 registry 接线**：见上文占位说明。
- **runner 镜像预置二进制协议**：编译产物如何进入 runner 镜像/容器，
  随 P1-018 runner 协议定义。

### 实测记录（2026-10-20，arm64）

- 首次冒烟全链路通过：SQL 编译 Success（2.5s）→ Rust 编译单 rustc 完成
  （约 1.5h，`CARGO_BUILD_JOBS=1`）→ 产物 `feldera_pipe_pipeline_*_main`
  279MB。
- runner 动态链接闭环：二进制 `docker cp` 进 runner 容器，`ldd`
  全解析（`librdkafka.so.1 → /usr/local/lib/`，runner 镜像自带），直接执行
  报 `Error parsing command line arguments: dbsp_adapters 0.358.0`（无参数
  的正常 usage 错误）即证明可执行。
- 注意：runner 容器内 `chmod` `/tmp` 下文件会
  `Operation not permitted`（只读挂载），`docker cp` 已保留宿主执行位，
  无需再 chmod。
