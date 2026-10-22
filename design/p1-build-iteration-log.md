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
