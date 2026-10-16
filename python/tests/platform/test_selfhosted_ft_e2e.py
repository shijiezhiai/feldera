"""Self-hosted, enterprise-edition fault-tolerance end-to-end test.

This suite starts its own ``pipeline-manager``, built with the
``feldera-enterprise`` cargo feature, on a free port with a private embedded
Postgres.  It then compiles and runs a datagen -> materialized table ->
materialized view pipeline whose results are read back over the manager's HTTP
API, and checks two fault-tolerance properties of that enterprise build:

* suspending a pipeline (``stop(force=False)``) and starting it again must not
  rewind the input progress watermark -- the restarted pipeline resumes the
  input it had already consumed instead of replaying it from scratch, and
* ``start_from_checkpoint`` must really restore state: a checkpoint that one
  pipeline pushed to its configured checkpoint directory must bring a *new*
  pipeline with empty local storage up at exactly the record count that was
  checkpointed.

Both properties belong to the enterprise edition: checkpointing to storage and
checkpoint synchronization are gated behind the ``feldera-enterprise`` feature,
and an OSS build answers ``501 EnterpriseFeature`` to the relevant endpoints.

The suite is opt-in, because it needs artifacts that the default test run does
not build:

* ``target/debug/pipeline-manager`` built with ``--features feldera-enterprise``
  (``CARGO_NET_OFFLINE=true cargo +1.96.1 build -p pipeline-manager
  --features feldera-enterprise``),
* the SQL compiler jar at
  ``sql-to-dbsp-compiler/SQL-compiler/target/sql2dbsp-jar-with-dependencies.jar``
  (``cd sql-to-dbsp-compiler && ./build.sh``),
* a JDK 19 or newer for that jar (the compiler pom targets Java 19; point
  ``FELDERA_TEST_JAVA_HOME`` at one if it is not the ``JAVA_HOME`` on the
  machine), and
* librdkafka 2.12.1 or newer discoverable by ``pkg-config``, because generated
  pipelines link it dynamically (``./scripts/install-librdkafka.sh`` installs
  one; ``FELDERA_LIBRDKAFKA_PREFIX`` points at a different prefix).

Run it with::

    FELDERA_SELFHOSTED_ENTERPRISE_E2E=1 \\
    UV_CACHE_DIR=/tmp/feldera-uv-cache \\
    uv run --locked python -m pytest -n0 -s tests/platform/test_selfhosted_ft_e2e.py

The first compilation of a pipeline builds the whole runtime, which takes a
long time.  Point ``FELDERA_SELFHOSTED_E2E_WORKDIR`` at a persistent directory
to keep the manager state and that cargo cache across runs; the suite then
reuses only the generated-program cargo cache and starts the manager on a fresh
database.  Without that variable, the suite uses a fresh temporary directory and
removes it afterwards.

The manager's embedded Postgres binds the fixed port 8082, so only one suite
that starts its own manager can run at a time.

When a test fails, the manager log is in ``<workdir>/logs/manager.log`` and the
pipeline logs are available through ``GET /pipelines/<name>/logs``.
"""

from __future__ import annotations

import glob
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import Iterator

import pytest

from feldera import FelderaClient, PipelineBuilder
from feldera.enums import CompilationProfile
from feldera.runtime_config import RuntimeConfig
from tests.platform_rbac.manager import AuthConfig, Manager
from tests.utils import env_truthy, wait_for_condition

# ---------------------------------------------------------------------------
# Paths, opt-in gate and tunables
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]

MANAGER_BINARY = Path(
    os.environ.get(
        "FELDERA_TEST_BINARY",
        str(REPO_ROOT / "target" / "debug" / "pipeline-manager"),
    )
)

SQL_COMPILER_JAR = Path(
    os.environ.get(
        "FELDERA_SQL_COMPILER_JAR",
        str(
            REPO_ROOT
            / "sql-to-dbsp-compiler"
            / "SQL-compiler"
            / "target"
            / "sql2dbsp-jar-with-dependencies.jar"
        ),
    )
)

LIBRDKAFKA_PREFIX = Path(
    os.environ.get(
        "FELDERA_LIBRDKAFKA_PREFIX",
        str(REPO_ROOT / "target" / "librdkafka-install"),
    )
)

# The toolchain the repository pins for the generated pipeline crates. The
# default rustup toolchain is older than their MSRV.
CARGO_TOOLCHAIN = os.environ.get("FELDERA_TEST_CARGO_TOOLCHAIN", "1.96.1")

# Generated pipelines build offline by default: this host has no usable
# crates.io index, and the dependency closure is cached.
CARGO_NET_OFFLINE = os.environ.get("FELDERA_TEST_CARGO_NET_OFFLINE", "true")

# Rows the datagen plan produces. The plan is finite, so the table reaches
# exactly this count and then stops growing: a stable, exact signal for both
# "did the pipeline resume" and "did it start over".
DATAGEN_RECORDS = 20_000
DATAGEN_RATE = 5_000

INGEST_TIMEOUT_S = 300.0
CHECKPOINT_TIMEOUT_S = 300.0
POLL_INTERVAL_S = 0.5

# The embedded Postgres the manager installs and starts binds this fixed port,
# so only one suite that starts its own manager can run at a time.
POSTGRES_PORT = 8082

# How long to wait for that port to become free before giving up. A suite that
# is already running releases it when it finishes.
POSTGRES_PORT_WAIT_S = float(os.environ.get("FELDERA_TEST_POSTGRES_PORT_WAIT_S", "900"))

pytestmark = pytest.mark.skipif(
    not env_truthy("FELDERA_SELFHOSTED_ENTERPRISE_E2E"),
    reason=(
        "needs a locally built enterprise pipeline-manager, the SQL compiler jar "
        "and librdkafka; set FELDERA_SELFHOSTED_ENTERPRISE_E2E=1 to run"
    ),
)


# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------


def _require_prerequisites() -> None:
    """Fail loudly, rather than skip, when the opt-in run lacks its artifacts.

    The test was explicitly requested, so a missing prerequisite is a broken
    environment, not a reason to report success by skipping.
    """
    missing = [
        str(path) for path in (MANAGER_BINARY, SQL_COMPILER_JAR) if not path.exists()
    ]
    if missing:
        pytest.fail(
            "missing prerequisites for the self-hosted enterprise e2e test: "
            + ", ".join(missing)
            + "\n\nbuild them with:\n"
            "  CARGO_NET_OFFLINE=true cargo +1.96.1 build -p pipeline-manager "
            "--features feldera-enterprise\n"
            "  (cd sql-to-dbsp-compiler && ./build.sh)\n"
        )


def _await_free_postgres_port() -> None:
    """Wait for the port the manager's embedded Postgres binds.

    That port is fixed inside the manager, so two suites that each start a
    manager cannot run at the same time.  A suite that is already running
    releases the port when it finishes, so waiting is right; starting anyway
    would only produce an unhelpful ``pg_ctl: could not start server``, and
    neither process would say why.
    """
    deadline = time.monotonic() + POSTGRES_PORT_WAIT_S
    while True:
        with socket.socket() as probe:
            probe.settimeout(1.0)
            if probe.connect_ex(("127.0.0.1", POSTGRES_PORT)) != 0:
                return
        if time.monotonic() >= deadline:
            pytest.fail(
                f"port {POSTGRES_PORT} is still in use after "
                f"{POSTGRES_PORT_WAIT_S:.0f} s: the manager's embedded Postgres "
                "binds it, so only one suite that starts a manager can run at a "
                "time; stop the process that holds it "
                f"(`lsof -nP -iTCP:{POSTGRES_PORT} -sTCP:LISTEN`)"
            )
        time.sleep(POLL_INTERVAL_S)


def _java_binary() -> Path:
    """Return a ``java`` that can run the SQL compiler jar.

    The compiler's pom targets Java 19, so a JDK 19 or newer is required; the
    JDK that happens to be first on ``PATH`` frequently is not one.
    """
    candidates: list[Path] = []
    for env_var in ("FELDERA_TEST_JAVA_HOME", "JAVA_HOME"):
        home = os.environ.get(env_var)
        if home:
            candidates.append(Path(home) / "bin" / "java")

    which_java = shutil.which("java")
    if which_java:
        candidates.append(Path(which_java))

    for pattern in (
        "/opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home/bin/java",
        "/opt/homebrew/opt/openjdk*/bin/java",
        "/usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home/bin/java",
        "/usr/lib/jvm/*/bin/java",
    ):
        candidates.extend(Path(path) for path in sorted(glob.glob(pattern)))

    rejected: list[str] = []
    for candidate in candidates:
        if not candidate.is_file():
            continue
        try:
            result = subprocess.run(
                [str(candidate), "-version"],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as e:
            rejected.append(f"{candidate}: {e}")
            continue
        match = re.search(r'version "(\d+)', f"{result.stderr}{result.stdout}")
        if match is None:
            rejected.append(f"{candidate}: cannot parse the java version")
            continue
        if int(match.group(1)) >= 19:
            return candidate
        rejected.append(f"{candidate}: java {match.group(1)}")

    pytest.fail(
        "no JDK 19 or newer found for the SQL compiler jar; set "
        "FELDERA_TEST_JAVA_HOME to a JDK 19+.\nConsidered: " + "; ".join(rejected)
    )


def _write_tool_shims(shim_dir: Path, java_binary: Path) -> None:
    """Create the ``cargo`` and ``java`` shims the manager must use.

    ``pipeline-manager`` clears the environment of the ``cargo`` build it runs
    for a generated pipeline
    (``crates/pipeline-manager/src/compiler/rust_compiler.rs``) and re-adds
    only ``PATH`` plus a handful of cargo and runtime variables.  The manager's
    own environment therefore cannot tell that build to work offline or where
    librdkafka is; ``PATH`` is the one channel left, so the shim restates both
    and pins the toolchain and the JDK.  The manager invokes the SQL compiler
    as ``java -jar ...``, which picks up the same shim directory.
    """
    shim_dir.mkdir(parents=True, exist_ok=True)

    cargo = shutil.which("cargo")
    assert cargo is not None, "cargo is not on PATH"
    # `cargo` is a rustup proxy that dispatches on the name it was invoked
    # with, so the shim must keep that name: resolving the symlink would invoke
    # rustup itself, which rejects cargo's arguments.
    cargo = str(Path(cargo).absolute())

    lines = [
        "#!/bin/sh",
        "# Generated by python/tests/platform/test_selfhosted_ft_e2e.py.",
        "#",
        "# pipeline-manager clears the environment of the cargo build it runs for a",
        "# generated pipeline and keeps only PATH, so that build must be given its",
        "# environment here.",
        "set -eu",
    ]
    if CARGO_NET_OFFLINE:
        lines.append(f"CARGO_NET_OFFLINE={shlex.quote(CARGO_NET_OFFLINE)}")
        lines.append("export CARGO_NET_OFFLINE")
    if (LIBRDKAFKA_PREFIX / "lib" / "pkgconfig").is_dir():
        lines.append(
            f"PKG_CONFIG_PATH={shlex.quote(str(LIBRDKAFKA_PREFIX / 'lib' / 'pkgconfig'))}"
        )
        lines.append("export PKG_CONFIG_PATH")
    lines.append(f'exec {shlex.quote(cargo)} +{shlex.quote(CARGO_TOOLCHAIN)} "$@"')
    lines.append("")

    cargo_shim = shim_dir / "cargo"
    cargo_shim.write_text("\n".join(lines))
    cargo_shim.chmod(0o755)

    java_shim = shim_dir / "java"
    if java_shim.is_symlink() or java_shim.exists():
        java_shim.unlink()
    os.symlink(java_binary, java_shim)


# ---------------------------------------------------------------------------
# Pipeline definition
# ---------------------------------------------------------------------------


def _pipeline_sql() -> str:
    """A datagen -> materialized table -> materialized view program.

    Kafka is deliberately absent: the datagen transport is built into every
    build, and the materialized view is read back through the manager's HTTP
    query API.  The datagen has a primary key so that a replay would upsert
    rather than duplicate rows, keeping the row count a measure of *state*
    rather than of how many times input was processed.
    """
    connectors = json.dumps(
        [
            {
                "transport": {
                    "name": "datagen",
                    "config": {
                        "seed": 12345,
                        "plan": [
                            {
                                "limit": DATAGEN_RECORDS,
                                "rate": DATAGEN_RATE,
                                "fields": {
                                    "id": {
                                        "strategy": "increment",
                                        "range": [0, 2000000],
                                    },
                                    "name": {"strategy": "word"},
                                    "grp": {"strategy": "uniform", "range": [0, 50]},
                                },
                            }
                        ],
                    },
                }
            }
        ]
    )
    return f"""
CREATE TABLE t1 (
    id BIGINT NOT NULL PRIMARY KEY,
    name VARCHAR NOT NULL,
    grp INT NOT NULL
) WITH (
    'materialized' = 'true',
    'connectors' = '{connectors}'
);

CREATE MATERIALIZED VIEW v1 AS (SELECT * FROM t1);
"""


def _sync_storage(
    bucket: Path,
    start_from_checkpoint: object = None,
    fail_if_no_checkpoint: bool = False,
) -> dict:
    """A ``storage`` runtime-config value whose checkpoints sync to *bucket*.

    The self-hosted synchronizer in ``crates/sync-checkpoint`` treats the
    configured bucket as a directory on the local file system, so the test can
    inspect what was pushed without standing up an object store.
    """
    return {
        "backend": {
            "name": "file",
            "config": {
                "sync": {
                    "bucket": str(bucket),
                    "start_from_checkpoint": start_from_checkpoint,
                    "fail_if_no_checkpoint": fail_if_no_checkpoint,
                    "pull_interval": 2,
                    "retention_min_count": 2,
                    "retention_min_age": 0,
                }
            },
        }
    }


def _runtime_config(storage: object) -> dict:
    """The ``runtime_config`` of every pipeline in this suite."""
    return {
        "workers": 2,
        "hosts": 1,
        "logging": "debug",
        "fault_tolerance": "latest_checkpoint",
        "storage": storage,
        # The runner's 20 s default is tight on a loaded CI/dev machine: the
        # suite runs right after compiling and starting another pipeline, and
        # a provisioning attempt that merely exceeds 20 s fails the pipeline
        # outright rather than giving a flaky-but-eventually-healthy start.
        "provisioning_timeout_secs": 120,
    }


def _create_pipeline(client: FelderaClient, name: str, storage: object) -> str:
    """Compile and register a pipeline, returning its name.

    The SDK cannot express a file backend with a checkpoint-sync configuration
    through :class:`feldera.runtime_config.Storage`, which carries only the
    storage *resources*.  The runtime config is therefore assembled as a plain
    dictionary and adopted with :meth:`RuntimeConfig.from_dict`; the client
    sends the resulting fields verbatim.
    """
    PipelineBuilder(
        client,
        name,
        _pipeline_sql(),
        compilation_profile=CompilationProfile.DEV,
        runtime_config=RuntimeConfig.from_dict(_runtime_config(storage)),
    ).create()
    return name


def _discard(client: FelderaClient, name: str) -> None:
    """Remove a pipeline, clearing its storage on the way out.

    The manager refuses to delete a pipeline whose storage still exists, so a
    pipeline created with storage enabled has to be force-stopped and cleared
    before it can be deleted.
    """
    client.stop_pipeline(name, force=True)
    client.clear_storage(name)
    client.delete_pipeline(name)


# ---------------------------------------------------------------------------
# Observation helpers
# ---------------------------------------------------------------------------


def _view_count(client: FelderaClient, name: str) -> int:
    """Rows currently in the materialized table ``t1``."""
    rows = list(client.query_as_json(name, "SELECT COUNT(*) AS c FROM t1"))
    assert len(rows) == 1, f"unexpected ad-hoc query result: {rows}"
    return int(rows[0]["c"])


def _input_total_records(client: FelderaClient, name: str) -> int:
    """Records the pipeline's input connectors have produced so far."""
    stats = client.get_pipeline_stats(name)
    return sum(
        (entry.get("metrics") or {}).get("total_records") or 0
        for entry in stats.get("inputs") or []
    )


def _unique_name(prefix: str) -> str:
    """A pipeline name no other run of this suite will use."""
    return f"{prefix}-{uuid.uuid4().hex[:10]}"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def workdir() -> Iterator[Path]:
    """The directory holding the manager state, logs and tool shims.

    A short path is required because embedded Postgres binds a unix socket
    whose path the operating system caps, so this does not use pytest's own
    (deep) temporary directories.
    """
    override = os.environ.get("FELDERA_SELFHOSTED_E2E_WORKDIR")
    if override:
        root = Path(override)
        root.mkdir(parents=True, exist_ok=True)
        yield root
        return

    root = Path(tempfile.mkdtemp(prefix="feldera-selfhosted-e2e-"))
    try:
        yield root
    finally:
        shutil.rmtree(root, ignore_errors=True)


@pytest.fixture(scope="module")
def manager(workdir: Path) -> Iterator[Manager]:
    """The enterprise manager this suite owns for its whole run."""
    _require_prerequisites()
    shim_dir = workdir / "bin"
    _write_tool_shims(shim_dir, _java_binary())

    state = workdir / "state"
    # Start from a clean database and runner directory.  A state directory kept
    # across runs would otherwise carry stale pipelines and deployments, and a
    # Postgres cluster that a killed run left behind refuses to start.  The
    # compiler directory is deliberately kept: it holds the generated-program
    # cargo cache, which costs minutes to rebuild.
    shutil.rmtree(state / "pg", ignore_errors=True)
    shutil.rmtree(state / "runner", ignore_errors=True)
    _await_free_postgres_port()

    manager = Manager(state, workdir / "logs", https=False)
    home = workdir / "home"
    home.mkdir(parents=True, exist_ok=True)
    manager.start(
        AuthConfig(
            name="selfhosted-e2e",
            env={
                "PATH": f"{shim_dir}{os.pathsep}{os.environ['PATH']}",
                # The embedded Postgres this manager starts installs its server
                # under $HOME/.theseus/postgresql, so it needs a home directory
                # it may write to.
                "HOME": str(home),
            },
        )
    )
    try:
        yield manager
    finally:
        manager.stop()


@pytest.fixture(scope="module")
def client(manager: Manager) -> FelderaClient:
    """A client bound to the manager this suite started."""
    return FelderaClient(manager.base_url)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_suspend_and_restart_resumes_the_input_watermark(
    client: FelderaClient, workdir: Path
) -> None:
    """A restarted pipeline resumes its input instead of replaying it.

    The datagen plan is finite, so once the table holds every record the plan
    can produce, the run has consumed its input completely.  Suspending the
    pipeline then checkpoints that state; starting it again must restore the
    state and must not rewind the input progress.  Starting it *paused* makes
    the check exact: while paused no connector can produce anything, so the
    row count after the restart is the restored state and nothing else.
    """
    name = _unique_name("ft-e2e-suspend")
    _create_pipeline(client, name, storage=True)
    try:
        client.start_pipeline(name)
        wait_for_condition(
            "the datagen input to be consumed completely",
            lambda: _view_count(client, name) == DATAGEN_RECORDS,
            timeout_s=INGEST_TIMEOUT_S,
            poll_interval_s=POLL_INTERVAL_S,
        )
        watermark = _input_total_records(client, name)
        assert watermark == DATAGEN_RECORDS, (
            f"input progress before the suspend is {watermark}, expected "
            f"{DATAGEN_RECORDS}"
        )

        # `force=False` checkpoints before stopping, which is the enterprise
        # suspend path. A plain force-stop would not leave a checkpoint behind.
        client.stop_pipeline(name, force=False)

        client.start_pipeline_as_paused(name)
        restored = _view_count(client, name)
        assert restored == DATAGEN_RECORDS, (
            f"the restarted pipeline holds {restored} rows, expected the "
            f"checkpointed {DATAGEN_RECORDS}: it did not resume, and starting "
            f"from an empty state would report 0. Manager log: "
            f"{workdir / 'logs' / 'manager.log'}"
        )
        restored_watermark = _input_total_records(client, name)
        assert restored_watermark >= watermark, (
            f"input progress regressed across the suspend: {watermark} before, "
            f"{restored_watermark} after"
        )

        client.resume_pipeline(name)
        assert _view_count(client, name) == DATAGEN_RECORDS, (
            "the resumed pipeline replayed input it had already consumed"
        )
    finally:
        _discard(client, name)


def test_start_from_checkpoint_restores_a_pushed_checkpoint(
    client: FelderaClient, workdir: Path, tmp_path: Path
) -> None:
    """``start_from_checkpoint`` pulls a checkpoint into a brand new pipeline.

    One pipeline pushes a checkpoint of a fully ingested table into its
    checkpoint directory.  A second pipeline, with its own empty local storage
    and ``start_from_checkpoint: "latest"``, must come up holding exactly the
    rows the first one checkpointed -- which is only possible if the
    synchronizer really pulled the checkpoint, because a pipeline that failed
    to pull starts empty.
    """
    bucket = tmp_path / "checkpoint-bucket"
    bucket.mkdir()

    source = _unique_name("ft-e2e-sync-source")
    restorer = _unique_name("ft-e2e-sync-restorer")
    _create_pipeline(client, source, storage=_sync_storage(bucket))
    _create_pipeline(
        client,
        restorer,
        storage=_sync_storage(
            bucket, start_from_checkpoint="latest", fail_if_no_checkpoint=True
        ),
    )
    try:
        client.start_pipeline(source)
        wait_for_condition(
            "the datagen input to be consumed completely",
            lambda: _view_count(client, source) == DATAGEN_RECORDS,
            timeout_s=INGEST_TIMEOUT_S,
            poll_interval_s=POLL_INTERVAL_S,
        )

        sequence = client.checkpoint_pipeline(source)
        wait_for_condition(
            "the checkpoint to complete",
            lambda: (
                client.checkpoint_pipeline_status(source).get("success") == sequence
            ),
            timeout_s=CHECKPOINT_TIMEOUT_S,
            poll_interval_s=POLL_INTERVAL_S,
        )

        client.sync_checkpoint_response(source)
        wait_for_condition(
            "the checkpoint to be pushed to the checkpoint directory",
            lambda: (
                client.sync_checkpoint_status(source).get("success") is not None
                or client.sync_checkpoint_status(source).get("failure") is not None
            ),
            timeout_s=CHECKPOINT_TIMEOUT_S,
            poll_interval_s=POLL_INTERVAL_S,
        )
        sync_status = client.sync_checkpoint_status(source)
        assert sync_status.get("failure") is None, (
            f"pushing the checkpoint failed: {sync_status['failure']}"
        )
        pushed = sync_status["success"]
        assert (bucket / str(pushed)).is_dir(), (
            f"the pushed checkpoint {pushed} is not in {bucket}: "
            f"{sorted(path.name for path in bucket.iterdir())}"
        )

        # The restorer must not see the source's local storage: it is a
        # different pipeline with a different runner working directory, so the
        # only way it can hold the checkpointed rows is by pulling them.
        client.stop_pipeline(source, force=False)
        client.start_pipeline_as_paused(restorer)
        restored = _view_count(client, restorer)
        assert restored == DATAGEN_RECORDS, (
            f"the restorer holds {restored} rows, expected the checkpointed "
            f"{DATAGEN_RECORDS}; a pipeline that failed to pull starts empty "
            f"and reports 0. Manager log: "
            f"{workdir / 'logs' / 'manager.log'}"
        )

        client.resume_pipeline(restorer)
        assert _view_count(client, restorer) == DATAGEN_RECORDS, (
            "the restorer changed its row count after resuming"
        )
    finally:
        for pipeline in (source, restorer):
            _discard(client, pipeline)
