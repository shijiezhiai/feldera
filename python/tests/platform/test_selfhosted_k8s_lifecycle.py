"""Kubernetes runner end-to-end suite: the Python SDK drives the whole lifecycle.

The other suites in this directory talk to a manager whose pipelines run as
local processes.  This one assumes a manager installed from ``charts/feldera``
with ``FELDERA_RUNNER=kubernetes``, so every pipeline becomes a StatefulSet in
a real cluster, and it drives that lifecycle the way a user does: through the
Python SDK.

What it proves, in order:

1. ``PipelineBuilder.create()`` + ``start()`` reaches ``Running``, which means
   the runner rendered and applied the Secret, the storage claim, the Service,
   the NetworkPolicy and the StatefulSet, and the pod fetched its program
   binary from the compiler service.
2. Ingest and query work through the manager, so the pod is executing.
3. ``pause()``/``resume()`` keep the pod and its data; only the runtime state
   changes.
4. ``stop(force=True)`` scales the StatefulSet to zero but keeps the storage
   claim -- with the same UID on the way back up, so restarting reused the
   volume instead of recreating it.  The rows do not survive the restart:
   restoring a snapshot needs the fault-tolerance model, which the community
   edition rejects, so a fresh start counts from zero and the test asserts it.
5. ``delete(clear_storage=True)`` leaves nothing behind: no StatefulSet, no
   Service, no NetworkPolicy, no PersistentVolumeClaim and no Secret carries
   the pipeline's ``feldera.com/pipeline-id`` label any more.

The suite is opt-in because it needs a cluster, an installed release and
``kubectl``:

.. code-block:: bash

    FELDERA_K8S_E2E=1 FELDERA_K8S_NAMESPACE=feldera \\
    FELDERA_K8S_RELEASE=feldera KUBECONFIG=... \\
    uv run --locked python -m pytest -n0 -s \\
        tests/platform/test_selfhosted_k8s_lifecycle.py

Without ``FELDERA_HOST`` the suite opens its own ``kubectl port-forward`` to
``svc/<release>-controlplane-api-server``; set ``FELDERA_HOST`` to an endpoint
that already reaches the same manager to skip that.

The pipeline compiles with the ``unoptimized`` profile: a ``dev`` build spends
25 minutes linking a gigabyte of debug symbols, and this suite verifies the
lifecycle, not the optimizer.

Compilation is the only slow step; everything else is bounded by the waits
below.  A warm cluster finishes in about two minutes.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
import urllib.error
import uuid
import urllib.request
from typing import Iterator

import pytest

from feldera import FelderaClient, Pipeline, PipelineBuilder
from feldera.enums import CompilationProfile, PipelineStatus
from feldera.runtime_config import Resources, RuntimeConfig
from feldera.testutils import unique_pipeline_name

# Label the Kubernetes runner puts on every object it owns; the orphan check
# after `delete` selects on it.
PIPELINE_ID_LABEL = "feldera.com/pipeline-id"

# The generated program compiles the whole DBSP runtime on a cold cluster, which
# takes minutes; a warm compilation cache makes it seconds.  The timeout is
# generous because the first run on a fresh node is the slow one.
COMPILE_TIMEOUT_S = int(os.environ.get("FELDERA_K8S_COMPILE_TIMEOUT_S", "2400"))
DEPLOY_TIMEOUT_S = int(os.environ.get("FELDERA_K8S_DEPLOY_TIMEOUT_S", "900"))

SQL = """
CREATE TABLE t (i INT);
CREATE MATERIALIZED VIEW v AS SELECT COUNT(*) AS c FROM t;
"""

# One row per tuple; three rows, one of them a duplicate, so the view count is 3
# and a lost or replayed insert would show up as a different number.
ROWS = [{"i": 1}, {"i": 2}, {"i": 2}]
EXPECTED_COUNT = 3


def _unique_name(base: str) -> str:
    """A pipeline name that does not collide with a leftover from an earlier run.

    ``unique_pipeline_name`` keys off ``GITHUB_SHA``, so outside CI every run of
    the suite asks for the same name. That is fine for suites that clean up after
    themselves and never overlap, but this one leaves a pipeline behind whenever
    it fails, and a soak of a hundred runs then breaks on the second failure
    rather than reporting the first. The random suffix makes each run
    self-contained; the base name is kept so a human reading the cluster
    listings still knows which suite made the object.
    """
    suffix = uuid.uuid4().hex[:6]
    name = unique_pipeline_name(base)
    # `unique_pipeline_name` bounds the base to 62 characters; the suffix has to
    # fit inside that bound, not after it.
    return f"{name[: 62 - len(suffix) - 1]}_{suffix}"


pytestmark = pytest.mark.skipif(
    os.environ.get("FELDERA_K8S_E2E") != "1",
    reason=(
        "needs a Kubernetes cluster with the chart installed and FELDERA_RUNNER="
        "kubernetes; set FELDERA_K8S_E2E=1 to run"
    ),
)


def _kubectl(*args: str) -> str:
    """Run kubectl and return its stdout.

    The environment is inherited so ``KUBECONFIG``, ``FELDERA_K8S_CONTEXT`` and
    friends behave exactly as they do in the shell the operator used.
    """
    result = subprocess.run(
        ["kubectl", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"kubectl {' '.join(args)} failed with {result.returncode}:\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result.stdout.strip()


def _free_port() -> int:
    """Return a port that is free right now, for the API server tunnel."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _wait_for_http(url: str, timeout_s: float) -> bool:
    """Poll ``url`` until it answers, or give up."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"{url}/healthz", timeout=3) as response:
                if response.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(1)
    return False


def _pipeline_objects(namespace: str, pipeline_id: str) -> list[str]:
    """Every object the runner labelled as belonging to this pipeline."""
    kinds = "statefulset,service,networkpolicy,persistentvolumeclaim,secret,pod"
    output = _kubectl(
        "get",
        kinds,
        "--namespace",
        namespace,
        "--selector",
        f"{PIPELINE_ID_LABEL}={pipeline_id}",
        "--output",
        "name",
        "--ignore-not-found",
    )
    return [line for line in output.splitlines() if line.strip()]


def _has_object(namespace: str, pipeline_id: str, kind: str, suffix: str = "") -> bool:
    """Whether the pipeline still owns an object of ``kind`` ending in ``suffix``."""
    return any(
        object_.startswith(kind) and object_.endswith(suffix)
        for object_ in _pipeline_objects(namespace, pipeline_id)
    )


def _wait_until(description: str, condition, timeout_s: float) -> None:
    """Poll ``condition`` until it returns a truthy value.

    Failing with the description -- and not with the last observed value --
    keeps the message useful when the predicate is a label selector that keeps
    returning an empty list.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(2)
    raise AssertionError(f"timed out after {timeout_s:.0f}s waiting for {description}")


@pytest.fixture(scope="module")
def k8s() -> Iterator[tuple[FelderaClient, str]]:
    """A client for the Kubernetes manager and the namespace its pods live in."""
    namespace = os.environ.get("FELDERA_K8S_NAMESPACE", "feldera")
    release = os.environ.get("FELDERA_K8S_RELEASE", "feldera")

    host = os.environ.get("FELDERA_HOST")
    forward: subprocess.Popen | None = None
    if not host:
        port = _free_port()
        forward = subprocess.Popen(
            [
                "kubectl",
                "port-forward",
                "--namespace",
                namespace,
                f"svc/{release}-controlplane-api-server",
                f"{port}:8080",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        host = f"http://127.0.0.1:{port}"
        if not _wait_for_http(host, 60):
            forward.terminate()
            pytest.fail(f"the API server never answered at {host}")

    try:
        yield FelderaClient(host), namespace
    finally:
        if forward is not None:
            forward.terminate()
            forward.wait(timeout=10)


def _count(client: FelderaClient, pipeline: Pipeline) -> int:
    """Read the materialized view's count through the manager."""
    rows = [row for row in pipeline.query("SELECT c FROM v")]
    assert len(rows) == 1, f"the view returned {len(rows)} rows: {rows}"
    return rows[0]["c"]


def _wait_for_status(pipeline: Pipeline, expected: PipelineStatus, timeout_s: float):
    """Wait until the manager reports ``expected`` for the pipeline."""
    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        last = pipeline.status()
        if last == expected:
            return
        if last == PipelineStatus.NOT_FOUND:
            raise AssertionError(
                f"the pipeline disappeared while waiting for {expected}"
            )
        time.sleep(2)
    raise AssertionError(
        f"timed out after {timeout_s:.0f}s waiting for {expected}; last status was {last}"
    )


def test_pipeline_lifecycle_leaves_no_kubernetes_objects(k8s):
    """Drive one pipeline through its whole life and check the cluster at each step."""
    client, namespace = k8s
    name = _unique_name("k8s_lifecycle")
    pipeline: Pipeline | None = None

    try:
        pipeline = PipelineBuilder(
            client,
            name=name,
            sql=SQL,
            compilation_profile=CompilationProfile.UNOPTIMIZED,
            runtime_config=RuntimeConfig(
                resources=Resources(
                    cpu_cores_min=0,
                    cpu_cores_max=1,
                    memory_mb_min=256,
                    memory_mb_max=1024,
                ),
                provisioning_timeout_secs=DEPLOY_TIMEOUT_S,
            ),
        ).create()
        pipeline_id = pipeline.id()
        assert pipeline_id, "the manager did not assign a pipeline id"

        # 1. Deploy: the StatefulSet exists, the pod becomes Ready, and the
        #    manager flips to Running only after the pipeline's /status answers.
        pipeline.start(timeout_s=COMPILE_TIMEOUT_S + DEPLOY_TIMEOUT_S)
        _wait_for_status(pipeline, PipelineStatus.RUNNING, DEPLOY_TIMEOUT_S)

        objects = _pipeline_objects(namespace, pipeline_id)
        joined = "\n".join(objects)
        for kind in (
            "statefulset.apps/",
            "service/",
            "networkpolicy.networking.k8s.io/",
            "persistentvolumeclaim/",
            "secret/",
        ):
            assert _has_object(namespace, pipeline_id, kind), (
                f"the runner created no {kind} for this pipeline; it created:\n{joined}"
            )

        # 2. The pipeline executes: write rows, read the count back.
        pipeline.input_json("t", ROWS, update_format="raw")
        assert _count(client, pipeline) == EXPECTED_COUNT

        # 3. Pausing changes the runtime state only.  The pod stays, so the
        #    StatefulSet must not have lost its replica.
        pipeline.pause()
        _wait_for_status(pipeline, PipelineStatus.PAUSED, 120)
        assert _pipeline_objects(namespace, pipeline_id), (
            "pausing removed every Kubernetes object; it should keep the pod"
        )
        pipeline.resume()
        _wait_for_status(pipeline, PipelineStatus.RUNNING, 180)
        assert _count(client, pipeline) == EXPECTED_COUNT

        # 4. Stopping scales compute to zero but keeps storage.  The claim has to
        #    survive the stop with the same UID: a claim that is deleted and
        #    recreated looks identical by name, yet it silently drops the spill
        #    and checkpoint files an operator expects to still be there.
        #
        #    The rows themselves do not survive.  Restoring a snapshot on start
        #    needs the fault-tolerance model, which the community edition rejects
        #    (ValidationError::EnterpriseFeature("fault tolerance") in
        #    crates/pipeline-manager/src/db/types/utils.rs).  The claim holds
        #    spill and checkpoint files, not a start-up snapshot, so a restart
        #    counts from zero.
        claim_name = f"pipeline-{pipeline_id}-storage"
        claim_uid = _kubectl(
            "get",
            "persistentvolumeclaim",
            claim_name,
            "--namespace",
            namespace,
            "--output",
            "jsonpath={.metadata.uid}",
        )
        assert claim_uid, "the runner created no storage claim for the pipeline"

        pipeline.stop(force=True)
        _wait_for_status(pipeline, PipelineStatus.STOPPED, 180)
        _wait_until(
            "the pipeline pod to disappear after stopping",
            lambda: (
                not [
                    object_
                    for object_ in _pipeline_objects(namespace, pipeline_id)
                    if object_.startswith("pod/")
                ]
            ),
            180,
        )
        assert _has_object(
            namespace, pipeline_id, "persistentvolumeclaim/", "-storage"
        ), "stopping deleted the storage claim; only compute should scale down"

        pipeline.start(timeout_s=DEPLOY_TIMEOUT_S)
        _wait_for_status(pipeline, PipelineStatus.RUNNING, DEPLOY_TIMEOUT_S)
        assert (
            _kubectl(
                "get",
                "persistentvolumeclaim",
                claim_name,
                "--namespace",
                namespace,
                "--output",
                "jsonpath={.metadata.uid}",
            )
            == claim_uid
        ), "restarting replaced the storage claim instead of reusing it"
        assert _count(client, pipeline) == 0, (
            "a restart without fault tolerance must count from zero; if this ever "
            "returns the pre-stop rows, snapshot restore started working and this "
            "assertion should become EXPECTED_COUNT"
        )

        # 5. Deleting removes everything the runner created.  The API only
        #    accepts a delete once the pipeline is stopped and its storage is
        #    released, which is the same three-step walk the REST script does.
        pipeline.stop(force=True)
        _wait_for_status(pipeline, PipelineStatus.STOPPED, 180)
        pipeline.delete(clear_storage=True)
        _wait_for_status(pipeline, PipelineStatus.NOT_FOUND, 180)
        _wait_until(
            "every Kubernetes object of the deleted pipeline to disappear",
            lambda: not _pipeline_objects(namespace, pipeline_id),
            180,
        )
        pipeline = None
    finally:
        if pipeline is not None:
            try:
                pipeline.stop(force=True)
            except Exception:  # noqa: BLE001 - cleanup must not mask the failure
                pass
            try:
                pipeline.delete(clear_storage=True)
            except Exception:  # noqa: BLE001
                pass


def test_the_runner_reports_its_own_objects(k8s):
    """A pipeline's objects carry the labels a cleanup job selects on.

    The orphan sweep (P1-017) finds objects by label rather than by name, so the
    naming convention is not enough: the labels have to be there, and they have
    to identify both the pipeline and the deployment.
    """
    client, namespace = k8s
    name = _unique_name("k8s_labels")
    pipeline: Pipeline | None = None

    try:
        pipeline = PipelineBuilder(
            client,
            name=name,
            sql=SQL,
            compilation_profile=CompilationProfile.UNOPTIMIZED,
            runtime_config=RuntimeConfig(
                resources=Resources(cpu_cores_max=1, memory_mb_max=1024),
                provisioning_timeout_secs=DEPLOY_TIMEOUT_S,
            ),
        ).create()
        pipeline.start(timeout_s=COMPILE_TIMEOUT_S + DEPLOY_TIMEOUT_S)
        _wait_for_status(pipeline, PipelineStatus.RUNNING, DEPLOY_TIMEOUT_S)
        pipeline_id = pipeline.id()

        labels = json.loads(
            _kubectl(
                "get",
                "statefulset",
                f"pipeline-{pipeline_id}",
                "--namespace",
                namespace,
                "--output",
                "jsonpath={.metadata.labels}",
            )
        )
        assert labels.get(PIPELINE_ID_LABEL) == pipeline_id
        assert labels.get("app.kubernetes.io/name") == "feldera-pipeline"
        assert labels.get("app.kubernetes.io/managed-by") == "feldera-pipeline-manager"
        assert labels.get("feldera.com/deployment-id"), (
            "the objects carry no deployment id, so the orphan sweep cannot tell a "
            "live deployment from a leftover one"
        )

        pipeline.stop(force=True)
        _wait_for_status(pipeline, PipelineStatus.STOPPED, 180)
        pipeline.delete(clear_storage=True)
        pipeline = None
    finally:
        if pipeline is not None:
            try:
                pipeline.stop(force=True)
            except Exception:  # noqa: BLE001
                pass
            try:
                pipeline.delete(clear_storage=True)
            except Exception:  # noqa: BLE001
                pass
