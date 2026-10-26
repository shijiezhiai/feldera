# P1-004 构建迭代日志（2026-10-19）

> 目的：记录「同一份 Dockerfile 为何反复 1-2h 全量重来」的全部根因与改法，
> 让后续任何会话/人都能直接回答「怎么又重来了」而不必重新考古。

## 时间线

| # | 结果 | 死因（根因） |
|---|---|---|
| #1-#5 | 失败 | 早期探索（npmjs→npmmirror 等），细节见各构建日志 |
| #6 | killed SIGTERM | DSH App 重启杀后台 job（误判为幽灵 prune 互杀） |
| #7 | mold 下载失败 | GitHub release 资产慢+半截文件（curl exit 18）；已加 `--retry 4 --retry-all-errors --connect-timeout 20` |
| #8 | killed SIGTERM | 同上 App 重启杀 job |
| #9 | 失败 | webconsole 阶段 `bun ci` 卡死（registry.npmjs.org SSL 掐断）→ 已改 npmmirror |
| #10 | 失败 | 同上 bun ci；npmmirror 改后未生效于该轮 |
| #11 | killed（手动） | **bun 二进制安装卡死**：官方 install 脚本从 GitHub release 拉 bun-linux-aarch64.zip（本网 ~17s/MB，全量 23MB 需 6-7min 且常失败），curl 无进度输出 → 日志静默 1h+ 误判为「活着」 |
| warmup 试跑 | 断点验证 | webconsole 全量 123s 可复现；每次 build 的 stage 缓存正常原子留存 |

## 根因结论

1. **长 RUN 静默是最大敌人**：bun ci / gradle / cargo 完成前不输出进度行，
   日志数十分钟不动会误判死活。`docker stats` / `--progress=plain` 才能眼见
   为实。
2. **GitHub release 资产慢不是偶发**：rust-mold / bun 二进制都走 GitHub，
   本网 ~17s/MB。凡大二进制必须换 npmmirror 或 USTC。
3. **BuildKit 缓存层级陷阱**：RUN 中途失败→该层不提交→整条链的产物全丢
   （jar 33min、cargo 60-90min 全损）。长 RUN 必须
   `--mount=type=cache`（cargo）或分成独立小步（bun 下载→解压→清理）。

## 已落地防再犯

- `deploy/build-images.sh`：整张 manager 构建前先 `--target` 预烤
  webconsole / sql-compiler-jar / librdkafka 缓存，任一镜像失败不连坐。
- `Dockerfile.manager`：
  - bun 二进制改 npmmirror `/-/binary/bun/`（302→cdn，全量 8.3s），不再
    依赖 bun.sh install 脚本的 GitHub 拉取。
  - cargo RUN 用 `--mount=type=cache,target=/home/ubuntu/.cargo-target`
    （失败重跑断点续编，CARGO_TARGET_DIR 指向 cache mount）。
- 长任务不再挂后台 job：`nohup ... & disown` 脱离进程树（App 重启不杀）。

## 待验证（下一次真构建）

- 新 bun 下载是否保持 ~8s（容器内已端到端验证 7.9s 下载+解压+bun --version）。
- cargo cache-mount 命中后二次构建时长。

## P1-009：kind 上迭代 runner 的固定套路

- **只换二进制，不重建镜像**：先在带工具链的容器里
  `cargo build --release -p pipeline-manager`（target 挂在命名卷上，改一行
  增量 1.5 分钟），再用 `deploy/Dockerfile.manager.overlay` 叠一层
  `COPY`（秒级），`BASE_IMAGE` 指向上一个能跑的 manager 镜像。
  `deploy/build-images.sh` 见到 `BILI_MANAGER_BINARY` 就走这条路。全量
  `Dockerfile.manager` 构建依旧是 60–90 分钟，只在发版时用。
- **容器的可写层在容器重启时会被丢弃**（containerd 每次以镜像重新建容器
  快照）：`docker cp`／`kubectl cp` 塞进去的二进制、"用 mv 顶替"的路径，
  只要容器一重启就回到镜像里的版本。只有挂载卷（emptyDir/PVC）的内容会
  留下。所以 pod 内编译缓存（`/home/ubuntu/.feldera`，emptyDir）能跨重启，
  而临时替换的 manager 二进制不能——需要修二进制时只能出新镜像。
- **Helm 覆盖键要带子 chart 前缀**：umbrella 的 values 不会自动下传到子
  chart，`image.tag=...` 无效，必须写 `controlplane.image.tag` 与
  `controlplane.kubernetesRunner.image.tag`。写错的表现是
  `helm upgrade --wait` 五分钟超时，而 pod 仍是旧镜像。
- **`randAlphaNum` 不能出现在会被 upgrade 重新渲染的 Secret 里**：它每次
  渲染都换值，Postgres 数据目录里的旧密码不会跟着变，升级后 manager 直接
  `password authentication failed`。改成 `lookup` 复用集群里已有的值。
- **`kind load docker-image` 只吃得下单架构镜像**：本地 `docker build` 的
  单架构镜像没问题；`postgres:17-alpine` 这种带 manifest list 的会报
  `content digest ... not found`，要
  `docker save | ctr --namespace=k8s.io images import`。
- **`COPY` 继承宿主机的文件权限**，所以 `COPY deploy/pipeline-entrypoint.sh
  /usr/local/bin/pipeline-entrypoint` 会把检出目录里 `rw-------` 的权限原样带进
  镜像，pod 报 `cannot open /usr/local/bin/pipeline-entrypoint: Permission
  denied`（连 `#!/bin/sh` 都读不到）。`Dockerfile.runner` 改成普通 `COPY` 紧跟
  一条 `RUN chmod 0755`，既不看检出目录的权限位，也不要求 BuildKit
  （classic builder 不支持 `COPY --chmod`）。
- **容器的内存上限必须高于 pipeline 自己的 `max_rss_mb` 预算**。第一次
  e2e 用 `memory_mb_max=1024` 直接当容器 limit，pipeline 进程按 1 GiB 预算
  增长，加上二进制页、线程栈和分配器开销就把 cgroup 撑爆：
  `OOMKilled`（exit 137），automaton 看到 `CrashLoopBackOff` 后把 pipeline
  置为 Failed。现在 limit = 预算 + max(25%, 256MiB)，request 仍是预算。
- **编译产物按 pipeline id 归档**（`pipeline_<id>_v<n>_sc_<source>_ic_<integrity>`），
  所以即使 SQL 完全相同，新建 pipeline 仍要重编生成 crate 并重链接一次：
  在 warm 缓存上约 3–4 分钟，冷启动则按 profile 计（`optimized` 实测
  2 小时 15 分，`dev` 光最后链接就 13 分钟）。要把"改了 runner 之后跑一遍
  e2e"的代价压到可接受，编译缓存卷（`controlplane.compilationCache`）是必需的，
  它同时让 manager pod 重建后不必从零编译。

## 在 Linux 构建机上跑整条链（2026-10-22，flink-test-02）

镜像构建和 e2e 都可以整体搬离开发机。`flink-test-02` 是 48 核 / 124 GiB 的
Debian 10 机器，这里单独起了一个 Docker 24.0.9 守护进程（socket 与 data-root
都在 `/mnt/storage01/mayy/feldera` 下，不碰机器上原有的 19.03）。

一次性准备：

- `/mnt/storage01/mayy/feldera/env.sh` 导出 `DOCKER_HOST`、`PATH`
  （`bin/docker`、`bin/kind`、`bin/kubectl`、`bin/helm`）、`KUBECONFIG` 和
  `DOCKER_BUILDKIT=0`。这台机器没有 buildx 插件，classic builder 足够。
- kind 集群 `bili-p1005`（`kind create cluster`）。kind 自带 `standard`
  StorageClass，`controlplane.compilationCache` 能直接绑定。
- `webconsole-dist/` 仍是宿主机产物：在一次性容器里跑
  `bun install && bun run build:deps:web-console &&
  bun --cwd=js-packages/web-console run build:self`，再 `docker cp` 出来。
  `build:self` 打印 `✔ done` 之后 vite 会被 sass-embedded 子进程吊住不退出，
  要 `docker cp` 产物而不是等退出码。

构建参数（这条线路必需）：

- `APT_MIRROR=http://mirrors.ustc.edu.cn` —— `archive.ubuntu.com` 间歇性失败，
  `apt-get update` 掉包后 `apt-get install` 会报 `Unable to locate package`。
- `GITHUB_MIRROR=https://gh-proxy.com/https://github.com` —— GitHub 的 git
  协议在这条线路上不可用（`gnutls_handshake() failed` 或传输中途停滞）。
  `scripts/install-librdkafka.sh` 改下载
  `<mirror>/<owner>/<repo>/archive/<sha>.tar.gz`（GitHub archive 按 commit
  寻址，顶层目录名里带 OID，脚本校验它）；Dockerfile 里 calcite 与 cargo
  的 git 依赖走 `url.<mirror>/.insteadOf https://github.com/`。
- `DOCKER_BUILD_NETWORK=host` 只在桥接网络异常时打开；默认不要开。

踩到的坑：把 `br-mayy` 的 MTU 调成 1400 后，apt 与镜像层下载全部卡死
（`apt-get update` 反复 `Ign`/`Err`），恢复 1500 后 apt 立刻 12 MB/s。
低 MTU 不是"更保险"，在这个链路上只会把路径 MTU 发现搞坏。

### 第二轮：镜像链跑通后剩下的坑（2026-10-22 晚）

上面那条"从零建镜像"的线路里，镜像本身能构建出来，但**跑通 e2e** 还要再过
五关。这些都是构建机上实测的、和上游代码无关的环境问题：

- **cargo 的 libgit2 会永久卡住**：`Updating git repository` 之后 0% CPU 三十分钟
  不动（容器里 cargo 进程 0.2% CPU、无子进程）。改成
  `ENV CARGO_NET_GIT_FETCH_WITH_CLI=true`，让 git CLI 做 fetch（它认
  `url.insteadOf`，也会重试）。
- **`POSTGRESQL_VERSION` 必须在 cargo 那行显式给**：stage 里写的
  `~/.cargo/config.toml` 的 `[env]` 段在这个 stage 没生效，`pg_setup.rs` 的
  `env!("POSTGRESQL_VERSION")` 直接编译失败。可靠写法是
  `RUN POSTGRESQL_VERSION="=15.13.0" cargo build ...`。（构建上下文没有
  `.cargo/`，仓库自己的 `.cargo/config.toml` 也进不了镜像。）
- **samply 的安装只告警**：`samply-installer.sh` 内部还要直连 github 下载二进制，
  这条线路上必失败。它只用于性能剖析，改成 `... | sh || echo "warning: ..."`
  可让整张镜像不至于报废。
- **runner 的 Dockerfile 也得有镜像参数**：`install-librdkafka.sh` 的
  `SOURCE_MIRROR` 分支要 `curl`，而 runner 的 apt 行原本没装 `curl`，报
  `/tmp/install-librdkafka.sh: line 129: curl: command not found`。补 `curl` 并透传
  `ARG GITHUB_MIRROR` 后 180 MB 的 runner 秒级可建。
- **macOS 打出来的 tar 会毁掉 helm**：AppleDouble 文件 `._api-server-service.yaml`
  被 helm 当成模板，报
  `YAML parse error ... control characters are not allowed`。同步代码后先
  `find charts -name '._*' -delete`。

e2e 侧的三条：

- **kind 要 load 四张镜像**，不止 manager/runner：漏了 compiler 是
  `ImagePullBackOff`（pod 起不来），漏了 `postgres:17-alpine` 是整条链起不来。
  postgres 从 `docker.m.daocloud.io` 拉再 `docker tag` 回原名。
- **删 pipeline 要走完整状态机**：`stop?force=true` → 等
  `deployment_status=Stopped` → `clear` → 等存储释放 → `DELETE`。漏一步就是
  `DeleteRestrictedToClearedStorage` 或 `Cannot transition storage status from
  'in_use'`，而且脚本会静默"删失败"，下一轮跑出来 `c=6`、`c=9`（旧数据还在）。
- **`/ingress/<table>` 的默认 update format 是 raw**（每行一个裸 JSON 字符串），
  传 `[{"i":1},...]` 报 `invalid type: map, expected a string`。要显式
  `?format=json&update_format=insert_delete`，body 用换行分隔的
  `{"insert":{"i":1}}`。
- **`pkill -f "kubectl port-forward"` 会杀掉自己的 ssh 会话**（模式串命中了自己
  的命令行），用 `pgrep -f` 拿 PID 再 kill。

性能数字：这台上第一次编译（依赖已在镜像里、target 目录空）331 s，第二次编译
（PVC 里 target 已热）17 s，pod 起来 7 s。


## P1-010：网络通路迭代

`manager↔runner` 这一层只改 manager 与 chart，不需要新镜像层，所以迭代循环是最短的
一圈：改 Rust → 容器内增量编译 → overlay 镜像 → `kind load` → 跑 e2e。

- **`--features feldera-enterprise` 的编译要求工作区两个 enterprise 成员可读**：
  `crates/dbsp-enterprise` 与 `crates/sync-checkpoint` 是未跟踪的本地目录，
  `Cargo.toml` 的 `members` 却引用它们。宿主机上 `cargo` 以属主身份跑没问题，
  容器里以 uid 1000 跑就报 `failed to read .../Cargo.toml: Permission denied`。
  复制/同步源码前给这两个目录 `chmod -R a+rX`（本地已改，`git` 不跟踪）。
- **`kind load` 只认已存在的 tag**：P1-010 只重建 manager，runner/compiler 镜像
  没变，直接用 `docker tag ... bili.5 bili.6` 造同 tag 别名，脚本就能一次 load
  三张（脚本按同一个 `TAG` 找三张镜像）。
- **NetworkPolicy 的 selector 用 `kubernetes.io/metadata.name`**：API server 给
  每个 namespace 自动打这个名字标签，不依赖 release 名。用
  `app.kubernetes.io/name` 一类自造标签会在别的 release 里失配。
- **pipeline pod 不能有 kubelet 探针**：探针从节点网络命名空间发起，ingress 规则
  只放行 manager namespace，探针会被自己挡掉。就绪信号交给 manager 的
  `is_provisioned` 轮询。
- **`check` 的状态契约**：`/status` 的 200/503 视为健康（503 是"暂时读不到"），
  其它状态码视为不健康；连接被拒（容器刚起、还在下载二进制）不算失败，否则
  automaton 会在正常启动窗口里把 pipeline 判死。
- **`GET /v0/pipelines/{name}/logs` 是流式接口**：body 发完就挂着等新日志，
  `curl` 会一直等到 `--max-time` 才退出（表现为 `time_total` 正好等于超时值）。
  断言脚本要容忍超时退出码，只按内容判断。
- **follow pod 日志需要 `pods/log` 权限**：只给 `pods` 的 Role 会让
  `log_stream` 报 403，而这条错误只出现在 manager 自己的日志里（pipeline 照跑），
  所以 e2e 必须反过来断言「pipeline 自己打印的行出现在 log API 里」才抓得到。

## 第三轮：模板渲染（P1-011）

- **StatefulSet 的 selector 不可变**：改了模板里的 selector 标签后，对已存在的
  STS 做 merge patch 会被 API server 拒（`unable to patch ...: ApiError`），
  provision 每次重试都失败。迭代期把旧 STS 删掉再起，或者先 `clear()`。
- **模板必须自带 `--deployment-id`**：pipeline 二进制的 CLI 把它列为必需参数，
  模板漏了就是 pod 启动即退出（`the following required arguments were not
  provided: --deployment-id`），表现为 CrashLoopBackOff。
- **selector 标签只能由 manager 写**：占位符集合里没有裸 pipeline UUID，模板
  无法拼出 `app.kubernetes.io/instance=<uuid>`，于是 Service 没有 endpoint、
  pipeline 一直 `Unavailable`。现在 manager 直接覆盖 `name`/`serviceName`/
  selector，并把 selector 标签并入 pod labels。
- **有 storage 的 pipeline 必须有可写的 `{pipeline_storage_path}`**：K8s runner
  总是给 pipeline 一个 storage 路径，模板不挂 claim 就是
  `create failed: entity not found` + `recursive mkdir failed: permission denied`。

## 第三轮补记：P1-011 chart 变更的回归跑

- `TAG=…-bili.8 PROFILE=unoptimized REUSE=0 scripts/e2e-k8s-runner.sh` 在 kind 上
  一次通过，65s：创建 → Running → ingest → `SELECT c FROM v` = 3 → 清理。
- 比首轮的 331s 快，是因为编译缓存 PVC 里已有依赖与生成 crate 的 target，只剩
  最终 crate 重编与链接；这也说明「删 pipeline 保留 target」是有意义的。
- 回归判读要点：限额四个参数是「只加不减」（默认值与 chart values 一致，
  既有渲染结果不变）；模板开关的默认值是空字符串，`{{- with }}` 整段不渲染，
  manager 收到 0 个 `--kubernetes-runner-template-*` 参数。
- 清理断言看两类：DB 侧 pipeline 记录为空，集群侧带
  `feldera.com/pipeline-id` 的 sts/svc/secret/pvc/networkpolicy 为空。

## P1-012：供应链工具链在这台机器上的落地细节

- 工具版本（都放在构建机 `$FELDERA_HOME/bin`）：`cosign 2.4.1`、`trivy 0.76.1`、
  `kyverno` CLI `1.19.2`。二进制从 `gh-proxy.com` 前缀的 GitHub release 拉取。
- trivy 漏洞库：`mirror.gcr.io` 与 `index.docker.io` 都超时，**`ghcr.io/aquasecurity/trivy-db`
  可用**（129 MiB，32s 下完，约 4 MiB/s）。默认仓库本来就是 ghcr.io，但 trivy 会先试
  mirror.gcr.io，所以用 `TRIVY_DB_REPOSITORY=ghcr.io/aquasecurity/trivy-db` 显式指定可省一次超时。
- `helm show chart oci://ghcr.io/kyverno/charts/kyverno` 在这台机器上失败：
  `GDBus.Error: ... org.freedesktop.secrets was not provided`（helm 的 OCI 客户端走
  docker credential helper，撞上没有 keyring 的 root 会话）。所以集群内的 Kyverno
  安装没在本轮验证，准入判定用 `kyverno apply`（同一引擎、离线）验证。
- 自建 HTTP 制品库给 cosign 需要 `--allow-insecure-registry`，脚本用
  `INSECURE_REGISTRY=1` 控制。
- 签名是按 digest 绑定的：把同一个 digest 打成新 tag 仍然“已签名”；把 tag 指向
  新 digest 才会失效。演示未签名镜像必须提交一个**未被签名的新 digest**
  （`docker commit` 一个容器即可），不能只换个 tag 名。
- trivy 扫含 jar 的镜像会额外拉 Java 索引库；它先试 `mirror.gcr.io`（这台机器不通），
  脚本里把 `TRIVY_DB_REPOSITORY` 与 `TRIVY_JAVA_DB_REPOSITORY` 都钉到 `ghcr.io`。
  即便如此 ghcr 的 java-db 仍有 `stream ID 1; PROTOCOL_ERROR` 的半途失败，本轮
  manager 镜像的基线用 `--pkg-types os` 取（OS 包），Java 依赖留给 CI。
- 基线结果（2026-10-23）：manager 14 critical / 372 high，**全部来自
  `linux-libc-dev` 且全部无修复版本**（容器不跑该内核，不可达），用一条包级
  allowlist 条目带 reason + expires 处理；runner 0 critical / 0 high。
- **Java 索引库的下半段（同日晚些时候）**：`stream ID 1; PROTOCOL_ERROR` 不是网络问题，
  是 trivy 的 OCI 客户端：同一时刻用 `curl -C -` 拉同一个 blob（ghcr 的
  `sha256:65d5d63f…`，987,770,154 字节）只花 **25 秒**（37 MB/s）。trivy 客户端失败后
  从零重试，所以永远到不了终点。`deploy/security/fetch-java-db.sh` 直接读 manifest、
  用 curl 断点续传，校验字节数后解包到 `$TRIVY_CACHE_DIR/java-db`；之后
  `supply-chain.sh scan` 自动加 `--skip-java-db-update`，扫描不再访问网络。
- **jar 路径不是“配好了”而是“验证过”**：造了一个 `debian:9 + log4j-core-2.14.1`
  的镜像（`localhost:5001/feldera-jardemo:v1`），trivy 报出 `CVE-2021-44228` /
  `CVE-2021-45046` / `CVE-2021-45105`（`jar` 类型），gate 判 33 条 BLOCKED。
  manager 镜像本身 jar 扫描 0 条（shed 掉的编译器 jar 不带依赖元数据）。
- **cargo 噪声**：`--pkg-types os,library` 会把镜像里 `.cargo/registry` 的每个
  `Cargo.lock` 当项目扫，manager 镜像因此多出 1,023 条（P1-009 为了 pod 内离线编译
  才把这些缓存烘进镜像）。gate 默认 `--skip-ecosystems cargo`，只计数并打印
  `SKIPPED …`，不参与判定；Rust 依赖交给代码评审时的 workspace `Cargo.lock` 与
  未来的 `cargo audit`。

## P1-013：e2e 套件在 Linux 构建机上的落地（2026-10-23）

远端 flink-test-02（48 vCPU / 124 GiB / Debian 10）上跑 `python/tests/platform`
的条件比 Rust 侧苛刻：`tests/platform/conftest.py` 定义了 `pytest_configure_node`，
这是 xdist 专用钩子，**不装 pytest-xdist 时连 `-n0` 串行跑都会在 collection 阶段
INTERNALERROR 退出**（`PluginValidationError: unknown hook 'pytest_configure_node'`）。
装齐：`pytest pytest-timeout pytest-rerunfailures pytest-xdist pretty-errors`。

两个 SDK 用法坑：

- `Pipeline.id` 是**方法**不是 property，`pipeline.id` 拿到的是绑定方法，
  拼进 kubectl 查询会得到 `<bound method …>`；必须 `pipeline.id()`。
- `input_json(..., update_format="insert_delete")` 走的是带 envelope 的格式
  （`{"insert": {...}}`），直接喂 `[{"i": 1}]` 会 400 `ParseErrors`：`unknown field
  'i', expected one of table/insert/delete/update`。裸行数据要用 `update_format="raw"`。

一个被测试暴露的语义：**社区版没有快照恢复**，所以"stop 后重启数据还在"是错的
预期。`crates/pipeline-manager/src/db/types/utils.rs:204` 在未开 `feldera-enterprise`
时对 `fault_tolerance.is_enabled()` 直接返回 `ValidationError::EnterpriseFeature`；没有
FT 就没有 checkpoint 快照，PVC 上只有 spill / checkpoint 文件，启动不从它们恢复。
套件因此断言"重启后计数为 0"并把 claim 的 UID 不变作为"卷被复用而非重建"的证据。

## P1-013 — Kubernetes 生命周期 e2e（2026-10-23）

| 项 | 结果 |
|---|---|
| 两个用例（暖缓存） | 2 passed / 84.66s，复跑 87.69s |
| 五十轮 flaky 复跑 | **50 pass / 0 fail**，4300s（每轮约 86s） |
| 冷编译 | ~20 分钟（首次，集群内编译缓存为空） |
| 暖编译 | 12.1s |
| 启动 / 停止 | 7.6–8.6s / 11.8–12.2s |

修的两处真问题：`pipeline.id` 是方法不是 property；`unique_pipeline_name()`
在本地无 `GITHUB_SHA` 时前缀恒为 `local`，50 轮会撞名，套件自带随机后缀。

## P1-014 — OIDC JWK 自动刷新（2026-10-23）

| 项 | 数值 |
|---|---|
| 新增/改动文件 | 2（`auth.rs`、`api/main.rs`）+ 设计文档 |
| 单测 | 模块内 **24 passed**（新增 5 项），全量 lib 353 passed / 9 failed（既有，见下） |
| 刷新间隔 | 60s（access token 生命周期 1 小时） |
| 净增代码 | `auth.rs` +约 430 行（含测试），`main.rs` +19 |

- 一轮"失败即返回"的关键性质：拉取失败不改缓存。否则 issuer 抖一下所有人 401。
- 测试环境坑：`drop(MockServer)` 不是同步关端口，wiremock 的 shutdown 是异步的；改用"绑定后立即释放的端口"构造确定不可连 URL。
- 全量 9 个失败均为 `compiler::*`（本机无 SQL compiler jar → `SystemError`），在干净树上同样红，与本次改动无关；此外 `db_impl_behaves_like_model` 在默认栈大小下会栈溢出，需 `RUST_MIN_STACK=16777216`。

## P1-015 — 监控：抓取目标与 Grafana 看板（2026-10-26）

| 项 | 结果 |
|---|---|
| 单测 | `runner::kubernetes_runner` 新增 4 项（Service/端口名/NetworkPolicy peer/默认关闭），全模块 42 passed |
| 全新 pipeline 全链 | **78 s**（编译 unoptimized + 部署 + Running + 手动 checkpoint + Prometheus 抓到 + Grafana 读到） |
| 复用 pipeline | 18 s |
| `/metrics` | HTTP 200 / 294 KB / 1867 行带 `pipeline_name` |
| Grafana 读到的 checkpoint 数 | 2（与 `_count` 一致） |

五个坑，前三个都是"看起来像平台 bug、其实是脚本或环境"：

1. **clap 布尔 flag 不能写 `=true`**。chart 里 `--kubernetes-runner-metrics-service=true` 让 manager 启动即崩
   （`unexpected value 'true' ... no more were expected`）。同批还发现 `per-pipeline-namespace` 与
   `allow-kubernetes-env-prefix` 两处同样写错——这两处是 P1-009 遗留，从未被执行到。
2. **`pipefail` + `grep -q` 是陷阱**。`printf '%s\n' "$metrics" | grep -q ...` 在匹配后 grep 提前退出，
   producer 收 SIGPIPE（141），整条管道失败。表现是"显然是 200 且显然有这一行，断言却说没有"。
   修法：落文件后对文件 grep，其余几处改 `grep -c`（读到底）。
3. **overlay 镜像漏了 enterprise feature**。`Dockerfile.manager.overlay` 只是替换二进制，
   二进制必须自己带 `--features feldera-enterprise`，否则 manager 对 checkpoint 返 501。
   更隐蔽的是：即使 manager 带了，pipeline 二进制也得带，否则 checkpoint 异步失败
   （"Suspend is an enterprise feature"）——这个错误比 501 难读得多。
4. **`kubectl port-forward` 会随 Pod 重建而死**，而 Grafana 报 Ready 早于 HTTP 端口绑定。
   表现是 `failed to connect to localhost:3000 inside namespace`。修法：轮询里检测 forward 进程退出就重启，
   端口用空闲探测而非硬编码（上一轮残留的 13000 会让下一次以"与平台无关"的理由失败）。
5. **dashboard 的 `${DS_PROMETHEUS}` 在 proxy 调用里不会被替换**。Grafana 渲染时才替换变量，
   直接拿面板 expr 打 `/api/datasources/proxy` 会让 Prometheus 收到字面量 `${...}`，比出空 label。
   e2e 显式替换 `$DS_PROMETHEUS`/`$pipeline_name`/`$__rate_interval`，并用 `case *'$'*` 兜住未来新增变量。

另外 `histogram_quantile` 在采样太少的窗口里返回 `NaN` 是正常的（本例只 checkpoint 了一两次），
所以断言分两层：面板有结果（证明接线通）+ count 是有限且 ≥1（证明数值真到了）。
