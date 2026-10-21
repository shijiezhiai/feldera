//! Selection of the pipeline executor (runner) implementation at startup.
//!
//! The local runner is the default. Setting [`RUNNER_ENV`] to `kubernetes`
//! selects the Kubernetes runner, which requires [`KubernetesRunnerConfig`] and
//! additional cluster-side setup.
//!
//! [`KubernetesRunnerConfig`]: crate::config::KubernetesRunnerConfig

use std::fmt;

/// Environment variable that selects the pipeline executor implementation.
pub const RUNNER_ENV: &str = "FELDERA_RUNNER";

/// The pipeline executor implementation to use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunnerKind {
    /// Run pipeline state as local processes on the manager host.
    Local,
    /// Run pipeline state as pods in a Kubernetes cluster.
    Kubernetes,
}

impl RunnerKind {
    /// The canonical value of [`RUNNER_ENV`] that selects this runner.
    pub fn as_str(self) -> &'static str {
        match self {
            RunnerKind::Local => "local",
            RunnerKind::Kubernetes => "kubernetes",
        }
    }
}

impl fmt::Display for RunnerKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Parses a value of [`RUNNER_ENV`], falling back to [`RunnerKind::Local`] when
/// the variable is not set (or empty).
pub fn resolve_runner_kind(value: Option<&str>) -> Result<RunnerKind, String> {
    let Some(value) = value else {
        return Ok(RunnerKind::Local);
    };
    let normalized = value.trim().to_ascii_lowercase();
    match normalized.as_str() {
        // An empty value is treated the same as an unset variable so that
        // `FELDERA_RUNNER=` in a deployment manifest keeps the default.
        "" | "local" => Ok(RunnerKind::Local),
        "kubernetes" | "k8s" => Ok(RunnerKind::Kubernetes),
        other => Err(format!(
            "invalid {RUNNER_ENV} value '{other}': expected 'local' or 'kubernetes'"
        )),
    }
}

/// Reads [`RUNNER_ENV`] from the process environment and resolves the runner.
pub fn runner_kind_from_env() -> Result<RunnerKind, String> {
    match std::env::var(RUNNER_ENV) {
        Ok(value) => resolve_runner_kind(Some(&value)),
        Err(std::env::VarError::NotPresent) => resolve_runner_kind(None),
        Err(std::env::VarError::NotUnicode(_)) => {
            Err(format!("{RUNNER_ENV} contains invalid UTF-8"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{RunnerKind, resolve_runner_kind};

    #[test]
    fn defaults_to_local_when_unset() {
        assert_eq!(resolve_runner_kind(None), Ok(RunnerKind::Local));
    }

    #[test]
    fn treats_empty_value_as_local() {
        assert_eq!(resolve_runner_kind(Some("")), Ok(RunnerKind::Local));
        assert_eq!(resolve_runner_kind(Some("  ")), Ok(RunnerKind::Local));
    }

    #[test]
    fn parses_local() {
        assert_eq!(resolve_runner_kind(Some("local")), Ok(RunnerKind::Local));
        assert_eq!(resolve_runner_kind(Some("LOCAL")), Ok(RunnerKind::Local));
    }

    #[test]
    fn parses_kubernetes() {
        assert_eq!(
            resolve_runner_kind(Some("kubernetes")),
            Ok(RunnerKind::Kubernetes)
        );
        assert_eq!(
            resolve_runner_kind(Some(" Kubernetes ")),
            Ok(RunnerKind::Kubernetes)
        );
        assert_eq!(
            resolve_runner_kind(Some("k8s")),
            Ok(RunnerKind::Kubernetes)
        );
    }

    #[test]
    fn rejects_unknown_value() {
        let error = resolve_runner_kind(Some("docker")).unwrap_err();
        assert!(error.contains("FELDERA_RUNNER"), "{error}");
        assert!(error.contains("docker"), "{error}");
    }

    #[test]
    fn kind_round_trips_through_its_canonical_value() {
        for kind in [RunnerKind::Local, RunnerKind::Kubernetes] {
            assert_eq!(resolve_runner_kind(Some(kind.as_str())), Ok(kind));
            assert_eq!(kind.to_string(), kind.as_str());
        }
    }
}
