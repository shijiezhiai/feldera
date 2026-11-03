# 上游 rebase 第二次演练记录（2026-11-03，P1-031）

流程本身写在 `docs/upstream-sync.md`；首次演练（21 个提交、387 个上游提交）写在
`design/rebase-rehearsal-2026-10-21.md`。本文记录第二次演练：**56 个自有提交过一次 760 个上游
提交的漂移**，是 P1 全部工作第一次整体追上上游主线。

两次演练的差别值得先说明，因为它决定了下一次怎么安排：第一次只重放了 P1-001…P1-007，
上游改动没有和我们改同一个函数；这一次 P1-019…P1-027 已经动过 `PipelineExecutor`、
`FtConfig`、迁移号这些上游也在改的地方，冲突是必然的，不是运气不好。

## 1. 演练输入

| 项 | 值 |
| --- | --- |
| 自有起点 | `p1-030` @ `2074d309e`（56 个提交，P1-001…P1-030） |
| fork point | `2ad179e05`（`ci: Prepare for v0.358.0`） |
| 目标 | `origin/main` @ `4dc3639a8` |
| 上游漂移 | 760 个提交（含 v0.358.0…v0.375.0 共 18 个 tag） |
| 演练场地 | `git worktree add /tmp/wt-p1030-upstream -b chain-rebase p1-030` |
| 命令 | `git rebase --onto origin/main 2ad179e05 chain-rebase` |
| 结果 | 56/56 重放成功，另加 1 个收尾提交 `9ce1307c9`（5 文件 +226/−149） |

关于目标为什么是 `origin/main` 而不是 tag：演练开始时最新 tag `v0.375.0` **已经是
`4dc3639a8` 的祖先**（我们 rebase 到的基线比它新 27 个提交），下一个 tag 还没发。上游的 tag
节奏是每天一个（v0.370.0 起连续 6 天），所以「等下一个 tag」最多一天，但演练本身不能因此停摆；
按 main 走吸收的漂移更多，gates 的结论对 tag 同样成立。

## 2. 耗时

| 阶段 | 耗时 | 备注 |
| --- | --- | --- |
| worktree + 建分支 | < 10 s | 复用已有 /target 缓存不适用，但检出很快 |
| `git rebase` 重放 56 个提交 | **约 36 min** | 17:48:51 起，18:24:33 结束重放 |
| 编译/测试返工到全绿 | **约 72 min** | 18:24 → 19:36，10 轮修改 |

重放本身比第一次（3.3 s / 21 提交）慢了两个数量级，原因是**每一次冲突停下都需要人工判断**，
而这次有 20+ 次停下（见 §3）。第一次只有 1 次（`Cargo.lock`）。

编译返工的 72 分钟里，真正花在「读懂上游改了什么」上的时间远多于「改代码」：例如
`ConfigSize` 的迁移要读懂 `size.rs` 的单位语义，`provision` 的签名变化要知道
`legacy_spelling` 是给旧 runtime 用的。

**结论：以月度为节奏时，一次 rebase 预留 2 小时是安全的（36 min 重放 + 72 min 返工）；
季度做则要留半天以上。** 返工时间与「我们改过上游也在改的文件」数量成正比，不随提交数增长。

## 3. 冲突清单

按上游漂移的性质分类，而不是按文件——同一个原因往往命中多个文件，修一次要一起修。

### 3.1 上游重命名（一次命中，影响面最大）

上游 f74271ece 把 `dbsp_adapters` 整体改名为 `dbsp_connectors`，`crates/adapters/src/` 变成
`crates/connectors/src/`。我们的 P1-016 改的是 `crates/adapters/src/server.rs`，路径已经不存在。

处理：整个 `crates/adapters/` 目录删除，改动搬到 `crates/connectors/src/server.rs`。同时发现
上游自己已经实现了 SIGTERM 时的 checkpoint（`checkpoint_on_sigterm` /
`checkpoint_before_exit`，带测试），与 P1-016 的 `spawn_shutdown_handler` 语义重叠——
**保留上游实现**，只把 P1 的 `begin_suspend` 重构与两个测试移植过去。这比硬塞两份停机路径
好：两套实现同时存在，行为取决于哪个先响应信号。

### 3.2 接口演进（编译能过、语义会坏的那类）

| 上游改动 | 我们的适配 |
| --- | --- |
| `ResourceConfig` 的 `memory_mb_min/max`、`storage_mb_min/max` → `ConfigSize` | `kubernetes_runner.rs` 加 `fn mebibytes(size: ConfigSize) -> u64`，全部读写点迁移 |
| `FtConfig.max_rss_mb` → `max_rss: Option<ConfigSize>` | `:1947` 的默认值填充改用 `resources.memory_max` |
| `PipelineExecutor::can_provision` 少一个参数 | 去掉 `runtime_config`，命名空间从已序列化的 `deployment_config` 推 |
| `provision` 尾三参 `runtime_config + is_gen2` → `runtime_selector + legacy_spelling` | 用 `runtime_selector.is_gen2()` 判断；`legacy_spelling.any()` 时按旧拼写在 Secret 里渲染配置 |
| `discover_namespace_from_runtime_config_json` → `..._pipeline_config_json` | `reaper.rs:240` 改调用点 |

`legacy_spelling` 这一项最容易漏：编译不会报错（参数在那儿），但如果忽略它，固定旧 runtime
的 pipeline 会拿到新拼写的配置，表现为启动时报「未知配置字段」。

### 3.3 共享命名空间（编译完全不报错，只有跑测试才发现）

| 冲突 | 表现 | 处理 |
| --- | --- | --- |
| 迁移版本号 | 我们的 `V37__group_role_membership.sql` 与上游新增的 `V37__sync_stopped_deployment_resources.sql` 同号 → Refinery 报 `duplicate key value violates unique constraint "refinery_schema_history_pkey"`，**99 个测试失败**共因这一个 | `git mv V37 → V38` |

这是本次最贵的一个错误：它伪装成 99 个互不相干的失败，实际是一个编号问题。§4 的硬规则写明
「rebase 时重编号」，但这次 rebase 的目标是 main 而不是 tag，迁移是上游在 rebase 过程中才
新增的，重编号没有自动触发——**脚本应当把「迁移号唯一」做成 rebase 后的强制检查**，
已加进 `scripts/post-rebase-gates.sh` 的 invariants。

### 3.4 并集合并产生的方法体错位（最隐蔽）

两个分支各自给同一个 `impl` 块追加方法时，git 的合并结果可能把 A 的方法体放进 B 的方法里，
或者把 B 的语句接到 A 的函数体内——**编译完全通过，语义已经错了**。

本次实测两处：

1. `pipeline_automata.rs` 的 MockRunner：P1 的 `take_check()` 故障分支落进了 `clear()` 的方法体，
   `check()` 退化成无条件 `Ok(json!(""))`。表现是三个故障注入测试断言 `Stopping` 拿到
   `Provisioned`；如果这几个测试不存在，这个错误会一直潜伏到线上 pod 消失时才发现。
2. 多个文件尾部「两边各追加测试」时，git 把上游函数结尾的 `}` 当成公共后缀吞掉，
   我们的测试函数体嵌进上游函数内。症状是 `error: this file contains an unclosed delimiter`，
   但报错指向一个完全不相干的函数。

**经验法则：并集合并之后，凡是「两边都动了同一个 impl / 同一个文件尾」的地方，必须逐个
读一遍合并结果，不能只看测试绿了没有。** 宽口径的启发式扫描（找可疑缩进/结构）会产生数千个
假阳性，不划算；按「两边都改过的 hunk」定点复查才可行。

### 3.5 测试夹具的连带变化

| 变化 | 处理 |
| --- | --- |
| 上游 `get_logs` 路由没变，但 P1-019 给它加了 `leadership: web::Data<LeadershipHandle>` 参数 | 上游那个手搭 `App` 的测试补 `.app_data(web::Data::new(leader()))`，否则提取失败返回 500 |
| `resolve_login` 多一个 `group_role: Option<Role>` 参数 | `db/test.rs:1303` 补末位 `None` |
| `ResourceConfig` 字面量字段改名 | k8s runner 测试 6 处改 `ConfigSize::from_mib(...)` |
| P1 把 `setup` 改名为 `setup_with_faults` | 补一个无故障包装 `setup()`，让上游测试不用改 |

## 4. 门禁结果

按 `docs/upstream-sync.md` §5 逐项跑（脚本化之前是手工跑的，见 §5）：

| # | 门禁 | 结果 | 耗时 | 备注 |
| --- | --- | --- | --- | --- |
| 1 | lockfile resolves | **pass** | ~2 min | 必须在远端容器跑；本机拉不到 `feldera/delta-rs` 的 pin rev |
| 2 | workspace compiles | **pass** | 4 min 28 s | `cargo check --all-targets` |
| 3 | manager unit tests | **pass** | ~66 s | `568 passed / 0 failed`，`--test-threads=4` |
| 4 | FT e2e | **未跑** | — | 缺 JDK 19+（远端最高 17）与编译器 jar，见 §6 |
| 5 | three images | **未跑** | — | release 档才跑 |
| 6 | kind smoke | **未跑** | — | release 档才跑 |
| 7 | enterprise print | **未跑** | — | 本机同样卡在 delta-rs 的 pin rev |

另外跑了两项不编译的门禁（`promtool`）：`check rules` → `SUCCESS: 7 rules found`，
`test rules` → `SUCCESS`。

**门禁 1 是本轮唯一一个「看起来像代码 bug、其实是环境」的失败。** 本机
`~/.cargo/config.toml` 走 USTC git 索引，拉 `https://github.com/feldera/delta-rs.git` 的
pin rev `45a7cd64…` 超时，报 `revision … not found`——错误信息像是仓库被删了，实际是镜像没跟上。
远端容器换成 rsproxy 稀疏索引后 2 分钟内通过。

## 5. 门禁已脚本化

本轮把 §5 的七道门禁写成了 `scripts/post-rebase-gates.sh`：

* 一次运行跑完全部选定门禁，**每道门禁的输出单独落盘**（`$TMPDIR/rebase-gate-<n>.log`）；
* 写出 `design/rebase-gates-<date>-<sha>.md`，含耗时表与失败清单（失败的取日志末 6 行）；
* **不因前一道失败而停**：编译挂了通常单元测试也会挂，同时看到比逐个排查省一轮；
* 编号门禁之前先跑四条 §4 不变量（lock 已提交、迁移号唯一、stub crate 未被忽略、无冲突标记），
  这四条都是秒级且历史上真出过问题。

```bash
scripts/post-rebase-gates.sh                    # rebase-check 档：1-4 + invariants
scripts/post-rebase-gates.sh --scope release    # 全部七道
scripts/post-rebase-gates.sh --only 1,2         # 只跑指定项
scripts/post-rebase-gates.sh --dry-run          # 只打印计划
```

## 6. 未做的事与缺口

1. **门禁 4（FT e2e）没跑成。** 它需要：`--features feldera-enterprise` 构建的 manager、
   SQL 编译器 jar（`sql-to-dbsp-compiler/build.sh`，要 JDK 19+ 与 Calcite 构建）、
   librdkafka 2.12.1+。远端只有 JDK 17，且 jar 是 dangling 软链（指向已不存在的
   `/home/ubuntu/feldera/build/`）。补齐这三项才能跑通，成本在一台能连外网的构建机上约 1 小时。
2. **门禁 5–7 按设计留给 release 档**，本轮没跑。
3. **`Cargo.lock` 的重建在远端做了，本机没做**——本机拉不到 pin rev。这意味着本机无法独立
   验证锁文件，任何与 lock 相关的判断都必须在远端做。

## 7. 结论与下次

* **重放 36 min + 返工 72 min ≈ 2 小时**，其中返工的那半取决于「两边都改过的文件」有多少，
  与方法论无关、与提交数无关。
* **最贵的一类错误不是冲突，而是静默错位**：迁移号重复（99 个测试一起红）和方法体错位
  （编译通过、语义错）。前者已进脚本的不变量检查，后者只能靠「定点复查并集合并的 hunk」。
* **下次直接跑 `scripts/post-rebase-gates.sh`**，把 `design/rebase-gates-*.md` 作为演练记录的一部分；
  本文的 §2 耗时表就来自那次运行。
* 补口的顺序建议：先补门禁 4 的三项依赖（JDK 19 + jar + librdkafka），因为它是唯一一个
  「验证了平台层契约」的门禁；其余六项验证的是「能编、能跑、能发」。
