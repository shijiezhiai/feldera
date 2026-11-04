# P1-032: the performance baseline

P1-019 made the K8s runner provision a PVC per pipeline and clamp its size. The
platform plan asks for two things that PVC decision rests on and that nothing had
measured: that the disk behind that PVC meets the IOPS and bandwidth requirement
(`design/self-hosted-enterprise-platform-plan.md:143`), and that a pod crash
recovers within the P1 exit criterion of two minutes (`:288`). The regression
gate also wants a throughput number so a later change can be compared against it
(`:251`).

This work order produces all three from one command, and writes them into the
runbook so an operator can compare a later measurement against them.

Script: `scripts/perf-baseline.sh`.
Report: `design/perf-baseline-2026-11-04.md`.
Runbook: `docs/operations/performance-baseline.md`.

## 1. What the work order asked for

| Requirement | Where it landed |
| --- | --- |
| Same machine, local vs K8s PVC | `PATHS=local,k8s` runs the storage scope twice, once against a node directory and once against a `PersistentVolumeClaim` through the runner's own image |
| Verify the disk meets 16k IOPS | the storage scope measures 4 KiB `O_DIRECT` random read and write on a 16 GiB file and prints a verdict against 16k IOPS and 1000 MB/s |
| Throughput baseline | the throughput scope times a bounded datagen source into a materialized `COUNT(*)` |
| Recovery-time baseline | the recovery scope SIGKILLs the pipeline process and times the return to a running pipeline |
| Baseline numbers in a runbook appendix | `docs/operations/performance-baseline.md`, §Appendix |

## 2. How each scope measures

**Storage.** 4 KiB reads and writes with `O_DIRECT` over a 16 GiB file, because
the number has to describe the disk rather than the page cache. The file is
written sequentially before the random phase begins: an `ftruncate`d file is
sparse, and reading holes out of it does not touch the disk at all. That mistake
was made once here and produced 821,573 IOPS on a rotational disk; the fix is a
1 MiB-at-a-time fill plus `fsync` before the timed window.

The K8s half runs the same probe in a Job that mounts the claim, because the
question is what the *claim* delivers, not what the node's filesystem delivers.
The probe binary travels to the cluster as a gzipped ConfigMap. `kubectl apply`
cannot carry it: `apply` records the object in the
`kubectl.kubernetes.io/last-applied-configuration` annotation, and that
annotation is capped at 256 KiB while the base64 probe is 378 KiB, so the apply is
rejected and the Job then waits forever for a ConfigMap that does not exist. The
script creates the ConfigMap instead and asserts it is there.

**Throughput.** A datagen source with a bounded plan feeds
`CREATE MATERIALIZED VIEW v AS SELECT COUNT(*) FROM t`. The clock starts when the
pipeline reaches Running and stops when the processed counter reaches the plan's
limit, so the number describes the dataflow and not the pod start. The counter is
read from inside the pod rather than through the manager, so the manager's proxy
is not part of the measurement.

**Recovery.** The pipeline is SIGKILLed and the clock runs until a *new process*
answers and the manager reports Running. Two false signals had to be ruled out
first, and both are worth recording because either produces a number that looks
excellent and means nothing:

- The dying process keeps answering for a few hundred milliseconds, and the
  manager keeps reporting the last status it saw until its next check (2500 ms
  when provisioned). Timing to "`/stats` answers" or to "the manager says
  Running" therefore measures the cost of an `exec`.
- `kubectl exec <pod> -- kill -9 1` does not kill anything. The kernel discards
  SIGKILL and SIGSTOP sent to the init process of a PID namespace from inside
  that namespace, so the command returns success while the pipeline keeps
  running — and a measurement built on it reports single-digit milliseconds. The
  same signal sent from the node's namespace does reach the process, the
  container exits non-zero, and the kubelet's restart policy brings it back in
  the same pod. That is the fault the exit criterion describes.

Deleting the pod is a different fault with a different answer, and the script
deliberately does not use it: the manager cannot reach a pipeline that has no
pod, treats it as failed and stops it (`a_vanished_pod_stops_the_pipeline_and_records_the_error`),
so measuring it would report the time to stop.

This also fixed a blind spot in P1-028. `scripts/e2e-k8s-chaos.sh` used
`kubectl exec <pod> -- kill -9 1` for every crash cell -- the two pipeline cells
and the PostgreSQL break -- so those cells injected nothing and passed on
assertions that hold when the pipeline is simply left alone. They now go through
`crash_container_of_pod`, which takes the node and the init pid from `crictl` and
signals from there; the helper was exercised against a live pipeline and the
container restarted (restart count 0 -> 1). The nightly run is what confirms the
cells' assertions once the fault actually bites.

## 3. Results

Measured 2026-11-04 on the lab kind cluster: one node, `xfs` on a `PERC H330
Mini` RAID controller with rotational media.

| metric | local | PVC | requirement |
| --- | --- | --- | --- |
| sequential write (MiB/s) | 878.2 | 961.5 | ≥ 1000 |
| sequential read (MiB/s) | 647.7 | 745.3 | ≥ 1000 |
| random 4 KiB read (IOPS) | 150.8 | 158.6 | ≥ 16000 |
| random 4 KiB write (IOPS) | 1933.6 | 2604.4 | ≥ 16000 |

| metric | value |
| --- | --- |
| throughput | 108,010 records/s (5,000,000 records in 46,292 ms) |
| recovery | 3,903 ms |
| records lost in the crash | 210,000 (checkpoint held 1,110,000 of 1,320,000) |

The numbers say three separate things:

1. **A `local-path` PVC adds nothing measurable.** The two columns agree within
   noise because the claim is a bind mount on the same disk. This is the answer
   to the work order's local-vs-PVC question, and it also tells a later reader how
   to read a future run: a PVC far slower than the local column means the
   StorageClass is routing through something else.
2. **The recovery criterion is met with a 30× margin**, and the counter resuming
   at the checkpoint's value rather than at zero is what makes the number a
   recovery instead of a cold start.
3. **This machine's disk does not meet the requirement**, by two orders of
   magnitude on random reads. That is why the report's overall verdict is "not
   all requirements are met on this machine" while the throughput and recovery
   numbers are usable: the storage verdict is about the hardware the lab happens
   to have.

The baseline therefore does not yet answer the sizing question the platform plan
asks — it says the lab cannot. Re-running the same command on the target hardware
is what closes that gap, and the script exists so that the re-run is one command
rather than a new investigation.

## 4. What a later run should compare

- Random 4 KiB read at or above 16k IOPS, and the verdict line green.
- Throughput within the same order of magnitude; a large drop means the dataflow
  changed shape, not that the machine got slower.
- Recovery in single-digit seconds, and `records after recovery` no lower than
  `records at the last checkpoint`.

A failure in any scope is written into the report rather than skipped; a baseline
with a silent hole cannot be used to judge anything.
