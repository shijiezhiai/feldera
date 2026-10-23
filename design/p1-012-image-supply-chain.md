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
- Baseline: the first scan of the manager image is large (Ubuntu base, JRE and
  the Rust dependency tree). Triage it once, record the accepted findings with
  reasons and expiry dates, and keep `expires` short enough that they come back
  for review.

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
