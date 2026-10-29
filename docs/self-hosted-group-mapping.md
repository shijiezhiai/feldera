# 组到角色的映射（P1-024）

在此之前，平台只有两种角色来源：管理员通过 API 显式授予，以及登录时按
「首个用户 / 默认角色」兜底。IdP 里的组只被当成一张准入名单——`authorized_groups`
非空时，令牌的 `groups` claim 里必须含其中至少一个，否则 403；组与角色之间没有任何
关系。本文写清现在的关系是什么、为什么这样做，以及工单里写着但仓库里**不存在**的
东西。

## 1. 配置

```yaml
controlplane:
  auth:
    enabled: true
    provider: generic-oidc
    clientId: feldera-console
    issuer: https://idp.example.com/realms/feldera
  authorization:
    authorizedGroups: ["feldera-users"]   # 可选：纯准入名单
    groupRoleMaps:                        # 组 → 角色
      platform-admins: admin
      data-engineers: write
      analysts: read
```

渲染出的环境变量（`charts/feldera/charts/controlplane/templates/api-server.yaml`）：

| values | 环境变量 | 说明 |
|---|---|---|
| `authorization.groupRoleMaps` | `FELDERA_AUTH_GROUP_ROLE_MAPS` | JSON 对象；chart 用 `toJson` 渲染，`read`/`write`/`admin` 三值为 schema 枚举 |
| `authorization.authorizedGroups` | `FELDERA_AUTH_AUTHORIZED_GROUPS` | 逗号连接；纯准入名单 |

对应命令行参数 `--auth-group-role-maps`，默认 `{}`。

`groupRoleMaps` 只渲染在 `auth.enabled` 之内：没有认证就没有令牌，也就没有
`groups` claim 可读。manager 启动时对「配了映射却关了认证」直接报错而不是静默忽略，
理由见 §4。

## 2. 语义

**一个组既是准入也是角色。** 映射表的键同时充当准入名单，所以只配 `groupRoleMaps`
就够了，不必在 `authorizedGroups` 里重复一遍。需要"准入和角色由不同名单决定"时两
个都配，命中任一即准入（`validate_groups_authorization`）。

**多个组取最高。** 令牌带 `a=read, b=admin` 时角色是 `admin`，不是映射表迭代顺序
里的第一个。实现是 `GroupRoleMaps::role_for` 里的
`filter_map(...).max()`——映射表是 `BTreeMap`，但结论不依赖它：授权判断不能让容器
迭代顺序影响结果。

**`owner` 被拒。** `owner` 是平台级、跨租户的角色，和 `--owners` /
`--owner-trusts` 一样只从部署期配置来，运行期无法授予。映射表里写 `owner` 会在
启动时报错：

```
auth group role map for group `x` grants `owner`, which is configuration-only:
name the identity under --owners or --owner-trusts instead
```

## 3. 角色归属：三种情况

`tenant_membership` 有 `origin` 列（V36 引入），P1-024 加了一个值 `group`
（`V37__group_role_membership.sql`）。它回答的不是"谁创建了这行"，而是"谁现在掌管
这个角色"：

一句话规则：**映射表接管所有不是管理员显式授予的成员行。**

| 情况 | 行为 | 理由 |
|---|---|---|
| 管理员 API 授予过（`origin='api'`） | 不动 | 显式授予必须赢过登录，否则管理员提权几分钟后被打回 |
| 还没有成员行 | 按映射插入，`origin='group'` | 运维说了哪个组进来是什么级别，首个用户的兜底不该覆盖它 |
| `origin='group'` | 每次登录按令牌重写角色 | 把某人移出 IdP 的组，下一个令牌就降级——不需要管理员察觉 |
| `origin='claim'` / `'derived'` / NULL（V36 之前） | 同样按令牌重写，并改成 `origin='group'` | 这几种只记录"这行当初是怎么建出来的"，不代表有人选过它的角色；**打开映射表就是要对已有用户生效**，否则存量部署得人工迁移一遍 |

最后一行是实测纠正的：最初只让 `origin='group'` 的行跟随令牌，于是 kind 上
已存在的用户（P1-021 那轮以 `claim` 建的）配了映射却仍是旧角色，e2e 直接打回
`the mapped group granted 'read', not admin`。`IS DISTINCT FROM 'api'` 这个写法
同时解决了 V36 之前 `origin` 为 NULL 的行——`<> 'api'` 匹配不到 NULL。

第 2 条有个直接后果：**映射进来的首个用户不是 admin**。`first_user_role` 是
"谁先来谁是管理员"的默认，而运维一旦说了"这个组是 write"，把第一个进门的
人变成 admin 就是违背配置意图。

第 3 条靠 `upsert_member_role` 的一个细节实现：冲突时更新 `role`，且当新
`origin` 是 `api` 时一并更新 `origin`（`CASE WHEN EXCLUDED.origin = 'api'`）。
不这样做的话，一行曾经是 `group` 的成员被管理员改成 admin 后仍标着 `group`，
下一次登录就被映射表改回去了。

## 4. 与工单原文的差异（照现状调整过）

工单写的是「映射表配置面（fda + console 管理页）+ `oidc/trust_name.rs` 基础上的
trusted-identity 配置」。逐条对现状：

- **没有 fda 侧的对应能力**：`crates/fda` 是 CLI（`src/shell.rs`），它读写的是
  pipeline 和服务端配置，没有"改 manager 的 auth 配置"这条通道；manager 的认证配
  置全部来自命令行/环境变量，运行期没有写入口。所以 P1-024 落在 chart values +
  启动参数上，与 `owners`、`authorizedGroups` 同一形制。
- **没有 console 管理页**：console 能读到的只有自己的会话角色
  （`/v0/config/session`），没有任何"列出组映射"的接口，加一个管理页就得先加一组
  CRUD 接口和权限位。当前配置面是部署期的，因此没有管理页可加；这条与 P1-022 的
  `tenantNamespaces` 同类——配置走了 chart，就不是运行期资源。
- **`oidc/trust_name.rs` 管不到这里**：那个文件只校验 trust relationship 的**名字**
  （长度 `MAXIMUM_OIDC_TRUST_NAME_LENGTH = 100` 等），是 `oidc_trust_relationship`
  表的约束，与登录时的组无关。工单这句话的意图应是"trusted identity 那套配置"，
  但组的映射是登录路径的事，强行并到 trust 里会让"工作负载身份"和"人工登录身份"
  两种凭证共用一个配置，反而更乱。
- **`authorized_groups` 原本是纯名单**：改造后它仍是纯名单（准入），映射表是新增
  的第二条通路，没有把两者合并成一张表——合并会让"只准入不给角色"这种配置无处
  表达。

这些差异不改变工单的验收口径（组变更下一 token 生效、四级角色抽查），只改变了
配置面落在哪里。

## 5. 验证

单测（`cargo +1.96.1 test -p pipeline-manager --features feldera-enterprise --lib`）：

| 测试 | 守什么 |
|---|---|
| `auth::test::a_mapped_group_admits_without_an_authorized_groups_entry` | 映射表的键也是准入名单；变异验证过（短路成 `false` 会失败） |
| `auth::test::an_unmapped_group_is_refused_when_a_map_is_configured` | 未映射的组被拒；带映射时"无 `groups` claim"同样被拒 |
| `auth::test::the_admission_list_still_decides_on_its_own` | `authorized_groups` 单独配置仍然工作（没被新逻辑吃掉） |
| `auth::test::several_mapped_groups_yield_the_highest_role` | 多组取最高；空组/无组返回 `None` |
| `db::test::a_group_mapped_login_takes_the_mapped_role_not_the_first_user_role` | 映射压过 `first_user_role`，且成员表里的角色确实是映射值 |
| `db::test::a_group_managed_membership_follows_the_token` | 升级、降级、再次升级都在同一行；不带映射的令牌不动存量角色 |
| `db::test::an_existing_membership_takes_the_mapped_role_up` | 打开映射表后，以 `claim` 建的存量成员按映射改写并转成 `group`（这条是 e2e 失败后补的） |
| `db::test::an_api_granted_role_is_not_overwritten_by_a_group_mapping` | 管理员授予的角色不被下一次登录打回（这条抓到了真 bug，见 §3 末） |

chart 侧：`helm template` 渲染出 `FELDERA_AUTH_GROUP_ROLE_MAPS` 为 JSON
（`toJson`），schema 的枚举挡住 `owner` 与拼错的值。

远端 kind e2e：`scripts/e2e-k8s-groups.sh`（复用 P1-021 的 Keycloak 通路，同一张
chart、同一套令牌流程），在真实 IdP 上把用户搬来搬去：

```
-- a member of 'platform-admins' logs in as admin
   the map turned 'platform-admins' into admin
   the role is real: creating a pipeline returned 201
-- moving the user to 'analysts' demotes the same login to read
   the next token carried read, with no admin action in between
   the demotion is enforced: creating a pipeline now returns 403
-- a member of an unmapped group is refused
   the token was issued but the manager refused it: 401
-- returning to 'platform-admins' restores admin
   admin came back on the next token
PASS
```

它跑出三件单测覆盖不到的事：

1. **`groups` claim 要由 IdP 侧显式加 mapper 才有**（脚本加
   `oidc-group-membership-mapper`，`full.path=false`）。缺这一步时令牌里根本没有
   `groups`，平台会当成"没有可用的组"拒绝——与被移出所有组无法区分。
2. **越权是 401 不是 403**：`InsufficientGroups` 走
   `create_authz_json_error`（`auth.rs:246-251` → `ErrorUnauthorized`）。这是所有
   组检查的既有约定，脚本最初断言 403 是错的，改的是脚本不是代码。
3. **e2e 自己的坑**：`helm upgrade --reuse-values` 会保留上一轮的
   `controlplane.image.tag`，不显式 `--set` 就一直在测上一张镜像。第一版脚本因此
   连跑两次"失败"，实际测的是 p1-022 的旧二进制。

## 6. 剩余风险

- **组名是字符串**：IdP 侧改组名（而不是移动成员）等于换了一张表，平台不会报错，
  只会发现没人能登录。上线前应对照 IdP 的实际组名核对一遍。
- **claim 的形态**：只认 `groups` 这一个 claim（`OidcClaim::groups`，数组）。有的
  IdP 把它放在 `realm_access.roles` 或 `cognito:groups`，需要 IdP 侧加 mapper 转
  成 `groups`——这与 P1-021 的 audience mapper 是同一类前置。
- **没有审计**：角色因组变更而变时，只写一条 `Set role …` 之外的 info 日志（与
  API 授予同款），没有专门的"角色变更历史"表。P1-027 的审计日志接入时会补上。
