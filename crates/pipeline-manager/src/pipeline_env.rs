use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};

/// Environment variable names that users cannot override in pipeline configuration.
pub const ENV_VAR_BLOCKLIST: &[&str] = &["HOSTNAME", "RUST_LOG", "TOKIO_WORKER_THREADS"];

/// Environment variable prefixes that users cannot override in pipeline configuration.
pub const ENV_VAR_PREFIX_BLOCKLIST: &[&str] = &["FELDERA_", "KUBERNETES_", "TOKIO_"];

/// Whether pipeline environment variables whose name starts with `KUBERNETES_`
/// may be provided by the user.
///
/// Defaults to `false`, which means the `KUBERNETES_` prefix is always
/// rejected (the behavior of the local runner). The Kubernetes runner exposes
/// this as a configuration switch because pipeline pods may legitimately need
/// to receive cluster-related environment variables.
static ALLOW_KUBERNETES_ENV_PREFIX: AtomicBool = AtomicBool::new(false);

/// Returns whether the `KUBERNETES_` prefix is currently allowed in
/// user-provided pipeline environment variables.
pub fn allow_kubernetes_env_prefix() -> bool {
    ALLOW_KUBERNETES_ENV_PREFIX.load(Ordering::Relaxed)
}

/// Configures whether the `KUBERNETES_` prefix is allowed in user-provided
/// pipeline environment variables.
///
/// This is set once at manager startup based on the selected runner and its
/// configuration; it is not meant to be toggled at runtime.
pub fn set_allow_kubernetes_env_prefix(allow: bool) {
    ALLOW_KUBERNETES_ENV_PREFIX.store(allow, Ordering::Relaxed);
}

/// Validate user-provided pipeline environment variables and
/// avoid overrides of certain ENV 'namespaces'.
///
/// The 'blocked' names are often set by feldera itself and can cause
/// unexpected behavior when overridden with this mechanism by the
/// user.
///
/// - Don't allow anything starting with `FELDERA_`
/// - Don't allow anything starting with `KUBERNETES_` (unless allowed via
///   [`set_allow_kubernetes_env_prefix`])
/// - Don't allow anything starting with `TOKIO_`
/// - Don't allow explicit control variables such as `RUST_LOG`
pub fn validate_pipeline_env(env: &BTreeMap<String, String>) -> Result<(), String> {
    validate_pipeline_env_with(env, allow_kubernetes_env_prefix())
}

/// Same as [`validate_pipeline_env`], but with an explicit policy for the
/// `KUBERNETES_` prefix.
pub fn validate_pipeline_env_with(
    env: &BTreeMap<String, String>,
    allow_kubernetes_prefix: bool,
) -> Result<(), String> {
    let forbidden: Vec<String> = env
        .keys()
        .filter(|key| {
            ENV_VAR_BLOCKLIST.contains(&key.as_str())
                || ENV_VAR_PREFIX_BLOCKLIST.iter().any(|prefix| {
                    key.starts_with(prefix) && !(allow_kubernetes_prefix && *prefix == "KUBERNETES_")
                })
        })
        .cloned()
        .collect();

    if forbidden.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "the following environment variable(s) are reserved and cannot be overridden: {}",
            forbidden.join(", ")
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::{validate_pipeline_env, validate_pipeline_env_with};
    use std::collections::BTreeMap;

    #[test]
    fn accepts_non_reserved_env_vars() {
        let env = BTreeMap::from([("TEST_ENV".to_string(), "x".to_string())]);
        assert!(validate_pipeline_env(&env).is_ok());
    }

    #[test]
    fn rejects_feldera_env_vars() {
        let env = BTreeMap::from([("FELDERA_TEST_ENV".to_string(), "x".to_string())]);
        assert!(validate_pipeline_env(&env).is_err());
    }

    #[test]
    fn rejects_reserved_env_vars() {
        let env = BTreeMap::from([
            ("TOKIO_WORKER_THREADS".to_string(), "1".to_string()),
            ("RUST_LOG".to_string(), "debug".to_string()),
        ]);
        assert!(validate_pipeline_env(&env).is_err());
    }

    #[test]
    fn rejects_kubernetes_env_vars() {
        let env = BTreeMap::from([("KUBERNETES_SERVICE_HOST".to_string(), "x".to_string())]);
        assert!(validate_pipeline_env(&env).is_err());
    }

    #[test]
    fn accepts_kubernetes_env_vars_when_allowed() {
        let env = BTreeMap::from([("KUBERNETES_SERVICE_HOST".to_string(), "x".to_string())]);
        assert!(validate_pipeline_env_with(&env, true).is_ok());
    }

    #[test]
    fn allowing_kubernetes_prefix_keeps_other_namespaces_blocked() {
        let env = BTreeMap::from([
            ("KUBERNETES_SERVICE_HOST".to_string(), "x".to_string()),
            ("FELDERA_TEST_ENV".to_string(), "x".to_string()),
        ]);
        assert!(validate_pipeline_env_with(&env, true).is_err());
    }
}
