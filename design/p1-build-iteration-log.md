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
