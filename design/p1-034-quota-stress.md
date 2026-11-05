# P1-034: three teams on one platform, and a quota that holds under pressure

P1-022 gave each tenant a namespace with a quota in it and made a full quota fail
fast instead of waiting out the provisioning timeout. P1-033 then put two tenants
against each other and proved they cannot reach one another by *network,
namespace, secret or API* — but it did so with one pipeline per tenant, and a
quota that admits one pipeline is never pressed. The work order asks for the
remaining case (`design/p1-work-orders.md:120`):

> pilot teams ② and ③ onboarded + tenant quota stress test (proved they cannot
> hit each other) — 3 teams online; stress report (zero quota penetration)

Two things are therefore missing: the platform has never carried more than one
pipeline per tenant while several tenants are asking for capacity at the same
time, and nothing has measured what happens when a tenant asks for more than it
is allowed.

## 1. The three teams, stated for what they are

The work order depends on P1-029 (pilot team ① onboarded), and P1-029 has no
commit in this tree: the chain runs P1-019 … P1-033 without it, and nothing in
the repository names a pilot team, a team's owner, or a workload. The plan only
says "3 pilot teams run non-critical pipelines on Kubernetes"
(`design/self-hosted-enterprise-platform-plan.md:288`).

So the three teams below are **stand-ins**: three tenants with the shape a real
pilot would have (own namespace, own quota, own API key, two non-critical
pipelines each), named for what they exercise rather than for an organisation.
Naming a real team would invent an agreement nobody made. What the work order
can be held to here is the *procedure* — that onboarding a team is a sequence
that works from an empty cluster — and the load behaviour of the quotas. The
calendar half of P1-029's definition of done ("seven days without a P0") and the
people half of "feedback into the backlog" cannot be produced by a test.

| Team | Tenant | Namespace | Two non-critical pipelines |
|---|---|---|---|
| `pilot-stream` | pilot-stream | `tenant-pilot-stream` | `stream-orders`: datagen → filtered + materialized view; `stream-rollup`: datagen → grouped count |
| `pilot-risk` | pilot-risk | `tenant-pilot-risk` | `risk-events`: datagen → distinct event kinds; `risk-window`: datagen → sliding window count |
| `pilot-recsys` | pilot-recsys | `tenant-pilot-recsys` | `recsys-clicks`: datagen → materialized view; `recsys-sessions`: datagen → grouped session count |

Each pipeline is an unbounded `datagen` input plus one `CREATE MATERIALIZED VIEW`,
which is what makes it non-critical: it never finishes, holds no external
credential, and losing it costs nothing. Pipelines declare `cpu_cores_min: 1.0`,
`memory_min: 4Gi`, `storage_min: 4Gi` so the quota arithmetic below is exact
rather than approximate.

## 2. What "they cannot hit each other" has to mean under load

The P1-033 suite proved reachability boundaries. Under load the interesting
failures are different ones: a quota that is checked per request but counted
late, a refusal that arrives as a timeout rather than a verdict, a tenant's
saturation spilling into another tenant's provisioning, and a refusal that leaks
a resource anyway. Six properties, each with the failure it catches:

| # | Property | The failure it catches |
|---|---|---|
| L1 | A tenant's accepted pipelines never exceed `floor(quota / request)` on any axis | An admission race: two pipelines accepted where one fits, because two requests were counted before either was written |
| L2 | `ResourceQuota.status.used` never exceeds `hard`, on every axis, at every sample | The API server is the last line of defence; if the manager's own accounting admits past it, this number shows it first |
| L3 | A refused pipeline ends `Stopped` with the quota message, not a provisioning timeout and not a crash | A refusal that is indistinguishable from a broken platform. The operator cannot tell "buy more quota" from "the manager is wedged" |
| L4 | While tenant A is saturated, tenant B's pipelines still reach `Running` and B's `status.used` is unchanged | Saturation shared through the control plane: one compiler queue, one automaton loop, one API — the place where tenants actually do touch |
| L5 | No object belonging to A exists in B's namespace, under load | P1-033's ISO-1 escape, re-tested with concurrent requests rather than one |
| L6 | A refusal is final: the manager never restarts, and the API server records no new pod creation attempt for a refused pipeline once it has settled | A refusal that retries forever: a full quota turning into a provisioning storm against the API server. Counting *events* cannot answer this — the StatefulSet controller retries with backoff and the API server aggregates those attempts into one event with a count of about eighteen — so the property is measured as "the count stops growing", which is true only if the manager took the StatefulSet away |

## 3. Sizing, as arithmetic

The kind cluster (bili-p1005) is a single node with 48 CPU, ~124 GiB and 110
pods; 38 TiB of its disk is free, so the pods in this test are scheduled rather
than left `Pending`, and the numbers are about admission rather than scheduling.

| Per tenant | Value | Why |
|---|---|---|
| pipeline requests, each | `cpu 1.0`, `memory 4Gi`, `storage 4Gi` | the unit every other number is a multiple of |
| quota `requests.cpu` | `4` | four pipelines fit; two are already running, so two slots are free |
| quota `requests.memory` | `16Gi` | four pipelines fit, two free — the same arithmetic as CPU |
| quota `persistentvolumeclaims` | `12` | deliberately roomier than CPU allows; see below |
| quota `requests.storage` | `48Gi` | twelve claims of `4Gi`; likewise roomier |
| quota `defaultRequest.cpu` | `100m` | a `requests.cpu` quota requires *every* pod in the namespace to declare a CPU request; the default is what makes the entry usable at all (P1-033 met this) |
| pipelines onboarded | `2` | the "team online" half |
| pipelines attempted under pressure | `4` | two free slots against four contenders, so each team admits exactly two and refuses exactly two |

CPU and memory allow four pipelines; storage allows twelve. That asymmetry is the
point. Refusals can only come from CPU and memory, so the number of storage
claims afterwards answers a separate question — **does a pipeline that the quota
refused leave its volume claim behind?** A StatefulSet controller creates the
claims before the pod, so a refusal at the pod step can strand a claim that then
counts against the tenant forever. With storage deliberately roomy, a claim count
above four is exactly that leak, and would be invisible in a test where every
axis refuses at once.

The two-free-slots-against-four-contenders shape matters for a second reason: a
tenant whose quota is already full refuses everything, and "refused everything"
satisfies every upper bound here without ever exercising admission. With
headroom, both outcomes happen at once — some contenders are admitted, some are
refused, in the same run, against the same quota.

Per team: two onboarded plus four contenders plus one late request is seven
pipelines; three teams is twenty-one. Compilation is the cost of this test — the
compiler is a single replica
(`charts/feldera/charts/compiler/templates/statefulset.yaml:10`) and each
pipeline compiles its own program, so twenty-one compilations run roughly in
sequence at fifteen to twenty-five seconds each (measured on P1-033's five
pipelines in 160s). The script passes `profile: unoptimized`, which is the
difference between minutes and tens of minutes and changes nothing about
admission.

## 4. The phases

`scripts/e2e-k8s-quota-stress.sh`, one script, run on the machine that holds the
cluster:

1. **Install with authentication, without tenant mapping.** Quotas are keyed by
   tenant id and a tenant id exists only after the tenant does, so the quota
   cannot be in the first install (P1-033 learned this; the same two-phase shape
   applies).
2. **Create three tenants, read their ids**, and mint one `write` API key per
   tenant from the platform owner.
3. **Upgrade with the three quotas and `tenantNamespaceAutomation=true`**, then
   assert each namespace exists, carries the manager's managed-by label, and has
   the expected `ResourceQuota`.
4. **Onboard:** create each team's two pipelines and wait for `Running`. This is
   the "3 teams online" half. Record the time from create to `Running` per team.
5. **Press:** per tenant, four creates issued concurrently (not sequentially),
   then wait for every one of them to settle in either `Running` or `Stopped`
   with an error. Nothing is asserted while creating; the assertions run on the
   settled state. A background sampler reads `status.used` every two seconds for
   the whole phase, because a quota that is exceeded for two seconds is exceeded
   and a single reading afterwards cannot tell that apart from one that never
   was.
6. **Assert L1–L6** and print the numbers: per tenant, attempts, admitted,
   refused, refusal wall-clock from create to `deployment_error`, peak
   `status.used` per axis, storage claims left behind, objects of other tenants
   found in the namespace, manager restarts.
7. **Clean up** with each tenant's own key, and check that `status.used` returns
   to zero for the pipelines that were deleted — a quota that never gives a
   resource back is a slow-motion outage.

Running it a second time on the same cluster reuses the tenants, so step 1 of the
next run deletes the previous run's pipelines through the API before measuring
anything. It has to go through the API: a pipeline's Kubernetes objects belong to
the manager, and deleting them with `kubectl` leaves the row saying `provisioned`
for objects that no longer exist, after which stop, clear and delete are all
refused permanently and the only way out is to delete the rows. That is a
property of the platform worth knowing, not just of this script — the suite fails
with the reset recipe rather than timing out when it meets such a row.

## 5. What was measured

Run on 2026-11-05 against the kind cluster `bili-p1005` (one node, 48 CPUs, 124
GiB), manager and compiler images tagged `p1-033`, which is the tree of commit
`4f426c860` plus this work order's script. `PASS` in 345 seconds.

Onboarding, which is the "3 teams online" half:

| team | two pipelines `Running` after |
| --- | --- |
| pilot-stream | 34s |
| pilot-risk | 31s |
| pilot-recsys | 34s |

Quota held by two running pipelines, against a quota of 4 CPU / 16Gi / 12 claims
/ 48Gi — exactly what §3 predicts:

```
requests.cpu=2/4  requests.memory=8Gi/16Gi  requests.storage=8Gi/48Gi  persistentvolumeclaims=2/12
```

Pressure, four concurrent requests per team with two slots free:

| team | admitted | refused | refusals settled after |
| --- | --- | --- | --- |
| pilot-stream | 2 | 2 | 34s, 44s |
| pilot-risk | 2 | 2 | 71s, 81s |
| pilot-recsys | 2 | 2 | 107s, 116s |

Peak `status.used` across all samples, all three teams: `requests.cpu=4/4`,
`requests.memory=16Gi/16Gi`, `requests.storage=24Gi/48Gi`,
`persistentvolumeclaims=6/12`. Never over the ceiling on any axis, at any of the
two-second samples.

The remaining properties:

- A saturated team refuses further requests with the quota's own words, and no
  other team's four axes move by a byte. The refusal leaves a volume claim
  behind (6 → 7) because the StatefulSet controller creates the claim before the
  pod; deleting the pipeline releases it. That asymmetry is deliberate (§3): a
  storage quota larger than the CPU quota makes this visible instead of hiding it.
- No pipeline object appears in another team's namespace.
- The manager restarted zero times. The API server recorded 112 refused pod
  creation attempts for the 6 refused pipelines — about eighteen per refusal,
  because the StatefulSet controller retries with backoff and the API server
  aggregates the attempts into one event with a count. What matters is that the
  count did not grow in the thirty seconds after the pipelines settled: the
  manager had taken the StatefulSets away, so nothing was still asking.
- Cleanup returned every axis to zero for all three teams.

## 6. What gets recorded, and where

- This document, with the results above: the numbers, the tree they were
  measured on, and anything the assertions caught.
- `design/p1-work-orders.md` P1-034 row: the same numbers in one line, plus the
  decision about P1-029.
- `docs/self-hosted-tenant-namespaces.md`: a "sizing a quota" subsection, because
  the arithmetic in §3 is the thing an operator gets wrong — a `requests.cpu`
  quota without `defaultRequest.cpu` refuses pipelines that never asked for CPU.

## 7. Out of scope

- Real pilot teams, their owners, and their workloads: no roster exists to
  onboard (§1).
- P1-029's calendar criterion (seven days without a P0) and its feedback loop.
- SSO login, pod-crash RTO and the dashboard: they belong to P1-036's exit
  rehearsal.
- A nightly workflow. P1-033's isolation suite is a gate because "another tenant
  cannot reach this one" is a property that can regress silently; this run is a
  measurement answering a work order's question, and it costs 345 seconds on top
  of two image builds. If the quota arithmetic later becomes something a change
  can break, the script is ready to be scheduled the same way.
