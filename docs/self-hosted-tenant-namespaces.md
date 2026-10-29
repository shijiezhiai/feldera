# 每租户命名空间与配额（P1-022）

平台默认把所有租户的 pipeline 放在同一个 namespace 里。要让"这个租户最多能用
多少"成为可执行的限制，先得让这个租户的 pipeline 独占一个 namespace，因为
`ResourceQuota` 统计的是 namespace 里的总量；挤在一起时，配额只能是整个平台的
总量，而不是某个租户的。

本文写清四件事：chart 上怎么配、控制面在什么时候建/删什么、配额打满时长什么样，
以及工单里写着但**与代码不一致**的地方。

## 1. 配置

```yaml
controlplane:
  kubernetesRunner:
    enabled: true
    # 键是租户 UUID，值形如 "<namespace>: <quota 键=值, ...>"
    tenantQuotas:
      "01a17648-0b1e-7000-8000-000000000001": "tenant-acme: requests.cpu=16,requests.memory=32Gi,limits.cpu=4,persistentvolumeclaims=8,requests.storage=200Gi"
      "01a17648-0b1e-7000-8000-000000000002": "tenant-globex: requests.cpu=8"
    # 打开后，创建/删除租户会同步建/删 namespace；关闭时平台只做检查与告警
    tenantNamespaceAutomation: false
```

值是"namespace 名 + 冒号 + 配额"，多个租户之间用 **`;`** 连接（渲染成
`FELDERA_KUBERNETES_RUNNER_TENANT_QUOTAS`）。这里有一个已经踩过的坑：

- **租户之间用 `;`，一个租户的配额键之间用 `,`**。命令行参数的分隔符是 `;`，
  因为 `requests.cpu=16,requests.memory=32Gi` 自己就用逗号分键；若按逗号切分会把
  一个租户切成两条坏条目。
- `helm --set` 里值含逗号必须转义成 `\,`，否则 helm 先按逗号切分。

配额合法键（`QuotaSpec::hard()`，见
`crates/pipeline-manager/src/runner/tenant_namespace.rs`）：
`requests.cpu`、`requests.memory`、`limits.cpu`、`limits.memory`、
`persistentvolumeclaims`、`requests.storage`。写别的键会让 manager 在启动时
报错而不是静默忽略。

租户的 UUID 在 `GET /v0/tenants` 里查；名字解析只在启动时做一次，改名不影响
映射，改 UUID 需要重启。

## 2. 控制面做什么

启动时（`TenantNamespaces::from_config`）：

- 没有 `tenantQuotas` → 整个功能不启用，**完全不碰集群**（不给没有 K8s 的部署
  增加负担）。
- 有配额 → 每个条目解析成 `TenantNamespacePlan`（tenant UUID、namespace、配额、
  LimitRange 默认值）。

自动化开关（`tenantNamespaceAutomation`）：

| 开关 | 租户创建 | 租户删除 | 启动检查 |
|---|---|---|---|
| 开 | 建 namespace + `ResourceQuota` + `LimitRange`；失败则回滚删租户并报错 | 删 namespace（级联回收其中所有 pipeline 的资源） | 补齐缺失/漂移的对象 |
| 关 | 不建，只记录租户已有映射 | 不删，保留（避免误删正在跑的业务） | 只检查 namespace 是否存在，缺了打 warn |

关掉自动化是**默认**，因为删除租户时级联删 namespace 是破坏性动作：它会把里面
所有 pipeline 的 StatefulSet、PVC、Secret 一起带走。要平台替你管，就把开关打开。
开关打开但 `tenantQuotas` 为空时 chart 渲染直接 `fail`——那说明有人以为自己在
管租户命名空间，实际什么都没管。

平台给每个自己建的 namespace 打上两个标签：

- `feldera.com/managed-by=feldera-manager`
- `feldera.com/tenant-id=<uuid>`

只有带 `managed-by` 标签的 namespace 会在租户删除时被删。运维手工建的 namespace
即使登记在 `tenantQuotas` 里也不会被回收，避免把别人的命名空间删掉。

## 3. 配额打满时长什么样

pipeline 创建后 StatefulSet 会被 `kubectl apply`，但 Pod 被准入控制器拒绝，
所以 Pod **始终不存在**。

这里有一个实测推翻过的假设，值得写下来：**失败不在 StatefulSet 的
`status.conditions` 上**。在 kind 集群（k8s v1.33.1）上实测，配额打满时
StatefulSet 的 `status` 只有 `replicas: 0`，`conditions` 是空的。失败只体现在
一条 Event 上：

```
Warning  FailedCreate  statefulset/probe  create Pod probe-0 in StatefulSet probe
failed error: pods "probe-0" is forbidden: exceeded quota: probe, requested:
requests.cpu=4,requests.memory=8Gi, used: requests.cpu=0,requests.memory=0,
limited: requests.cpu=1,requests.memory=1Gi
```

（`count` 会随重试累加。）

因此 `is_provisioned` 的逻辑是：Pod 不存在时**列出该 namespace 的 Event，筛出
`involvedObject.kind=StatefulSet`、`involvedObject.name=pipeline-<id>`、
`type=Warning`、`reason=FailedCreate` 的那条**，有就立刻失败，而不是等到供给
超时（默认 180s）报一句"pod 不存在"。

两个容错点，都是刻意的：

- 列 Event 失败（例如 RBAC 没给 `events` 的 `list`）只打 debug 日志、不影响供给。
  只读不了 Event 就把部署判失败，会让权限收紧的集群完全没法跑。
- 只认 `StatefulSet` 名下、且 `reason=FailedCreate` 的 Warning；namespace 是共享的，
  别的 pipeline 的 Event 混在同一个列表里。

实测错误串形如：

```
the tenant's namespace has no room for this pipeline: pods
"pipeline-<uuid>-0" is forbidden: exceeded quota: tenant-acme, requested:
requests.cpu=4, used: requests.cpu=16, limited: requests.cpu=16.
Free capacity by deleting or shrinking another pipeline in the same tenant,
or raise the tenant's quota
```

前半段是 Kubernetes 自己的消息（原样保留，包含 requested/used/limited 三组数字，
运维据此算还要释放多少），后半段是平台给的动作建议。

非配额原因的 `FailedCreate`（例如节点 CPU 不足）同样立刻失败，但不带配额建议。

## 4. 与工单/直觉不一致的地方

- **工单说"租户创建→namespace + ResourceQuota（cpu/mem/storage 总和）+
  LimitRange 默认值"**，三者都由本单实现，但 `LimitRange` 的默认值来自 chart 的
  `resourceLimits`（平台资源区间），不是每个租户单独配。理由：默认值的作用是让
  没有声明 requests 的 pod 也能被配额计入，它应当反映平台允许的尺寸，而不是租户
  的额度。
- **工单说"租户删除→级联回收"**：只在自动化开关打开时成立。关闭时保留 namespace，
  这是刻意的，见上表。
- **配额条目优先于纯 `tenantNamespaces` 映射**。同一个租户同时出现在两张表里时，
  按配额条目走；否则配额会圈住一个该租户 pipeline 并不在里面的 namespace——看着
  生效，实际什么都没管住。
- **namespace 的生命周期挂在租户 CRUD 上，不挂在 pipeline 上**，因为配额是按租户
  总量算的。
- 从配置里去掉某个租户的配额条目，**不会**删掉它已有的 namespace 和里面的
  pipeline；manager 在启动时打 warn 提示这些 namespace 不再被托管，由运维决定
  怎么处理。

## 5. 验证

单元测试（`cargo +1.96.1 test -p pipeline-manager --features feldera-enterprise --lib runner::`）：

- `runner::tenant_namespace` 15 个：配额解析、非法键、空配额不建对象、多个租户用
  `;` 连接、名字解析、同名 namespace 去重、标签、LimitRange 的默认值与上限，以及
  写进新 namespace 的 `RoleBinding`（绑哪个 `ClusterRole`、主体是哪个 service
  account）。
- `runner::kubernetes_runner` 中的 `is_provisioned_fails_fast_when_the_tenant_quota_refused_the_pod`
  与 `..._reports_a_statefulset_failure_that_is_not_a_quota`：配额失败立刻报错且
  带上 K8s 原始数字；非配额失败不带配额建议。

chart 渲染（`bash scripts/e2e-k8s-chart.sh`）：

- 两个租户的配额用 `;` 拼成一个环境变量；
- 关自动化时不渲染 `ClusterRole` 与 `TENANT_NAMESPACE_AUTOMATION`，开了才渲染；
- 开了自动化但没配额时渲染失败；
- runner 的 `Role` 与那座 `ClusterRole` 的规则逐行一致（见 §6.2）。

## 6. 两个只有跑起来才会暴露的缺口

### 6.1 自动化建的 namespace 里没有任何授权

chart 把 runner 的权限渲染成一个 `Role`，绑在 release 自己的命名空间里。租户的
namespace 是运行时才建的，那里没有任何绑定——manager 第一次去建租户的
StatefulSet 就被拒：

```
secrets is forbidden: User "system:serviceaccount:feldera:feldera-controlplane"
cannot create resource "secrets" in API group "" in the namespace "tenant-acme"
```

修法是让 chart 额外渲染一座 `ClusterRole`（`<release>-controlplane-pipeline-runner`，
规则与那座 `Role` 相同），manager 在创建 namespace 之后自己写一个 `RoleBinding`
指过去。主体和 `ClusterRole` 的名字来自配置
（`--kubernetes-runner-manager-service-account`、`--kubernetes-runner-tenant-cluster-role`），
因为 manager 读不出自己的身份：它自己就是一个 service account，API server 不告诉
它"你是哪一个"。

**第一版写错了**：我给那座 `Role` 打了聚合标签，指望 `ClusterRole` 通过
`aggregationRule` 把规则收上来。集群控制器的聚合只扫 `ClusterRole`，namespaced
的 `Role` 完全不参与，聚合结果是 `rules: null`——绑定写成功、权限是空的，比不写
更难查。现在两处规则并列写在模板里，由 chart 测试逐行比对防漂移（§5）。

### 6.2 StatefulSet 默认不滚动

`helm upgrade --set compiler.image.tag=...` 之后 `helm get values` 显示新 tag，
Pod 里跑的还是旧镜像：`StatefulSet` 的 `updateStrategy` 默认是 `OnDelete`。P1-005
撞过一次（`postgres:16` 的 Pod 活过了升级到 17 的那次 release），这单又撞了一次
（compiler 停在 `p1-018`）。两处模板都补了 `updateStrategy: {type: RollingUpdate}`。
