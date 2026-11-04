# P1-033: tenant isolation, audited and proved

P1-022 through P1-025 each added one mechanism that keeps one tenant from
reaching another: a namespace per tenant with a quota in it, a role table that
names the tenant each route acts in, group-to-role mapping in the identity
provider, and an allowlist for connector secrets. The platform plan states the
promise those four mechanisms are supposed to add up to — "tenant quota
stress-testing (they cannot hit each other); every secret-allowlist escalation
case returns 403" (`design/self-hosted-enterprise-platform-plan.md:290`) — and
the work order asks for it to be *proved* rather than asserted
(`design/p1-work-orders.md:118`).

Nothing had done that. Each suite tested its own mechanism from the inside: one
tenant hitting its own quota, one tenant's secrets, one tenant's roles. No test
ever put two tenants against each other, and no document said what should happen
when they meet.

Reading the code for this audit found one case where they meet and the answer is
wrong: a pipeline may name the namespace it deploys into, and the runner honours
that name even when the tenant has a namespace of its own — so a tenant can place
its pipeline inside another tenant's namespace and mount that tenant's secrets
(ISO-1). Writing the suite that proves the fix found three more: a pod that keeps
a service-account token it has no use for (ISO-2), a quota map that silently
places nothing where it says it does (ISO-7), and two defects that left the
multi-tenant mode dead rather than breached — a `RoleBinding` Kubernetes would
not let the manager create (ISO-8) and a `NetworkPolicy` that shut the manager
out of every tenant namespace (ISO-9). The last two are the argument for the
suite: neither is visible from a single-tenant test, and neither is a breach
either, so nothing would have reported them.

This document is the review packet: the threat model, what already holds, the
findings and what is being done about each, the risks deliberately accepted, and
where the regression suite runs.

## 1. What "cannot hit each other" has to mean

Four boundaries, each with an attacker who is an authenticated tenant with the
`write` role in their own tenant and no other privilege:

| # | Boundary | The attack it stops |
|---|----------|---------------------|
| N | network | tenant A's pipeline opens a connection to tenant B's pipeline |
| Q | quota | tenant A consumes all of a shared resource so tenant B cannot run |
| S | secrets | tenant A reads a Secret that belongs to tenant B |
| A | authorization | tenant A's key reads or writes tenant B's pipeline, key, or membership |

A boundary holds when the answer is a refusal the attacker cannot turn into
data: a closed port, a `Forbidden` from the API server, a 403 or 404 from the
manager, or a pipeline that never starts. It does not hold when the refusal
merely happens to be inconvenient — a 404 that reveals nothing is a pass, an
error message quoting the other tenant's resource name is not.

## 2. What already holds

**Network.** Every pipeline gets a `NetworkPolicy` that admits only the manager's
namespace (and the monitoring namespace when it differs) on the pipeline's port
(`crates/pipeline-manager/src/runner/kubernetes_runner.rs:827`
`render_network_policy`, `policy_types: ["Ingress"]`). Because the policy is
created in the pipeline's own namespace, tenant B's pipeline is not reachable
from tenant A's namespace — not because of anything tenant-aware, but because
the peer selector names the manager namespace and A's pods are not in it. The
pipeline's own Service is therefore closed to every other tenant. Egress is
deliberately open: `design/p1-010-network-path.md` records the decision, taken
because a pipeline's sources and sinks are arbitrary external addresses and
closing egress would need a per-connector allowlist.

**Quota.** `tenant_namespace::apply`
(`crates/pipeline-manager/src/runner/tenant_namespace.rs:680`) writes a
`ResourceQuota` and a `LimitRange` into the tenant's namespace, labelled as
platform-managed. A pipeline that exceeds its quota is refused at creation time
with the API server's numbers and a next step, rather than sitting in
`Provisioning` until the timeout (`scripts/e2e-k8s-tenant-quota.sh`). Quotas are
per namespace, so one tenant's consumption cannot move another's ceiling.

**Secrets.** A connector may reference `${secret:kubernetes:<name>/<key>}` only
when `<name>` is on the deployment's allowlist
(`crates/pipeline-manager/src/runner/kubernetes_runner.rs:1094`
`connector_secrets`). Only the referenced keys are projected into the pod, via
`SecretVolumeSource.items`, and the values never reach the database
(`scripts/e2e-k8s-secrets.sh` asserts both). Because the mount is
namespace-local, a tenant can only ever mount its own namespace's Secret.

**Authorization.** The route table assigns every route a minimum role and an
acting tenant (`crates/pipeline-manager/src/api/rbac.rs`), and two tests keep the
table honest: `every_tenant_scoped_route_reaches_a_handler_that_reads_the_acting_tenant`
(`:542`) and `handlers_that_take_a_tenant` (`:602`). `select_acting_tenant`
(`crates/pipeline-manager/src/auth.rs:779`) resolves the `Feldera-Tenant` header
against the caller's memberships and answers `403` for a tenant it is not a
member of (`DBError::NotATenantMember`, `crates/pipeline-manager/src/db/error.rs:1284`).
Queries filter by `tenant_id` (`crates/pipeline-manager/src/db/operations/pipeline.rs`
— list `:113`, by name `:160`, by id `:220`), so another tenant's pipeline is
invisible rather than merely forbidden.

## 3. Findings and the remediation checklist

Severity is the impact of the finding as it stood when the audit started, not
the effort to fix it.

| ID | Sev | Finding | Action | Proof |
|----|-----|---------|--------|-------|
| ISO-1 | High | A pipeline may name its own namespace (`runtime_config.resources.namespace`), and `KubernetesRunner::namespace` (`crates/pipeline-manager/src/runner/kubernetes_runner.rs:1470`) prefers that name over the tenant mapping "as given rather than checked". A tenant mapped to its own namespace can therefore deploy into another tenant's namespace, where the namespace-local Secret mount resolves to *that* tenant's Secret and a connector pointed at an attacker-controlled URL carries the value out. | When the tenant has a mapped namespace, an explicit namespace must equal it; anything else is refused with an actionable error. Unmapped tenants keep the old behaviour, which is what existing pipelines rely on. | Unit tests on both branches; e2e cross-tenant attempt in the suite (§5). |
| ISO-2 | Medium | Pipeline pods are created without `automount_service_account_token` (`kubernetes_runner.rs:993` sets only `service_account_name`), so the namespace's default token is mounted into a pod whose program is tenant-supplied SQL and whose connectors are tenant-supplied addresses. The default account usually holds no permission, so the impact is reconnaissance rather than access — but it is a credential in a container that has no use for it. | Set `automount_service_account_token: Some(false)`; a pipeline that genuinely needs the API server sets `kubernetesRunner.pipelineServiceAccount` and can be given the flag back explicitly. | Unit test beside `service_account_and_env_are_forwarded` (`:3146`). |
| ISO-3 | High | The four boundaries are held up by code reading alone. No test has two tenants. A regression in any of the four mechanisms — a dropped `tenant_id` filter, a relaxed route, a namespace override, a widened policy — would pass every suite in the repository. | `scripts/e2e-k8s-isolation.sh`: one install, two tenants with their own namespaces and quotas, both keys, all four boundaries attacked in sequence. | The suite itself; wired into CI (§5). |
| ISO-4 | Medium | A cross-tenant read answers `404`, not `403`, because the row filter hides the object before any role check runs. That is the right answer (it reveals nothing) but it is undocumented and unpinned: a future change that returns `403` with the name in the body would pass unnoticed. | Assert `404` and assert the body carries no trace of the other tenant's name; state the rule in the isolation doc. | Steps 4 and 5 of the suite. |
| ISO-5 | Low | The secret allowlist is a list of *names*, global to the deployment. Isolation comes only from the namespace scope of the mount, which means two tenants sharing one namespace share Secrets. That is inherent to the shared-namespace deployment mode, but nothing says so where an operator reads it. | Document the consequence in `docs/self-hosted-secrets.md`; assert in the suite that a Secret that exists only in the other tenant's namespace is not mountable. | Suite step 6. |
| ISO-6 | Low | A tenant namespace has no default-deny policy of its own (`tenant_namespace.rs` creates the namespace, quota and limit range only). Every *pipeline* is covered by its own policy, but any other workload an operator puts in that namespace is open to every tenant. | Accepted and documented (§4): a default-deny would also close the platform's own paths and cannot be verified on a CNI without policy support. | Documented only. |

| ISO-7 | Medium | The quota map is keyed by tenant id where the runner reads it, but resolved by *name* when it is built, so an entry written with a tenant name creates the namespace and the quota and then leaves that tenant's pipelines in the shared namespace — spending a quota nothing is counted against, and moving them nowhere. The chart documents the id, but nothing notices the name. | Warn at start-up when a key is not a tenant id, naming the tenant and the id to use instead. | `TenantNamespaces::from_config`, and `docs/self-hosted-tenant-namespaces.md`. |
| ISO-8 | High | Tenant namespace automation could not work on a fresh install. The manager creates a `RoleBinding` in the tenant namespace that grants the runner's permissions, and Kubernetes refuses it — "is attempting to grant RBAC permissions not currently held" — because the manager holds those permissions through a `Role` in its own namespace only, as the chart intends. Tenant creation rolled back, so the feature failed closed and had never worked anywhere except a cluster where an older chart had left the binding behind. | With `tenantNamespaceAutomation`, the chart also creates a `ClusterRoleBinding` for the manager to the same `pipeline-runner` `ClusterRole`: the grant exists before the binding that needs it. | Chart render assertions in `scripts/e2e-k8s-chart.sh`; the suite creates both namespaces from scratch. |
| ISO-9 | High | Every pipeline in a tenant namespace was `Unavailable`. The `NetworkPolicy` admits the namespace the *manager* runs in, and `render_stateful_set` computed that namespace from the *pipeline's* namespace whenever `--kubernetes-runner-manager-namespace` was unset — although `crates/pipeline-manager/src/config.rs:2384` documents it as the runner's own namespace. In a tenant namespace the policy admitted the tenant and shut the manager out, so the pipeline started, answered nothing, and the runner gave up on it. | Fall back to the runner's own namespace (`KubernetesRunner::manager_namespace`), and pass the flag explicitly from the chart. | Unit test `a_pipeline_in_a_tenant_namespace_admits_the_runner_namespace`; the suite's network step reaches B's pipeline from the manager and not from A. |

ISO-1 and ISO-2 are code changes. ISO-3 is the suite. ISO-4 through ISO-7 are
documentation plus assertions. ISO-8 and ISO-9 were found by building that suite
and are the argument for having built it: both are invisible to a single-tenant
test, and both leave the feature dead rather than breached.

One gate was red before any of this and had been for several work orders:
`scripts/e2e-k8s-chart.sh` compares the rendered chart against a recorded golden
file, and the golden had not been re-recorded after P1-028 added a
`volumeClaimTemplates` entry to the database StatefulSet
(`cf1120c42`). The render assertions added for ISO-8 and ISO-9 are in that same
suite, so it was re-recorded and is green again.

## 4. Risks accepted, with the reason

**Egress is open.** A tenant's pipeline can open connections to the manager's
API, PostgreSQL, and the Kubernetes API server. Each answers with its own
authentication, and none of them trusts a caller because it is inside the
cluster. Closing egress per tenant would need a per-connector allowlist that
breaks arbitrary sources and sinks, which is the trade recorded in
`design/p1-010-network-path.md`. The suite asserts the *ingress* side, which is
the boundary that protects other tenants' pipelines.

**Unmapped tenants share a namespace.** A deployment that maps no namespace for
a tenant leaves it in the platform's namespace, where it shares the quota, the
NetworkPolicy peers and the Secret namespace with every other unmapped tenant.
That is the pre-P1-022 mode and it is not isolation; `ISO-5` documents it rather
than pretending otherwise. The suite maps both tenants, so it tests the
supported multi-tenant shape.

**A tenant namespace has no default-deny.** See ISO-6. The platform's own
workloads in that namespace are reached by the manager through the cluster
network, and a blanket deny would need an explicit allow for each of them. It is
listed here so a reviewer sees it was considered, not missed.

**The audit trail is the manager's, not the cluster's.** P1-027 covers who did
what through the API; Kubernetes audit logs are the operator's concern and are
not part of this work order.

## 5. The regression suite

`scripts/e2e-k8s-isolation.sh` installs one release with authentication on, two
tenants each with a namespace and a quota, one `write` key per tenant, and then
attacks every boundary in turn. It reuses `scripts/keycloak-fixture.sh` for the
identity provider and follows the conventions of the existing suites: progress on
stdout, data on stderr, one `fail` per assertion with the observed value quoted.
A green run takes about three minutes on the build cluster.

The install is two phases, which the quota map forces: it is keyed by tenant id,
and a tenant has no id until it exists.

1. **Phase one.** The release, with authentication on and no tenant mapping. An
   owner signs in, creates tenants `acme` and `beta`, and the suite reads their
   ids.
2. **Phase two.** `helm upgrade` with `tenantNamespaceAutomation`, the two ids
   mapped to `tenant-acme` and `tenant-beta` with the same quota each, and the
   connector Secret allowlist on. Asserts each namespace exists, is labelled as
   platform-managed, and carries a `ResourceQuota`, a `LimitRange` and the
   runner's `RoleBinding` — ISO-8's regression is that last one.
3. **Keys.** Each tenant mints its own `write` key, and each key lists its own
   tenant's keys and no other's.
4. **Network.** A pipeline per tenant, both running. From A's pod, a request to
   B's pipeline Service must time out; from the manager's namespace the same
   request must answer `200`. The second half is what makes the first half mean
   something — a pod that cannot reach anything also "cannot reach B" — and it is
   ISO-9's regression.
5. **Quota.** A's first pipeline asks for the whole core, which fills A's quota;
   the same half-core request is then refused in A and accepted in B. A's
   pipelines are deleted before the secret steps, so the quota step cannot refuse
   them for the wrong reason.
6. **Secrets.** A Secret is created in each namespace, and one in B's only. A
   mounts its own — the value in the pod's filesystem must be A's marker — and a
   pipeline of A's referencing B's Secret must produce a pod the kubelet refuses
   to start, naming that Secret, in A's namespace. B mounts the same Secret
   successfully, so the reference is not broken: it is looked up in the wrong
   tenant. Neither pipeline is required to stay up; the mount happens before the
   program starts, which is the same choice `scripts/e2e-k8s-secrets.sh` makes.
7. **Authorization.** A's key against B's pipeline: `404`, and compared byte for
   byte against the answer for a name that never existed — only the name may
   differ, because a `404` that differs tells A the pipeline exists (ISO-4).
   `start` and `DELETE` also `404`, B's pipeline survives, A's key list does not
   contain B's key, `Feldera-Tenant: <B>` is `403`, listing B's members is `403`,
   and creating a tenant is `403`.
8. **Namespace escape.** A's pipeline naming `tenant-beta` must be refused at
   provisioning with an error naming both namespaces, and leave no pod,
   StatefulSet, Service or Secret in B's namespace (ISO-1's regression).

CI: `.github/workflows/test-tenant-isolation.yml`, nightly at 03:11 UTC and on
demand, mirroring `chaos-nightly.yml`, plus a pull-request trigger filtered to
the paths that can break a boundary — the runner, the route table, the
authentication code, the migrations, the chart and the suite itself. It is
nightly rather than on every pull request because it needs a kind cluster, an
identity provider, and two images.

## 6. What the security review needs

- This document, with §3's table as the finding list and the state of each.
- A green run of `scripts/e2e-k8s-isolation.sh`, pasted into the review thread.
- The residual-risk section read and either accepted or turned into new findings
  — ISO-6 in particular is a deployment decision, not a code one.
- Confirmation that the suite runs on a schedule, so the guarantees decay into a
  failing pipeline rather than into folklore.
