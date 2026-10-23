# P1-011: pipeline template rendering and resource limits

This note covers what the Kubernetes runner renders for a pipeline pod, which
parts an operator may override, and the limits the platform puts on what a
pipeline may ask for.

## Renderer

`crates/pipeline-manager/src/runner/kubernetes_runner.rs` renders the pipeline
objects with pure functions: `RenderInput::render` turns the pipeline
configuration into a `Secret`, an optional `PersistentVolumeClaim`, a headless
`Service`, a `NetworkPolicy` and a `StatefulSet`. Nothing in the renderer talks
to the API server, so the shape of the objects is unit-testable without a
cluster.

The built-in renderer is the default template. An operator who needs something
else — extra volumes, node selectors, tolerations, sidecars — supplies a
StatefulSet template instead of patching the manager:

```yaml
kubernetesRunner:
  template:
    configMap: feldera-pipeline-template   # existing ConfigMap
    key: pipelineTemplate                  # entry inside it
    namespace: ""                          # empty = release namespace
```

The runner reads that ConfigMap when it provisions a pipeline, substitutes the
placeholders below, parses the result as a `StatefulSet` and creates it. The
releaser's `name` and `namespace` are always overwritten with the pipeline's
own, so a template cannot accidentally create a second pipeline or escape its
namespace.

Errors are explicit: a missing ConfigMap, a missing key or a body that does not
parse as a StatefulSet fails provisioning with a message that names the
ConfigMap, the key and the parse error. Nothing is partially created after that
point — the template is read before the first object is applied.

## Placeholders

| Placeholder | Value |
| --- | --- |
| `{id}` | `pipeline-<pipeline uuid>`: name prefix of every object |
| `{namespace}` | namespace the pipeline runs in |
| `{pipeline_executor_image}` | runner image the pod runs |
| `{binary_ref}` | URL the entrypoint downloads the program binary from |
| `{program_info_ref}` | URL of the program information document |
| `{pipeline_storage_path}` | mount path of the storage claim, empty without storage |
| `{storage_class_name}` | storage class of the claim, empty when unset |
| `{deployment_id}` | UUID of this deployment |
| `{deployment_initial}` | initial runtime status (`paused`, `running`, …) |
| `{bootstrap_policy}` | bootstrap policy, empty when there is none |
| `{storage_class}` | alias of `{storage_class_name}` |

Substitution is plain string replacement, which is what the documentation
promises. A placeholder in a YAML comment is replaced too. An unknown
`{name}` is left alone so the YAML parser reports where it is, instead of the
runner silently dropping configuration.

## Resource limits

`kubernetesRunner` values map one to one onto manager arguments, so the range
is changed in one place:

| Chart value | Manager argument | Default |
| --- | --- | --- |
| `lowerLimitMemoryMegabyte` | `--kubernetes-runner-lower-memory-mb` | 100 |
| `upperLimitMemoryMegabyte` | `--kubernetes-runner-upper-memory-mb` | 32000 |
| `defaultStorageMegabyte` | `--kubernetes-runner-default-storage-mb` | 30000 |
| `upperLimitStorageMegabyte` | `--kubernetes-runner-upper-storage-mb` | 128000 |

Semantics:

* A memory request below the lower limit is raised to it, one above the upper
  limit is lowered to it. The clamp applies to the request, so the observable
  values are always inside the range.
* The container limit leaves headroom above the pipeline's own memory budget
  (`max_rss_mb`): a quarter more, at least 256 MB. A limit equal to the budget
  lets the pipeline's own pages, thread stacks and allocator push the cgroup
  over the edge, which is an OOM kill of a pipeline that never exceeded its
  stated budget.
* Storage that the pipeline does not request uses `defaultStorageMegabyte`;
  everything is capped at `upperLimitStorageMegabyte`.
* `canonicalize()` rejects an inverted memory range and a default storage above
  the storage ceiling at startup, so a misconfigured chart fails the manager's
  boot rather than silently provisioning out-of-range pods.

Zero quantities are dropped instead of being rendered as `cpu: "0"`, because a
zero request is legal but meaningless and it hides the fact that the user never
asked for a reservation.

### What a template must supply

The pod spec of a rendered template is the template's, but three things stay the
manager's: the object's name, its `serviceName` and the selector labels. The
Service selects the pod by them, and no placeholder carries the bare pipeline
UUID, so a template could not spell them correctly; the manager overwrites them
instead of rejecting the template.

Everything else the pod needs is the template's responsibility, and the runner
cannot inject it:

* the argument list of the pipeline binary, including the `--deployment-id` the
  CLI requires (a template without it makes every pod exit at startup with
  `the following required arguments were not provided: --deployment-id`);
* the config Secret mounted at `/var/feldera/config`;
* a writable mount at `{pipeline_storage_path}` for the storage claim the runner
  creates, when the pipeline has storage enabled;
* `FELDERA_PROGRAM_BINARY_URL={binary_ref}`, because the entrypoint downloads the
  program from there.

[`deploy/pipeline-template.example.yaml`](../deploy/pipeline-template.example.yaml)
is a working example; the surest starting point is the pod spec of a running
pipeline (`kubectl get sts pipeline-<uuid> -o yaml`) with the concrete values
replaced by placeholders.

## Tests

* Unit tests cover the clamp boundaries, the headroom formula, the default
  storage, the placeholder table and the template path (including a missing
  ConfigMap and a template without the key).
* Property tests (`proptest`) assert over arbitrary inputs that a clamped value
  is inside the range, that clamping is idempotent, that the container limit is
  never below the budget, and that substitution never leaves a known
  placeholder behind.

## Out of scope

Ephemeral storage limits (`lowerLimitEphemeralStorageMegabyte` and friends) and
connector secret allow-lists belong to the connector work orders; the values in
`values.yaml` are reserved for them and the runner does not read them yet.

## Verification on the kind cluster

The chain was exercised on `flink-test-02` (48 vCPU kind node) with a ConfigMap
template that annotates the pod, mounts the storage claim and passes the full
argument list:

* the rendered StatefulSet carries the template's annotations
  (`feldera.com/rendered-by: template`), the substituted
  `{deployment_id}` and `{bootstrap_policy}`, and the substituted
  `{pipeline_executor_image}`;
* the headless Service gets an endpoint, because the manager's selector labels
  are merged into the pod labels the template declares;
* the pipeline reaches `Running` in 8 s (program already compiled) and answers
  `SELECT c FROM v` with `3` after ingest;
* the storage claim is created with the default size — a `30000Mi` request,
  `Bound` — and mounted at `{pipeline_storage_path}`;
* with the template removed, the built-in renderer clamps a pipeline that asks
  for `memory_mb_min: 50, memory_mb_max: 512` to a `100Mi` request and a `768Mi`
  limit (the budget plus the 256 MiB headroom).
