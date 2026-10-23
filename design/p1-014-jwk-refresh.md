# P1-014 — OIDC JWK 自动刷新

上游 `crates/pipeline-manager/src/auth.rs` 的模块文档曾明写：

> We don't yet refresh JWK keys automatically, but a restart of the pipeline manager will refresh the cache.

这份文档说明这次补上了什么、为什么必须是后台循环、以及哪些行为被刻意排除。

## 1. 问题：一条缓存命中永远不会去问 issuer

`JwkCache::get()` 的顺序是"命中就返回，未命中才去取"。这个设计只覆盖了一个方向的轮换：

| 场景 | 缓存未命中路径能否处理 |
|---|---|
| issuer 换到新 `kid` | 能 —— 新 token 的 `kid` 不在缓存里，触发一次拉取 |
| issuer 撤掉旧 `kid` | **不能** —— 旧 `kid` 还在缓存里，命中即返回 |

第二种才是安全相关的那个。凭什么要接受一个 issuer 已经撤回的签名密钥？密钥泄露后的轮换正好走这条路径：issuer 从 JWKS 里删掉旧 key，但所有还在有效期内的、由旧 key 签发的 token 在这个进程里继续被判定为合法，直到缓存项过期、并且恰好有请求把它挤出去。缓存生命周期（`DEFAULT_JWK_CACHE_LIFETIME_SECONDS = 120`）给了上界，但这是"两分钟"而不是"立即"，而且进程只要持续有命中就永远不会主动核对。

上游代码里原本留了 `// TODO: implement periodic refresh` 和 `// TODO: Introduce a minimum delay between refreshes` 两处标记，这次一起收掉。

## 2. 方案：一个循环，加上把刷新体抽出来

```
main.rs: run()
  └─ spawn_jwk_refresh(state, provider, 60s, shutdown_rx)   ← 只在配了 auth provider 时启动
       └─ 每 tick: refresh_login_keys(&cache, &source, &clients)
            ├─ fetch_jwk_oidc_keys(...)?          ← 失败则早返回，缓存不动
            └─ cache.replace(source, keys)        ← 整体替换，旧 kid 被清掉
```

三个决定值得记：

**整体替换而不是合并。** `replace()` 先 `cache_clear()` 再装入新集合。一次 JWKS 拉取返回的是 issuer 当前的**全部**密钥，因此"不在返回值里"就等于"已撤回"。合并会让被撤回的 key 继续存活 —— 而这恰恰是轮换要阻止的那一件事。`P1-014` 的 `replace_drops_a_retired_key` 与 `a_refresh_drops_a_key_the_issuer_retired` 都钉住这一点。

**失败不动缓存。** 拉取失败时只 `warn!` 并按原样保留旧 key。issuer 短暂抖动不该把整个认证打挂 —— 拿旧的（尚未过期）密钥继续验签，远比让所有人 401 好。未命中路径仍然按需重试，两条路互不依赖。

**60 秒，不更短。** 我们验签的 access token 生命周期是一小时；轮换后的 key 只需在它签发的 token 到达之前可见。一分钟远在预算之内，同时把稳态负载压到"每个 issuer 每分钟一次请求"。

## 3. 为什么把刷新体抽成 `refresh_login_keys`

第一版把 fetch + replace 直接写在循环体内，结果是循环**一行都没有被测试覆盖** —— 测到的只是它调用的两个零件。抽成独立函数后，`a_refresh_drops_a_key_the_issuer_retired` 可以真的驱动"第一次发布 key A，第二次发布 key B"，观察 A 被丢掉。

这不是为了测试而重构：抽出来的函数正好也是循环体唯一有判断的分支，剩下的 `select!` 与 `interval` 是 tokio 的职责，不需要我们测。

## 4. 范围之外（有意不做）

- **不做 jitter。** 多副本 manager 会在同一秒内一起刷新。issuer 每分钟多收 N 个请求（N = 副本数），对任何正常 IdP 可忽略；引入 jitter 会让"多快能看到轮换"这个性质变得不可预测，对这个补丁不值。
- **不做失败退避。** 失败后仍是每分钟一次。上游原本的 TODO 提过"minimum delay between refreshes"，但未命中路径本来就没有节流（`IssuerJwkCache` 那套 cooldown 是给联邦 issuer 用的，登录 provider 没有对应机制）。给循环单方面加退避会造成"循环在退避、请求路径仍在猛拉"的不一致。真要做得两条路一起做，属于另一个改动。
- **不改缓存生命周期。** `TimedCache` 的 120 秒仍然生效，循环只是保证旧 key 的存活时间不超过一个刷新间隔。

## 5. 测试

`crates/pipeline-manager/src/auth.rs` 的 `mod test`，新增 5 项（模块内共 24 项，全绿）：

| 测试 | 钉住的断言 |
|---|---|
| `replace_drops_a_retired_key` | 整体替换：旧 kid 消失、新 kid 可用 |
| `unknown_kid_fetches_the_current_key_set` | 未命中路径走完真实 HTTP（wiremock issuer），拉到的 key 能验签 |
| `a_refresh_drops_a_key_the_issuer_retired` | 驱动 `refresh_login_keys` 两次，issuer 中途换 key，旧 kid 失效 |
| `a_failed_refresh_keeps_the_previous_keys` | issuer 不可达时缓存不变、`source` 不变（下次仍指向同一 URL） |
| （既有）`valid_token` 等 | 登录流程未受影响 |

两个写测试时踩到的真问题，都值得记：

1. **`DecodingKey` 没有 `PartialEq`。** 无法断言"缓存里是新 key 本身"，只能断言"旧 kid 不在了 + 新 kid 在"。对整体替换语义来说这个代理足够紧。
2. **`drop(MockServer)` 不等于端口立刻关闭。** 第一版测试先 drop mock 再断言"拉取必然失败"，第一次跑红；改成轮询重试后又变成"10 秒内都没停"。wiremock 的 shutdown 是异步的。最终改用"绑定一个端口立刻释放"来构造确定不可连的 URL —— 这类"我以为 drop 是同步的"假设，是测试 flaky 的常见来源。
3. **issuer 校验比签名先失败。** 最初的失败信息是 `InvalidIssuer` 而不是签名错误，因为 `default_claim()` 里的 `iss` 是 `some-iss`。断言信息如果只写"验签失败"，排查方向会被带偏。

## 6. 上游提交形态

工单要求 upstream-first。改动只碰 `auth.rs`（`JwkCache` 加 `source` 字段、`replace()`、`get()` 简化、`refresh_login_keys`、`spawn_jwk_refresh`、模块文档）与 `main.rs`（启动/停止接线），不依赖任何自托管平台层代码，可直接作为独立 PR 发给 `feldera/feldera`。文档中原先"不自动刷新"的表述一并订正，否则补丁落地后注释就变成假话。
