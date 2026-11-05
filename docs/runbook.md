# Runbook v1

The four things an operator does: **deploy it**, **upgrade it and get back if the
upgrade is wrong**, **put a team on it**, and **work out why something is
broken**. This page is the entry point for all four. It is written for someone
who has not seen this system before and has a terminal, a cluster, and no
colleagues awake.

Everything here is a command you can paste, against names the chart actually
creates:

| what | name |
| --- | --- |
| release | `feldera` (a `helm` release name you choose) |
| namespace | `feldera` |
| API server | Deployment `feldera-controlplane-api-server`, Service of the same name, port 8080 |
| compiler | StatefulSet `feldera-compiler` |
| database | StatefulSet `feldera-db` (bundled Postgres), Service `feldera-db`, port 5431 |
| pipeline metrics target | any Service labelled `feldera.com/metrics-scrape=true` |

Substitute your release name throughout; nothing else changes.

**What this version does not cover.** Standby pipelines and control-plane
failover are P3. What exists today is a leader election between manager
replicas (§2.4), not HA of the data plane. §5 says exactly where the line is, so
nobody reads the rest of this page and assumes more than it promises.

## 1. Deploy

### 1.1 What you need before the first command

- A Kubernetes cluster you can `kubectl apply` into, with a StorageClass that
  can provision `ReadWriteOnce` volumes. Pipelines keep their state on those
  volumes; without one, every pipeline sticks at `Provisioning`.
- `kubectl` and `helm` v3 on your machine, able to reach the cluster.
- The three images, reachable *by the cluster*: `feldera-manager`,
  `feldera-compiler`, `feldera-runner`. Build them with
  `deploy/build-images.sh` — see `docs/self-hosted-images.md` — which tags them
  `localhost:5001/feldera-*` and, with `PUSH=1`, pushes them to a local registry
  on port 5001. The chart asks for exactly those names, and **a cluster does not
  resolve `localhost:5001` to your machine's registry**; either give the cluster
  a route to a registry and set `controlplane.image.registry` (plus the compiler's
  and the runner's) to something it can pull, or load the images into the nodes
  directly, as the section below does for kind.
- Postgres: bundled by default (a StatefulSet with a 10Gi volume). To use an
  external one, set `controlplane.postgresExternal=true` and
  `controlplane.felderaDatabaseSecretRef` to the **connection string itself**,
  e.g. `postgres://feldera:<password>@db.example:5432/feldera`. The field name
  says Secret, and the enterprise chart reads it as the name of one with a
  `.connection_url` key; this chart passes the value straight through as
  `--db-connection-string` (verified with `helm template`). Keep it in a values
  file you do not commit.

On kind specifically, an image that is in the local Docker daemon is not
automatically in the node, and the node has no registry to fall back on. Load it,
or the pods sit in `ErrImagePull`:

```bash
kind load docker-image --name <cluster> localhost:5001/feldera-manager:<tag>
kind load docker-image --name <cluster> localhost:5001/feldera-compiler:<tag>
kind load docker-image --name <cluster> localhost:5001/feldera-runner:<tag>
kind load docker-image --name <cluster> postgres:17-alpine
```

Each of the first three is several gigabytes; two to four minutes apiece is
normal, and skipping this step is the most common way a first deploy fails.

### 1.2 Install

```bash
helm upgrade --install feldera charts/feldera \
  --namespace feldera --create-namespace \
  --set controlplane.image.tag=<tag> \
  --set compiler.image.tag=<tag> \
  --set controlplane.kubernetesRunner.image.tag=<tag> \
  --set controlplane.postgresPassword="$(openssl rand -hex 16)" \
  --wait --timeout 10m
```

Three flags, a password, and `--wait`. What each one does:

- **Three tags.** The manager, the compiler and the pipeline runner are separate
  images and version independently; the compiler tag also names the SQL compiler
  that builds every pipeline, so a mismatch shows up as pipelines that compile
  differently from what you think you deployed. Leaving one behind is the most
  common upgrade mistake, and nothing warns you.
- **`postgresPassword`.** Optional but recommended: left out, the chart generates
  a 24-character password, stores it in `<release>-db-insecure-secret`, and
  reuses that stored value on every later upgrade (it looks the Secret up, so
  `helm template` shows a random one each time). Setting it yourself is what makes
  the password reproducible. Inside the pod `psql` uses the local socket and needs
  no password, so this is the credential that opens the database **from outside
  the cluster** — and it is the one you must not lose along with the database
  volume.
- **`--wait`.** Without it the command returns before the API server is up and
  the next command in your script fails for no interesting reason.

`controlplane.auth.enabled` is off by default: no login, no API keys, anyone who
can reach port 8080 is an owner. That is fine on a laptop. It is not fine on a
shared cluster, and §3 turns it on.

### 1.3 Watch it come up

```bash
kubectl -n feldera rollout status deploy/feldera-controlplane-api-server --timeout=5m
kubectl -n feldera rollout status sts/feldera-compiler --timeout=5m
kubectl -n feldera get pods
```

Success is three pods `Running` and **ready**: the API server, the compiler, the
database, and (once you start a pipeline) one more per pipeline. The API server's
readiness probe is `GET /healthz` on 8080, so "ready" already means the HTTP
surface answers and the database connection is up — migrations run before the
server binds (see §2.2), which is why a migration failure shows as
`CrashLoopBackOff` rather than as a served 500.

On a **cold install the API server restarts once or twice before it stays up**,
with this in the previous instance's log:

```
Error: Postgres connection pool error: 'Error occurred while creating a new
object: error connecting to server: Connection refused (os error 111)'
```

The bundled database and the manager are created at the same moment and the
manager is the one that loses the race. The readiness probe keeps it out of
service while this happens, so it is a restart count of 1–2 and two or three
minutes, not a fault; `helm upgrade --install --wait` returning successfully is
the proof it settled. What would be a fault is a restart count that keeps
climbing (the database is genuinely unreachable — wrong Secret, or `db-0`
Pending on a volume) or `Connection refused` from an address that is not the
bundled database.

A rollout status that hangs on `sts/feldera-compiler` is worth reading rather
than waiting out: a pipeline reports `Pending` until the compiler has built it,
so a compiler that cannot start looks exactly like a pipeline that will not
start, ten minutes later. `kubectl -n feldera logs sts/feldera-compiler` names
the cause immediately.

### 1.4 Prove it works

Reach the API. `port-forward` is the honest way on a laptop, with two caveats. The
first is that an idle forward silently dies after a few minutes, and every command
then fails with a connection refused that has nothing to do with the platform.
The second is that a forward returns before it is usable — `curl` in the same
second gets an empty body, and a script that parses that empty body fails with
`Expecting value: line 1 column 1 (char 0)`, which is a client bug wearing a
platform bug's clothes. Wait for a 200 before you ask anything:

```bash
kubectl -n feldera port-forward svc/feldera-controlplane-api-server 8080:8080 &
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/v0/pipelines)" = 200 ] && break
  sleep 1
done
curl -s localhost:8080/healthz; echo
curl -s localhost:8080/v0/pipelines; echo      # [] on a fresh install
```

Run one forward at a time. Two forwards onto the same Service, or a forward and a
`kubectl exec` racing each other, produce `404 Unable to find matching target
resource method` and half-empty responses that look like the manager misbehaving.

Then run a pipeline end to end. The smallest one that exercises compile,
provision, and the data plane. Put the body in a file rather than on the command
line — the SQL quotes and the JSON inside it quote each other, and a heredoc is
the difference between a command you can read and one you cannot:

```bash
cat > /tmp/hello.json <<'JSON'
{
  "name": "hello",
  "program_code": "CREATE TABLE t (x INT) WITH ('connectors' = '[{\"transport\":{\"name\":\"datagen\",\"config\":{\"plan\":[{\"limit\":1000000}]}}}]');\nCREATE MATERIALIZED VIEW v AS SELECT * FROM t;",
  "program_config": {"profile": "unoptimized"},
  "runtime_config": {}
}
JSON
curl -s -X POST localhost:8080/v0/pipelines \
  -H 'Content-Type: application/json' -d @/tmp/hello.json | head -c 200; echo
curl -s -X POST 'localhost:8080/v0/pipelines/hello/start'
```

`datagen` takes **no `format` section** — it generates its own rows. Copying a
`"format": {"name": "json", ...}` from a Kafka or file connector is the most
common first mistake, and it fails at pipeline boot rather than at compile:
`Format not supported on input endpoint 't.unnamed-0': datagen endpoints do not
support custom formats: remove the 'format' section from connector specification`.
The pipeline then sits at `deployment_status: Running` with a `deployment_error`
and zero replicas, which looks like a crash and is a configuration problem.

`unoptimized` compiles the Rust part of the pipeline without optimizations: use
it for every smoke test, leave it off for real pipelines. **The first pipeline on
a fresh install still takes about five minutes**, and that is the compiler
building its dependency graph, not a hang; on a machine with slow storage it can
take longer. Two things help:

- Give every pipeline a `name` inside its connector list (`"name": "in"`); the
  SQL compiler warns `Connector nr. 1 for table 't' does not have a name`, and an
  unnamed endpoint is hard to find in a log ten minutes later.
- Turn on `controlplane.compilationCache.enabled=true` so the compiler's build
  cache survives pod restarts. Its chart comment says it exists for exactly this;
  the e2e suites leave it off because their clusters are disposable.

Watch the status until it is running:

```bash
watch -n2 'curl -s localhost:8080/v0/pipelines/hello | python3 -c "import json,sys; p=json.load(sys.stdin); print(p[\"deployment_status\"], p[\"program_status\"], p.get(\"deployment_error\"))"'
```

The pipeline is up when `deployment_status` is `Running` **and** `program_status`
is `Success`. `Success` — not `Running`, which is the value you will look for and
never see: the program status ends at `Success` once the program has booted, and a
program that failed to boot ends at `SqlError`, `RustError` or `SystemError` with
the reason in `deployment_error`. Checking `program_status == Running` is how you
end up watching a healthy pipeline for half an hour.

Delete it when you are done:

```bash
curl -s -X POST 'localhost:8080/v0/pipelines/hello/stop?force=true'
curl -s -X POST 'localhost:8080/v0/pipelines/hello/clear'
curl -s -X DELETE localhost:8080/v0/pipelines/hello
```

Three calls, in that order, because each one refuses to run while the previous
state has not settled: `clear` needs the pipeline fully stopped, `delete` needs
the storage cleared. They return 202 and the transition happens asynchronously —
poll the status, do not assume.

### 1.5 Monitoring, if you are installing it

The platform exports metrics whether or not anything scrapes them. On Docker
Compose, `--profile grafana` starts Prometheus and Grafana already wired to
`deploy/config/prometheus.yml`, which loads `deploy/config/feldera-alerts.yml`.
On Kubernetes there is a working reference in `scripts/e2e-k8s-monitoring.sh`;
the two values that matter are these:

```bash
  --set controlplane.kubernetesRunner.metrics.enabled=true \
  --set controlplane.kubernetesRunner.metrics.namespace=<monitoring-namespace>
```

`metrics.enabled` makes each pipeline expose a second, `ClusterIP` Service
labelled `feldera.com/metrics-scrape=true`; `metrics.namespace` names the
namespace allowed to scrape it, which the runner adds as an extra peer in the
pipeline's `NetworkPolicy` (that policy otherwise admits only the manager). Both
halves are needed — a Service nothing may reach is as useless as permission with
no target — and `FelderaScrapeTargetDown` is the alert that says one is missing
(§4.3).

Verify the rules parse and still fire *before* you believe a quiet dashboard —
both commands need no cluster and no network:

```bash
promtool check rules deploy/config/feldera-alerts.yml
promtool test rules deploy/config/feldera-alerts.test.yml
```

### 1.6 First-install failures, by symptom

| symptom | cause | fix |
| --- | --- | --- |
| `ErrImagePull` / `ImagePullBackOff` | image not in the node or registry (`localhost:5001` on a node that is not the build host) | `kind load docker-image`, or set the three `registry` values |
| `CrashLoopBackOff`, log says `migration N is missing from the filesystem` | the image is **older** than the database's schema — you installed an older tag over a database a newer one migrated | §2.3; this is not fixable by waiting |
| `CrashLoopBackOff`, log says `migration N is different than filesystem one` | two builds disagree about a migration's text; the database was migrated by a build that is not this one | same as above: restore, or use the build that migrated it |
| `helm upgrade` fails: `tenantNamespaceAutomation needs tenantQuotas` | automation with no quota entry to act on | add the tenant's quota first (§3.3), then turn automation on |
| `helm upgrade` fails: `ClusterRole ... cannot be imported into the current release` | the release name is already used in another namespace — Helm's ownership annotation pins a ClusterRole to one | use a different release name for the second install |
| pods `Pending`, event `pod has unbound immediate PersistentVolumeClaims` | no default StorageClass, or none that provisions RWO | set `postgresPersistence.storageClassName` and, for pipelines, `controlplane.kubernetesRunner.storageClassName` |
| API server ready but every pipeline stuck at `Provisioning` | the runner cannot create objects: RBAC, or the storage class it was told to use is not in `storageClassNamesSupported` | `kubectl -n feldera logs deploy/feldera-controlplane-api-server \| grep -i runner` |
| pipeline `Running` but `/status` in the manager times out, status flaps to `Unavailable` | manager and pipeline in different namespaces with a NetworkPolicy between them that does not admit the manager's namespace | §4.2, *Unavailable* |

## 2. Upgrade, and getting back

### 2.1 What an upgrade actually changes

Three things, in this order:

1. **Images and chart** — new pods, same database.
2. **Schema** — the manager runs its migrations at startup, before it serves HTTP.
   `crates/pipeline-manager/src/all_in_one.rs:105` calls `db.run_migrations()`
   before any service starts, so this is not a background job you can watch; it
   is a precondition for the pod becoming ready.
3. **Nothing about your pipelines** — they are StatefulSets of their own, and
   the manager's view of them lives in the database, not in its memory. A
   manager restart does not stop a running pipeline; when it comes back, the
   automaton reads each row and, from `Provisioned`/`Provisioned`, observes and
   enforces the runtime status (`crates/pipeline-manager/src/runner/pipeline_automata.rs:514`).
   Expect a brief window where pipeline status is stale, not a restart of the
   data plane.

### 2.2 Before you upgrade

```bash
# 1. note what you are on, so rollback has a target
helm -n feldera history feldera | tail -3
kubectl -n feldera get deploy feldera-controlplane-api-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# 2. take a database dump -- the only rollback that always works (§2.3)
kubectl -n feldera exec feldera-db-0 -- \
  pg_dump -U feldera -d feldera > feldera-$(date +%Y%m%d-%H%M).sql

# 3. make sure nothing is mid-transition; a restart during provisioning
#    leaves rows that describe objects that were never finished
curl -s localhost:8080/v0/pipelines | \
  python3 -c 'import json,sys
for p in json.load(sys.stdin):
    print(p["name"], p["deployment_status"], p["program_status"])'
```

Anything not `Running`/`Stopped` is worth resolving first. Take the dump even on
a test cluster: it is fifteen seconds and it is the difference between a bad
afternoon and a lost one.

### 2.3 Rolling back: what works and what does not

**Migrations are forward-only, and refinery refuses to start on a mismatch.**
Two refusals are configured by default (`refinery-core 0.9.2`,
`abort_divergent`/`abort_missing` both `true`) and this repository does not turn
them off:

- the database has a migration the running binary does not embed → the manager
  exits at startup with `migration N is missing from the filesystem`. That is
  exactly what an older image does against a database a newer image migrated.
- the database and the binary disagree about a migration's checksum → `migration
  N is different than filesystem one`.

So **`helm rollback` alone is not a rollback** once the new version has started
and migrated. It reverts the chart and the image, the old binary then refuses to
start, and the pod crash-loops with a successful-looking Helm revision behind
it. The order that works:

```bash
# 1. stop the control plane so nothing writes during the restore
kubectl -n feldera scale deploy/feldera-controlplane-api-server --replicas=0

# 2. restore the dump taken before the upgrade
kubectl -n feldera exec -i feldera-db-0 -- \
  psql -U feldera -d feldera -v ON_ERROR_STOP=1 < feldera-<when>.sql

# 3. go back to the previous chart revision (reverts image and values)
helm -n feldera rollback feldera <revision>

# 4. bring the manager back on that revision
kubectl -n feldera scale deploy/feldera-controlplane-api-server --replicas=1
kubectl -n feldera rollout status deploy/feldera-controlplane-api-server --timeout=5m
```

Restoring the dump replaces the schema wholesale, so run it only while the
manager is down; an instance running through it will serve 500s and may
re-apply migrations on top of a half-restored database. What the restored rows
mean for pipelines that are still running as pods is the one thing to check
rather than assume: compare `/v0/pipelines` against
`kubectl -n feldera get statefulset -l app.kubernetes.io/name=feldera-pipeline` and
reconcile the difference by hand (§4.2, *zombie row*).

If the new version started but did **not** migrate — that is, the rollback is
within the same schema version — plain `helm rollback` is fine and much faster.
To tell which happened, compare the schema version the database records against
the migration the binary embeds, rather than trusting the log: `run_migrations()`
logs at `info!` only when it actually applies something, so a start with nothing
to do is silent at the default level and "no line in the log" means both "zero
migrations" and "the pod never got that far".

```bash
kubectl -n feldera exec feldera-db-0 -- \
  psql -U feldera -d feldera -tAc 'SELECT max(version) FROM refinery_schema_history'
kubectl -n feldera exec feldera-db-0 -- \
  psql -U feldera -d feldera -tAc 'SELECT version, name FROM refinery_schema_history ORDER BY version DESC LIMIT 3'
```

The maximum version is the schema the database is on. If the image you are going
back to embeds a smaller maximum, its manager will not start (§2.3); if it embeds
the same one, `helm rollback` alone is enough.

### 2.4 Upgrading with two replicas

`controlplane.replicaCount=2` is the zero-downtime path, because the manager
elects a leader through a Postgres advisory lock
(`crates/pipeline-manager/src/db/leader_election.rs`): one process holds the
lock and runs the reconciliation loop, the others serve HTTP and take over if
the lock's connection dies. The chart turns the election on by itself once
`replicaCount > 1` (`charts/feldera/charts/controlplane/templates/api-server.yaml:105`,
`FELDERA_LEADER_ELECTION=true`); at one replica the process is leader
immediately and takes no lock, which its startup log says in as many words:
`Leadership election is disabled: this process reconciles pipelines`. The lock
key is a constant and its comment says why it must never change — a different
key would let an old and a new deployment elect two leaders during the upgrade
itself.

- Set `controlplane.apiServerAntiAffinity=required` when the nodes allow it;
  `preferred` (the default) puts both replicas wherever they fit.
- Migrations are serialized by Postgres, not by the chart: an instance starting
  up waits for another's migration rather than failing
  (`crates/pipeline-manager/src/db/storage_postgres.rs:2000-2005`, where the
  migration transaction deliberately has no lock timeout).
- With `replicaCount=1` (the default) the API is down for the length of the
  rollout. Expect `FelderaScrapeTargetDown` for the manager's `/v0/metrics`
  target during that window; it is not an incident, and it clears itself.

### 2.5 After the upgrade

```bash
curl -s localhost:8080/healthz; echo
curl -s localhost:8080/v0/pipelines | python3 -c 'import json,sys; [print(p["name"], p["deployment_status"]) for p in json.load(sys.stdin)]'
kubectl -n feldera logs deploy/feldera-controlplane-api-server --tail=50 | grep -iE 'migration|error'
```

Three things to confirm: the API answers, every pipeline is in the status it was
in before (a pipeline that was `Running` and is now `Stopped` means the upgrade
touched it, which it should not), and no pipeline reports `deployment_error`.

## 3. Put a team on it

### 3.1 Decide three things first

| decision | why it is not reversible later |
| --- | --- |
| the **tenant** name and id | a tenant's id is what the quota map and the namespace map are keyed on; the name can change, the id cannot |
| the **namespace** it gets | a pipeline's volumes live there; moving a tenant later means moving its storage |
| the **quota** | it bounds the *namespace*, so two tenants sharing one namespace share one quota |

Everything else — pipelines, keys, members — is reversible.

### 3.2 Turn on auth, then create the tenant

Auth on, one tenant per team. Leave the naming to a later pass (§3.3) — the chart
refuses `tenantNamespaceAutomation` without a quota entry to act on, because
there would be no namespace to keep in step:

```bash
helm upgrade feldera charts/feldera --namespace feldera \
  --set controlplane.auth.enabled=true \
  --set controlplane.auth.provider=generic-oidc \
  --set controlplane.auth.clientId=<client-id> \
  --set controlplane.auth.issuer=<issuer-url> \
  --set controlplane.authorization.authAudience=<client-id> \
  --set "controlplane.owners[0]=<your-email>"
```

The manager refuses to start with `auth.enabled=true` and an empty issuer — that
failure is at pod start, not at login, which is deliberate: a half-configured
auth is worse than none. `docs/self-hosted-auth.md` covers the provider side;
`docs/self-hosted-rbac-tenancy.md` covers roles and the `Feldera-Tenant` header.
Once auth is on, every call below needs the token of a platform owner:

```bash
OWNER_TOKEN=<the access token your IdP issued you>
```

```bash
curl -s -X POST localhost:8080/v0/tenants \
  -H "Authorization: Bearer $OWNER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"acme"}' | tee /tmp/acme.json
ACME_ID=$(python3 -c 'import json;print(json.load(open("/tmp/acme.json"))["id"])')
```

Keep the id: `tenantQuotas` and `tenantNamespaces` are keyed by it. A key that is
a name rather than a UUID is a mistake the manager warns about at startup and
then ignores — the namespace and the quota are created, the tenant is not mapped
to them, and its pipelines land in the shared namespace while the chart claims a
quota bounds them.

### 3.3 Give it a quota, in two passes

The map is keyed by tenant id, and the id only exists after the tenant does. So:
create the tenant (§3.2), then upgrade with the quota, which also restarts the
manager — and a restart is what applies it, because the quota is reconciled once
at startup (`crates/pipeline-manager/src/runner/tenant_namespace.rs:606`,
`verify_at_startup`):

```bash
helm upgrade feldera charts/feldera --namespace feldera \
  --reuse-values \
  --set-string "controlplane.kubernetesRunner.tenantQuotas.${ACME_ID}=tenant-acme: requests.cpu=4\,requests.memory=16Gi\,persistentvolumeclaims=12\,requests.storage=48Gi\,defaultRequest.cpu=100m" \
  --set controlplane.kubernetesRunner.tenantNamespaceAutomation=true
```

`--reuse-values` keeps the auth and tag settings from §1.2 and §3.2 instead of
requiring you to repeat them; a `helm upgrade` that forgets one resets it to the
chart default, and the chart default for `auth.enabled` is off.

The entry's shape is `<namespace>: <key>=<value>,...` — the chart prefixes the
tenant id and joins entries with `;` (`charts/feldera/charts/controlplane/templates/api-server.yaml:87`).
Inside one entry a comma separates the quota's own keys, which is why the commas
in `--set-string` are escaped: unescaped, Helm splits your quota into three
settings and the manager rejects or silently truncates it.

Automation is what lets the manager create the namespace and its quota; without
it, the namespace must already exist and the API server only warns at startup
that it does not.

Two rules decide whether that quota is usable at all, and both bite silently:

- `requests.cpu` (or `requests.memory`) requires **every** pod in the namespace to
  declare it. The platform does not add a CPU request to pipelines that did not
  ask for one, so without `defaultRequest.cpu` the quota refuses pipelines that
  never wanted CPU.
- The same goes for `limits.cpu`: do not write it unless you mean it.

Then confirm the namespace, the quota and the binding exist, and that nothing is
using them yet:

```bash
kubectl get ns tenant-acme -o jsonpath='{.metadata.labels}{"\n"}'
kubectl -n tenant-acme get resourcequota,limitrange
kubectl -n tenant-acme get rolebinding feldera-pipeline-runner
kubectl -n tenant-acme get resourcequota -o jsonpath='{.items[0].status.used}{"\n"}'
```

Sizing arithmetic and a measured example: `docs/self-hosted-tenant-namespaces.md`
§3.1.

### 3.4 Hand over a key, not a login

A pilot team needs one credential and one URL:

```bash
curl -s -X POST localhost:8080/v0/api_keys \
  -H "Authorization: Bearer $OWNER_TOKEN" \
  -H "Feldera-Tenant: ${ACME_ID}" \
  -H 'Content-Type: application/json' \
  -d '{"name":"acme-write","role":"write"}'
```

`role` may be `read` or `write`; `admin` and `owner` are never issuable as keys.
The response contains the secret **once** — it cannot be retrieved again — and
it looks like `apikey:<secret ending>` with a colon in it, which matters if you
put it in a shell variable built with `IFS=:`.

The key is bound to the tenant it was minted in; `Feldera-Tenant` selects among
the tenants the caller belongs to. Verify the boundary before handing the key
over, because it is cheaper to prove now than to explain later:

```bash
curl -s localhost:8080/v0/pipelines -H "Authorization: Bearer $ACME_KEY"   # only acme's
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/v0/pipelines \
  -H "Authorization: Bearer $ACME_KEY" -H "Feldera-Tenant: ${BETA_ID}"     # 403
```

Cross-tenant reads by name or id are **404**, not 403: the queries carry
`WHERE tenant_id = $1`, so a tenant's pipeline does not exist for anyone else.
403 means "you are not a member of the tenant you asked for"; 404 means "that
pipeline is not yours". Both are correct, and telling them apart is most of
debugging a tenancy complaint.

### 3.5 What "onboarded" means

- The tenant exists, with a namespace, a quota and a runner RoleBinding.
- The team has a `write` key, and that key sees its own pipelines and nobody
  else's (§3.4's two commands).
- The team's first pipeline reaches `Running`, and its storage lands on a volume
  in its own namespace (`kubectl -n tenant-acme get pvc`).
- Its metrics are scraped, so `FelderaPipelineNotRunning` and the checkpoint
  alerts would reach whoever is on call. The dashboard answers "is it healthy";
  `docs/operations/alerting.md` answers "what do I do now".
- `kubectl -n tenant-acme get resourcequota -o jsonpath='{.items[0].status.used}'`
  is non-empty once a pipeline runs — if it stays `{}`, the pipeline is not in
  that namespace, whatever the API says.

## 4. When it is broken

### 4.1 The first three commands

Before reading any alert, establish which of the three layers is at fault:

```bash
# 1. the platform: is the API up and does the database answer?
curl -s localhost:8080/healthz; echo

# 2. the pipeline: what does the manager think, and why?
curl -s localhost:8080/v0/pipelines/<name> | python3 -m json.tool | \
  grep -E '"(deployment_status|program_status|deployment_error|deployment_resources_status|storage_status)"'

# 3. the cluster: is the pod there, and what did it say?
#    Pipeline objects are named by pipeline *id*, not by name.
ID=$(curl -s localhost:8080/v0/pipelines/<name> | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
kubectl -n feldera get pods,statefulset,pvc -l "feldera.com/pipeline-id=${ID}"
kubectl -n feldera logs "pipeline-${ID}-0" --tail=50
```

`deployment_error` is where the manager writes the reason it gave up. Many
failures appear there and nowhere else.

Two naming traps in step 3: the Kubernetes objects are `pipeline-<id>` (so a
`kubectl get pods | grep <name>` finds nothing and looks like a missing pod), and
a tenant's pipeline lives in the tenant's namespace, not the release's.

### 4.2 Symptom → cause

| what you see | most likely cause | what to do |
| --- | --- | --- |
| API returns **401** everything | token expired (a run that spans a `helm upgrade` outlives a Keycloak access token) | re-authenticate; the platform is fine |
| API returns **403** on a tenant | the caller is not a member of the tenant named in `Feldera-Tenant` | add the membership (§3.2's endpoints) |
| API returns **404** for a pipeline that exists | you are acting in another tenant — every query is tenant-scoped | resend with the right `Feldera-Tenant` |
| pipeline `Pending` forever | compiler pod not up, or compilation is queued behind others | `kubectl -n feldera logs sts/feldera-compiler`; check `FelderaCompileQueueSlow` (§4.3) |
| pipeline refused, `deployment_error` mentions `exceeded quota` | the namespace quota is full | §3.3; the error names the axis. Deleting a pipeline does not free the quota until its storage is cleared |
| pipeline `Unavailable`, and `/status` in the manager times out | NetworkPolicy between manager and pipeline does not admit the manager's namespace, or the pipeline is in a tenant namespace while the runner assumed it was in its own | check the runner's NetworkPolicy for the manager namespace; this was a real defect once (P1-033) and the chart now passes `--kubernetes-runner-manager-namespace` explicitly |
| `CrashLoopBackOff` after an upgrade | migration refusal (§2.3) | read the log; restore or use the matching image |
| `stop`, `clear` and `DELETE` all fail with `DeleteRestrictedToFullyStopped` / `StorageStatusImmutableUnlessStopped` **and** the row says `provisioned` for objects that do not exist | someone deleted the pipeline's Kubernetes objects behind the manager's back | the row cannot be repaired through the API. Reset: scale the manager to 0, `psql -c 'DELETE FROM pipeline;'` in the database, scale back |
| every command fails with connection refused after a while | the `port-forward` died | re-run it; prefer `kubectl exec` for long work |
| `ErrImagePull` on a new tag | image not in the node | `kind load docker-image`, or push it |
| a pipeline's metrics are missing but it is `Running` | the metrics Service is not labelled, or the NetworkPolicy does not admit the monitoring namespace | §1.5; check `up` in Prometheus before believing an alert about the pipeline |

### 4.3 Alerts

Seven rules, all in `deploy/config/feldera-alerts.yml`, every one carrying a
`runbook_url` that points at a section of `docs/operations/alerting.md`. That
page is the per-alert procedure; this table is the index.

| alert | severity | page on |
| --- | --- | --- |
| `FelderaPipelineNotRunning` | warning | not `Running` for 15 minutes |
| `FelderaCheckpointFailing` | critical | >3 permanent checkpoint failures in 15 minutes |
| `FelderaCheckpointStale` | critical | no successful checkpoint for 3 intervals |
| `FelderaStorageVolumeFillingUp` | warning | storage volume over 80% |
| `FelderaCompileQueueSlow` | warning | compilation queued or running for 30 minutes |
| `FelderaProvisioningTimeout` | critical | provisioning for 30 minutes |
| `FelderaScrapeTargetDown` | critical | Prometheus cannot scrape a target |

Two rules of thumb, both learned the hard way:

- **Check `up` before believing an alert about a pipeline.** Per-pipeline series
  come from the pipeline pod's `/metrics`; manager-side series
  (`pipeline_program_status`) come from `/v0/metrics`. A rule that stops
  matching is usually a scrape target that went away, not a pipeline that
  broke.
- **A quota refusal is asynchronous.** `POST /v0/pipelines` returns 201 and the
  verdict arrives later in `deployment_error`. Nothing that must prove "zero
  penetration" can be asserted from the API response alone — assert against the
  Kubernetes objects and `resourcequota.status.used`.

## 5. Standby and control-plane failover (placeholder)

P3. Recorded here so the boundary is explicit rather than discovered during an
incident.

**Today**: `replicaCount=2` gives you a manager that survives a pod loss — one
leader reconciles, the other serves HTTP and takes the lock when the holder's
connection dies. Pipelines are unaffected by a manager restart.

**Not today**: a pipeline cannot be parked in a `Standby` state waiting for
another to fail over. The alert rules already ignore `Standby`,
`AwaitingApproval` and `Coordination` for that reason — they are long-lived by
design — but nothing creates them yet. There is no failover of a running
pipeline to a second copy, and no automatic promotion. If the node running a
pipeline dies, the pipeline restarts from its last checkpoint when the pod is
rescheduled; that is fault tolerance, not HA.

## 6. Where the rest lives

| you are asking about | read |
| --- | --- |
| building images, registries, supply chain | `docs/self-hosted-images.md` |
| sign-in, OIDC providers, owners | `docs/self-hosted-auth.md` |
| roles, the `Feldera-Tenant` header, 401/403/404 | `docs/self-hosted-rbac-tenancy.md` |
| group → role mapping from an IdP | `docs/self-hosted-group-mapping.md` |
| tenant quotas, namespace automation, sizing | `docs/self-hosted-tenant-namespaces.md` |
| Kubernetes Secrets a pipeline may reference | `docs/self-hosted-secrets.md` |
| chaos testing, failure injection | `docs/self-hosted-chaos.md` |
| compiling offline / without egress | `docs/self-hosted-offline-compilation.md` |
| a developer machine that builds this tree | `docs/self-hosted-dev-env.md` |
| JSON logs and the audit trail | `docs/operations/json-logging.md` |
| alerts and per-alert procedure | `docs/operations/alerting.md` |
| throughput, recovery and storage numbers | `docs/operations/performance-baseline.md` |
| what changed upstream and how to rebase | `docs/upstream-sync.md` |

## 7. First deploy, as executed

This page was followed, start to finish, on a cluster that had never run it. The
record is here for two reasons: it dates the numbers §1 and §2 quote, and it
lists what the first version of this page got wrong, which is the part a reader
cannot reconstruct.

**Environment**: 2026-11-05, single-node `kind` cluster on a 48-CPU / 124 GiB
machine, local-path storage on a spinning disk, images built from this tree and
tagged `p1-033`, pipeline runner `v0.357.0-52-gc13e46766-bili.1`. A separate
release already existed in the same cluster, in a different namespace —
deliberately, because that is the situation §1.6's first row describes.

| step | what happened | took |
| --- | --- | --- |
| §1.2 install | `helm upgrade --install ... --wait` succeeded | 28.8 s |
| §1.3 pods | API server restarted **twice** on `Connection refused (os error 111)`, then held; compiler and database never restarted | ~2 min to all-ready |
| §1.4 health + list | `{"status":"healthy"}`, `[]` | instant |
| §1.4 first pipeline: SQL compile | `program_status: CompilingSql` → `CompilingRust` | 2.3 s |
| §1.4 first pipeline: Rust compile | cold cargo target, `profile: unoptimized` | **4 min 55 s** |
| §1.4 first pipeline: running | `deployment_status: Running`, `program_status: Success` | — |
| §1.4 change the program, restart | same pipeline, warm cargo target | **< 59 s** |
| §1.4 stop / clear / delete | `202 "Pipeline is forcefully stopping"`, `202 "Pipeline storage is being cleared"`, `200`; list empty | ~40 s |
| §2.2 `pg_dump` | 715 lines | < 1 s |
| §2.4 manager restart (single replica) | `rollout restart`; the pipeline kept running on the same pod | 13 s |

The restart deserves the detail, because "the manager restarted and the pipeline
did not notice" is the claim that matters most in §2.1. Before: `Running
Success`, `deployment_id` `01a1a9c8…`, pipeline pod UID `97f91c14…`. After the
new manager pod was ready: the same `deployment_id`, the same pod UID, the same
status. The pipeline was never stopped, rescheduled, or recompiled. The new
manager's log says why it came up cleanly:

```
{"level":"INFO","target":"pipeline_manager::db::leader_election",
 "fields":{"message":"Leadership election is disabled: this process reconciles pipelines"}}
```

With `replicaCount=1` there is no election to win — that line is what §2.4's
`replicaCount=2` replaces with a lock, and it is also why the query in §2.3
prints the schema version rather than a migration log line:

```bash
$ kubectl -n runbook exec feldera-rb-db-0 -- psql -U feldera -d feldera -tAc \
    'SELECT max(version), count(*) FROM refinery_schema_history'
38|39
```

**What this page got wrong on its first draft**, both now fixed above:

1. The sample pipeline passed a `format` section to `datagen`, copying it from a
   Kafka example. It compiles — the SQL compiler does not validate connector
   options — and then the pipeline boots with zero replicas and a
   `deployment_error` naming `Format not supported on input endpoint`. Twenty
   minutes went into reading that as a platform fault. A sample in a runbook has
   to be one that was run.
2. §1.4 said the pipeline is up when `program_status` is `Running`. It never is:
   the value is `Success`. The check as written waits forever on a healthy
   pipeline, and the longer it waits the more it looks like a real hang. The
   status pair that means "up" is `Running` + `Success`, and the pair that means
   "failed" is anything else with a non-empty `deployment_error`.

Two smaller corrections, both from the same run: a `port-forward` is not usable
the instant it returns (a `curl` in the same second returns an empty body, and a
script parsing it reports a JSON error that looks like a platform bug), and
`Database migrations finished` is not logged when there is nothing to apply, so
it cannot be used to tell a no-op upgrade from a failed start — §2.3 queries
`refinery_schema_history` instead.
