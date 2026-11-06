# 混沌矩阵（P1-028）

矩阵是 `scripts/e2e-k8s-chaos.sh`：五类故障 × 两档容错，每格注入一次故障，
断言这一档承诺的东西，最后打印成一张表。

```
FAULT × TIER
              L1（优雅）              L2（崩溃）
kill-pod      精确不丢                恢复到最后一个 checkpoint，且计时（P1 出口：<2min）
delete-pvc    回到空库且可见          崩溃+丢盘也回到空库
drop-postgres 数据面不中断            控制面能收敛且可重启
drop-storage  继续摄入、事后补 checkpoint  恢复到不早于最后的 checkpoint
drop-kafka    输入断不致命、不重不漏   从 checkpoint 偏移重放、不重复
```

运行：

```bash
TAG=v0.357.0-52-gc13e46766-bili.1 bash scripts/e2e-k8s-chaos.sh          # 全矩阵
FAULTS=kill-pod,drop-kafka TAG=... bash scripts/e2e-k8s-chaos.sh        # 两类 × 两档
CELLS=drop-kafka:L2 TAG=... bash scripts/e2e-k8s-chaos.sh               # 一格
KEEP=1 CELLS=drop-storage:L1 TAG=... bash scripts/e2e-k8s-chaos.sh      # 留现场
```

一条命令跑完约 13 分钟（十格，编译缓存已热）。单个镜像 tag 不统一时用
`MANAGER_TAG` / `RUNNER_TAG` / `COMPILER_TAG` 分开指定。

**必须是 enterprise 构建。** 每一格都建带 `fault_tolerance` 的 pipeline，
而 FT 是编译期特性：OSS 构建的 manager 会在建 pipeline 时回
`400 InvalidRuntimeConfig ... enterprise feature: fault tolerance`，pipeline
进程侧（`crates/connectors/src/server.rs`）有同一个 `cfg` 门。所以用
`deploy/Dockerfile.manager`（它自带 `--features feldera-enterprise`）构建，
或自己构建时加同一个 flag。判断手上这个镜像行不行，两条都不用建 pipeline：
`curl :8080/v0/config` 的 `edition` 是 `Enterprise` 还是 `Open source`，
以及 `GET /v0/pipelines` 里 `platform_version` 有没有 `+enterprise` 后缀。

`kill-pod:L2` 额外计时：从 `kill -9` 到重启后的进程**按 checkpoint 的记录数
回答查询**为止，这段就是 P1 出口条件里的「Pod 崩溃自动恢复 RTO」——不是等到
`deployment_status` 变 `Running`（那只是 pod 起来了，进程还没应答）。判据是
`RTO_LIMIT`（默认 120 秒），超了直接 fail，所以这条承诺由每夜的矩阵守着，而不是只在验收那天量一次。

答案到达后还有一条更严的断言：manager 必须**当场**把这个 pipeline 报成 `Running`。
它依赖两件事——headless Service 发布未就绪的地址（否则容器重启的那一两秒里 DNS
直接查不到这个名字），以及 manager 不把一次连接失败当成终局。两者都在
`crates/pipeline-manager/src/runner/` 里修过一次（见 `design/p1-036-exit-rehearsal.md`
§7），因此这条断言同时也是那两个修复的回归检查：任何一边退回去，`kill-pod:L2`
都会在一秒内红。

最后一次整跑（2026-11-02，kind `bili-p1005`，manager `p1-027` / compiler
`p1-025` / runner `v0.357.0-52-gc13e46766-bili.1`）：**10 passed, 0 failed, in 785s**。

## 1. 为什么每格的断言不一样

五类故障听起来对称，其实承诺不同，写成同一句断言就只能用一个最弱的，
而那格也就失去了意义。三处必须分开说：

**删 PVC 不可能是"不丢数据"。** 这个仓库里没有对象存储后端：`crates/storage/src/lib.rs:219`
遍历 inventory，全仓只注册了 `default`（`posixio_impl.rs:1062`）与 `file`
（`:1086`）两个工厂，`StorageBackendConfig::Object` 必然返回 `BackendNotSupported`。
也就是说 PVC 里的 checkpoint 是**唯一**一份。删掉它之后再承诺"数据还在"是假的，
能承诺的只有"平台恢复正常、并且这个损失对操作者可见"——所以 L1/L2 断言的是
回到 0 行且查得到，而不是回到 1000 行。

同理，"断对象存储"这一格无法真的断开对象存储，注入的是**让存储目录不可写**。
效果等价：checkpoint 写不进去。

**断 PG 时不能用 manager 路径取证。** `forward_streaming_http_request_to_pipeline_by_name`
（`crates/adapters/src/../runner/interaction.rs:577-600`，走 `check_pipeline`）先查库再转发，
所以数据库一停，经 manager 的每个请求都失败。若用 manager 的 `/query` 断言"数据面还在"，
测到的是控制面而不是数据面。脚本里这几格一律 `kubectl exec` 进 pod 直连
`127.0.0.1:8080/query`。

**断 Kafka 的 L2 能承诺"不重复"，L1 只承诺"不丢"。** Kafka 是这套树里唯一能做到
精确一次的输入：消费偏移量随 checkpoint 落盘，恢复时从记录的偏移继续。L2 断言
恢复后总数**恰好**等于 topic 里的记录数（多一条说明偏移没被采纳，少一条说明恢复点错了）。

## 2. 各格的注入手法

| 故障 | 注入 | 为什么这样注入 |
|---|---|---|
| kill-pod L1 | `kubectl scale sts --replicas=0`，等日志出现 `exit checkpoint written` | 走 kubelet 的 SIGTERM 路径，等于运维的滚动重启 |
| kill-pod L2 | `kubectl exec <pod> -- kill -9 1` | entrypoint 用 `exec`，PID 1 就是 pipeline 进程；容器非 0 退出，kubelet 重启它 |
| delete-pvc | `kubectl delete pvc pipeline-<id>-storage` | 直击唯一副本 |
| drop-postgres | `kill -9 1`（postmaster） | 见第 3.1 节：数据库卷是 `emptyDir`，scale 到 0 会连 pgdata 一起丢，注入过强 |
| drop-storage | root helper pod 把 `/storage` 下顶层条目 chmod 500 | pipeline pod 是 uid 1000、目录属 root，pod 内 `chmod` 报 `Operation not permitted`；helper pod `runAsUser: 0` 挂同一 PVC |
| drop-kafka | `kubectl scale deploy/chaos-kafka --replicas=0` | 单 broker KRaft，缩到 0 等于输入彻底不可达 |

恢复 storage 权限时必须 `chmod 777`：`700` 时属主是 root，uid 1000 仍然写不进去。

## 3. 跑矩阵跑出来的三个真问题

### 3.1 控制面数据库落在 `emptyDir` 上（已修）

`charts/feldera/charts/controlplane/templates/db.yaml` 原本是：

```yaml
      volumes:
        - name: data
          emptyDir: {}
```

StatefulSet 也没有 `volumeClaimTemplates`。后果：数据库 pod 一被替换，pgdata 全丢，
而迁移只在 API server 启动时跑，于是此后每个请求都返回

```
Unexpected Postgres error: 'db error: ERROR: relation "pipeline" does not exist'
```

这不是理论问题——本矩阵第一次实现 drop-postgres 就是用 `scale --replicas=0` 注入的，
直接把控制面打成了空库，`/v0/pipelines` 全线 500。

修复：新增 `controlplane.postgresPersistence`（默认 `enabled: true`，`size: 10Gi`），
把数据卷改成 `volumeClaimTemplates`。实测：建一行 → `kubectl delete pod feldera-db-0`
→ 新 pod 起来后该行还在（修复前会消失）。

**升级注意**：`volumeClaimTemplates` 是 StatefulSet 的不可变字段，已存在的 release
直接 `helm upgrade` 会失败：

```
spec: Forbidden: updates to statefulset spec for fields other than 'replicas', ...
```

迁移步骤（旧数据本来就在 `emptyDir` 上，会随旧 pod 丢掉）：

```bash
kubectl delete sts feldera-db -n feldera --cascade=orphan   # 留住 pod
helm upgrade ...                                            # 新建带 PVC 的 STS
kubectl delete pod feldera-db-0 -n feldera                  # 让新 PVC 被绑定（WaitForFirstConsumer）
kubectl rollout restart deploy/feldera-controlplane-api-server   # 重跑迁移重建 schema
```

### 3.2 输入不可达时"重启"是致命的

这条不是 bug，是必须写进运维手册的行为：**已经在跑的** pipeline 遇到 broker 消失
只报 `AllBrokersDown` 并继续运行；但**正在初始化**的 pipeline 连不上输入就是致命错误：

```
ERROR dbsp_adapters::util: 't.c' input connector initialization: task failed:
FATAL error on input endpoint 't.c': BrokerTransportFailure
Error initializing the pipeline: FATAL error on input endpoint 't.c': BrokerTransportFailure
```

源码依据：`crates/adapters/src/transport/kafka.rs:80-95` 的 `refine_kafka_error` 只把
`RDKafkaErrorCode::Fatal` 判为致命，但连接失败发生在 `connect()` 里，被包装成了 fatal。
manager 随后把 pipeline 判为 `Failed`，StatefulSet 缩到 0：

```
deployment_error: RunnerCheckError "the pipeline's .../status returned 500,
  which is neither a status report (200) nor a temporary unavailability (503)"
```

`/status` 返回 500 是因为 `terminated_status()`（`crates/adapters/src/server.rs:1677-1699`）
在 controller 已终止且非 suspended 时返回 `INTERNAL_SERVER_ERROR`。

运维含义：**输入源恢复之前不要重启 pipeline**。矩阵因此引入了 `kafka_wait_serving`——
不只看 broker pod 是不是 Ready，而是通过 service 名 `--describe` topic，确认它真能服务
连接器、且 topic 还在。

脚本里也加了 `MAX_START_RETRIES`（默认 3）：初始化失败会把 pipeline 打回 `Stopped`，
自动重试比把剩余预算耗在轮询一个不会动的 pipeline 上更诚实。

### 3.3 测试夹具自身的两个假象

这两条留在文档里，因为它们都曾让矩阵"看起来通过"或"看起来失败"，而两次都是夹具的错：

- **broker 的日志目录在容器文件系统里。** 最初 chaos-kafka 是 Deployment + KRaft 无 PVC，
  scale 到 0 再回来，topic 连同数据一起没了。于是"broker 不可达"和"输入被抹掉"无法区分。
  已给它加 `chaos-kafka-data` PVC 与 `KAFKA_LOG_DIRS`。
- **进度行写到了 stdout。** `start_pipeline` 被 `id="$(start_pipeline ...)"` 调用，
  而 `wait_for_running` 往 stdout 打 `still starting (Provisioning); 900s left`，
  于是 `id` 变成了那串字，pod 名永远匹配不上，表现为"pipeline 消费了 0 条记录"。
  `say`/`note` 现在一律写 stderr。

## 4. 矩阵进 CI

`.github/workflows/chaos-nightly.yml` 每夜跑全矩阵，退出码即判据：任何一格失败（含
超时未跑完）都让 job 红。日志与矩阵表作为 artifact 保留。

自托管 runner 的前置条件与 `test-k8s-runner.yml` 相同：`K8s_E2E_RUNNER` 标签、
`df` ≥ 40GiB、kind 集群 `bili-p1005` 已存在、三个镜像已 `kind load`。

## 5. 没覆盖到的

- **真对象存储**：开源树没有该后端，`S3 容灾`（母文档 §5.5 的 L3–L5）无法在这里验证，
  要等 P2 的自研后端。
- **网络分区**：当前五类都是进程/卷/依赖级故障，没有 `NetworkPolicy` 或 `tc netem`
  造出来的半连通状态。
- **多副本**：控制面选主（P1-019）的故障切换没进矩阵，它需要另一条 e2e
  （`scripts/e2e-k8s-leader-election.sh`）。
