# Feldera on the Bilibili Kubernetes clusters

This directory is the Bilibili-specific deployment of the chart in
`charts/feldera`. It is an overlay, not a fork: the chart stays generic, and
everything this cluster imposes lives in `values.yaml` and, when a value cannot
express it, in a pipeline template.

Prerequisites, in order:

```bash
kubectl create namespace feldera

# The registry needs credentials, and the pipeline pods need their own copy:
# the manager does not pass its `imagePullSecrets` down to the StatefulSets it
# renders.
kubectl -n feldera create secret docker-registry bilibili-hub \
  --docker-server=hub.bilibili.co \
  --docker-username="$HUB_USER" \
  --docker-password="$HUB_TOKEN"
```

Install:

```bash
helm upgrade --install feldera charts/feldera -n feldera \
  -f deploy/bilibili/values.yaml \
  --set controlplane.postgresPassword="$POSTGRES_PASSWORD"
```

`values.yaml` names four things this repository cannot know: the registry
group, the node labels, the node taints and the storage class. They are marked
`TODO` next to the setting they feed. Read them off a running Flink job rather
than guessing:

```bash
kubectl -n <flink-namespace> get pod -l component=jobmanager \
  -o jsonpath='{.items[0].spec.nodeSelector}{"\n"}{.items[0].spec.tolerations}'
kubectl get storageclass
```

## What the overlay sets, and why

| Constraint | Setting | Why it cannot be a cluster default |
| --- | --- | --- |
| Images live in the internal registry | `imagePullSecrets`, `controlplane.kubernetesRunner.pod.imagePullSecrets` | Pipeline pods are rendered by the manager, not by Helm; they do not inherit the manager's secret. |
| Nodes are labelled and tainted by workload | `nodeSelectors.*`, `tolerations.*`, `kubernetesRunner.pod.*` | A pod inherits neither from its parent. An untolerated taint shows up as `Pending`, not as an error. |
| Admission controller sizes `pid_max` | `annotations.controlPlane`, `kubernetesRunner.pod.annotations` | The annotation has to be on every pod, including the pipeline pods. |
| Pipeline state must survive an eviction | `kubernetesRunner.storageClassName` + `storageClassNamesSupported` | The default class may be local to one node, which loses the only copy of a pipeline's state. |

## Verifying an installation

```bash
# The manager reports the features it was built with; enterprise is a build
# flag, not an entitlement, and the fault-tolerance settings are refused
# without it.
kubectl -n feldera exec deploy/feldera-controlplane-api-server -- \
  curl -s localhost:8080/v0/config | grep -o '"edition":"[^"]*"'

# The pipeline pods must come up on the streaming nodes and pull without a
# secret of their own.
kubectl -n feldera get pod -l app.kubernetes.io/name=feldera-pipeline \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName

# The chart's own checks, which also cover the golden render.
MANAGER_TAG=<tag> COMPILER_TAG=<tag> RUNNER_TAG=<tag> scripts/e2e-k8s-chart.sh
```

## When a value is not enough

`deploy/pipeline-template.yaml` is an example of the other mechanism: the
manager can take the whole pipeline StatefulSet from a ConfigMap instead of
rendering it. Use it only for what the five flags cannot express — a hostPath
mount, hostNetwork, an extra sidecar — because a template reproduces the
command line, the volumes and the config Secret, and therefore has to be
re-read after every upstream change to those.

Note that the template replaces the rendered object wholesale: node selector,
tolerations and pull secrets set through the flags **do not** apply to a
pipeline that uses a template.
