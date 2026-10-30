# 编译 Pod 的无出网编译

本文记录 P1-026 的验收与一处策略 bug。工单原文写的是「sparse index 代理或
vendor 二选一」，实测结论是**两者都不需要**——真正缺的是一段从未被执行过的
NetworkPolicy。

## 1. 依赖从哪来

`deploy/Dockerfile.manager` 在构建阶段就把 cargo 的依赖缓存搬进了运行时镜像：

```dockerfile
# deploy/Dockerfile.manager:380-381
COPY --from=builder --chown=ubuntu /home/ubuntu/.cargo/registry /home/ubuntu/.cargo/registry
COPY --from=builder --chown=ubuntu /home/ubuntu/.cargo/git /home/ubuntu/.cargo/git
```

并在 `$HOME/.cargo/config.toml` 里设了离线：

```toml
# deploy/Dockerfile.manager:370
[net]
offline = true
```

缓存规模实测 71775 个文件（约 1.5GB），包含 lock 里 5 个 git 依赖的 bare 仓库。
`offline = true` 的效果是：缺任何一个 crate 就**立刻**报错，而不是去网上找。

所以编译 Pod 不需要 crates 代理，也不需要 vendoring。工单里的这一项不成立。

## 2. 缺的是什么

`charts/feldera/charts/compiler/values.yaml` 里 `networkPolicy.enabled` 原本默认
**false**，而全仓库没有任何 e2e 打开过它（`grep -c networkPolicy
scripts/e2e-k8s*.sh` 只命中 P1-026 自己新增的脚本）。策略写了四年，从未执行。

「渲染得出」不等于「能工作」。P1-026 把它默认打开，并第一次真正验证。

## 3. P1-018 留下的一处选择器 bug

模板里第二条 egress 规则，注释写的是「The API server, which polls this pod」：

```yaml
# 修复前
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: {{ .Chart.Name }}   # ← 这是 compiler 自己
          app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - protocol: TCP
      port: {{ .Values.compilerPort }}
```

`.Chart.Name` 在 compiler 子 chart 里等于 `compiler`，而 API server 是
`controlplane` chart 的 pod，标签 `app.kubernetes.io/name: controlplane`。这条
规则永远匹配不到 API server，只是允许 compiler 访问自己。

实测（kind / bili-p1005）：

| 配置 | compiler → API server:8080 | compiler → 1.1.1.1 |
|---|---|---|
| 原策略（`name: compiler`） | 超时 exit 28 | 超时 exit 28 |
| 改后（`name: controlplane`） | **200** | 超时 exit 28 |
| 策略关闭 | 可达 | **301**（通） |

**为什么一直没人发现**：pipeline 编译是单向的。API server 发起编译请求，
compiler 执行，产物落在自己的 PVC 上，由 API server 主动来取。compiler 从不
回连 API server，所以规则写错也不影响编译。只有当 egress 策略真的打开、且
API server 需要主动拉取产物时，才会暴露成「取不到产物」。

修复是把它变成一个值，因为子 chart 读不到兄弟 chart 的元数据：

```yaml
# charts/feldera/charts/compiler/values.yaml
apiServerName: controlplane
apiServerPort: 8080
```

compiler 自连的那条规则（port 8085）保留，它服务于 `compileInThisPod=false`
的拆分拓扑。

## 4. 验收

`scripts/e2e-k8s-offline-compile.sh` 不读策略去推断，而是真的断网再编译：

1. 用 chart 打开 egress 策略，确认策略对象存在；
2. Pod 内访问 `1.1.1.1:80` 必须失败（按字面地址，绕开 DNS）；
3. 编译一个 pipeline，必须 `Success`；
4. `.cargo/registry` 的文件数在编译前后必须**不变**——这一步抓的是「本机缓存
   恰好完整所以能编译」的假通过：那种情况下编译会去下载，在真正的无网集群里
   才失败；
5. 产物出现在 compiler 的 PVC 上，且属于本次创建的 pipeline（删除后重建，
   排除复用旧产物的可能）。

实跑结果：

```
-- 1. the release runs with the compiler egress policy on
   egress policy present: feldera-compiler
-- 2. the compiler pod cannot reach the internet
   no route to 1.1.1.1
-- 3. a pipeline compiles with the internet unreachable
   compilation succeeded with no route out
-- 4. the compilation fetched nothing
   cargo registry unchanged: 71775 files before and after
-- 5. the artifact is on the compiler's claim
   published: pipeline_01a18aa9-..._ic_a40807c2...
PASS
```

第 2 步的断网是策略造成的，不是网络本来就不通——反向验证过：关掉策略后同一
个 Pod 立刻拿到 301。

## 5. 默认值

`networkPolicy.enabled` 现在是 **true**。理由：

- 母文档 §5.2 的要求是「编译 Pod 仅允许访问 crates mirror + 制品库」，一个
  默认关闭的访问控制不是控制；
- 它此前从未被打开过，所以「默认 false 是安全的」这一直觉没有证据支撑，而
  P1-026 证明了打开之后编译正常。

不实现 NetworkPolicy 的 CNI，或需要额外端点的部署，显式关闭或加白名单：

```bash
--set compiler.networkPolicy.enabled=false
--set 'compiler.networkPolicy.egressAllow[0].to[0].ipBlock.cidr=10.0.0.0/8'
```

这两个动作都写在 values 文件里，比默默出网可见。

## 6. chart 断言

`scripts/e2e-k8s-chart.sh` 新增两步，防同款 bug 复发：

- 渲染出的 NetworkPolicy 里必须有**同一条**规则同时含 `name: controlplane` 和
  `port: 8080`（分开写在两条规则里等于谁都不通）；
- `compiler.networkPolicy.enabled=false` 必须真的不渲染策略。

**这条断言的第一版是空转的**：它 `grep 'name: controlplane'` 匹配到了
controlplane chart 自己 Deployment 的标签，所以无论策略写什么都没关系。
写这段测试时我正好在修一个「grep 到了相似但不同的东西」的 bug。改成先切出
NetworkPolicy 文档、再按 `- to:` 分块匹配后，反向验证才真的红。

## 7. 与工单原文的差异

| 工单 | 实际 |
|---|---|
| sparse index 代理或 vendor 二选一 | 都不需要：依赖缓存已在运行时镜像内，`offline = true` |
| DoD：编译 Pod 无公网 egress 也能编译成功 | 已满足，并由 e2e 用真断网证明 |

工单的这一项实际工作量不是「搭 mirror」，而是「打开并验证一条从未执行的策略，
顺带修掉它的选择器 bug」。
