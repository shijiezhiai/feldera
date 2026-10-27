# P1-019: Helm 平台完整化（storage class 白名单 / PVC clamp / per-tenant namespace / 多副本选主）

状态：实现完成，待验收记录
依赖：P1-005（umbrella chart）、P1-011（资源范围）、P1-015（监控 Service）、P1-018（compiler 分离）
工单：`design/p1-work-orders.md:90`

## 1. 这一单解决什么问题

工单列了四件事：storageClass 白名单、PVC clamp、per-tenant namespace values、
manager 2 副本。前三件是"把已有的 Rust 侧能力暴露到 chart"；第四件不是。

`replicaCount: 2` 在 P1-019 之前是一个会毁掉所有 pipeline 的旋钮。原因在
`crates/pipeline-manager/src/runner/main.rs` 的 `reconcile`：每个实例各自每
`PIPELINE_DISCOVERY_INTERVAL`（2s）列出全部 pipeline，在**进程内存**里
`Arc<Mutex<PipelinesState>>` 建立 automaton，状态不进数据库。两个实例各起一套
automaton 共管同一批 pipeline，于是：

1. 双方各生成一个 `deployment_id` 并写进 `pipeline` 行；
2. `set_deployment_resources_status`（`db/operations/pipeline.rs`）是纯
   `UPDATE ... WHERE tenant_id AND id`，**没有版本谓词**，互相覆写不会被拒绝；
3. 每个 automaton 读到对方的 deployment_id，判定"这不是我的部署"，于是拆掉对方的
   对象。

可观测结果是 pipeline 永远进不了稳态，两个实例轮流重启它。这比"重复劳动"严重得多，
所以这一单没有按工单的字面去"在 values 注释里标明主副本行为"，而是实现了真正的选主：
注释不会阻止任何人在 `replicaCount: 2` 之后把节点扩到两个。

## 2. 选主设计

`crates/pipeline-manager/src/db/leader_election.rs`

**用 Postgres session 级 advisory lock，不用 lease/etcd/DB 表。**

- lock 属于连接：进程崩溃、主机与数据库分区、pod 被内核杀掉，连接消失的瞬间锁就释放，
  没有可调的租约时长，也没有留下双主的路径。
- `pg_try_advisory_lock`（非阻塞）而非阻塞版：阻塞版会把连接 park 在服务端，
  请求取消不保证能打断，等待中的 standby 与挂死的实例无法区分。
- key `0x6665_6c64_6572_6101` 是任意常量，**绝不能改**：改了会让旧部署与新部署
  持有两把不同的锁，滚动升级期间选出双主。

**leader 必须心跳自证。**

`HEARTBEAT_INTERVAL = 5s`、`HEARTBEAT_TIMEOUT = 5s`，每拍在**锁所在的那条连接**上
`SELECT 1`。失败即 `warn!("Leadership lost after {}s without a successful heartbeat")`
→ 释放 → 降为 standby。没有这一步，网络分区就会产生这个模块本要防的双主：
被隔离的旧 leader 会继续按它最后看到的状态 reconcile，同时新 leader 也在接管。

**HTTP 面不在锁后面。**

standby 照常服务 `/healthz` 与所有读写接口（答案都来自同一个数据库），否则 Service
只会路由到 leader，第二副本就失去了它存在的意义。唯一例外是跟随 pipeline 日志：
日志缓冲在**持锁进程的内存**里（`runner/main.rs` 的 `get_logs` 查
`PipelinesState`），所以 standby 对日志请求返回 **503 而不是 404** —— pipeline 是
存在的，只是日志流在另一个实例上，重试（或 failover 之后）会成功。返回 404 会教会
客户端放弃一个本来能跟上的 pipeline。

**参数**

| 常量 | 值 | 理由 |
|---|---|---|
| `ACQUIRE_TIMEOUT` | 10s | 单次抢锁最多等这么久；启动期在这里挂住会拖死整个进程（API 在角色确定前不服务），有界才能不让慢数据库变成 liveness 失败 |
| `RETRY_INTERVAL` | 2s | leader 死后秒级被接管（期间 pipeline 无人 reconcile），又不至于让每个 standby 打爆数据库 |
| `HEARTBEAT_INTERVAL` | 5s | |
| `HEARTBEAT_TIMEOUT` | 5s | 心跳挂起与心跳失败在本模块的语义里没有区别 |

`FELDERA_LEADER_ELECTION`（`CommonConfig.leader_election`，默认 false）开关。
单实例时关掉是刻意的：没什么可选，拿锁只会多一条数据库连接依赖，还会让误启的第二个
manager 静默变成不 reconcile 的 standby。chart 在 `replicaCount > 1` 时自动打开它。

## 3. 降级时正在跑的 automaton 怎么办

`stop_automatons` 直接 `abort()`，不尝试优雅停机。理由写在函数注释里：

- automaton 在 Kubernetes 调用中间没有干净的让出点；
- automaton 的写是单语句 UPDATE，被 kill 在两条语句之间只会留下一个下一任 leader
  照读的行；
- 下一任 leader 从行重新发现并驱动 pipeline，走的正是 manager 重启的同一条路径。

## 4. storage class 白名单

工单要求"IOPS≥16k/≥1000MB/s 盘型标签"。实际落地为**允许清单**，而不是在 chart 里
按 IOPS 标签过滤：磁盘性能标签（`ebs.csi.aws.com/volumeType: io2` 之类）是云厂商
各自的词表，chart 无法通用地解释它们；而平台能判定的事实是"这个 class 名是否在我允许
的集合里"。清单由部署者按自己集群的 class 命名填写。

`StorageClassPolicy::resolve`（`runner/kubernetes_runner.rs`）：

| 输入 | 允许清单关 | 允许清单开 |
|---|---|---|
| pipeline 指名 class | 用它 | 在清单内→用它；不在→`RunnerError::StorageClassNotAllowed`（HTTP 400） |
| pipeline 未指名 | 用 `storageClassName` 默认值，否则集群默认 | 同左，但默认值本身也要过清单 |

解析发生在 `provision` 的**第一件事**，早于任何对象创建：被拒绝的 class 不该在集群里
留下一个 PVC。解析结果存进 `KubernetesRunner.storage_class`，于是同一个部署的 claim 与
模板占位符 `{storage_class_name}` 一定一致。

空清单 + 开关打开 = 一律拒绝。这是故意的："我允许这些 class" 而一个都没列，安全读法
是"一个都不允许"。

## 5. PVC clamp

Rust 侧已经有 `ResourceLimits::clamp_storage`（含 proptest：clamp 幂等、上下界），
`storage_for` 在 `defaultStorageMegabyte`/`upperLimitStorageMegabyte` 之间夹。这一单
做的是把两个值接到 chart（`kubernetesRunner.defaultStorageMegabyte` /
`upperLimitStorageMegabyte`，模板里已经是 `--kubernetes-runner-default-storage-mb`
与 `--kubernetes-runner-upper-storage-mb`），并把这个事实写进本文档，而不是再实现一遍
钳制。

## 6. per-tenant namespace

`KubernetesRunnerConfig.kubernetes_runner_tenant_namespaces`：`tenant=<uuid>:<namespace>`
（逗号分隔，可重复）。`TenantNamespace::from_config` 在 runner 构造时解析一次。

解析优先级（`namespace()`）：

1. pipeline 运行时配置里的 `resources.namespace`（显式指定永远赢）；
2. 该 tenant 的映射；
3. `--kubernetes-runner-namespace`。

**格式错误的一条不会让整轮启动失败**，只是 `warn!` 跳过并落到共享 namespace ——
一条写错的条目不该让其他所有 tenant 的 pipeline 都provision 不了。

**namespace 必须预先存在**：manager 的 Role 是 namespaced（
`controlplane/templates/rbac.yaml` 注释明写不授予 cluster 级权限），无法创建 namespace。
`can_provision` 的 dry-run Secret 探测会在 provision 前给出"namespace 不存在"的错误。
不做"缺失就回退到共享 namespace"：那会把两个 tenant 的 pipeline 放进同一个 namespace，
正是这个设置要避免的隔离失效。

需要 `TenantId` 才能查映射，所以 `PipelineExecutor::new` 增加了 `tenant_id` 参数
（`runner/main.rs` 的 discovery 循环本来就有它，只是没往下传）。

## 7. chart 改动

| 值 | 渲染成 |
|---|---|
| `controlplane.replicaCount` | `Deployment.spec.replicas`；`>1` 时加 `FELDERA_LEADER_ELECTION=true` 与 required `podAntiAffinity` |
| `kubernetesRunner.enableStorageClassNamesSupported` + `storageClassNamesSupported` | `--kubernetes-runner-enable-storage-classes` + `--kubernetes-runner-storage-classes=a,b` |
| `kubernetesRunner.storageClassName` | `--kubernetes-runner-storage-class=<name>` |
| `kubernetesRunner.tenantNamespaces` | `--kubernetes-runner-tenant-namespaces=tenant=<uuid>:<ns>,...` |

required 反亲和而非 preferred：两个副本落在同一个节点会一起失效，共置不增加可用性
却会赔上 leader。单节点集群（如 kind）上 `replicaCount > 1` 会 Pending——这是正确的
拒绝，而不是要绕过的问题。

`values.schema.json`（新增）拒绝平台无法兑现的 values：
`replicaCount < 1`、空的 class 名、映射到空 namespace 的 tenant。

**被放弃的 schema 条款**（理由记录下来，避免以后有人"补回来"）：原本想用
`allOf/if/then` 校验"默认 class 必须在允许清单内"与"内存下界 ≤ 上界"。JSON Schema
无法比较两个值之间的大小，也无法做成员判断，只能对默认 class 硬编码为 `null`，
那会误拒合法的默认值。这两条在 manager 侧由 `StorageClassPolicy::resolve` 与
`ResourceLimits::canonicalize` 检查 —— 那里两个值都在手上。schema 说不了真话，
不如不说。

## 8. 验收

### 单元测试（127 passed，`runner::` 子树）

```
CARGO_NET_OFFLINE=true cargo +1.96.1 test -p pipeline-manager \
  --features feldera-enterprise --lib runner::
```

新增：

- `db::leader_election::tests` 5 个：禁用选举立刻是 leader / 新 standby 没有 leader 历史 /
  promotion 唤醒 waiter / 选举任务结束唤醒 waiter / **publish 同一角色不唤醒 waiter**
  （否则 standby 每 2s 唤醒所有等待者）；
- `kubernetes_runner`: 白名单内外、默认值过白名单、开关关闭透传、空清单拒绝一切、
  **provision 阶段被拒时不创建任何对象**（`POST` 计数 0）、resolved class 落到 claim、
  tenant 映射命中/未命中/格式错误跳过、显式 namespace 仍胜过 tenant 映射；
- `runner::main`: standby 的日志请求答 503、leader 对未知 pipeline 答 404（原来 6 个
  get_logs 测试因为新增 extractor 而 500，已补 `web::Data<LeadershipHandle>`）。

### chart golden + schema（`scripts/e2e-k8s-chart.sh`）

```
helm template ... > charts/feldera/tests/golden/default.yaml   # GOLDEN_UPDATE=1 录制
```

断言：默认值渲染与录制一致；`replicaCount=1` 不出现选举 env 与反亲和；
`replicaCount=2` 两者都出现；白名单与 tenant 映射到达 manager 的 flag；
三类无法兑现的 values 被 schema 拒绝。

golden 里数据库密码用 `--set controlplane.postgresPassword=golden-render` 钉住：
密码本来就是随机生成以防升级锁死，随机值会让每次渲染都不同。

### kind e2e（`scripts/e2e-k8s-leader-election.sh`）

真实集群两副本，六步：两 pod Ready → 恰好一 leader 一 standby（读日志）→ standby
`/healthz` 200 → 从 Service 创建 pipeline 并 start 后它真的 Running → standby 对日志
请求答 503 而 leader 答 200 → 删掉 leader 的 pod 后 standby 接管且 pipeline 仍是
Running。

### 第 6 步查出来的真缺陷：新 leader 把别人的 pipeline 当不存在

这一单最重要的产物不是 chart，是下面这个 bug。第一版 e2e 只断言「接管后不是
Failed」，于是它绿着通过了——而实际每一次接管都把正在跑的 pipeline 停掉了。

现象：删掉 leader pod 后，新 leader 在 `Leadership acquired` 之后 2 秒内把该
pipeline 从 `provisioned` 推到 `stopping`，`deployment_error` 写着
`the pipeline pod 'pipeline-<uuid>-0' does not exist in namespace 'feldera'`，
而同名的 StatefulSet 与 Pod 都还在（`kubectl get sts` 可见）。

根因在 `crates/pipeline-manager/src/runner/kubernetes_runner.rs` 的 `get_pod`：

```rust
let client = match &self.kubernetes {
    Some(client) => client.clone(),
    None => return Ok(None),   // ← 报成「pod 不存在」
};
```

`self.kubernetes` 是这个 runner 进程缓存的 k8s client，只在 `provision`/`stop`/
`clear` 里被填。被提升的新 leader 刚启动、还没 provision 过任何东西，缓存是
`None`；它从数据库重建 automaton 后立刻调 `check()`，`check()` 调 `get_pod()`，
拿到 `Ok(None)`，于是判定 pipeline 的 pod 已经没了 → `TransitionToStopping`。

「读不到」和「不存在」是两件事，而这个混淆的后果是**任何一次 failover 都会停掉
全部正在跑的 pipeline**——恰好是双副本要防的那个故障。修法是让 `get_pod` 自己
建 client（`kubernetes_client()`，它本来就会缓存），把错误如实报成配置错误：

```rust
async fn get_pod(&mut self, namespace: &str) -> Result<Option<Pod>, ManagerError> {
    let client = self.kubernetes_client().await?;
```

配两个单测：`check_without_a_client_reports_the_configuration_error` 与
`is_provisioned_without_a_client_reports_the_configuration_error`，都断言错误
信息**不含** `does not exist`。

教训有两条。其一是断言要长成"能失败"的样子：`Running` 与 `not Failed` 差着一个
真实故障，而只有前者会红。其二是这个 bug 靠单测很难发现——`fake_runner` 总是
预置好 client，测试环境里没有"刚被提升"这个状态；是这个 e2e 的第 6 步把状态造
出来了。

## 9. 已知限制

- **接管后新 leader 的首个 reconcile 会让每条 pipeline 各发一次读请求**。缓存
  client 的修法（见 §8）让 `get_pod` 在首次调用时建 client，代价是接管瞬间
  一次性的 client 构建，而不是每条 pipeline 各建一个——client 之后被缓存。
- **failover 期间 pipeline 有秒级无人 reconcile**（`RETRY_INTERVAL` 2s + 心跳超时
  上限 5s）。对已经 Provisioned 的 pipeline 没有影响（它的 pod 自己跑着），
  影响的是这个窗口内需要状态推进的 pipeline。
- **standby 的内存不预热**。接管后要从数据库重建全部 automaton，因此接管瞬间的
  首个 reconcile 比稳态慢，且此时日志缓冲是空的（客户端重试即可）。
- **advisory lock 不跨数据库集群**。多集群/多数据库的部署不在这套模型的适用范围内，
  那种拓扑需要外部选主服务（母文档 §5.7 另有 etdc/Lease 的讨论，留到 P3）。
- **`storageClassNamesSupported` 只按名字匹配**。清单里的 class 在集群里是否真的
  存在、是否真的满足 IOPS 要求，chart 与 manager 都不检查（检查需要 cluster 级
  read 权限，而 manager 的 Role 没有）。
