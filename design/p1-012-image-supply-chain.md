# P1-012 — Image supply chain: signing, scanning, admission

Status: implemented. Branch `p1-012`.

## 1. What this protects against, and what it does not

A registry is a mutable store: whoever can push to it can replace the bytes
behind a tag. Two independent controls narrow that risk.

| Control | Answers | Does not answer |
|---|---|---|
| cosign signature | "did the release key sign exactly this digest?" | "is this image safe?" |
| trivy CVE gate | "does this image carry known vulnerabilities above the threshold we accept?" | "is this the image we built?" |

Both are needed: a signature on a vulnerable image is still a vulnerable image,
and a clean scan of a swapped image is still the wrong image.

## 2. Keys

- Algorithm: ECDSA P-256, produced by `cosign generate-key-pair`.
- The private key lives only in the CI secret store (or, on a developer
  machine, in `deploy/security/keys/`, which is git-ignored).
- `deploy/security/cosign.pub` *is* committed: it is the verification key that
  clusters and reviewers use, and a public key is not a secret.
- Rotation: generate a new pair, sign the new images, update `cosign.pub`, the
  Kyverno policy's inline key and the annotation below, then re-verify one old
  image to confirm the old key is no longer trusted.

```bash
deploy/security/supply-chain.sh keygen            # writes keys/ and copies keys/cosign.pub
export COSIGN_PASSWORD=...                        # keep it in the CI secret store
deploy/security/supply-chain.sh sign  localhost:5001/feldera-manager:v0.357.0-...-bili.1
deploy/security/supply-chain.sh verify localhost:5001/feldera-manager:v0.357.0-...-bili.1
```

### No transparency log

Signatures are made with `--tlog-upload=false` and verified with
`--insecure-ignore-tlog`, because a self-hosted deployment has no Rekor. The
signature then proves *the release key signed this digest*, not *when* or *that
the signing was publicly witnessed*. If a Rekor instance becomes available,
drop both flags and the Kyverno `ctlog.enabled: false`, and nothing else
changes.

## 3. The CVE gate

`deploy/security/supply-chain.sh gate IMAGE...` runs `trivy image`, writes a
JSON report under `deploy/security/reports/` (git-ignored) and evaluates it with
`deploy/security/gate.py`.

- Threshold: `FAIL_ON`, default `CRITICAL,HIGH`.
- Suppression: `deploy/security/vulnerability-allowlist.json`. Each entry has
  an `id`, an optional `image` substring, a `reason` and an `expires` date.
  An expired entry stops applying on its own, so a temporary suppression cannot
  silently become permanent. `gate.py` prints `ALLOWED …  until <date>` for
  every suppressed finding, so the output always shows what the gate is
  ignoring.
- An entry names either one `id` (a CVE) or one `pkg` (a package). A `pkg`
  entry covers every finding in that package, including future ones, which is
  exactly why it also has to expire.
- Baseline: the first scan of the manager image on 2026-10-23 reported 14
  critical and 372 high findings — **all 386 in `linux-libc-dev`, and none with
  a fix** (re-confirmed with Java and Node scanning enabled, see below). The container never runs that kernel, so the allowlist carries one
  package-level entry for it with a reason and an expiry date rather than 386
  CVE entries. Everything else in the image scanned clean, which is the useful
  part of the baseline: the OS packages are current, and the noise came from a
  package that cannot be exploited from inside the container.
- The runner image scanned 0 critical / 0 high.

Both controls are wired into `deploy/build-images.sh`:

```bash
SIGN=1 deploy/build-images.sh                 # sign every pushed image
SCAN=1 SIGN=1 deploy/build-images.sh          # sign, then enforce the CVE gate
FAIL_ON=CRITICAL SCAN=1 deploy/build-images.sh   # start at CRITICAL only
```

They default to off so that a plain build stays fast; CI turns them on.

## 4. Admission control

`deploy/security/policies/verify-images.yaml` is a Kyverno `ClusterPolicy` that
rejects any pod in the platform that references a `localhost:5001/feldera-*`
image without a valid signature from the release key. It also mutates the tag to
the verified digest, so the running container is pinned to the bytes that were
verified.

Prerequisites for a self-hosted, plain-HTTP registry:

- Kyverno installed (chart can be pulled over OCI:
  `helm install kyverno oci://ghcr.io/kyverno/charts/kyverno`).
- Kyverno must be allowed to talk to an HTTP registry; that is a Kyverno
  installation setting (`allowInsecureRegistry`), not a policy setting.

Check the policy without a cluster using the Kyverno CLI (this is the same
engine the webhook runs, and what P1-012 was verified with):

```bash
kyverno apply deploy/security/policies/verify-images.yaml \
  --resource deploy/security/tests/unsigned-pod.yaml     # 2 rules fail: no signatures found
kyverno apply deploy/security/policies/verify-images.yaml \
  --resource deploy/security/tests/signed-pod.yaml       # 2 rules pass
```

On a cluster with the policy installed:

```bash
kubectl apply -f deploy/security/tests/unsigned-pod.yaml   # expect: denied by feldera-verify-images
kubectl apply -f deploy/security/tests/signed-pod.yaml     # expect: admitted, digest pinned
```

Two things to keep in mind when installing it:

- Kyverno must be able to *read* the registry (it fetches the signature from it).
  With a plain-HTTP registry that means the Kyverno installation has to allow an
  insecure registry, and `localhost:5001` must resolve to the registry from the
  Kyverno pod — on a kind cluster that is not true by default, so the image
  references in the policy are the first thing to adjust for a real cluster.
- The `kyverno.io/v1` `ClusterPolicy` API is deprecated in Kyverno 1.19 in
  favour of `policies.kyverno.io/v1alpha1` `ImageValidatingPolicy`. The policy
  here is kept on the older API because that is what the deployments we target
  run today; migrating means rewriting the `verifyImages` block as CEL and is
  tracked as a follow-up.

### Java dependencies

Scanning the manager image also means scanning the SQL compiler jar, and that
needs the separate Java index database: a 942 MiB OCI artifact
(`ghcr.io/aquasecurity/trivy-java-db:1`, layer
`sha256:65d5d63f…`, 987,770,154 bytes) that unpacks into a 1.5 GiB
`trivy-java.db`. Trivy fetches it from `mirror.gcr.io` first and falls back to
`ghcr.io`; `supply-chain.sh` pins both repositories to `ghcr.io` because the
first one is unreachable in this network.

Trivy's own OCI client could not finish that download here. It reported
`oci download error: copy error: stream error: stream ID 1; PROTOCOL_ERROR;
received from peer` after about a third of the artifact, and every retry started
again from zero — a 942 MiB artifact that arrives in 300 MiB pieces never
arrives at all.

`deploy/security/fetch-java-db.sh` sidesteps the client: it reads the manifest
directly, then downloads the blob with `curl -C -`, so an interrupted transfer
resumes where it stopped, and only unpacks once the byte count matches the
manifest. On the build host the artifact arrived at 37 MB/s in 25 seconds —
the client was the bottleneck, not the link. `supply-chain.sh java-db` runs the
script, and `supply-chain.sh scan` adds `--skip-java-db-update` once the index
is in `$TRIVY_CACHE_DIR/java-db`, so scans never talk to the registry again.

With the index in place the scans default to `--pkg-types os,library`
(`SCAN_PKG_TYPES`) and do cover Java. That path is not taken on faith: a demo
image built from `debian:9` with `log4j-core-2.14.1` dropped in reports
`CVE-2021-44228`, `CVE-2021-45046` and `CVE-2021-45105` (`jar` results), and the
gate blocks them. The manager image itself scans **clean for Java** (0
findings): its compiler jar is shaded, so it exposes no dependency metadata.

### Why `cargo` findings do not fail the gate

`--pkg-types os,library` also scans the Cargo registry and git checkouts that
the manager image ships *on purpose*, so that a pipeline can be compiled inside
a pod without network access (see `design/p1-009-kubernetes-runner.md`). Trivy
treats every `Cargo.lock` under `.cargo/registry/src/…` as a project and
reports every transitive dependency of every crate — 1,023 findings in the
first run, none of them executed or reachable at runtime.

The gate therefore skips ecosystems that are build-time caches by default
(`--skip-ecosystems cargo`, `SKIP_ECOSYSTEMS` in `supply-chain.sh`). It prints
`SKIPPED <n> finding(s) in cargo: build-time dependency cache, not deployed
code`, so the exclusion is visible and counted rather than silent. Rust
dependencies are still covered where they matter: by the workspace
`Cargo.lock` reviewed in code review, and by a `cargo audit` step that belongs
in CI rather than in image scanning.

### The baseline with Java enabled

Re-running the scan with `--pkg-types os,library` on 2026-10-23 changed nothing
that the gate looks at: the same 386 `linux-libc-dev` findings (allowlisted by
package), zero Java findings, zero Node findings, and 1,023 `cargo` findings
that are skipped as build-time cache. The compiler and runner images were
scanned the same way (`supply-chain.sh gate` over all three).

## 5. The deliberate failure case

`deploy/security/selftest.sh` proves that both gates reject a bad input, which
is what the work order asks for:

1. a pushed, signed image verifies;
2. the same repository at an unsigned tag is rejected by `verify`;
3. a deliberately vulnerable reference image (`debian:9` by default) blocks the
   CVE gate;
4. the same report passes once every blocking finding is allowlisted, which
   proves the allowlist is the only knob that can unblock a finding.

## 6. A detail that matters when reasoning about signatures

A cosign signature is attached to a **digest**, not to a tag. Two consequences:

- Re-pointing a tag at different bytes invalidates it: the new digest has no
  signature, and both `cosign verify` and the admission policy reject it.
- Adding a *new* tag that points at an already-signed digest inherits the
  signature. That is correct (the bytes are the same), but it means "this tag
  was signed" is not a meaningful statement; "this digest was signed" is.

## 7. Follow-ups

- SBOM generation (`trivy image --format spdx-json`) attached as a cosign
  attestation; the gate stays the same, the evidence gets richer.
- The policy currently covers the platform's own images. User-supplied pipeline
  images are out of scope: accepting them is the product's premise, and the
  cluster's own policy layer should decide about them.
- A scheduled re-scan of the deployed digests, so that a CVE published after
  the build still reaches the team.
