# 共享测试用 Postgres：让 `cargo test` 能默认并行

## 1. 问题

`pipeline-manager` 的单元测试在启用了 `postgresql_embedded` 时，**每个测试各自
起一个内嵌 Postgres 集群**。并行跑整套测试时，这会以两种方式失败：

1. 一部分 `pg_ctl` 报 `could not start server`，测试报错
   `Unable to install test database: gave up after several attempts`
   （`crates/pipeline-manager/src/db/test.rs`）；
2. 测试进程退出后残留 `postgres -D <tmpdir>` 进程，下一次运行基线更差。

实测（macOS，`kern.sysv.shmmni = 32`）：并行跑 `runner::`（134 个测试）在第一轮
就出现安装失败；干净基线上连续多次运行后残留 postmaster 累积到 20 个，之后
每轮都失败。

## 2. 根因

每个新起的 Postgres 集群会分配 **System V 共享内存段**。macOS 把
`kern.sysv.shmmni` 硬编码为 32（Linux 默认 4096，且可调），**不能在运行时提高**。
并行测试很快把 32 个段用光，之后每次 `pg_ctl start` 都失败。这个失败信息看起
像"测试坏了"，实际是宿主机资源耗尽。

## 3. 走过的弯路

**方案 A：限制同时运行的集群数（信号量）。** 先实现过一次：全局信号量 + 槽位
租约。两轮实测都失败：

- 槽位在 `DbHandle::drop` 里释放 → 但大多数测试拿的是 `setup_pg()` 返回的
  `(StoragePostgres, TempDir)` 元组，**根本不构造 `DbHandle`**，槽位永不归还，
  整套测试在第 9 个测试处死等（挂起而非失败，更难查）。
- 改成把槽位绑到返回的租约上 → 但调用方写的是 `let (db, _temp) = setup_pg()`，
  Rust **按声明顺序析构元组字段**，`_temp` 先于 `db` 析构，于是槽位在 Postgres
  还是活的（它由 `db` 持有）的时候就被归还。上限形同虚设：设 cap=10 时实测
  同时存活 **17** 个 postmaster。
- 再改成"槽位延后到 postmaster 真正退出才释放"（detached 线程轮询
  `postmaster.pid`）→ 语义对了，但整套测试从 83 秒退化到 **688 秒**（cap=2），
  且仍有残留：测试二进制退出时线程被杀，清理来不及完成。

结论：**"限制并发 + 每个测试一个集群"这条路本身不对**，因为没有任何钩子能在
"集群开始关闭"这个时刻释放配额，而真正的稀缺资源要到关闭完成才释放。

**方案 B：整进程共享一个集群，每个测试一个数据库**（采用）。这是非 embedded
路径（外部 Postgres）早就在用的形态。

## 4. 实现

改动集中在 `crates/pipeline-manager/src/db/test.rs`：

- `shared_cluster::get()`（`tokio::sync::OnceCell`）在首次调用时安装并启动**唯一**
  的集群，绑定随机端口，数据目录是进程级 `tempfile::TempDir`。
- 集群对象被**存进静态值**（`SharedCluster { admin_url, _pg, _temp_dir }`）。
  这一点是必须的：`postgresql_embedded::PostgreSQL` 在 `Drop` 时会停掉服务器，
  如果只是 `get()` 里的局部变量，函数一返回服务器就没了，所有测试都会
  `Connection refused`（第一次实现踩过）。
- `setup_pg()` 每次 `CREATE DATABASE test_<uuid>`，用该库初始化
  `StoragePostgres` 并跑迁移，返回 `TestDatabaseLease`。
- `TestDatabaseLease::drop` 在后台线程上用独立 runtime 执行
  `DROP DATABASE ... WITH (FORCE)`。`Drop` 里不能 await，直接在测试 runtime 上
  block 会卡死；失败属尽力而为，库名唯一，进程退出后临时目录一并消失。
- 进程退出用 `atexit` 注册的 handler 跑 `pg_ctl stop --mode fast --wait`，
  不依赖任何 `Drop`（测试二进制退出时构造函数不一定被析构）。
- `url_with_database()` 单独抽出来并带单测：把 `host:port` 误当作库名、
  丢掉 query string 这类错误，症状会是"测试之间互相干扰"而不是"URL 拼错"，
  很难定位。

## 5. 验收

干净基线（`pkill -f 'postgres -D'`）上，`cargo test` **默认并行**：

| 范围 | 结果 | 耗时 |
|---|---|---|
| 全量（跳过 `compiler::`、`db_impl_behaves_like_model`） | **371 passed / 0 failed** | 71–77 秒（连跑 3 次全绿） |
| `runner::` | **134 passed / 0 failed** | ~47 秒（连跑 3 次全绿） |
| `db::types::` | **38 passed / 0 failed** | 0.02 秒 |

共享内存段峰值 **3**（基线 2 + 集群 1 段），运行结束残留 postmaster **0**。
改造前同一套测试在 `--test-threads=1` 下约 110–300 秒。

`postgresql_embedded` 未启用时（外部 Postgres）的构建与测试不受影响。

## 6. 已知限制

- **测试之间不再隔离服务器进程**。任何一个测试如果用 `SELECT ... FROM
  pg_stat_activity` 或依赖服务器级配置，会看到其它测试的连接。当前没有测试这么做。
- **一个测试把服务器搞崩会带走整套测试**（`DROP DATABASE ... WITH (FORCE)` 只
  影响自己的库）。这是换取并行能力的代价；回退方式是把
  `FELDERA_TEST_MAX_EMBEDDED_PG` 之类的开关重新加回来，或临时用
  `--test-threads=1`（在共享集群下串行仍正确，只是更慢）。
- `db::test::db_impl_behaves_like_model` 本机栈溢出，与本改动无关，仍单独跳过。
