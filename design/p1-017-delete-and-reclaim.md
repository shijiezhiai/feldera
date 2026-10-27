# P1-017: deleting a pipeline, and collecting what a deletion misses

Status: implemented (branch `p1-017`).

## 1. What a deletion has to do

Deleting a pipeline removes its database row and the objects the runner created
for it. The row goes first: the API returns once the pipeline is gone from the
database, and the objects are deleted afterwards by the runner. That order is
correct for availability — a failed object deletion leaves a pipeline that can no
longer be reached through the API rather than a pipeline whose row reappeared —
but it means the objects can outlive their pipeline.

Two mechanisms close that gap:

- **Retention**, which keeps the storage claim of a deleted pipeline when an
  operator asks for it, so a mistaken deletion does not destroy ingested data.
- **The reaper**, a background scan that reports or deletes objects whose
  pipeline is no longer in the database.

## 2. Retention (`--kubernetes-runner-retain-storage-claims`)

Off by default. When on, `clear()` annotates the claim and skips deleting it:

```
feldera.com/storage-retention: kept-on-pipeline-delete
feldera.com/retained-pipeline-id: <uuid>
```

Every other object still goes: the `StatefulSet`, both `Service`s, the
`NetworkPolicy`, and the config `Secret`. A retention that kept more than the
claim would leave a half-deleted pipeline behind, which is worse than deleting
the data.

The annotation is not decoration. It is what distinguishes a claim an operator
kept from a claim a crash left:

| claim state | reaper reports it | reaper deletes it (with `--reap-orphans`) |
|---|---|---|
| pipeline in database | no | no |
| pipeline gone, not annotated | yes | yes |
| pipeline gone, annotated | no | no |
| name the runner never produces | no | no |

The annotation also serves a human: the pipeline row that named the claim is
gone by then, so without it the claim cannot be attributed to anything.

Retention off is the default because an unbounded set of kept claims is a disk
leak. A deployment that turns it on needs a lifecycle policy for what it leaves:
an operator reviews the annotated claims and deletes the ones no longer wanted.
This is also why the reaper skips them even when deletion is enabled — the
annotation is the operator's decision and the scan is not allowed to overrule it.

## 3. The reaper (`--kubernetes-runner-reap-orphans`)

Runs once when the manager starts and every six hours after that. Reporting is
the default; `--kubernetes-runner-reap-orphans` makes the same scan delete.

### How objects are identified

By name, not by label:

```
pipeline-<uuid>                StatefulSet, Service, NetworkPolicy
pipeline-<uuid>-metrics        Service (only with --metrics-service)
pipeline-<uuid>-config         Secret
pipeline-<uuid>-storage        PersistentVolumeClaim
```

A name is used because a label is written by the object's creator. A manager
killed between creating an object and labelling it leaves an object that no
label-based scan can see — which is the case the reaper exists for.

The name is parsed, not just prefix-matched: `Uuid::parse_str` must accept the
middle, and the suffix must match the kind. An object an operator created in the
same namespace therefore cannot be mistaken for a leftover, and the
`StatefulSet` and `Service` that share a name stay distinct objects. The claim
suffix is read only for a claim, so a `Service` named `pipeline-<uuid>-storage`
is not a claim.

### What a scan does

For each configured namespace (`--kubernetes-runner-namespace`,
`--kubernetes-runner-manager-namespace`, `--kubernetes-runner-metrics-namespace`)
plus each namespace the live pipelines request, it lists the five kinds and
compares each name's pipeline id against the database.

Ordering matters when deleting: `StatefulSet`, `Service`, `NetworkPolicy`,
metrics `Service`, `Secret`, and the claim last. A `StatefulSet` that still
exists keeps a pod using the claim, and deleting the claim first would detach
the volume from a running pod.

A failure to list one kind is reported and the scan continues, so one missing
permission does not hide the other kinds.

### Deliberate limits

- **No server-side filtering.** A `metadata.name` field selector accepts only
  `=`, `==` and `!=`; a prefix bound is rejected with `invalid selector`. The
  whole namespace is transferred and filtered in the manager. The first version
  of this module sent `metadata.name>=pipeline-,metadata.name<pipeline-.` and
  every scan on a real cluster reported six list failures instead of a result;
  `lists_without_a_field_selector` pins the fix.
- **Only the five kinds the runner creates.** The runner-created pod comes from
  the `StatefulSet`, so a survived `StatefulSet` covers it. Objects from other
  controllers (an `Ingress` a deployment adds, a `ServiceMonitor`) are not
  scanned: the reaper does not know their names, and guessing would put the
  delete path near live traffic.
- **Namespaces are scanned, not discovered.** A namespace that a deleted
  pipeline created and no live pipeline names is never visited, so an object in
  it is neither reported nor deleted. Discovering it would mean listing
  namespaces and inferring ownership, which is how a scan deletes a namespace
  someone else owns.
- **No dry-run flag for a single pipeline.** The scan is platform-wide; a
  single delete already goes through the runner's `clear()`.

## 4. Failure modes, and why the safe one is the default

| event | result |
|---|---|
| manager killed after the row is dropped, before objects are deleted | objects stay; the next scan reports them |
| `clear()` fails partway | the objects it did not reach stay; the next scan reports them |
| retention on, `clear()` succeeds | the claim stays, annotated; the scan skips it |
| retention on, annotation patch fails | the claim stays unannotated; the scan reports it and a human decides |
| kind cannot be listed | that kind is reported as a failure; the other kinds are still scanned |
| one object cannot be deleted | it is reported as both unreferenced and failed |

Reporting first is the reason a wrong identification costs a log line instead of
a pipeline's data. Deletion stays opt-in.

## 5. Acceptance

Unit tests (`cargo +1.96.1 test -p pipeline-manager --lib runner::`): 113 pass.

`runner::reaper` (11):

| test | what it holds |
|---|---|
| `parses_every_kind_the_runner_names` | every kind's name round-trips through the parser |
| `rejects_a_name_of_another_kind` | the claim suffix is read only for a claim |
| `rejects_names_the_runner_never_produces` | operator-created names are never orphans |
| `keeps_objects_of_a_live_pipeline` | a live pipeline's objects are neither reported nor deleted |
| `reports_only_objects_of_a_missing_pipeline` | only the orphan is reported; `feldera-db` is not |
| `reads_the_claim_suffix_only_for_a_claim` | a `Service` sharing the claim's name is untouched |
| `deletes_in_the_order_that_keeps_state_mounted` | deletion order: StatefulSet, Service, then claim |
| `reports_a_list_failure_and_continues` | a 403 on one kind does not stop the scan |
| `skips_an_annotated_retained_claim` | a kept claim is not even reported |
| `lists_without_a_field_selector` | no scan sends a name selector the API server rejects |
| `a_clean_report_is_clean` | an empty scan is distinguishable from a failed one |

`runner::kubernetes_runner` gained `clear_retains_the_storage_claim_when_configured`
(the claim survives, the other five objects do not, and the patch carries both
annotations) and `the_retention_annotation_is_the_one_the_reaper_reads`.

End-to-end (`scripts/e2e-k8s-reaper.sh`, on the `bili-p1005` kind cluster,
manager image `p1-017-reaper2`):

```
-- 1. create objects whose pipeline does not exist
   created pipeline-11111111-... and pipeline-11111111-...-storage
-- 2. the manager reports both, and deletes neither
   Reaper: found an object whose pipeline no longer exists kind="StatefulSet" ...
   Reaper: found an object whose pipeline no longer exists kind="PersistentVolumeClaim" ...
   PASS: reported, and left in place
-- 3. the platform's own objects are never reported
   PASS: feldera-db present and unreported
-- 4. a claim kept by a deletion is not reported as an orphan
   PASS: the annotated claim is left alone
```

Deletion mode, against the same cluster with
`FELDERA_KUBERNETES_RUNNER_REAP_ORPHANS=true`:

```
Reaper: deleted an object whose pipeline no longer exists kind="StatefulSet"        name=pipeline-22222222-...
Reaper: deleted an object whose pipeline no longer exists kind="PersistentVolumeClaim" name=pipeline-22222222-...-storage
kubectl get sts,pvc | grep -c "pipeline-1111|pipeline-2222"  ->  0
```

The three failures e2e caught, none of which the unit tests could:

1. The field selector is invalid on a real API server (§3).
2. `tracing` renders `pipeline_id` as `pipeline-id`.
3. A restarted deployment's previous pod log still holds the earlier scan, so a
   script that greps the deployment's log reads the *previous* run's result and
   calls a correct skip a failure. The script now reads the pod created by the
   restart.
