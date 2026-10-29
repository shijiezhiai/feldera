//! Runs the api-server, compiler and runner services in one process.
use crate::api::main::ApiDoc;
use crate::cluster_monitor::{LocalResourcesPoller, cluster_monitor};
use crate::compiler::main::{artifact_server_main, compiler_main, compilation_tasks_main, compiler_precompile};
#[cfg(feature = "postgresql_embedded")]
use crate::config::PgEmbedConfig;
use crate::config::{
    ApiServerConfig, CommonConfig, CompilerConfig, DatabaseConfig, KubernetesRunnerConfig,
    LocalRunnerConfig,
};
use crate::db::storage_postgres::StoragePostgres;
use crate::events_cleaner::events_cleaner;
use crate::license::LicenseCheck;
use crate::platform_enable_unstable;
use crate::runner::main::runner_main;
use crate::runner::pipeline_executor::PipelineExecutor;
use clap::{ArgMatches, Args, Command, FromArgMatches};
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};
use tracing::info;
use utoipa::OpenApi;

/// Adds the CLI arguments of all services run by [`run`].
pub fn augment_args(cli: Command) -> Command {
    let cli = CommonConfig::augment_args(cli);
    #[cfg(feature = "postgresql_embedded")]
    let cli = PgEmbedConfig::augment_args(cli);
    let cli = DatabaseConfig::augment_args(cli);
    let cli = ApiServerConfig::augment_args(cli);
    let cli = CompilerConfig::augment_args(cli);
    let cli = LocalRunnerConfig::augment_args(cli);
    KubernetesRunnerConfig::augment_args(cli)
}

/// Runs the services until the api-server stops, or performs `--dump-openapi` or `--precompile`.
///
/// `reaper_config` is `Some` only for the Kubernetes runner: it starts the
/// background scan that reclaims cluster objects whose pipeline no longer
/// exists. The local runner has no cluster to scan, and passing `None` keeps
/// it from parsing Kubernetes arguments it does not use.
///
/// `tenant_namespace_config` is likewise `Some` only for the Kubernetes runner
/// that carries tenant quotas: it lets the API server keep each tenant's
/// namespace in step with the tenant. Without it a tenant namespace is never
/// created, so the tenants that name one stay in the shared namespace.
pub async fn run<E: PipelineExecutor + 'static>(
    matches: &ArgMatches,
    license_check: Arc<RwLock<Option<LicenseCheck>>>,
    runner_config: impl FnOnce(LocalRunnerConfig) -> E::Config,
    reaper_config: Option<KubernetesRunnerConfig>,
    tenant_namespace_config: Option<KubernetesRunnerConfig>,
) -> anyhow::Result<()>
where
    E::Config: Send + 'static,
{
    let common_config = CommonConfig::from_arg_matches(matches)
        .map_err(|err| err.exit())
        .unwrap();
    if let Some(features) = &common_config.unstable_features {
        platform_enable_unstable(features);
    }
    #[cfg(feature = "postgresql_embedded")]
    let pg_embed_config = PgEmbedConfig::from_arg_matches(matches)
        .map_err(|err| err.exit())
        .unwrap();
    let api_config = ApiServerConfig::from_arg_matches(matches)
        .map_err(|err| err.exit())
        .unwrap();
    if api_config.dump_openapi {
        let openapi_json = ApiDoc::openapi().to_pretty_json()?;
        tokio::fs::write("openapi.json", openapi_json.as_bytes()).await?;
        return Ok(());
    }
    let compiler_config = CompilerConfig::from_arg_matches(matches)
        .map_err(|err| err.exit())
        .unwrap();
    let local_runner_config = LocalRunnerConfig::from_arg_matches(matches)
        .map_err(|err| err.exit())
        .unwrap();

    let common_config = common_config.canonicalize()?;
    #[cfg(feature = "postgresql_embedded")]
    let pg_embed_config = pg_embed_config.canonicalize()?;
    // `api_config` currently does not have any paths
    let compiler_config = compiler_config.canonicalize()?;
    let executor_config = runner_config(local_runner_config.canonicalize()?);

    if compiler_config.precompile {
        compiler_precompile(common_config, compiler_config).await?;
        info!("Pre-compilation finished");
        return Ok(());
    }
    let database_config = DatabaseConfig::from_arg_matches(matches)
        .map_err(|err| err.exit())
        .unwrap();
    let db: StoragePostgres = StoragePostgres::connect(
        &database_config,
        #[cfg(feature = "postgresql_embedded")]
        pg_embed_config.clone(),
    )
    .await
    .expect("Could not open connection to database");

    // Run migrations before starting any service
    db.run_migrations().await?;
    let db = Arc::new(Mutex::new(db));

    // Running multiple compiler workers on the same machine is not yet supported
    // due to the HTTP server ran by compiler_main & cleanup status files.
    // For now, we run a single compiler worker in the pipeline manager.
    let worker_id = 0;
    let total_workers = 1;

    // A process that both compiles and serves artifacts runs them together:
    // that is the single-container deployment, and the two share one working
    // directory anyway. A process that compiles without serving uploads to
    // `--compiler-host`, and one that serves without compiling is the durable
    // artifact store behind that host.
    if common_config.runs_compilation() && common_config.runs_artifact_server() {
        let db_clone = db.clone();
        let common_config_clone = common_config.clone();
        let compiler_config_clone = compiler_config.clone();
        let _compiler = tokio::spawn(async move {
            compiler_main(
                common_config_clone,
                compiler_config_clone,
                db_clone,
                worker_id,
                total_workers,
                // The pipeline-manager does not have automatic restart if it fails, as such
                // it cannot exit when target is cleared to have any precomputed precompilation
                // reapplied.
                false,
            )
            .await
            .expect("Compiler server main failed");
        });
    } else if common_config.runs_compilation() {
        let db_clone = db.clone();
        let common_config_clone = common_config.clone();
        let compiler_config_clone = compiler_config.clone();
        let _compiler = tokio::spawn(async move {
            compilation_tasks_main(
                common_config_clone,
                compiler_config_clone,
                db_clone,
                worker_id,
                total_workers,
                false,
            )
            .await
            .expect("Compiler compilation tasks failed");
        });
    } else if common_config.runs_artifact_server() {
        let db_clone = db.clone();
        let common_config_clone = common_config.clone();
        let compiler_config_clone = compiler_config.clone();
        let _artifact_server = tokio::spawn(async move {
            artifact_server_main(common_config_clone, compiler_config_clone, db_clone)
                .await
                .expect("Artifact server main failed");
        });
    }

    if common_config.runs_api() {
        // Elect one instance to reconcile the pipelines. Only that instance
        // spawns automatons; the others serve the API from the same database
        // and take over when the leader's lock is released. With a single
        // instance the election is off and this is the leader at once.
        let leadership = crate::db::leader_election::start_election(
            common_config.leader_election,
            db.clone(),
        );

        // Spawn local runner
        let db_clone = db.clone();
        let common_config_clone = common_config.clone();
        let leadership_clone = leadership.clone();
        let _local_runner = tokio::spawn(async move {
            runner_main::<E>(
                db_clone,
                common_config_clone,
                executor_config,
                leadership_clone,
            )
            .await;
        });

        // Spawn cluster monitor
        let common_config_clone = common_config.clone();
        let db_clone = db.clone();
        tokio::spawn(async move {
            cluster_monitor(db_clone, common_config_clone, LocalResourcesPoller {}).await;
        });

        // Spawn events cleaner
        let db_clone = db.clone();
        let common_config_clone = common_config.clone();
        tokio::spawn(async move {
            events_cleaner(db_clone, common_config_clone).await;
        });
    }

    // Spawn the orphan reaper, which has no meaning without a cluster to scan.
    if let Some(config) = reaper_config.filter(|_| common_config.runs_api()) {
        let delete = config.kubernetes_runner_reap_orphans;
        let db_clone = db.clone();
        // Failing to build the client is not fatal: the runner itself reports
        // the same configuration problem when the first pipeline is
        // provisioned, and a platform with no pipelines still serves the API.
        match crate::runner::reaper::client(&config).await {
            Ok(client) => {
                tokio::spawn(async move {
                    crate::runner::reaper::run(db_clone, config, client, delete).await;
                });
            }
            Err(error) => {
                tracing::error!(
                    "Orphan reaper disabled: unable to reach the Kubernetes API: {error}"
                );
            }
        }
    }

    if !common_config.runs_api() {
        // Nothing else can block this process: the compiler, the artifact
        // server and the runner all run as tasks that log and exit when they
        // fail, and a process that exits takes them down with it. Waiting
        // forever here keeps the process alive for the sake of the HTTP
        // surfaces it does serve.
        info!(
            "Running services {:?}: the API server is not among them, waiting indefinitely",
            common_config.services
        );
        std::future::pending::<()>().await;
    }

    // The api-server blocks forever
    crate::api::main::run(
        db,
        common_config,
        api_config,
        license_check,
        tenant_namespace_config,
    )
        .await
        .expect("API server main failed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::augment_args;
    use crate::config::KubernetesRunnerConfig;
    use clap::{Command, FromArgMatches};

    /// The local runner and Kubernetes runner configurations are both
    /// registered on the same command tree, so their arguments must not
    /// collide (a collision panics at runtime, not at compile time).
    #[test]
    fn runner_arguments_do_not_conflict() {
        augment_args(Command::new("test")).debug_assert();
    }

    /// An invocation without runner-specific flags parses into both runner
    /// configurations: the local runner keeps its defaults and the Kubernetes
    /// runner is inert until it is selected.
    #[test]
    fn default_invocation_parses_both_runner_configs() {
        let matches = augment_args(Command::new("test")).get_matches_from(["test"]);
        let local = crate::config::LocalRunnerConfig::from_arg_matches(&matches).unwrap();
        assert_eq!(local.coordinator_binary, None);
        let kubernetes = KubernetesRunnerConfig::from_arg_matches(&matches).unwrap();
        assert_eq!(kubernetes.kubernetes_runner_namespace, "feldera");
        assert_eq!(kubernetes.kubernetes_runner_pipeline_executor_image, None);
    }
}
