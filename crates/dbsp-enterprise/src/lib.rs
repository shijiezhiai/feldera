//! Self-hosted placeholder for the enterprise DBSP extension crate.
//!
//! # Why this crate exists
//!
//! The closed-source Feldera distribution ships `dbsp-enterprise`, the crate
//! holding enterprise-only runtime extensions. The SQL compiler in
//! `--enterprise` mode injects a path dependency on it into every generated
//! pipeline (`MultiCratesWriter`), which links it with
//! `extern crate dbsp_enterprise;` (`CircuitWriter`). The open-source code
//! never references symbols from it, but the generated program does not
//! compile unless the crate exists and links, so this placeholder must be
//! present in the source tree the compiler points at.
//!
//! # What it holds today
//!
//! Nothing. Self-hosted builds currently need no extensions: the open-source
//! tree registers its pluggable implementations through `inventory`
//! (`StorageBackendFactory`, `CheckpointSynchronizer`), and the only
//! registration the self-hosted platform supplies so far — the checkpoint
//! synchronizer stub — lives in the sibling `sync-checkpoint` crate.
//!
//! # Replacement plan (P2)
//!
//! Enterprise extensions that the company platform will implement (per the
//! self-hosted platform plan) are registered from this crate: keep the crate
//! name, the crate path, and the `extern crate` injection point unchanged, so
//! that already-generated pipelines pick up the extensions without being
//! recompiled from SQL.
