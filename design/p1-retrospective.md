# P1 retrospective: what thirty-eight work orders bought

P1 was planned as six sprints, thirty-eight work orders and a four-condition exit
(`design/self-hosted-enterprise-platform-plan.md` §6). This is the record of what
shipped, what cost more than estimated, what the work found that nobody ordered,
and what that means for P2. It is written from the branch, not from memory: every
claim below is a commit, a script, or a test that still runs.

Work order: `design/p1-work-orders.md` row P1-038.

## 1. The branch, in numbers

| | |
|---|---|
| commits | 64 (`origin/main..HEAD`: thirty-eight work orders, one rebase, one correction, and this record) |
| hand-written change | 164 files, `+40042 / −504` |
| generated change | 21 files under `webconsole-dist/`, `+512347` (documented in `docs/upstream-sync.md` §4: the image copies it instead of building the web console in BuildKit) |
| new e2e suites | 17 (`scripts/e2e-k8s-*.sh`; upstream has none) |
| new CI workflows | 3 (`test-k8s-runner.yml`, `chaos-nightly.yml`, `test-tenant-isolation.yml`) |
| records and runbooks | `design/` and `docs/`, `+7843` |

The ratio is the first honest finding: 93% of the diff is a build artifact that
is supposed to be there, and the platform work is 40k lines of Rust, shell,
Helm and Markdown. Anyone reviewing this branch by diff size will draw the wrong
conclusion.

## 2. What each work order delivered

Status legend: **shipped** means a commit plus a test or e2e that exercises it;
**shipped, stand-in** means the mechanism is real but the counterpart is a
fixture; **not shipped** means exactly that.

| ID | Delivered | Evidence | Status |
|---|---|---|---|
| P1-001 | `crates/dbsp-enterprise`, `crates/sync-checkpoint` stubs | `878d38ea5` | shipped |
| P1-002 | `--enterprise` FT e2e v0 + local-directory synchronizer | `b89da102a` | shipped |
| P1-003 | rdkafka build path for `dbsp_connectors` | `9222f28d4` | shipped |
| P1-004 | source-built images (manager/compiler/runner) | `2dce89bc0` plus the `deploy(...)` fixes it took | shipped |
| P1-005 | Helm chart skeleton + kind smoke | `7bf89aa79` | shipped |
| P1-006 | KubernetesRunner ADR (executor → K8s objects) | `7f4ae0efc` | shipped |
| P1-007 | `FELDERA_RUNNER` dispatch | `77579b0a5` | shipped |
| P1-008 | upstream sync process + first rehearsal | `3278f6b20` | shipped |
| P1-009 | KubernetesRunner vertical slice | `1d38c53cb`, `e6398b3af` | shipped |
| P1-010 | manager↔pipeline network path + NetworkPolicy | `f41b75829` | shipped |
| P1-011 | StatefulSet rendering + resource clamp | `cefd74293`, `93d65b091` | shipped |
| P1-012 | cosign + vulnerability gate | `2be409860`, `64f4f3204`, `1560a8584` | shipped |
| P1-013 | kind lifecycle e2e (create→run→delete, zero residue) | `6ba02c1ab`, `eb4007214`, `e0532eb83` | shipped |
| P1-014 | OIDC signing-key refresh | `916d8ccb3` | shipped |
| P1-015 | pipeline metrics + Grafana dashboard | `144a0702d` | shipped |
| P1-016 | checkpoint on SIGTERM | `cdfc88657` | shipped |
| P1-017 | delete/reclaim + reaper | `f662eae4a`, `728e265cc` | shipped, reaper does not collect Services (§5.6 of the rehearsal) |
| P1-018 | compiler separated into its own pod | `19d552f2f` | shipped |
| P1-019 | full Helm chart, leader election, failover fix | `fcbbcf991` | shipped |
| P1-020 | model-based automaton tests (found the stuck-`Stopping` bug) | `776ad448e` | shipped |
| P1-021 | console OIDC login + TLS | `b0dd2bc34` | shipped, IdP is the Keycloak fixture |
| P1-022 | per-tenant namespace + ResourceQuota + LimitRange | `609c93a39`, `464b4a0c1` | shipped |
| P1-023 | tenant scope in the RBAC table | `e45809b69` | shipped |
| P1-024 | OIDC group → role | `cdaba1297` | shipped |
| P1-025 | connector Secret references, allowlisted by name | `9b01b7a86` | shipped |
| P1-026 | crates mirror: compile with no public egress | `f50249b13` | shipped |
| P1-027 | audit log (principal, route, decision) | `974f55111`, `b297f92c8` | shipped |
| P1-028 | chaos matrix, five faults × two tiers | `cf1120c42` | shipped |
| P1-029 | pilot team ① onboarding + seven-day window | — | **not shipped** (see §4.5) |
| P1-030 | alerting baseline, seven rules | `30b68a943` | shipped |
| P1-031 | upgrade rehearsal + post-rebase gates as one command | `e2ac064e3`, `9ce1307c9` | shipped (the rehearsal is the rebase itself) |
| P1-032 | performance baseline + the fault the matrix never injected | `19f299477` | shipped |
| P1-033 | tenant isolation suite + the four defects it found | `4f426c860` | shipped |
| P1-034 | three teams + quota stress | `83026b483` | shipped, teams are stand-ins |
| P1-035 | runbook v1, executed end to end | `ba444571a` | shipped, on a fresh namespace |
| P1-036 | the exit, measured | `d9a6115e8` | shipped, three conditions with a stand-in |
| P1-037 | automaton multi-active code review (input to §5.7) | — | **not shipped** |
| P1-038 | this document + the P2 backlog | — | this commit |

Thirty-five shipped, two did not, and the thirty-eighth is this document. The two
that did not are the two that needed something the branch could not supply on its
own: a real pilot team's week (P1-029) and a code walkthrough that was superseded
by an empirical answer (P1-037 — §7.2).

## 3. The exit, measured

`design/p1-036-exit-rehearsal.md` is the record; the summary is that four
conditions have numbers:

- three tenants online with quotas pressed and zero cross-tenant bleed, 352s;
- a crashed pod serving again in **1s** against a 120s bound, resuming at exactly
  the last completed checkpoint;
- a console login through an IdP that ends as the tenant's owner;
- a Grafana panel whose own query returns numbers that came through a real
  Prometheus.

Three of them are met with a named stand-in (the company IdP, the company
monitoring stack, real pilot teams). That is the difference between "ready" and
"declared", and the rehearsal keeps the two apart on purpose.

## 4. Where the effort actually went

The plan estimated 38 work orders and 166 person-days (`design/p1-work-orders.md`
§1). The work landed, but not
in the proportions the plan assumed. Five things cost more than the estimate, and
each has a lesson worth carrying into P2.

### 4.1 The rebase was the expensive part, and the cost was not in the conflicts

Fifty-six commits replayed over about 36 minutes against an `origin/main` that had
renamed `dbsp_adapters` to `dbsp_connectors`, moved `crates/adapters/src/` to
`crates/connectors/src/`, and changed `FtConfig.checkpoint_interval_secs:
Option<u64>` into `checkpoint_interval: Option<Option<ConfigDuration>>`
(`design/rebase-rehearsal-2026-11-03.md`). The conflicts fell into three classes,
only one of which git shows you:

- **A rename that moves a directory.** Our P1-016 edits pointed at a path that no
  longer existed. Worse, upstream had meanwhile implemented checkpoint-on-SIGTERM
  itself, so the right answer was to keep upstream's implementation and port only
  the `begin_suspend` refactor and its tests — two shutdown paths would have made
  behaviour depend on which signal handler ran first.
- **Interface changes that compile and then mean something else.** Five of them:
  `ResourceConfig` fields became `ConfigSize`, `max_rss` likewise,
  `can_provision` lost a parameter, `provision`'s last three arguments became
  `runtime_selector` + `legacy_spelling`, and a reaper helper was renamed. The
  `legacy_spelling` one is the trap: ignoring it compiles cleanly and then a
  pipeline pinned to the old runtime receives new-spelling configuration and dies
  at startup with "unknown config field".
- **A shared namespace where nothing conflicts textually.** Our
  `V37__group_role_membership.sql` and upstream's
  `V37__sync_stopped_deployment_resources.sql` share a number; Refinery aborts
  and **99 tests fail for one cause**. That one is now a hard rule in
  `docs/upstream-sync.md` §4: renumber our migrations to `max(upstream, ours)+1`.

The most expensive single failure mode was still not a conflict. When both sides
append a test at the end of a file, git takes upstream's closing brace of the last
function as a common suffix: our new function lands *inside* upstream's function,
the file loses a brace, and the compiler reports an unclosed delimiter at an
unrelated function. It happened in `metrics.rs`, `controller.rs`, `program.rs`,
`pipeline_env.rs` and twice in `pipeline_automata.rs`. A grep for unbalanced
braces finds nothing useful (3 262 hits, all doc comments); the compiler is the
only reliable detector.

Lesson: after a rebase, `cargo check` is not a formality, it *is* the conflict
detector, and the branch must be compiled before any conflict hunk is believed
resolved. A test appended at end-of-file is a merge hazard — P2 should prefer new
test modules over appended functions in files upstream also edits.

### 4.2 The enterprise feature is a build flag, not an entitlement

The plan's biggest risk (§9-R1) was that fault tolerance would turn out to be
gated at runtime. It is gated at *compile* time, in one `#[cfg]`:
`crates/pipeline-manager/src/db/types/utils.rs:204` rejects `fault_tolerance` when
`feldera-enterprise` is off, and `crates/connectors/src/server.rs:946` does the
same in the pipeline process. That is good news — it means no licensing service,
no phone-home — and it bit us anyway, because a hand-rolled overlay image dropped
the flag and the only symptom was `400 InvalidRuntimeConfig ... enterprise
feature: fault tolerance` with the body swallowed by `curl --fail`.

Lesson: a capability that changes what the binary accepts should be visible in
the binary's own output. `GET /v0/config` reports `"edition": "Enterprise"`;
`GET /v0/pipelines` reports `"platform_version": "0.376.0+enterprise"`. Both are
now in `docs/self-hosted-chaos.md`, and the chaos suite should preflight on them
rather than discover it at the first pipeline.

### 4.3 The disk was the slowest thing in the plan, and it is not ours to fix

P1-032 was written to prove a 16k IOPS disk type. `/mnt/storage01` turned out to
be a mechanical RAID (`ROTA=1`, PERC H330), and the kind cluster keeps its
volumes there. No amount of testing reaches 16k IOPS on a spinning disk, so the
baseline was re-cut to what the hardware can answer: sequential 878/961 MiB/s,
4K random read 150/158 IOPS, and — the number that matters operationally — a
local-path PVC costs *nothing* over a local directory on the same disk. The
throughput baseline (108 010 records/s) and the recovery baseline (3 903 ms,
210 000 records of at-least-once replay) are now on record for the SSD model to
be compared against.

Lesson: a performance criterion that names a hardware property must name the
hardware. "16k IOPS" on an unknown disk is not a gate, it is a wish; P2 should
re-run `scripts/perf-baseline.sh` on the real target and keep the two numbers
side by side.

### 4.4 Every e2e suite had bugs of its own

Seventeen suites, and the pattern was consistent: the first run fails for a
reason that has nothing to do with the platform. The recurring causes, all now
fixed and worth knowing:

- `awk '...; exit'` at the head of a pipeline returns 141 (SIGPIPE) under
  `pipefail`, and `set -e` turns that into a silent exit — green on a fast
  machine, red on a slow one. Three call sites.
- `kubectl exec <pod> -- kill -9 1` is a no-op: the kernel refuses SIGKILL to the
  PID namespace's init. Five chaos injections were doing nothing while asserting
  success. Signals must come from the node namespace (`crictl inspect` → `kill`).
- `kubectl port-forward` fails silently when idle, and a `curl` immediately after
  it starts returns an empty body (`Expecting value: line 1 column 1`).
- `python3 - <<'PY'` inside a pipeline competes for stdin; `python3 -c` does not.
- `trap cleanup EXIT` overwrites the script's exit status with its own —
  a successful run reports failure because the last `[ -n "$x" ] && cmd`
  returned 1.
- A Grafana panel asserts nothing when `histogram_quantile` returns an *empty*
  result (zero rate), which looks identical to a broken panel.

Lesson: a suite is code too. Budget roughly a third of the estimate for making
the instrument trustworthy, and prefer assertions that fail loudly over
assertions that pass on a technicality — three of the six above were "passing"
tests that measured nothing.

### 4.5 The pilot teams were the one thing code could not produce

P1-029 asked for a real team's pipelines running for seven days with no P0
incident. There is no team in the repository. P1-034 substituted three tenants
with realistic quotas and two pipelines each, and proved the platform holds them
apart under pressure — which is the part that is engineering — while the
seven-day window, the feedback loop and the "non-critical pipeline" judgement
stay with whoever runs the pilots.

Lesson: keep scheduling and engineering in separate work orders. A row whose DoD
requires another organisation's calendar should be a P2 item from the start, not
a P1 row that quietly turns into a stand-in.

## 5. What the work found that nobody ordered

This is the part of P1 that justifies its cost. Seven defects were found, not by
reading the code, but by running it against a second tenant, a second failure, or
a second build:

| Found by | Defect | Severity |
|---|---|---|
| P1-033 (isolation suite) | `runtime_config.resources.namespace` overrode the tenant's namespace: tenant A could place a pipeline in B's namespace and have a `${secret:kubernetes:...}` resolved there | High, a real escape |
| P1-033 | `tenantNamespaceAutomation=true` could not work on a fresh install: the manager lacks the RBAC it needs to grant, and Kubernetes refuses | High, feature was unusable |
| P1-033 | `manager_namespace` fell back to the *pipeline's* namespace, so a tenant-namespace pipeline was unreachable by the manager and settled at `Unavailable` | High, tenancy half-broken |
| P1-020 (model tests) | the automaton could stick in `Stopping` forever under a pod event | Medium |
| P1-019 (leader election) | failover left the old leader reconciling | Medium |
| P1-032 (chaos injection) | five chaos cells never injected the fault they asserted | Medium, false confidence |
| P1-036 (rehearsal) | `force stop` was accepted and then ignored for ~9 minutes; a reaper that leaves Services behind | Medium, unexplained |

The pattern: the defects that matter are found when a mechanism meets its second
customer — a second tenant, a second failure mode, a second build. Single-tenant
testing found none of the three High ones.

## 6. P2's planned scope is already spent

The plan's P2 (M6–M7) was written before P1 started, and P1 pulled most of it
forward, because each mechanism only worked when it met a real adversary:

| Planned P2 | Reality after P1 |
|---|---|
| namespace / quota / secret allowlist | shipped in P1-022, P1-025, P1-033, P1-034 |
| group → role + audit + JWK refresh | shipped in P1-024, P1-027, P1-014 |
| security review + penetration test | review package written (`design/p1-033-tenant-isolation.md`), external test **not** done |
| tenant quota stress (they cannot hit each other) | shipped, P1-034, zero penetration in 352s |
| secret allowlist escalation must be 403 | shipped, P1-033 |
| self-service onboarding | **not started** |

So P2 is not "the multi-tenancy milestone" any more. What remains is: the
external security review and penetration test, self-service onboarding, turning
the three stand-ins into the real ones, the control-plane HA decision, and paying
down what P1 found and did not fix. `design/p2-work-orders.md` re-cuts the
milestone along those lines — twelve work orders instead of the plan's six, with
the same exit gate: quota stress, 403s, and a passed security review before
self-service opens.

## 7. Open questions, updated

`design/self-hosted-enterprise-platform-plan.md` §11 listed four.

**7.1 FT gating — closed.** It is a compile-time feature (§4.2), no entitlement
check, no runtime licence. The e2e tail the question mentions (an `--enterprise`
binary that pauses and resumes, plus a local rdkafka build) closed with P1-002,
P1-003 and, for the crash path, P1-028 and P1-036.

**7.2 Automaton multi-active — answered empirically, not by walkthrough.**
P1-019 made the manager a Deployment with a Lease, and P1-036 measured what
happens when the reconciling instance is restarted: the pipeline keeps running,
its `deployment_id` and pod UID do not change, and control returns in 13s. That
is the behaviour a Lease is supposed to give, and it makes the P1-037 walkthrough
unnecessary for the P2 decision: the remaining question is not "can the automaton
be multi-active" but "is a warm standby worth 15s of unavailability". P1-037 is
therefore dropped and the decision moves to P2-004.

**7.3 IdP group-claim capacity and role governance — still open, and it is a
policy question.** No amount of code settles who owns the group-to-role table.
It is P2-002, and it needs an owner before self-service opens (P2-007).

**7.4 JDBC/point-query gateway — not needed for P1 or P2.** No pilot asked for
it; views leave through Kafka and S3. Kept as a P4 candidate.

## 8. Process changes for P2

1. **Each work order names the adversary.** "A second tenant", "a second failure",
   "a second build" — a mechanism with one customer is untested by construction.
2. **Stand-ins are declared in the same sentence as the result.** The rehearsal
   format (`p1-036`) worked: condition, measurement, result, and a gap list that
   says which part is a fixture.
3. **A suite's first green is not evidence.** The six instrument bugs in §4.4 all
   produced green runs that measured nothing. Every new suite needs one run where
   the assertion is expected to fail.
4. **Scheduling work orders are separated from engineering ones** (§4.5), and
   carry a named owner outside the team.
5. **The enterprise build flag is a preflight, not a discovery** (§4.2).

## 9. Verdict

P1 delivered the platform it promised: a Kubernetes runner with quotas, tenants,
secrets, SSO, audit, alerts, a runbook and a chaos matrix, on a branch that
rebases cleanly onto a moving upstream, with 35 of 38 work orders shipped and the
thirty-eighth being this record. It also found three High-severity
tenant-isolation defects and two false-confidence test suites, which is more than
a milestone usually gets for its money.

Two things did not happen, and both were outside the code: a real pilot team's
week, and an external security review. P2 starts from there rather than from the
plan's original list.
