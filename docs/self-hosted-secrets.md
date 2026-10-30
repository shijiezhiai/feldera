# Connector secret references

A pipeline's configuration can name a Kubernetes `Secret` instead of holding a
credential, and the platform never sees the value. This page describes what that
buys a tenant, what the platform refuses, and how to turn it on.

Feldera upstream documents the reference syntax as
[secret references](https://docs.feldera.com/connectors/secret-references/): a
configuration value may be the string `${secret:kubernetes:<name>/<key>}`, which
the runtime replaces with the contents of that key before the connector starts.
The mechanism is the runtime's; what the platform adds is the decision of *which*
Secrets may be named, and the mount that makes the value appear where the
runtime looks.

## Why the platform has to decide

A Kubernetes `Secret` is readable by every pod in its namespace that mounts it,
and a pipeline pod can mount what the runner is allowed to read. A pipeline's
configuration, though, is writable by anyone who can change a pipeline in that
tenant — that is the ordinary role of a data engineer, not an operator. Put those
two facts together without a check and any tenant member can name the manager's
own database credentials, point an HTTP output connector at a host they control,
and read the value back out of the response.

The allowlist is therefore not a convenience. It is the boundary between "a
pipeline author may refer to credentials they were given" and "a pipeline author
may read anything this cluster holds".

## Turning it on

```yaml
controlplane:
  kubernetesRunner:
    enabled: true
    connectorKubernetesSecrets:
      enableAllowlist: true
      allowlist:
        - kafka-creds
        - s3-credentials
```

The chart renders this as
`FELDERA_KUBERNETES_RUNNER_CONNECTOR_KUBERNETES_SECRETS_ALLOWLIST=kafka-creds;s3-credentials`
on the manager container (`--kubernetes-runner-connector-kubernetes-secrets-allowlist`
on the command line). The delimiter is `;`, matching the other list-valued runner
settings in this chart.

Off is the default, and off means **no** connector may reference a Secret. It
does not mean "no enforcement": a case-insensitive reading of "allowlist
disabled" would leave every Secret in the namespace reachable, which is the
failure this setting exists to prevent.

The schema enforces two shapes, so a mistake is caught by `helm install` rather
than by a pipeline that fails at start-up:

* `enableAllowlist: false` with a non-empty `allowlist` is refused. A list that
  is silently ignored reads as enforcement to whoever wrote it.
* Each entry must be a valid Secret name (an RFC 1123 label). The manager checks
  this again at provisioning, because the API accepts configurations from paths
  the chart never sees.

## What a reference looks like

```json
{
  "runtime_config": {
    "inputs": {
      "orders": {
        "stream": "orders",
        "transport": {
          "name": "kafka_input",
          "config": {
            "topic": "orders",
            "bootstrap.servers": "kafka:9092",
            "sasl.username": "${secret:kubernetes:kafka-creds/username}",
            "sasl.password": "${secret:kubernetes:kafka-creds/password}"
          }
        }
      }
    }
  }
}
```

The reference is an ordinary string value, so it works in any connector field
that the runtime resolves — Kafka options, S3 keys, HTTP headers. Nothing in the
configuration says it is a secret; the `${secret:...}` prefix is the whole
marker, which is why the platform has to scan the configuration rather than
trust a typed field.

`${env:NAME}` is a different mechanism and is unaffected: it reads the pipeline
pod's own environment, which the platform already limits through
`FELDERA_`/`KUBERNETES_`/`TOKIO_` prefix rejection (`pipeline_env.rs`). A
configuration that uses only `${env:...}` needs no allowlist entry.

## What the runner does with a listed reference

For each Secret the configuration names, the runner adds one volume:

```yaml
volumes:
  - name: secret-kafka-creds
    secret:
      secretName: kafka-creds
      items:                      # only the keys the configuration uses
        - {key: password, path: password}
        - {key: username, path: username}
```

and mounts it at `/etc/feldera-secrets/kubernetes/kafka-creds`. That layout is
what `secret_resolver` reads under its default secrets directory:
`${secret:kubernetes:<name>/<key>}` resolves to
`<secrets dir>/kubernetes/<name>/<key>`.

Two details are deliberate:

* **One volume per Secret, not per key.** Kubernetes mounts a volume, not a
  file, so grouping by Secret keeps the object count at the number of distinct
  Secrets rather than the number of references.
* **`items` names only the referenced keys.** Mounting the whole Secret would
  place every key in it in the pod's filesystem. A pipeline that asks for one
  credential should not receive the others living next to it. The end-to-end test
  asserts this: a Secret with an extra key the configuration never names must not
  have that key in the pod.

The values are never read by the manager. It reads the Secret's *name* from the
configuration, checks the name against the allowlist, and emits the volume; the
kubelet projects the contents, and the runtime reads them from the filesystem.
That is why the value cannot appear in the database, the logs, or an API
response: it never enters the manager's address space.

## What is refused, and when

| Situation | Result |
| --- | --- |
| Secret named, allowlist empty | Provisioning fails: `... not on the allowlist: no Secret is allowed (set --kubernetes-runner-connector-kubernetes-secrets-allowlist)` |
| Secret named, not on the allowlist | Provisioning fails, error names the Secret and lists the allowed ones |
| Secret name is not a valid RFC 1123 label | Provisioning fails before the volume is built |
| Secret on the allowlist, key absent from the Secret | Provisioning succeeds; the pod fails to start and the kubelet reports the missing key |

The first three are checked before the runner creates anything, so a refused
configuration leaves no StatefulSet, no claim and no Service behind. The fourth
cannot be checked by the manager — it does not read the Secret — so it surfaces
as a pod that cannot start, with the kubelet naming the missing key in the pod's
events.

The refusal is a provisioning error rather than a 422 on the API call. The
upstream API has no 422 path for pipeline configuration (the error mapping uses
400 for bad requests), and refusing at provisioning keeps the rule in one place:
a configuration that was accepted can still be refused later if an operator
removes a Secret from the allowlist, and the pipeline's `deployment_error` then
explains why.

## Rotating a value

Change the Secret; the pod's projected files follow within the kubelet's sync
period (about a minute by default), but a running connector has already read the
value into its own memory. The pipeline restarts to pick up a new credential:
`POST /v0/pipelines/{name}/stop` then `start`. Rotation is therefore a
maintenance operation, not something that happens behind a running pipeline.

Removing a Secret from the allowlist does not stop pipelines that are already
running — the volume is in their pod spec. It prevents new deployments, and the
next restart fails with the allowlist error.

## Checking it yourself

`scripts/e2e-k8s-secrets.sh` runs the whole path against a kind cluster:

1. Two Secrets are created, one on the allowlist and one not.
2. A pipeline that names the unlisted one is started; the script waits for the
   provisioning error and asserts it names that Secret and mentions the
   allowlist. It then asserts no StatefulSet exists for the refused pipeline.
3. A pipeline that names the listed Secret is started. The script reads the
   value out of the pod at the path the resolver uses, asserts a second
   referenced key arrived, and asserts an unreferenced key of the same Secret did
   **not**.
4. It reads the pipeline row out of Postgres, asserts the stored configuration
   still holds the reference string, and asserts the marker value appears in no
   text or JSON column of any table.

The unit tests in `crates/pipeline-manager/src/runner/kubernetes_runner.rs`
cover the classification itself: listed, unlisted, invalid name, output-side
reference, environment reference, and the volume-name collision case for Secret
names longer than a volume name may be.

## Limits

* **The list is names, not (name, key) pairs.** Listing a Secret hands every key
  in it to any pipeline permitted to reference it. Keep unrelated credentials in
  separate Secrets.
* **All pipelines in a namespace share the list.** The allowlist is a runner-wide
  setting, not per tenant. A per-tenant list would need a per-tenant runner, which
  this platform does not have yet.
* **`secrets` are mounted read-only and never mediated.** The manager cannot
  audit which pipeline read which key; the volume projection is the only record.
* **No secret is available to the compiler.** Compilation does not resolve
  references, so a program that embeds one is unaffected by this setting.
