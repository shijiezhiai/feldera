# 上游 rebase 首次演练记录（2026-10-21，P1-008）

流程本身写在 `docs/upstream-sync.md`；本文只记录这次演练的输入、数据、冲突与结论，供下次
rebase 对照。

## 1. 演练输入

| 项 | 值 |
| --- | --- |
| 自有起点 | `p1-007` @ `1b28cab89`（21 个自有提交，58 个新增文件 + 9 个上游文件改动） |
| fork point | `2ad179e05`（`ci: Prepare for v0.358.0`），即上游 v0.357.0 之后 4 个提交 |
| 目标 | `v0.367.0`（2026-10-17，fetch 时的最新 tag） |
| 演练场地 | `git worktree add /tmp/feldera-p1008 -b p1-008-rehearsal p1-007`（不动主工作区） |
| 命令 | `git rebase v0.367.0`，冲突后 `git checkout --theirs Cargo.lock && git add` + `git rebase --continue` |

## 2. 上游漂移（fetch 前后）

| 项 | 值 |
| --- | --- |
| 演练前本地最新 tag | v0.357.0（2026-09-26） |
| fetch 后新增 tag | v0.358.0 … v0.367.0，共 10 个（v0.334.1/v0.334.2 为历史补全） |
| `2ad179e05..v0.367.0` 提交数 | 387 |
| 其中 `..v0.358.0`（fork 后第一个 tag） | 58 |
| 迁移版本 | 我们最高 `V36`，上游 v0.367.0 已到 `V37`（三周 +1） |

结论：上游节奏是 **3 周 10 个 tag、387 个提交**。季度 rebase 等于一次吃 400+ 提交，月度也仍在
100+ 量级；流程文档因此把"季度"降为下限、实际按月度 + 试点窗口前执行。

## 3. 冲突清单与耗时

| 文件 | 冲突类型 | 处理 | 备注 |
| --- | --- | --- | --- |
| `Cargo.lock` | binary merge（上游 `.gitattributes:1` 标 `merge=binary`） | rebase 中取**我们**一侧（rebase 里 `HEAD` 是上游提交，`--theirs` 即我们），rebase 结束后重置为上游版本再一次 `cargo metadata` 重建 | **唯一**冲突 |
| `.gitignore` | 自动合并 | — | 我们取反两行保留（`git check-ignore` 复验通过） |
| `Cargo.toml` | 自动合并 | — | `dbsp-enterprise`/`sync-checkpoint` 成员与 `postgresql_embedded` 改动都在 |
| 其余 6 个上游文件 | 自动合并 | — | `config.rs`、`pipeline_env.rs`、`runner.rs`、`all_in_one.rs`、`bin/pipeline-manager.rs`、`README.md` |

关于 `Cargo.lock` 的两次选边（本次演练的核心发现）：

* 第一次手工演练里我在第一个停止点取了上游一侧，结果**后续每个碰到 lock 的提交都再次冲突**（21 个
  提交里约 10 个改过 lock）——因为我们的提交链是围绕"我们的 lock"写的，换成上游 lock 后基线不再匹配。
* 改成在 rebase 过程中取**我们**一侧后，21 个提交只停 1 次。
* 但 rebase 结束后必须把 lock 重置回上游版本再重建，否则 lock 停留在旧依赖图上：v0.367.0 把
  `deltalake` 及 20 个同族包从 crates.io 换成了 `git+https://github.com/feldera/delta-rs?rev=c7f5926ec`。
* 这套"先取我们、再重置、最后重建"的两次选边已固化进 `scripts/rebase-onto-upstream.sh`。

耗时（墙钟，M 系机器，SSD）：

| 阶段 | 耗时 |
| --- | --- |
| worktree 检出（9 915 文件，150 MiB） | 约 40 s |
| `git rebase` 重放 21 个提交（含 1 次冲突停下）+ 自动解析 | 约 3 s |
| 同上，`scripts/rebase-onto-upstream.sh --skip-lock` 端到端 | **3.3 s** |
| **小计（到 rebase 完成）** | **< 1 min** |

提交完整性：`comm` 比对 `2ad179e05..p1-007` 与 `v0.367.0..HEAD` 的 subject 集合，**无缺失、无
重复**，21 个提交全部重放（SHA 全部变化，符合预期）。

## 4. 校验发现

1. **`Cargo.lock` 离线不可校验，联网重建受镜像影响。** `CARGO_NET_OFFLINE=true cargo +1.96.1
   metadata --locked` 0.5 s 内失败：`revspec 'c7f5926ecb0e2cf3307422150e0dfbfbee1f26d0' not
   found`——上游在 v0.367.0 引入了本地缓存没有的 git 依赖（`feldera/delta-rs`）。
   * 走本机默认配置（`~/.cargo/config.toml` 把 crates.io 换成 USTC 的 git 索引镜像）时，4 分钟
     超时，只打印 8 次 `spurious network error … transfer too slow: … transferred 0 bytes`。
   * 改用 rsproxy 稀疏索引（`--config source.crates-io.replace-with="rsproxy" --config
     source.rsproxy.registry="sparse+https://rsproxy.cn/index/"`）后约 2 分钟成功（时间都在下载
     `deltalake`/`parquet` 等新依赖）。
   * 重建结果相对上游 v0.367.0 的 lock **只多 17 行**：`dbsp-enterprise` 与 `sync-checkpoint`
     两个成员条目及其依赖，没有任何版本漂移——这就是"先取我们、再重置、最后重建"的干净终态。
   * 结论：gate 1 需要能用的 registry 镜像，本机默认配置不满足；镜像参数未写进脚本，按环境传
     `CARGO_*`/`--config` 即可。
2. **patch surface 目前仍然很小。** 387 个上游提交没有触碰 `all_in_one.rs`、
   `pipeline_env.rs`、`runner.rs`、`README.md`；只有 `config.rs`（我们 P1-007 也改了）和三个
   构建/元数据文件被上游动过，且都自动合并成功。这是运气，不是保证——P1-009 之后同一个
   `config.rs` 会被双方反复修改，届时再抽 `patches/`。
3. **`.gitattributes` 的 `merge=binary` 是硬约束。** 不是"建议"，是 git 根本不会给合并结果：
   每次 rebase 必然停在这一点，且 `git diff` 看不到内容。已写进
   `scripts/rebase-onto-upstream.sh` 的自动解析分支。
4. **迁移号是共享命名空间。** 上游三周把 V36 推到 V37；我们一旦开始写迁移，必须在 rebase 后
   重新编号（`max(上游, 我们) + 1`），否则 Refinery 启动即报重复版本。

## 5. 结论与后续

* rebase 本身是分钟级操作，**真正的成本在验证 gates**（三镜像重建是小时级）。流程文档因此把
  gates 分成"rebase check（1–4）"和"发布（1–7）"两档。
* 本次已把机械部分固化成 `scripts/rebase-onto-upstream.sh`（取 tag、建分支、重放、自动解
  `Cargo.lock`、重刷 lock）和 `scripts/apply-patches.sh`（patch 栈干跑与应用），patch 栈当前为空。
* 未做的事：rebase 后只做了结构性校验（提交完整性、文件归属、lock 重建），**没有跑编译与
  e2e**——这是 P1-009 开工前的第一件事，届时按 §5 gates 1–4 执行。
* 演练产物：本地分支 `p1-008-rehearsal`（21 个自有提交重放到 v0.367.0 + `chore(lock)` 提交，
  树是干净的）；临时 worktree `/tmp/feldera-p1008*` 已删除。重跑一遍用
  `scripts/rebase-onto-upstream.sh v0.367.0 --from p1-007`。
