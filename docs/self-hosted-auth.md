# 面向自有 IdP 的登录（P1-021）

自建平台在自己的域名下提供服务，浏览器登录交给公司的 IdP，控制面只做令牌校验。
本文写清三件事：chart 上怎么配、实际跑通的验证是什么、以及工单里写着但仓库里
**不存在**的东西（避免下一个接手的人照着工单找不存在的参数）。

## 1. 配置

```yaml
controlplane:
  # 控制面用 HTTPS 对外时（OIDC 重定向 URI 必须与注册值逐字一致，
  # console 访问 http 却注册了 https 的回调就会在 IdP 侧被拒）
  httpsSecretRef: feldera-tls          # 内含 tls.crt / tls.key
  auth:
    enabled: true
    provider: generic-oidc             # 或 aws-cognito
    clientId: feldera-console
    issuer: https://idp.example.com/realms/feldera
  authorization:
    authAudience: feldera-console      # 令牌 aud 必须含此值
    authorizedGroups: ["feldera-users"] # 可选：附加 groups scope 并校验
  owners:
    - ops@acme.test                    # 平台 owner（部署期配置，运行期不可授予）
```

渲染出的环境变量（`charts/feldera/charts/controlplane/templates/api-server.yaml`）：

| values | 环境变量 | 说明 |
|---|---|---|
| `auth.provider` | `AUTH_PROVIDER` | `generic-oidc` / `aws-cognito` / `none` |
| `auth.clientId` | `FELDERA_AUTH_CLIENT_ID` | console 在授权请求里发它，控制面校验 `aud` 或 `client_id` |
| `auth.issuer` | `FELDERA_AUTH_ISSUER` | 启动时走 discovery，取不到就退出 |
| `authorization.authAudience` | `FELDERA_AUTH_AUDIENCE` | 默认 `feldera-api`；**跟 IdP 里配的 audience 不一致就全 401** |
| `authorization.authorizedGroups` | `FELDERA_AUTH_AUTHORIZED_GROUPS` | 非空时才向 IdP 请求 `groups` scope |
| `owners` | `FELDERA_OWNERS` | 逗号连接；条目匹配「已验证邮箱 / 裸 sub / `<issuer> <sub>`」 |
| `auth.cognitoLoginUrl/LogoutUrl` | `AWS_COGNITO_LOGIN_URL` / `_LOGOUT_URL` | 仅 cognito 需要 |

`controlplane.auth.enabled=true` 时 schema 强制 `clientId`、`issuer` 非空，且
`provider` 不能是 `none`：否则 manager 会因缺变量 panic 进 CrashLoopBackOff，
把配置错误推迟到 pod 启动才暴露。`httpsSecretRef` 现在会真的把 Secret 挂到
`/tls`——此前只设了环境变量没有挂载，容器会读不到证书直接退出。

## 2. 与官方企业版文档的差异（别照抄）

仓库里没有 `enterprise/` 目录（那是闭源侧文档），工单引用的
`enterprise/authentication/generic-oidc.md`、`enterprise/https.md` 在此 fork 中
不可得。以本仓库源码为准的结论：

- **没有 `--auth-issuer` / `--auth-client-id` 命令行参数**：issuer 与 client id
  只从环境变量读（`crates/pipeline-manager/src/auth.rs`，`generic_oidc_auth_config`
  与 `aws_auth_config`）。
- **HTTPS 没有独立 Ingress 控制器**：manager 自己起 TLS（`FELDERA_ENABLE_HTTPS`
  + `FELDERA_HTTPS_TLS_CERT_PATH` / `_KEY_PATH`），也可以照旧在前面放外部
  Ingress 终止；两种路径都要让 console 的重定向 URI 与 IdP 注册值一致。
- **owner 不是数据库里的角色**：`FELDERA_OWNERS` / `FELDERA_OWNER_TRUSTS` 部署期
  配置，运行期 API 无法授予，防止有人把自己提权成平台 owner。
- **issuer 允许内网地址**：部署期配置的 issuer（`AUTH_PROVIDER` 指向的那个）走
  `OidcDestination::OperatorConfigured`，不受「必须公网 https」限制；这条分支是
  kind 上控件面用 Service DNS 访问 Keycloak 的前提。

## 3. 验证：真实 IdP 登录（`scripts/e2e-k8s-keycloak.sh`）

脚本在集群里起一个 Keycloak 26（`start-dev`），建 realm / public client（PKCE
S256）/ 测试用户 / audience mapper，然后 `helm upgrade` 把 chart 的 `auth.*`
指过去，再走一遍浏览器走的流程：

1. `/config/authentication` 公布的 issuer、client_id 与 chart 值一致（console 靠
   它拼授权请求，错了就是每次登录都失败且服务端无错）；
2. 授权码 + PKCE 换到令牌，控制面**接受**（说明 discovery、JWKS、audience 三条
   链路都通）；
3. 该令牌的角色是 `owner`：创建 pipeline 返回 201（只「能登录」但落成默认
   `read` 角色的话这里会是 403）；
4. 无令牌请求 401；**伪造签名**的同 claim 令牌同样 401（证明的是拒绝路径，不是
   只测了放行）。

```bash
export KUBECONFIG=...            # kind 集群
MANAGER_TAG=p1-021 scripts/e2e-k8s-keycloak.sh
# 控制面走 HTTPS 时：
HTTPS_SECRET=feldera-tls HTTPS_CA_CERT=/path/ca.pem MANAGER_TAG=p1-021 scripts/e2e-k8s-keycloak.sh
```

前置：`quay.io/keycloak/keycloak:26.0` 需预先 `kind load docker-image`（内网拉不
到外部仓库时，这是唯一的离线路径）。

## 4. 跑通过程中踩到的四个坑（都已固化进脚本与文档）

1. **`/config/authentication` 不在 `/v0` 下，其余都在。** 它是唯一免鉴权的路由
   （`crates/pipeline-manager/src/api/main.rs:1591` 注释），`/config/session` 和
   `/pipelines` 必须走 `/v0/…`。脚本一开始漏了前缀，拿到的是 404 而不是 401，
   看起来像"令牌没生效"。
2. **Keycloak 26 的健康端口是 9000，不是 8081。** 反映在 chart 之外的东西上：
   readinessProbe 打 8081 会让 pod 永远 NotReady。
3. **Keycloak 把 `KC_HOSTNAME` 写进登录表单的 action，而那个名字（Service DNS）
   测试机解析不了。** 只改 scheme+authority、保留 `session_code` 是安全的；把
   `KC_HOSTNAME` 指到 127.0.0.1 就会让令牌里的 `iss` 与 manager 侧不一致。
4. **Keycloak 的会话 cookie 带 `Secure`，curl 从 http 源不保存。** 浏览器在
   localhost（可信源）下会接受，所以脚本自己从响应头搬 cookie，而不是换成 TLS
   去"测试 Keycloak 的 cookie 策略"。

另有一条纯协议要求：PKCE 的 `code_verifier` 按 RFC 7636 必须 ≥43 字符，短于
该值 Keycloak 返回不透明的 400，看不出是 PKCE 问题。

## 5. 剩余风险

- **外部依赖**：真实公司 IdP 的 realm 配置（回调白名单、audience mapper）不在本
  仓库控制内，S1 末就需发起，脚本里的 Keycloak 只是替身。
- **ID token 与 access token 的差别**：console 通过 `oidc-client-ts` 拿 access
  token 发请求；IdP 若把 audience 只放进 ID token，控制面会 401（Keycloak 需要
  额外的 audience mapper，脚本已演示）。
- **登出**：generic-oidc 只做本地令牌清理，IdP 侧会话要用户在 IdP 登出。
