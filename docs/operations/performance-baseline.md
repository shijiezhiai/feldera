# Performance baseline

This page is the reference for "how fast is the platform on the hardware we
have", and for the disk requirement the PVC sizing rule depends on. The numbers
come from `scripts/perf-baseline.sh`; the run that produced the current baseline
is recorded in `design/perf-baseline-2026-11-04.md`.

Read the numbers as a floor, not a promise. They describe one machine, and the
storage numbers in particular describe its disks: a deployment on a different
disk type will disagree with the storage section and should, because that
section exists to tell you whether the disk you have is good enough.

## What the script measures

Three independent scopes, run separately or together:

| scope | what it answers | how |
|---|---|---|
| `storage` | is the disk good enough, and does a PVC cost anything over a local directory | 4 KiB `O_DIRECT` random reads and writes to a 16 GiB file, plus sequential `dd` throughput |
| `throughput` | how many records per second does a dataflow sustain | a datagen source feeding a materialized `COUNT(*)`, timed from Running to end of input |
| `recovery` | how long from a crash to a running pipeline, and how much was lost | SIGKILL to the pipeline process, timed to the new process answering again |

`PATHS=local,k8s` runs the storage scope twice: once against a directory on the
node, once against a `PersistentVolumeClaim` through the runner's own image. The
two numbers together are the answer to "does the PVC add overhead", which is the
only storage question a local directory cannot answer.

## Requirements the baseline is judged against

The disk requirement is IOPS and bandwidth, not capacity: the platform's
`StorageClass` whitelist asks for **16k IOPS and 1000 MB/s**. A disk below the
line works but will not keep up with a checkpoint-heavy pipeline, which is why
the script prints a verdict instead of only numbers.

The recovery requirement is the P1 exit criterion: **RTO < 120 s** for a pod
crash, with the RPO bound from the layering table — at-least-once with a 60 s
checkpoint interval loses at most 60 s of input.

## Running it

```bash
SCOPES=storage,throughput,recovery PATHS=local,k8s \
RUNNER_TAG=<the runner tag> REPORT=design/perf-baseline-$(date +%F).md \
  scripts/perf-baseline.sh
```

The script talks to the manager through a port-forward and cleans up after
itself; `KEEP=1` leaves the PVC and the pipelines behind for inspection. It needs
`kubectl`, `python3`, `gcc` and `docker`, and for the K8s storage scope a
container image that the cluster can pull.

The recovery scope needs one thing no other scope needs: it has to send a signal
to the pipeline process from the **node that hosts the pod**. `kubectl exec`
cannot do that — the kernel discards SIGKILL sent to the init process of a PID
namespace from inside that namespace, so `kubectl exec <pod> -- kill -9 1`
returns success and kills nothing. On a kind cluster the node is a container and
`docker exec <node> crictl ...` works; on a plain node run the script on that node
with `crictl` on `PATH`.

## Reading a result

- **Storage below the disk requirement is not a bug in the platform.** It is the
  machine telling you it is running on a disk the platform does not recommend.
  The fix is the disk, not the configuration.
- **A PVC close to the local directory is the expected result** for `local-path`
  storage, because the PVC is a bind mount on the same disk. A PVC far slower
  than the local directory means the storage class is pushing traffic through
  something else — a network filesystem, a throttled cloud volume — and that is
  worth understanding before it is blamed on the platform.
- **Throughput is a property of the dataflow, not of the machine alone.** A
  number much lower than the baseline on the same hardware means the query
  changed shape: more operators, a join that now spills, a wider record.
- **Recovery is bounded by the checkpoint interval, not by the scheduler.** If a
  run reports seconds, the pipeline resumed from checkpoint; if it reports the
  full provisioning time, it started cold and the checkpoint was not used.

## When a measurement fails

A failed measurement is reported, not skipped: a baseline with a hole in it
cannot be used to judge a later run. The failure table in the generated report
says which scope failed and why, and the exit status is non-zero if any did.

## Appendix: the baseline measured on 2026-11-04

Hardware: a single kind node on an `xfs` volume served by a `PERC H330 Mini`
RAID controller with rotational media, 39 TB, 3 % used. Runner
`v0.357.0-52-gc13e46766-bili.1`, fault tolerance `at_least_once` with a 10 s
checkpoint interval, `standard` (local-path) StorageClass. The raw report,
including the exact command, is `design/perf-baseline-2026-11-04.md`.

| metric | local directory | K8s PVC | requirement | verdict |
|---|---|---|---|---|
| sequential write (MiB/s) | 878.2 | 961.5 | ≥ 1000 | below |
| sequential read (MiB/s) | 647.7 | 745.3 | ≥ 1000 | below |
| random 4 KiB read (IOPS) | 150.8 | 158.6 | ≥ 16000 | **far below** |
| random 4 KiB write (IOPS) | 1933.6 | 2604.4 | ≥ 16000 | **far below** |

| metric | value | requirement |
|---|---|---|
| throughput | 108,010 records/s | — (baseline) |
| throughput, records | 5,000,000 in 46,292 ms | — |
| recovery (crash → running) | 3,903 ms | < 120,000 ms |
| records at the last checkpoint | 1,110,000 | — |
| records lost in the crash | 210,000 | bounded by the checkpoint interval |
| records after recovery | 1,380,000 | resumed, not restarted cold |

Three things this run establishes, and one it does not:

1. **The recovery criterion is met with a large margin** — 3.9 s against a 120 s
   budget. The pipeline resumed from its checkpoint (the counter continued at
   1.11 M rather than restarting at zero), so the number is a recovery and not a
   cold start.
2. **`local-path` PVCs cost nothing measurable over a local directory** — the two
   columns agree within run-to-run noise, which is what a bind mount on the same
   disk should do. A future run where the PVC column is much slower points at the
   StorageClass, not at the platform.
3. **This machine's disks do not meet the disk requirement, by two orders of
   magnitude on random reads.** That is the hardware, not a misconfiguration, and
   it is why the storage verdict says "not all requirements are met" while the
   recovery and throughput numbers are usable.
4. It does **not** establish a number for a disk that meets the requirement. The
   baseline has to be re-run on the target hardware before it can be used to size
   anything; on this machine the storage section is a statement about the lab.

