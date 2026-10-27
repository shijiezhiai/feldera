/// A binary that brings up all three of the api-server, compiler and runner
/// services.
///
/// The pipeline executor is selected with `FELDERA_RUNNER`: `local` (the
/// default) runs pipelines as processes on this host, `kubernetes` runs them as
/// pods in a Kubernetes cluster.
use clap::{Command, FromArgMatches};

use colored::Colorize;
use feldera_observability as observability;
use pipeline_manager::config::KubernetesRunnerConfig;
use pipeline_manager::runner::kubernetes_runner::KubernetesRunner;
use pipeline_manager::runner::local_runner::LocalRunner;
use pipeline_manager::runner::selection::{RunnerKind, runner_kind_from_env};
use pipeline_manager::{all_in_one, ensure_default_crypto_provider, init_fd_limit, pipeline_env};
use std::sync::Arc;
use tokio::sync::RwLock;

fn main() -> anyhow::Result<()> {
    ensure_default_crypto_provider();
    init_fd_limit();
    pipeline_manager::logging::init_service_logging(
        "[manager]".cyan(),
        feldera_observability::json_logging::ServiceName::Manager,
    );
    if let Some(provider) = rustls::crypto::CryptoProvider::get_default() {
        observability::fips::log_rustls_provider_fips_status(
            "startup default provider",
            provider.fips(),
        );
    }

    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            let matches =
                all_in_one::augment_args(Command::new("Pipeline manager CLI")).get_matches();
            let license_check = Arc::new(RwLock::new(None));
            match runner_kind_from_env().map_err(anyhow::Error::msg)? {
                RunnerKind::Local => {
                    all_in_one::run::<LocalRunner>(&matches, license_check, |config| config, None)
                        .await
                }
                RunnerKind::Kubernetes => {
                    let config = KubernetesRunnerConfig::from_arg_matches(&matches)
                        .map_err(|err| err.exit())
                        .unwrap();
                    // The API validates user-provided pipeline environment
                    // variables; let it see the Kubernetes runner's policy so
                    // the switch takes effect for API requests too.
                    pipeline_env::set_allow_kubernetes_env_prefix(
                        config.kubernetes_runner_allow_kubernetes_env_prefix,
                    );
                    let config = config.canonicalize()?;
                    // The reaper scans the same cluster the runner writes to,
                    // so it takes its own copy of the configuration.
                    let reaper_config = config.clone();
                    all_in_one::run::<KubernetesRunner>(
                        &matches,
                        license_check,
                        move |_local| config,
                        Some(reaper_config),
                    )
                    .await
                }
            }
        })
}
