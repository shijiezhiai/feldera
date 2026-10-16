# Self-hosted development environment

How to get a reproducible, green `cargo build -p dbsp_adapters` (all default features) on a
developer machine. Verified on macOS 26.4 on arm64; the steps are the same on Linux apart from
the tool-installation lines.

The only non-obvious prerequisite is **librdkafka**. Nothing in this document asks you to change
Cargo feature wiring, and you should not: the `dynamic-linking` feature discussed below is
unconditional upstream.

## 1. Why libraries must already be on the system

* `crates/adapters/Cargo.toml:122` enables the `rdkafka` crate with `dynamic-linking` (see the
  comment at `crates/adapters/Cargo.toml:115-121`). With that feature `rdkafka-sys` does **not**
  build a vendored copy of librdkafka; its build script probes pkg-config for `rdkafka` with
  `atleast_version("2.12.1")` and exits non-zero if the probe fails.
* `Cargo.lock:10147` pins `rdkafka-sys 4.10.0+2.12.1`, so the system librdkafka must be **2.12.1
  or newer**. Distribution packages are typically older, which is why this repository builds
  librdkafka from source.
* `README.md:139-145` states the same requirement and points at `scripts/install-librdkafka.sh`.
  `deploy/Dockerfile` and `.devcontainer/postCreate.sh` call that same script, so a laptop build
  and the CI/container build follow one code path.

The script builds librdkafka against AWS-LC so that Kafka TLS uses the same cryptographic
implementation as the rest of the system, and it refuses to install a dylib that links a shared
`libssl`/`libcrypto` (`otool -L` check on macOS, `readelf` on Linux).

## 2. Toolchain

| Tool | Why | Version verified |
| --- | --- | --- |
| Rust / cargo | `Cargo.toml:10` sets `rust-version = "1.96.1"`; there is no `rust-toolchain.toml`, so invoke `cargo +1.96.1` | 1.96.1 |
| C/C++ compiler | cdylib/DuckDB/sqlite builds | Apple clang 21.0.0, SDK 26.4 (`xcode-select --install`) |
| `cmake` + GNU `make` | `scripts/install-librdkafka.sh`, AWS-LC | cmake 4.0.3, make 3.81 |
| `git` | the install script fetches pinned sources | any |
| `go` | required by the install script's tool check; also builds `aws-lc-fips-sys` under `--features fips` | 1.26.5 |
| `pkg-config` | resolves `rdkafka.pc` | 2.5.1 |
| `zstd` | the script configures `--enable-zstd`, so `rdkafka.pc` has a hard `Requires.private` on libzstd | Homebrew zstd 1.5.7 |
| `openssl@3` | only needed so pkg-config can resolve the `libcrypto`/`libssl` entries of `Requires.private`; TLS itself is AWS-LC (static) | Homebrew openssl@3 3.6.1 |

On macOS install the non-Rust tools with
`brew install cmake zstd openssl@3 pkg-config go`.

SASL needs no Homebrew package on macOS: the system SDK provides `sasl.h` and `libsasl2.tbd`, so
the script's `--enable-gssapi` check passes against `/usr/lib/libsasl2.2.dylib`. The README's
`cyrus-sasl` entry is harmless but was not needed here.

## 3. Install librdkafka into a stable prefix

Do not install into `target/`: `cargo clean` deletes it. Do not assume `/usr/local` is writable
without `sudo`, and do not hard-code a prefix whose `PKG_CONFIG_PATH` a later build forgets.
Pick one stable directory and use it everywhere, for example `$HOME/.feldera-dev`:

```sh
export PREFIX="$HOME/.feldera-dev"
./scripts/install-librdkafka.sh
```

Notes:

* The script reads the librdkafka and AWS-LC versions/commits from `Cargo.lock`; rerun it after a
  `rdkafka` version bump.
* It needs network access (it fetches pinned sources into a temporary directory). This is
  independent of `CARGO_NET_OFFLINE`. To keep the work directory on a volume of your choosing,
  set `TMPDIR`. On the machine used for this document the whole run took about two minutes and
  printed exactly two lines:

  ```
  librdkafka v2.12.1 (e1db7eaa517f0a6438bc846a9c49ede73b9ea211), AWS-LC 991e67ff4cf04df4dd89e407f8b920c6936cb56a, prefix /Users/<user>/.feldera-dev
  installed librdkafka 2.12.1 to /Users/<user>/.feldera-dev
  ```

* It installs `$PREFIX/lib/librdkafka.1.dylib` (plus the static and C++ variants) and the
  pkg-config files `$PREFIX/lib/pkgconfig/rdkafka{,-static,++,++-static}.pc`.
* If the script fails, read `configure.log`/the build log it points at; the common failures are a
  missing tool from its `for tool in cmake git awk go make cc` check and a missing zstd
  development package.

Check the installation before building Rust:

```sh
pkg-config --exists rdkafka && echo ok
pkg-config --libs rdkafka        # -L$PREFIX/lib -lrdkafka
pkg-config --cflags rdkafka      # may print -I... for the Requires.private entries
```

## 4. PKG_CONFIG_PATH

`rdkafka.pc` is an autotools file with `Requires.private: zlib libcrypto libssl libzstd`, so
pkg-config has to be able to resolve those packages as well. The value verified for this setup:

```sh
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig:/opt/homebrew/lib/pkgconfig"
```

The `$PREFIX` entry on its own is enough for `pkg-config --libs rdkafka`, but `--cflags` and
`--static` need the `openssl@3` and `zstd` entries as well. On Linux the equivalent extra entries
come from the system paths and are usually not needed.

`rdkafka-sys`' build script declares `rerun-if-env-changed` on `PKG_CONFIG_PATH`, so after fixing
the variable it re-probes automatically — there is no need to clean the build directory.

## 5. Build and verify

```sh
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig:/opt/homebrew/lib/pkgconfig"
CARGO_NET_OFFLINE=true cargo +1.96.1 build -p dbsp_adapters
```

`CARGO_NET_OFFLINE=true` is the discipline for this checkout (the registry cache is complete for
the host target). `cargo metadata --offline` fails on Linux-only crates such as `linux-raw-sys`
that are absent from the cache; that is expected and harmless — build the crate instead.

Success looks like ``Finished `dev` profile [unoptimized + debuginfo] target(s)``, plus:

```sh
ls -l target/debug/libdbsp_adapters.rlib
grep rustc-link target/debug/build/rdkafka-sys-*/output
# cargo:rustc-link-search=native=<$PREFIX>/lib
# cargo:rustc-link-lib=rdkafka
```

`cargo build -p dbsp_adapters`, with default features (`crates/adapters/Cargo.toml:18-30`:
`with-kafka`, `with-deltalake`, `with-iceberg`, `with-avro`, `with-nexmark`, `with-pubsub`,
`with-redis`, `with-nats`, `with-postgres-cdc`, `with-dynamodb`, `with-heap-profiling`), pulls in
1270 unique crates as reported by `cargo tree -p dbsp_adapters --prefix none`.

### Resource notes

* Two cargo builds in the same checkout serialize on `target/debug/.cargo-lock`; the second one
  prints `Blocking waiting for file lock on build directory` and waits for the first. Do not start
  a second build "in parallel" — it does not overlap, it only queues.
* Linking `dbsp_adapters` is memory-hungry. With 16 GB of RAM and `-j6` the machine went into swap
  (16-17 GB in use, load average ≈64) while `datafusion`, the AWS SDK crates and
  `deltalake`/`iceberg` compiled. Use `-j4` or less on a 16 GB machine, and keep a few GB of disk
  free: a `dev`-profile build of this crate leaves roughly 11 GB in `target/`.

## 6. Recorded run (2026-10-16)

* `scripts/install-librdkafka.sh` with `PREFIX=$HOME/.feldera-dev`: exit 0, two log lines, ~1m51s.
* `CARGO_NET_OFFLINE=true CARGO_INCREMENTAL=0 cargo +1.96.1 build -p dbsp_adapters -j 6`:
  exit 0, ``Finished `dev` profile [unoptimized + debuginfo] target(s) in 8m 41s``. Wall clock was
  109 minutes because another session was building `-p pipeline-manager` in the same target
  directory and held the build-directory lock; the immediate re-run finished in 9.37s.
* `target/debug/libdbsp_adapters.rlib` (327 MB) and
  `target/debug/deps/libdbsp_adapters-*.rlib` written at 13:49.
* `target/debug/build/rdkafka-sys-9bab8e76886f12ff/output:26-27` contains
  `cargo:rustc-link-search=native=/Users/<user>/.feldera-dev/lib` and
  `cargo:rustc-link-lib=rdkafka` — proof that the build resolved the installed librdkafka rather
  than a vendored copy.
* `ctypes.CDLL("$PREFIX/lib/librdkafka.1.dylib")` loads successfully, so every `NEEDED` entry
  (`libzstd.1.dylib`, `/usr/lib/libsasl2.2.dylib`, `libz.1.dylib`) resolves at run time too.

## 7. Troubleshooting

**`The system library "rdkafka" required by crate "rdkafka-sys" was not found`**

`rdkafka-sys`' build script probes pkg-config for librdkafka ≥ 2.12.1 and exits with
`librdkafka 2.12.1 cannot be found on the system: …` followed by `Dynamic linking failed. Exiting.`
when the probe fails. Causes, in order of likelihood:

1. `PKG_CONFIG_PATH` does not contain `$PREFIX/lib/pkgconfig` for the shell (or the environment
   file, e.g. `.envrc`, `.cargo/config`) that runs cargo. Export it as in §4 and rebuild.
2. `pkg-config` is not installed or not on `PATH`.
3. librdkafka was never installed, or was installed into a build directory that `cargo clean` then
   removed. Rerun `scripts/install-librdkafka.sh`; `cargo clean` does **not** touch `$PREFIX`.
4. The installed version is older than 2.12.1 (a `brew`/`apt` package). Reinstall with the script.

**`Library not loaded: … librdkafka.1.dylib` when running a binary**

The build-time probe succeeded but the loader cannot find the dylib. Either the run environment
differs from the build environment, or the prefix moved. Reinstall into a stable prefix and keep
it out of the build directory.

**Nothing re-probes after exporting `PKG_CONFIG_PATH`**

It should: `rdkafka-sys` declares `rerun-if-env-changed` on `PKG_CONFIG_PATH`. If in doubt,
`cargo build -p rdkafka-sys -vv` shows the probe output.

## 8. Scope and constraints

* No `Cargo.toml` feature wiring was changed to make this work, and none should be: the
  vendored-build path is not supported upstream.
* Container validation is out of scope here; where a Docker daemon is available, `deploy/Dockerfile`
  is the reference forward environment.
* Disk discipline matters on the machine this was verified on (460 GB volume at 93 % used): avoid
  `cargo clean`, avoid concurrent cargo builds, and delete temporary artifacts larger than 1 GB
  once they have served their purpose.
