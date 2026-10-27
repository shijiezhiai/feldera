# P1-018: compiling in a separate pod

Status: implemented (branch `p1-018`).

## 1. What was already there, and what was missing

The manager has always had two halves. `compiler_main` spawns the SQL worker,
the Rust worker and the artifact HTTP server together; `artifact_server_main`
spawns the HTTP server and its janitor alone. The second function carries a
comment saying it exists for "deployments where compiler workers are ephemeral
and this process is the durable binary store", and had **no caller**: the shape
was written and never wired.

What was missing was not the split itself but the ability to choose it. Every
process ran every service, so a compiler pod had no way to say "compile, do not
serve the API", and the artifact store could not outlive a compilation.

The splitter is `--services` (`FELDERA_SERVICES`), a list of `all`, `api`,
`compiler`, `artifact-server`:

| selection | runs |
|---|---|
| `all` (default) | API server, runner, compilation, artifact server — the single-container deployment |
| `api` | API server, runner, cluster monitor, events cleaner, orphan reaper |
| `compiler` | SQL and Rust compilation tasks |
| `artifact-server` | artifact HTTP surface and janitor |
| `compiler,artifact-server` | both of the above in one pod |

`all` is the default so an existing deployment keeps working unchanged, which is
what the P1-005 chart relied on.

## 2. Why the artifact server and the compiler are separate roles

They share a working directory and a database, so putting them in one pod is
tempting. Two properties argue against it:

- **The store must survive what the compiler cannot.** A compilation takes
  minutes to hours and holds a cargo target directory; the artifact store holds
  the result. A pod restart must not take every published binary with it — but
  the pod that holds the result does not need to be the pod doing the work.
- **Compilation scales, storage does not.** N compilers uploading to one store
  needs the store to be one thing. The reverse (one compiler, N stores) is not a
  shape anyone wants.

The chart therefore runs `compiler,artifact-server` in the compiler pod: today
one pod does both, and turning `compileInThisPod` off leaves a pure store that N
stateless compiler pods can be pointed at without changing the API server.

## 3. The artifact path, and why it is HTTP

The API server never reads the compiler's filesystem. It asks
`--compiler-host:--compiler-port` for `/artifacts/<id>/<version>/<source>/<binary>/<program-info>`,
which means:

- the API server pod does not need the claim mounted — it needs the URL;
- the compiler pod does not need the API server's port — it needs the DB;
- the two can restart independently.

This is what makes the hash comparison in the e2e meaningful. Two processes
reading the same PVC would agree trivially; two processes agreeing over HTTP,
one of which wrote the file and the other of which never had it, is a real
statement about where the artifact is.

## 4. The images

`deploy/Dockerfile.compiler` used to build a toolchain-only image (JDK, Maven,
cargo, mold, librdkafka) with `CMD ["sleep", "infinity"]`. It had no manager
binary, no sql2dbsp jar and no source tree, so it could not compile anything.

It is now the manager image plus a service selection. That is not laziness:
compiling a pipeline needs the manager binary, the jar, `Cargo.lock`, the
`crates/` tree, the Rust toolchain **and** the ~1.5 GB offline cargo cache, and
`deploy/Dockerfile.manager` already carries all of it because it compiles
pipelines in-process when it runs every service. Rebuilding that stack in a
second Dockerfile produces two images that drift, and the drift surfaces as a
compiler that fails on a crate version only one of them has.

The Dockerfile asserts at build time that the base still carries each piece, so
a base image that stops shipping the source tree fails the build rather than the
first compilation.

`deploy/build-images.sh` derives the compiler tag from the manager tag it just
built, in that order, so the two cannot be built from different sources.

## 5. Network policy

`charts/feldera/charts/compiler/templates/networkpolicy.yaml`, off by default.
When on, egress is limited to the database, DNS, the API server and whatever an
operator lists in `egressAllow`. Ingress is limited to the API server unless
`restrictIngress` is off, in which case the kubelet's probes keep reaching the
pod from the node (a policy that blocked them would restart a healthy compiler
forever).

Off by default because kind has no CNI that enforces it and a policy that
silently does nothing is worse than an absent one: it reads as a control that
exists.

## 6. Acceptance

`scripts/e2e-k8s-compiler.sh` asserts seven things in order, each of which the
next one hides:

1. the API server pod selects `api` and the compiler pod selects something
   containing `compiler`;
2. the API server log shows no compilation worker;
3. the API server pod reaches the compiler's `/healthz` over the service DNS;
4. a pipeline reaches `Success`;
5. the binary exists on the compiler's claim;
6. the API server pod fetches that binary over HTTP and the bytes hash to what
   the compiler logged — the DoD's "remote artifact equals local artifact";
7. a program with a bad column returns the SQL compiler's own diagnostic through
   the API, so errors travel the same path as artifacts.

Unit tests cover the service selection: defaults, explicit roles, the refusal of
`compiler` without `artifact-server`, and an unknown role name.
