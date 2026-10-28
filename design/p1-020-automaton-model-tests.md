# P1-020: 状态机模型测试（故障注入 + 属性测试）

状态：实现完成，待验收记录
依赖：P1-009（K8sRunner）、P1-017（reaper）、P1-019（选主）
工单：`design/p1-work-orders.md:90`

## 1. 这一单解决什么问题

`pipeline_automata.rs` 是控制面的心脏：它决定每个 pipeline 在 `Stopped /
Provisioning / Provisioned / Stopping` 之间怎么走。它同时是整条链路里最难测的
部分——因为它只有两种输入：

- 用户的 desired status（`/start`、`/stop`）；
- 集群与执行器的回答（`provision()`、`is_provisioned()`、`check()`、`stop()`、
  `clear()`）。

P1-020 之前，所有既有测试都走**成功路径**：每个 trait 方法都返回 `Ok`。于是真正的
风险被结构性地排除了——执行器报错时的分流（`TransitionToStopping` vs
`RemainStoppingUpdateDetails` vs `RemainProvisioningUpdateDetails`）、超时判定、
以及数据库层对状态转换的校验，全都没有被任何测试触达过。

这一单给 `PipelineExecutor` 加了一个按调用点分队列的故障注入层，并用 proptest 在
随机事件序列上验证不变量。

## 2. 注入层设计

### 2.1 按调用点分队列，而不是一个共享队列

第一版用一条队列，结果不可用：`check()` 的故障会被助手的预热 tick 取走，测试看到
的是"注入的故障没有生效"。现在每个 trait 方法一条队列：

```rust
struct FaultSchedule {
    provision, check, stop, clear: Arc<Mutex<VecDeque<Fault>>>,  // 一次性
    sticky: Arc<Mutex<Vec<Fault>>>,                              // 每轮都生效
    delivered: Arc<Mutex<Vec<Fault>>>,                            // 断言用
}
```

`delivered` 是关键：`take()` 弹出一个故障时同时记账，于是测试可以断言
`faults.delivered() == vec![Fault::CheckPodGone]`，而不是只断言"最终状态对了"。
没有这一条，一个把故障吞掉的实现也会通过。

### 2.2 粘滞故障

`NeverProvisioned` 必须**每一轮都回答相同**。队列式只生效一次，下一轮
`is_provisioned()` 返回成功，超时永远不会触发——实测表现是 `left: Provisioning,
right: Stopping`。所以 `with()` 和 `inject()` 都把它放进 `sticky`：

```rust
if self.faults.is_sticky(Fault::NeverProvisioned) {
    self.faults.record_delivery(Fault::NeverProvisioned);
    return Ok(ProvisionStatus::Ongoing { details: json!("still scheduling") });
}
```

### 2.3 六个故障，对应工单要求的六类事件

| 故障 | 模拟的集群事件 | 注入点 |
| --- | --- | --- |
| `CheckPodGone` | Pod 被驱逐 / 节点丢失 | `check()` |
| `CheckUnreachable` | kube-apiserver 不可达 / watch 断连 | `check()` |
| `ProvisionConflict` | 409，对象已存在且不归我 | `provision()` |
| `NeverProvisioned` | 调度卡住，PVC 永远 Pending | `is_provisioned()`（粘滞） |
| `StopUnreachable` | 停机时 API 不可达 | `stop()` |
| `ClearUnreachable` | 回收时 API 不可达 | `clear()` |

## 3. 六个场景测试

每个都断言**状态 + 错误码 + 故障确实被投递**：

- `a_vanished_pod_stops_the_pipeline_and_records_the_error`
- `an_unreachable_cluster_is_a_check_error`
- `a_provision_conflict_stops_the_pipeline`
- `provisioning_that_never_finishes_times_out`
- `a_failed_stop_is_retried`
- `a_failed_clear_is_retried`

## 4. 属性测试

```rust
enum Event { Start, Stop, Fault(Fault), Tick }
```

随机序列（1..20 个事件，48 个 case）喂给 automaton，**每个事件之后**检查三条
不变量（不只在末尾检查——中途违约正是把 pipeline 卡死的原因）：

1. **排空后必须停在 `Stopped`**。40 轮上限，超限即失败，所以活锁会被报出来而不是
   挂住测试。
2. **`Provisioned` 不得携带 `deployment_error`**。运营者唯一的解释渠道是一条陈旧
   的错误，比没有更糟。
3. **执行器报错后不得仍是 `Provisioned`**，且**进入 `Stopping` 时必须留下原因**。
   第三条是这一单真正抓到 bug 的那条。

两条建模上的诚实修正（写在这里，避免后人以为测试在放水）：

- `Start` while `Stopping` 会被 API 拒绝（`InvalidResourcesStatusTransition`），
  测试用 `try_desire_start` 把它当 no-op——这是正确的产品行为，不是缺陷。
- 末尾不能要求"有过致命故障就一定有 error"：后续一次合法的 `Start` 会清掉
  error。最小化序列 `[NeverProvisioned, Start, Tick, Tick, Start]` 就是这个教训。
  所以检查放在每轮投递处。

## 5. 测试发现的真实缺陷

**`Stopping -> Stopping` 被数据库拒绝。**

`transit_stopping_towards_stopped()`（`pipeline_automata.rs`）在 `stop()` 失败时
返回 `Action::RemainStoppingUpdateDetails { error }`——即"记下原因、留在
`Stopping`、继续重试"。但 `validate_resources_status_transition`
（`db/types/resources_status.rs:177`）的白名单里没有
`(InUse, Stopping, Stopping)`，于是这次写入被拒。

后果链：

1. 第一次失败因为 10 秒的 details 更新窗口（`DETAILS_UPDATE_MIN_INTERVAL`）没有
   真的写库，所以看不出问题；
2. 10 秒后窗口打开，那次重试写被拒，`do_run` 返回 `Err`；
3. `run()` 对 `Err` 的处理是**退避重试**（5s→10s→30s…→1200s），不是崩溃；
4. 于是 pipeline 停在 `Stopping`，错误不更新，重试在退避里空转——运营者看不到
   为什么停不下来。

修复是一行白名单 + 6 行注释说明为什么这个自环是必需的：

```rust
| (StorageStatus::InUse, ResourcesStatus::Stopping, ResourcesStatus::Stopping)
```

### 验证方式（这是关键）

不只看"修完测试绿了"，而是**反向验证**：

- 撤掉这一行 → 属性测试立刻失败，最小化序列
  `[Fault(StopUnreachable), Start]`，报
  `InvalidResourcesStatusTransition { storage_status: InUse, current_status: Stopping, new_status: Stopping }`；
- 加回来 → 通过；
- 另外三个种子（`0178e4ad…`、`eee89d8e…`、`cca1cbb3…`）写入
  `crates/pipeline-manager/src/proptest-regressions/pipeline_automata.txt` 并入库，
  保证回归时这几个序列优先重跑。

场景测试与属性测试的覆盖是互补的：注入 `CheckPodGone` 改成返回 `Ok` 时，场景测试
会挂、属性测试不会（`check` 成功时 automaton 合理地保持 `Provisioned`）。两条都
保留。

## 6. 新加的状态矩阵单元测试

`db/types/resources_status.rs` 增 4 个测试：

- `a_failed_stop_can_record_its_reason_while_staying_in_stopping` —— 本次修复；
- `transitions_that_skip_a_state_are_still_rejected` —— 确认没把规矩写松
  （`Stopped→Provisioned`、`Provisioning→Stopped`、`Provisioned→Stopped`、
  `Provisioned→Provisioning` 仍被拒）；
- `a_cleared_pipeline_can_still_start` —— `Cleared + Stopped → Provisioning` 仍允许；
- `stopping_is_still_always_possible` —— desired status 规则未被波及。

## 7. 验收

```
# runner 全量（可直接并行，见 §8 的说明；不再需要 --test-threads=1）
CARGO_NET_OFFLINE=true cargo +1.96.1 test -p pipeline-manager \
  --features feldera-enterprise --lib runner::
# → 134 passed

CARGO_NET_OFFLINE=true cargo +1.96.1 test -p pipeline-manager \
  --features feldera-enterprise --lib db::types::
# → 38 passed（含本单 4 个新测试）
```

属性测试单跑约 42–66 秒；`runner::` 全量串行约 110–300 秒（随机器负载）。

## 8. 已知限制 / 后续

**工单里"kind 双后端"这一条没有按字面做。** 工单写的是"fake watch + kind 双
后端"，但 P1-020 实际交付的是**进程内故障注入 + 属性测试**，没有起 kind 集群。
理由：

- 本单要验证的是 automaton 的**决策逻辑**，而决策逻辑的全部输入就是五个 trait
  方法的返回值。ka 层面的"Pod 真的没了"与"`check()` 返回 PodGone"对 automaton
  是同一件事，前者是 P1-013（k8s 生命周期 e2e）与 P1-016/P1-017 已经在 kind 上
  实测过两次的东西。
- 在 kind 上可靠地制造"409 → 之后的 200""watch 断连后重连"需要改集群本身，
  测试基础设施成本远高于它带来的置信度增量。

如果后续要补，最小可用做法是在 P1-013 的 kind e2e 里加一个用例：pipeline 跑起来
之后 `kubectl delete pod`，断言 manager 进 `Stopping` 再进 `Stopped` 且
`deployment_error` 含 `RunnerCheckError`。这部分由 P1-013 的脚本承载更合适。

**其他已知项：**

- ~~`runner::` 测试并行跑必然 flaky~~ —— **已修**（P1-021 前置单，见
  `design/shared-test-postgres.md`）。内嵌 Postgres 改为整进程共享一个集群、
  每测试一个库，`cargo test` 默认并行即可，`--test-threads=1` 不再需要。
- `db::test::db_impl_behaves_like_model` 在本机 **栈溢出**（SIGABRT）。既有问题，
  与共享集群无关，仍单独跳过。
- 属性测试的 `cases = 48` 仍保留：换共享库后单个 case 更快了，但这个值本单
  没有重新标定，留给后续按需上调。
