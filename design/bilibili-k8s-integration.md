# Feldera on the Bilibili Kubernetes clusters

Status: drafted 2026-11-06. Owner: platform. Companion of
`deploy/bilibili/` (the overlay) and `.gitlab-ci.yml` (the image pipeline).

## 1. What this is

The self-hosted stack in this repository — manager, compiler, pipeline runner —
running on Bilibili's Kubernetes clusters instead of a laptop's kind cluster.

The clusters are not generic. Everything below was read off the reference
integration in `flink-1.20` (`~/code/bilibili/flink-1.20/flink`), which has been
running Flink on them for years:

| The clusters require | Where it is expressed in Flink | Where it is expressed here |
| --- | --- | --- |
| Images from the internal registry, with a pull secret | `kubernetes.container.image.ref: 127.0.0.1:65001/flink/flink-1.20:$TAG` | `imagePullSecrets` + `hub.bilibili.co/bigdata/feldera-*` |
| Workload-specific nodes, tainted | pod template + node affinity in the Flink config | `nodeSelectors`/`tolerations` per workload, and `kubernetesRunner.pod.*` |
| `pid_max` sized by an admission controller | annotation `cloud.bilibili.co/sysctls-pids.max` on the pod template | the same annotation on the control plane, the compiler and the pipeline pods |
| Bulk scratch on the node's `/mnt` | `kubernetes.mount-paths: /mnt:/mnt` | optional `hostPath` in `deploy/bilibili/pipeline-template.yaml` |
| An external API server, not the in-cluster one | `KUBERNETES_SERVICE_HOST=apiserver.bilibili.co` | not applicable: Feldera's manager runs *inside* the cluster it drives, so in-cluster config is correct here |

## 2. What was borrowed, and what was not

Borrowed:

* **Tag-driven publishing to two registries.** `hub.bilibili.co` is what the
  clusters pull; `tx-deepblue-hub.bilibili.co/bigdata` is what the platform's
  catalogue reads. Both get the same image under the same tag.
* **Environment by tag prefix** (`pre-`/`uat-`/`dev-`/other → env → BMR
  domain), so one pipeline serves all four and nobody hand-edits a domain.
* **A notification at the end of the release**, so the platform's record and
  the registry agree about what exists.
* **The idea of a pod template the platform can override**, which in Flink is
  `pod-template.yaml` and here is the P1-011 pipeline template.

Not borrowed:

* **The inline registry password.** The Flink `.gitlab-ci.yml` carries the
  deepblue credential in the file. This one reads masked CI/CD variables
  instead; a repository reader must not be able to push to the registry.
* **`hostNetwork: true`.** Flink's jobmanager uses it; Feldera's manager reaches
  a pipeline through a headless Service that resolves to the pod IP, and
  host-network pods make that address the node's, which collides with every
  other host-network pod on the same node. Nothing needs it: the pipeline's
  HTTP is consumed by the manager, not by an external client.
* **A ZooKeeper/HA layout.** Feldera's control plane is one manager plus one
  Postgres; leadership among replicas is `--kubernetes-runner-leader-election`,
  not ZooKeeper.

## 3. The five manager flags

The pipeline pod is rendered by the manager, not by Helm, so a Helm value
cannot reach it. Two mechanisms already existed for this:

1. **The pipeline template** (P1-011): a ConfigMap holding a whole StatefulSet
   with placeholders. Complete control, and complete responsibility — the
   template must reproduce the command line, the volumes and the config Secret,
   so every upstream change to those has to be mirrored by hand.
2. **What we added**: five flags, `--kubernetes-runner-pod-{node-selector,
   tolerations,image-pull-secrets,labels,annotations}`, which the runner applies
   to the StatefulSet it renders.

The flags win for the four cluster constraints because they say *only* the four
things the cluster needs, and they inherit every future change to the rendered
pod spec for free. The template stays available for what flags cannot express
(hostPath, extra sidecars) and the README says so, including the trap that a
template replaces the flags wholesale.

Labels are the one place where the flags could break the platform: the runner
finds its pods, services and claims by labels it owns. So
`check_no_reserved_pod_labels` refuses an operator label that collides with
one of them, rather than letting the pipeline become invisible to its own
manager.

## 4. What the chart change fixed

`charts/feldera/charts/controlplane/values.yaml` has carried `nodeSelectors`,
`tolerations`, `labels` and `annotations` since P1-005 — with no template
reading any of them. Four settings that looked like they worked and silently
did nothing, which is worse than not having them: an operator who sets
`nodeSelectors.controlPlane` and sees the pod land anywhere has no reason to
suspect the chart.

All four are now consumed by the API server, the database and the compiler
StatefulSet, and `imagePullSecrets` was added where it was missing entirely.
The compiler is a separate subchart and takes its own copies, because a subchart
cannot read its sibling's values — a fact that produced two other bugs in this
repository before (see `p1-017`).

## 5. Verification

Everything below runs without a Bilibili cluster:

```bash
helm lint charts/feldera
scripts/e2e-k8s-chart.sh                     # golden render + schema rejections
helm template feldera charts/feldera -n feldera -f deploy/bilibili/values.yaml
cargo test -p pipeline-manager --lib -- runner::kubernetes_runner
```

The golden render is byte-identical after the chart change, which is the
evidence that the new fields are inert when unset: a self-hosted installation
produces exactly the objects it produced before.

With a cluster, the acceptance steps are in `deploy/bilibili/README.md`:
pipeline pods land on the streaming nodes (`.spec.nodeName`), pull without a
per-pipeline secret, and `scripts/e2e-k8s-chaos.sh` passes with those pods,
because the chaos suite is what proves the scheduling did not break the crash
behaviour.

## 6. Open questions

These need an answer from the cluster owners; the values file marks each one
`TODO` at the setting it feeds.

1. **Registry group and tag rule.** `hub.bilibili.co/bigdata/feldera-*` is a
   guess from the deepblue layout. The tag is currently the upstream version
   plus `-bili.N`, which is this repository's convention, not the cluster's.
2. **Node labels and taints.** `workload=control-plane|compile|streaming` are
   placeholders. Read them off a Flink jobmanager pod.
3. **Storage class for pipeline state.** It must survive an eviction; a
   local-path class does not. The allowlist mechanism is already wired.
4. **Identity.** These clusters use Kerberos (`flink@BILIBILI.CO`) for service
   identity. Feldera's control plane authenticates people with OIDC
   (`--auth-provider oidc`). If the platform's SSO is not OIDC, this needs a
   broker, and until then the deployment runs with authentication off — which
   is acceptable only inside a namespace nobody else can reach.
5. **Postgres.** Embedded with a PVC is fine for a pilot; the platform's
   managed Postgres is the answer for anything with an SLA, and
   `postgresExternal` already supports it.
