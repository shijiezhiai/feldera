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
