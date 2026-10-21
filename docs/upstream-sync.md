# Upstream sync policy

This fork carries a self-hosted enterprise platform layer on top of `feldera/feldera`. Upstream
releases fast: between v0.357.0 (2026-09-26) and v0.367.0 (2026-10-17) there were **10 tags and 387
commits**. A fork that cannot absorb that flow is dead within a quarter, so the integration ritual
is part of the product, not an afterthought.

This document defines three things: which of our changes are allowed to touch upstream files, how
those edits are carried when a rebase would otherwise conflict, and the exact rebase steps with the
gates that must pass before the result is trusted. Measured numbers from the first rehearsal are in
`design/rebase-rehearsal-2026-10-21.md`.

## 1. How our branch is layered

Every change we make belongs to exactly one of three buckets. The bucket decides how it survives a
rebase.

| Bucket | What it contains | Rebase behaviour |
| --- | --- | --- |
| **A. New files only** | `charts/`, `deploy/Dockerfile.{manager,compiler,runner}`, `deploy/build-images.sh`, `deploy/docker-compose.bili-smoke.yml`, `deploy/maven-settings.xml`, `crates/dbsp-enterprise`, `crates/sync-checkpoint`, `design/`, `docs/self-hosted-*.md`, `docs/design/`, `python/tests/platform/test_selfhosted_ft_e2e.py`, `webconsole-dist/` | Never conflicts. Verified: all 58 added files replayed clean through 387 upstream commits. |
| **B. Edits to upstream files** | Currently 9 files, listed below | This is the **patch surface**. Kept as small as possible; grows only with review. |
| **C. Upstream-reserved names** | `crates/dbsp-enterprise`, `crates/sync-checkpoint` (both ignored upstream because the real crates are closed-source) | Needs the `.gitignore` negation in bucket B to stay visible. |

The current patch surface, with the smallest change that achieves the goal in each file:

| File | Why we edit it | Size |
| --- | --- | --- |
| `.gitignore` | un-ignore the two stub crates (bucket C) | 5 lines |
| `Cargo.toml` | add the two workspace members; drop `postgresql_embedded`'s `bundled` feature (its build script calls the GitHub releases API and fails on anonymous quota) | ~10 lines |
| `Cargo.lock` | generated | — |
| `README.md` | pointer to `docs/self-hosted-*.md` | 3 lines |
| `crates/pipeline-manager/src/config.rs` | `KubernetesRunnerConfig` | ~119 lines |
| `crates/pipeline-manager/src/pipeline_env.rs` | `validate_pipeline_env_with` + `KUBERNETES_` prefix switch | ~60 lines |
| `crates/pipeline-manager/src/runner.rs` | module declarations | 2 lines |
| `crates/pipeline-manager/src/all_in_one.rs` | register both executors' CLI args | ~34 lines |
| `crates/pipeline-manager/src/bin/pipeline-manager.rs` | `FELDERA_RUNNER` dispatch | ~39 lines |

Rule of thumb: **if an upstream edit is generally useful, send it upstream instead.** The runner
dispatch in `all_in_one.rs` / `bin/pipeline-manager.rs` is generic (any executor, not just ours) and
is the strongest upstream-PR candidate we have; carrying it as a patch forever is the expensive
option. Until such a PR lands, it stays bucket B.

## 2. `patches/` convention

`patches/` holds the edits to upstream files that cannot be upstreamed in time (or at all). It is
applied mechanically after a rebase by `scripts/apply-patches.sh`.

* **Name**: `patches/NNNN-kebab-name.patch`, four-digit, monotonically increasing. Numbers are never
  reused; if a patch has to be rewritten, it gets the next number and a note in the header.
* **Size**: at most **2 000 changed lines** per patch. A patch that grows past that is either split
  by concern or converted into bucket A (new file + one-line include), which is the preferred fix.
* **Scope**: one logical change per patch. A patch that touches unrelated files cannot be reviewed,
  and cannot be dropped selectively when upstream finally implements the feature.
* **Header** (inside the patch, above the diff):

  ```text
  Upstream-Ref: feldera@v0.367.0 (sha 7caff0799)
  Reason: <one sentence: why we cannot wait for upstream>
  Conflicts: <files/functions where upstream churn is expected>
  Upstream-PR: <link, or "none planned">
  ```

* **Generation**: `git format-patch -1 <sha> -o patches/ --start-number <n>` for a single commit;
  `git diff <base>..<head> -- <paths> > patches/NNNN-name.patch` when the change spans commits.
* **Never** put generated or vendored files in a patch (`Cargo.lock`, `webconsole-dist/`,
  `sql-to-dbsp-compiler/**/target/`).

Current state: **the stack is empty.** The nine bucket-B files are ordinary commits on the working
branches. P1-007's runner wiring (5 of the 9 files) is the first extraction candidate; extraction
waits until P1-009 touches the same functions, because splitting history before the interface stops
moving costs more than it saves.

## 3. Rebase procedure

Quarterly is the floor, not the target: with a tag every 1–3 days, do it **at least monthly, plus
before every pilot window**. A rehearsal against 10 releases took minutes (see the record), so the
real cost is the verification gates, not the rebase.

```bash
# 0. preconditions: clean tree, no in-flight image build, >= 15 GiB free
git -C <repo> status --short          # must be empty

# 1. fetch
git fetch origin main --tags

# 2. pick the target: the newest *tag*, not origin/main (main sits between releases)
git for-each-ref --sort=-creatordate --format='%(refname:short) %(creatordate:short)' refs/tags | head -3

# 3. branch off the current working branch, never rebase a branch CI already validated
git switch -c sync/<tag>

# 4. replay our commits onto the tag (driver script does steps 4-6)
scripts/rebase-onto-upstream.sh <tag>

# 5. re-apply the patch stack (empty today)
scripts/apply-patches.sh

# 6. regenerate the lockfile: online, once, at the end (mirror note under §5, gate 1)
cargo +1.96.1 metadata --format-version 1 > /dev/null

# 7. gates (section 5), then push and record
git push myfork sync/<tag>
```

`scripts/rebase-onto-upstream.sh <tag> [--from <ref>] [--skip-lock]` automates steps 4–6: it
refuses a dirty tree, creates `sync/<tag>`, reports the drift, replays the commits, resolves a
`Cargo.lock` stop by taking our side (rule 4), stops on any other conflict with the file list,
applies the patch stack, then resets the lock to the tag and refreshes it
(`--skip-lock` stops before the refresh).

## 4. Hard rules

**`Cargo.lock` is not mergeable.** Upstream marks it `merge=binary` in `.gitattributes:1`, so git
refuses to produce a merged file and every rebase that touches it stops. The two-sided dance is
deliberate:

1. *During* the rebase, resolve to **our** side (`git checkout --theirs -- Cargo.lock` — inside a
   rebase `HEAD` is the upstream commit, so `--theirs` is ours). Our commits were authored against
   that lock, so only the first one conflicts instead of all of them; the rehearsal went from 10+
   stops to 1 with this choice.
2. *After* the rebase, reset the file to the upstream version (`git checkout <tag> -- Cargo.lock`)
   and run one `cargo metadata`. Upstream moves dependencies between releases — v0.367.0 moved
   `deltalake` (and 20 sibling packages) from crates.io to `git+https://github.com/feldera/delta-rs`
   at a pinned rev — so a lock that is "mostly ours" is simply wrong, not slightly stale.

Do not hand-edit the lock, and do not regenerate it on every stop: mid-rebase most steps do not
have our workspace members yet.

**Migrations are forward-only.** `crates/pipeline-manager/migrations/V<n>__*.sql` is a shared,
global namespace: the highest number went from V36 (our fork point) to V37 within three weeks.
Never edit a file that exists (a deployed database has already run it), never reuse a number, and
**renumber our new migrations at rebase time** to `max(upstream, ours) + 1`. A duplicate `V<n>`
makes Refinery abort on startup, which looks like a code failure and wastes a debugging session.

**`.gitignore` is a known conflict point.** Upstream ignores `crates/dbsp-enterprise` and
`crates/sync-checkpoint`; our negation lines (`!crates/dbsp-enterprise`, `!crates/sync-checkpoint`)
must survive. After a rebase, verify:

```bash
git check-ignore -v crates/dbsp-enterprise/src/lib.rs   # must print nothing
git ls-files crates/dbsp-enterprise crates/sync-checkpoint | wc -l   # must be > 0
```

**`webconsole-dist/` is a generated artifact.** 21 files, 18 MiB, ~495 000 lines, committed because
`deploy/Dockerfile.manager` copies it into the image instead of building the web console inside
BuildKit (building it there deadlocks image export on Docker Desktop, see
`docs/self-hosted-images.md`). It is bucket A and never conflicts, but it goes **stale** whenever
upstream changes `js-packages/web-console/`. Rebuild it as part of the image gate; never hand-edit.

**Never force-push a branch someone may have pulled.** Rebase rewrites our commits (fresh SHAs on
every replay). Push `sync/<tag>` and let the working branches fast-forward onto it; `--force-with-lease`
only on `myfork` feature branches with no other consumer.

## 5. Post-rebase gates

All of these must pass before a rebased branch replaces a working branch. They mirror the P1
verification story; the image gate is the slow one, so run the first three first.

| # | Gate | Command | Catches |
| --- | --- | --- | --- |
| 1 | Lockfile resolves | `cargo +1.96.1 metadata --format-version 1` (network) | upstream added a dependency (including new `git` deps) we cannot resolve |
| 2 | Workspace compiles | `cargo +1.96.1 check --all-targets` | API drift in the 9 bucket-B files |
| 3 | Manager unit tests | `cargo +1.96.1 test -p pipeline-manager --lib` | behavioural drift in runner/config code |
| 4 | FT e2e (local) | `python/tests/platform/test_selfhosted_ft_e2e.py` | checkpoint/restore contract used by the platform layer |
| 5 | Three images | `deploy/build-images.sh` | Dockerfile drift (paths, toolchain pins, base image) |
| 6 | kind smoke | `helm upgrade --install` + `/healthz` == 200 | chart/values drift against renamed settings |
| 7 | Enterprise print | compile a pipeline with `--enterprise` | the two stub crates still satisfy the code the compiler generates |

Gate 1 and 2 are fast; gate 5 is the long pole (currently hours with a cold cache). For a *rebase
check* before a pilot, gates 1–4 plus a warm-cache image rebuild are enough; for a release, all
seven.

Gate 1 needs a **working registry mirror**, and it is the one gate whose failure looks like a code
bug. Upstream keeps moving dependencies to new sources (v0.367.0 moved `deltalake` and 20 sibling
packages to a pinned `git` rev), so the lock must be resolved online every time. On the verification
machine the default `~/.cargo/config.toml` (crates.io replaced by the USTC *git* index) times out
with `transfer too slow … transferred 0 bytes`; overriding to the rsproxy sparse index resolves in
about two minutes:

```bash
cargo metadata --format-version 1 \
  --config 'source.crates-io.replace-with="rsproxy"' \
  --config 'source.rsproxy.registry="sparse+https://rsproxy.cn/index/"'
```

A correct refresh leaves the lock within ~20 lines of the tag's lockfile (only our two workspace
members differ); anything else means the resolve silently used a stale graph.

## 6. When a rebase goes wrong

* **Abort**: `git rebase --abort` restores the pre-rebase state. Our commits are additive, so the
  worst case is losing the conflict resolution work, not our history.
* **A patch no longer applies**: `scripts/apply-patches.sh` uses `git apply --3way`, which leaves
  conflict markers and a usable index. Resolve, then regenerate that patch with
  `git diff --staged > patches/NNNN-name.patch` under its **next** number and note why in the header.
* **Upstream changed an interface we implement** (the realistic case: `PipelineExecutor` in
  `crates/pipeline-manager/src/runner/pipeline_executor.rs`, or the StatefulSet template placeholders
  in `crates/feldera-types/src/config.rs`): the interface change and our adapter change go into one
  commit, and the ADR (`docs/design/adr-k8s-runner.md`) is updated in the same commit. Splitting
  them produces a commit that does not compile.
* **A leak appears only after the rebase**: check first whether the lockfile was regenerated at the
  end (rule 4); a stale lock silently keeps old dependency versions and can mask an upstream fix.
