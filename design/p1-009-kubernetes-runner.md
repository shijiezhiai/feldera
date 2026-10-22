# P1-009 — Kubernetes pipeline runner

Companion to [`adr-k8s-runner.md`](adr-k8s-runner.md), which fixes the trait
mapping and the provisioning decisions. This note records what the
implementation actually creates, what it needs from the cluster, and how the
end-to-end test drives it.

## Selecting the runner

The manager picks its executor at start-up:

| `FELDERA_RUNNER` | Executor | Notes |
| --- | --- | --- |
| unset, empty or `local` | `LocalRunner` | Default; spawns pipeline processes next to the manager. |
| `kubernetes` or `k8s` | `KubernetesRunner` | One pod per pipeline; needs the configuration below. |

Values are matched case-insensitively after trimming. Anything else is a
start-up error rather than a silent fall-back, so a typo cannot quietly put
production pipelines on the manager's own host.

`KubernetesRunnerConfig` (`crates/pipeline-manager/src/config.rs`) reads:

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `--kubernetes-runner-kubeconfig` | `FELDERA_KUBERNETES_RUNNER_KUBECONFIG` | Kubeconfig path; when unset the client uses in-cluster credentials. |
| `--kubernetes-runner-namespace` | `FELDERA_KUBERNETES_RUNNER_NAMESPACE` | Namespace of the pipeline objects (default `feldera`). |
| `--kubernetes-runner-pipeline-executor-image` | `FELDERA_KUBERNETES_RUNNER_PIPELINE_EXECUTOR_IMAGE` | Image of the pipeline pod; provisioning refuses to start without it. |
| `--kubernetes-runner-per-pipeline-namespace` | `FELDERA_KUBERNETES_RUNNER_PER_PIPELINE_NAMESPACE` | Create a namespace per pipeline instead of sharing one. |
| `--kubernetes-runner-allow-kubernetes-env-prefix` | `FELDERA_KUBERNETES_RUNNER_ALLOW_KUBERNETES_ENV_PREFIX` | Lift the `KUBERNETES_` prefix block on user-supplied pipeline env vars. |

The last flag is the controlled switch for the block list in
`crates/pipeline-manager/src/pipeline_env.rs`: the default keeps the local
runner's behaviour, where a `KUBERNETES_*` variable in a pipeline's `env` is
rejected because it would shadow what the kubelet injects.

## Objects per pipeline

Names derive from the pipeline id, so a `get all` shows which pipeline owns
what:

| Object | Name | Purpose |
| --- | --- | --- |
| Secret | `pipeline-<id>-config` | `config.yaml` of the pipeline, mounted read-only at `/var/feldera/config`. |
| PersistentVolumeClaim | `pipeline-<id>-storage` | Storage directory, only when the pipeline uses storage; mounted at `storage_config.path`. |
| Service | `pipeline-<id>` | Headless (cluster IP `None`) service on port 8080; the pod's DNS name is the provision location. |
| StatefulSet | `pipeline-<id>` | One replica; `terminationGracePeriodSeconds: 60`; the pod is `pipeline-<id>-0`. |

Labels: `app.kubernetes.io/name=pipeline`,
`app.kubernetes.io/managed-by=feldera`, `feldera.io/instance`,
`feldera.io/pipeline-id` and `feldera.io/deployment-id`. The selector carries
the first four only, since a StatefulSet's selector is immutable and the
deployment id changes on every restart.

The pod runs as the image's non-root user (uid 1000, gid 1000), with
`allowPrivilegeEscalation: false` and all capabilities dropped. The container
command is `/usr/local/bin/pipeline-entrypoint`: it downloads the program binary
from the compiler's `/binary/...` URL into the work `emptyDir`, then execs it
with the same argument set the local runner passes, except that the port is
fixed to 8080 and the bind address is `0.0.0.0` — there is no port file to read
back across pods.

## Provisioning flow

`provision` (see `crates/pipeline-manager/src/runner/kubernetes_runner.rs`):

1. Reject a loopback `compiler_host`. The pod downloads its binary from that
   host, and `127.0.0.1` would point at the pod itself. The chart therefore
   passes the manager service DNS name.
2. Reject gen2 pipelines, which the ADR defers.
3. Merge `program_info` into the deployment config, apply the memory fallback
   from `memory_mb_max`, and serialise it as `config.yaml` (900 KB limit, the
   same bound the local runner enforces).
4. Apply the storage claim (when configured), the secret, the service and the
   StatefulSet in that order, patching with a merge patch on `409 Conflict` so a
   retried provisioning converges instead of failing.

`is_provisioned` reports `Provisioned` once the pod's `Ready` condition is true;
`check` maps the fatal container states (CrashLoopBackOff, ImagePullBackOff,
ErrImagePull, InvalidImageName, CreateContainerConfigError, a failed container,
a pod that gave up) to an error, and otherwise reports the pod phase.
`stop` scales the StatefulSet to zero and waits for the pod to disappear.
`clear` deletes the StatefulSet, service, secret and claim, tolerating `404`s.

## RBAC

`charts/feldera/charts/controlplane/templates/rbac.yaml` creates a namespaced
`Role` plus a `RoleBinding` to the control plane's service account. It grants
only what the runner calls: `pods get/list/watch`, and `statefulsets`,
`services`, `secrets`, `persistentvolumeclaims`
`create/get/list/watch/patch/delete`. There is no cluster-scoped role, so the
`Role` cannot read `Namespace` objects at all;
`--kubernetes-runner-per-pipeline-namespace` would need namespace creation,
which the ADR lists as out of scope for P1-009 and which is why the flag is off
by default.

`can_provision` therefore probes the namespace with a server-side dry run:
`POST /api/v1/namespaces/<ns>/secrets?dryRun=All` for a marker secret named
`feldera-runner-connectivity-probe`. A `403` proves the credential works but the
`Role` is missing an expected verb, and a `404` proves the namespace is absent;
both are reported as configuration errors before any object is created, and a
successful dry run creates nothing.

## Testing

Unit tests cover the pure render functions and drive the client against a fake
API server (`tests` module of `kubernetes_runner.rs`): resource order, namespace
absence, pre-existing objects (409 → patch), readiness, fatal container states,
stop and clear. They need no cluster.

`scripts/e2e-k8s-runner.sh` is the cluster test: it loads the manager and runner
images into a kind cluster, installs the chart with
`controlplane.kubernetesRunner.enabled=true`, creates a one-table pipeline,
starts it, waits for `Running`, ingests a row over HTTP and reads the aggregate
back from the ad-hoc query endpoint. It needs a local registry on
`localhost:5001` (`deploy/build-images.sh` fills it) and a kind cluster named by
`CLUSTER` (default `bili-p1005`).

Timing, measured on two machines. Both runs use `PROFILE=unoptimized`; the
`optimized` profile is 3-5x the compile time and is not needed for smoke tests.

Development machine (10 vCPU, kind 1.33.1):

- The generated Rust program is compiled **inside the manager pod**. With an
  empty cargo target directory this is the dominant cost: 2h15m for the
  `optimized` profile, and the `dev` profile spent 13 minutes in the final
  `mold` link alone.
- Enable `controlplane.compilationCache` on a cluster with a default
  StorageClass; the cache directory then lives on a PVC instead of the pod's
  writable layer. Recreating the pod with that cache turned a resumed compile
  into 1004.89 s (16.7 min) and reusing the artifacts for a *new* pipeline id
  into a single relink of the generated crate.
- Artifacts are keyed by pipeline id, so every new pipeline pays that relink
  even when the SQL is identical.

Build host (48 vCPU, single-node kind 1.33.1, images built on the same host):

- First start, empty compilation cache: SQL 2.52 s, Rust **331.23 s** (5.5 min)
  for a two-line program. The dependency sources are already in the image (see
  below), so this is compile time, not download time.
- Second start of the same program (warm PVC): Rust **17.13 s** — cargo only
  re-links the generated crate.
- Provisioning: the four objects are applied in under a second, the pod reports
  `Running` 7 s later (1 GB binary download included).
- `scripts/e2e-k8s-runner.sh` end to end (`REUSE=0`, warm cache): **58 s** for
  load images, install, create, start, wait for `Running`, ingest, query,
  shutdown, clear, delete and the orphan check.

Two consequences for a self-hosted deployment:

- The manager image carries the cargo registry and git checkouts that the
  generated program needs (`COPY --from=builder .../.cargo/registry` and
  `.../.cargo/git`) and its cargo config sets `offline = true`. A pod cannot
  reach github.com in most clusters, and without the baked cache every
  compilation ends in `SSL error: class=Ssl (16)` or `transfer too slow`. This
  costs about 1.9 GB of image size; drop it once P1-018 moves compilation to a
  compiler service that has its own cache volume.
- `scripts/e2e-k8s-runner.sh` takes `PROFILE` (`unoptimized` by default) and
  `REUSE` (`1` keeps the pipeline between runs, `0` deletes it and asserts the
  objects are gone). It also walks the API state machine that deletion needs:
  `stop?force=true`, wait for `Stopped`, `clear`, wait, then `DELETE`.

## Building and iterating on images

A full manager build (the `Dockerfile.manager` target) takes most of an hour
because every change under `crates/` invalidates the Rust layers. While working
on the runner, build the binary in a warm container and swap it into the image:

```bash
# Once: a container with the toolchain, the repository at /src and a target
# volume that survives restarts.
docker run -d --name bili-cargo-builder --entrypoint sleep \
  -v "$PWD:/src" -v feldera-bili-target:/target -e CARGO_TARGET_DIR=/target \
  -w /src localhost:5001/feldera-manager:<tag> infinity
docker exec -u root bili-cargo-builder chown -R ubuntu:ubuntu /target
docker exec bili-cargo-builder cargo build --release --locked \
  -p pipeline-manager --features feldera-enterprise
docker cp bili-cargo-builder:/target/release/pipeline-manager deploy/.build/

# Then: a layer that only replaces the binary (seconds instead of an hour).
BILI_MANAGER_BINARY=deploy/.build/pipeline-manager deploy/build-images.sh
```

`deploy/Dockerfile.manager.overlay` exists for exactly this step, and
`deploy/build-images.sh` uses it whenever `BILI_MANAGER_BINARY` points at a
binary. Published images must still come from the full `Dockerfile.manager`
build, so the final iteration set is always rebuilt the slow way before it is
pushed.

Note that a manager pod's writable layer is discarded when its container
restarts: anything written outside a mounted volume (including a swapped
binary) is gone. Only `emptyDir` and PVC contents survive, which is why the
compilation cache is the one thing worth mounting.

A file copied into an image keeps the mode it had in the build context, so
`COPY deploy/pipeline-entrypoint.sh` faithfully reproduced a `rw-------` file and
the pod failed with `cannot open /usr/local/bin/pipeline-entrypoint: Permission
denied`. The `Dockerfile.runner` copy now pins `--chmod=0755` so the image no
longer depends on the checkout's permissions.

## Operational notes

The database password must survive `helm upgrade`. The original template used
`randAlphaNum` unconditionally, so every upgrade rewrote the Secret while the
Postgres data directory kept the old password; the new manager pod then failed
with `password authentication failed for user "feldera"`. The template now
reuses the value already in the cluster via `lookup` and only generates one when
the Secret does not exist. `helm template` has no cluster to query, so dry runs
still show a random value.
