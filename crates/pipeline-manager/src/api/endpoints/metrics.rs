use crate::api::main::ServerState;
use crate::db::types::combined_status::CombinedStatus;
use crate::db::types::pipeline::ExtendedPipelineDescrMonitoring;
use crate::db::types::program::ProgramStatus;
use crate::db::{storage::Storage as _, types::tenant::TenantId};
use crate::error::ManagerError;
use actix_web::web::Bytes;
use actix_web::{
    HttpResponse, get,
    http::Method,
    web::{Data as WebData, ReqData},
};
use awc::body::MessageBody as _;
use feldera_types::runtime_status::RuntimeStatus;
use serde_json::{Value, json};
use std::fmt::Write as _;
use tracing::debug;

const STATUS_METRIC: &str = "pipeline_status";
const STATUS_HELP: &str =
    "Whether the pipeline is in the status named by the status label: 1 if it is, 0 if it is not.";
const STATUS_SINCE_METRIC: &str = "pipeline_status_since_timestamp_seconds";
const STATUS_SINCE_HELP: &str = "Unix timestamp at which the pipeline entered the status named by the status label. For the status the pipeline is currently in, `time() - this` is how long it has been there.";
const PROGRAM_STATUS_METRIC: &str = "pipeline_program_status";
const PROGRAM_STATUS_HELP: &str = "Whether the pipeline's program is in the compilation stage named by the program_status label: 1 if it is, 0 if it is not.";
const PROGRAM_STATUS_SINCE_METRIC: &str = "pipeline_program_status_since_timestamp_seconds";
const PROGRAM_STATUS_SINCE_HELP: &str = "Unix timestamp at which the pipeline's program entered the compilation stage named by the program_status label. `time() - this` is how long it has been there; time spent in `pending` is the time the pipeline waited in the compile queue.";

/// Returns the `HELP` and `TYPE` lines of the `metric` family.
fn family_header(metric: &str, help: &str) -> String {
    format!("# HELP {metric} {help}\n# TYPE {metric} gauge\n")
}

/// Returns the status that `pipeline` reports.
fn status_of(pipeline: &ExtendedPipelineDescrMonitoring) -> CombinedStatus {
    CombinedStatus::new(
        pipeline.deployment_resources_status,
        pipeline.deployment_runtime_status,
    )
}

/// Appends the status of `pipeline` to the metric family.
fn write_status_metrics(status_family: &mut String, pipeline: &ExtendedPipelineDescrMonitoring) {
    let labels = format!(
        "pipeline=\"pipeline-{}\",pipeline_name=\"{}\"",
        pipeline.id, pipeline.name
    );
    let status = status_of(pipeline);

    for candidate in CombinedStatus::ALL {
        writeln!(
            status_family,
            "{STATUS_METRIC}{{{labels},status=\"{}\"}} {}",
            candidate.as_str(),
            u8::from(candidate == status)
        )
        .unwrap();
    }
}

/// The Unix timestamp at which `pipeline` entered its current status.
///
/// The two halves of the status are recorded separately and a combined status is
/// derived from them, so which timestamp applies depends on which half moved
/// last: a stopped pipeline has no runtime timestamp at all, and a provisioned
/// one has both.
fn status_since(pipeline: &ExtendedPipelineDescrMonitoring) -> f64 {
    let since = match status_of(pipeline) {
        // The runtime half is only meaningful once the resources exist, and it
        // is the one that moves for every status a running pipeline can be in.
        CombinedStatus::Stopped
        | CombinedStatus::Provisioning
        | CombinedStatus::Stopping
        | CombinedStatus::Unavailable => pipeline.deployment_resources_status_since,
        _ => pipeline
            .deployment_runtime_status_since
            .unwrap_or(pipeline.deployment_resources_status_since),
    };
    since.timestamp_millis() as f64 / 1000.0
}

/// Appends how long `pipeline` has been in its current status to the metric
/// family.
fn write_status_since_metrics(family: &mut String, pipeline: &ExtendedPipelineDescrMonitoring) {
    writeln!(
        family,
        "{STATUS_SINCE_METRIC}{{pipeline=\"pipeline-{}\",pipeline_name=\"{}\"}} {}",
        pipeline.id,
        pipeline.name,
        status_since(pipeline)
    )
    .unwrap();
}

/// Appends the compilation stage of `pipeline`'s program to the metric families.
///
/// The stage gauge carries one series per stage, so a dashboard can graph the
/// queue depth. The `since` gauge carries a single series, labelled with the
/// stage the program is in right now: a program has one stage at a time, and
/// repeating that one timestamp under eight stage labels would claim each stage
/// has its own, which it does not.
fn write_program_status_metrics(
    status_family: &mut String,
    since_family: &mut String,
    pipeline: &ExtendedPipelineDescrMonitoring,
) {
    let labels = format!(
        "pipeline=\"pipeline-{}\",pipeline_name=\"{}\"",
        pipeline.id, pipeline.name
    );
    let since = pipeline.program_status_since.timestamp_millis() as f64 / 1000.0;

    for candidate in ProgramStatus::ALL {
        writeln!(
            status_family,
            "{PROGRAM_STATUS_METRIC}{{{labels},program_status=\"{}\"}} {}",
            candidate.as_str(),
            u8::from(candidate == pipeline.program_status)
        )
        .unwrap();
    }
    writeln!(
        since_family,
        "{PROGRAM_STATUS_SINCE_METRIC}{{{labels},program_status=\"{}\"}} {since}",
        pipeline.program_status.as_str()
    )
    .unwrap();
}

/// Renders the status metric families for `pipelines` in Prometheus format.
///
/// Each family is built in its own buffer and the buffers are concatenated in
/// order, because a scrape reads the body as one stream: samples for a family
/// must all follow that family's header, so the families cannot be interleaved.
pub(crate) fn status_metrics(pipelines: &[ExtendedPipelineDescrMonitoring]) -> String {
    let mut status_family = family_header(STATUS_METRIC, STATUS_HELP);
    let mut status_since_family = family_header(STATUS_SINCE_METRIC, STATUS_SINCE_HELP);
    let mut program_status_family = family_header(PROGRAM_STATUS_METRIC, PROGRAM_STATUS_HELP);
    let mut program_status_since_family =
        family_header(PROGRAM_STATUS_SINCE_METRIC, PROGRAM_STATUS_SINCE_HELP);

    for pipeline in pipelines {
        write_status_metrics(&mut status_family, pipeline);
        write_status_since_metrics(&mut status_since_family, pipeline);
        write_program_status_metrics(
            &mut program_status_family,
            &mut program_status_since_family,
            pipeline,
        );
    }

    let mut body = status_family;
    body.push_str(&status_since_family);
    body.push_str(&program_status_family);
    body.push_str(&program_status_since_family);
    body
}

/// Renders the status metric family for `pipelines` in JSON.
pub(crate) fn status_metrics_json(pipelines: &[ExtendedPipelineDescrMonitoring]) -> Vec<Value> {
    let mut status_values = Vec::new();
    for pipeline in pipelines {
        let status = status_of(pipeline);
        for candidate in CombinedStatus::ALL {
            status_values.push(json!({
                "labels": {
                    "pipeline": format!("pipeline-{}", pipeline.id),
                    "pipeline_name": pipeline.name,
                    "status": candidate.as_str(),
                },
                "value": u8::from(candidate == status),
            }));
        }
    }

    let status_since_values: Vec<Value> = pipelines
        .iter()
        .map(|pipeline| {
            json!({
                "labels": {
                    "pipeline": format!("pipeline-{}", pipeline.id),
                    "pipeline_name": pipeline.name,
                },
                "value": status_since(pipeline),
            })
        })
        .collect();

    let program_status_values: Vec<Value> = pipelines
        .iter()
        .flat_map(|pipeline| {
            ProgramStatus::ALL.iter().map(move |candidate| {
                json!({
                    "labels": {
                        "pipeline": format!("pipeline-{}", pipeline.id),
                        "pipeline_name": pipeline.name,
                        "program_status": candidate.as_str(),
                    },
                    "value": u8::from(*candidate == pipeline.program_status),
                })
            })
        })
        .collect();

    let program_status_since_values: Vec<Value> = pipelines
        .iter()
        .map(|pipeline| {
            json!({
                "labels": {
                    "pipeline": format!("pipeline-{}", pipeline.id),
                    "pipeline_name": pipeline.name,
                    "program_status": pipeline.program_status.as_str(),
                },
                "value": pipeline.program_status_since.timestamp_millis() as f64 / 1000.0,
            })
        })
        .collect();

    vec![
        json!({"key": STATUS_METRIC, "type": "gauge", "description": STATUS_HELP, "values": status_values}),
        json!({"key": STATUS_SINCE_METRIC, "type": "gauge", "description": STATUS_SINCE_HELP, "values": status_since_values}),
        json!({"key": PROGRAM_STATUS_METRIC, "type": "gauge", "description": PROGRAM_STATUS_HELP, "values": program_status_values}),
        json!({"key": PROGRAM_STATUS_SINCE_METRIC, "type": "gauge", "description": PROGRAM_STATUS_SINCE_HELP, "values": program_status_since_values}),
    ]
}

/// Returns the metrics that `pipeline` exports itself, or `None` when it is not
/// running or does not answer.
pub(crate) async fn fetch_pipeline_metrics(
    state: &ServerState,
    client: &awc::Client,
    tenant_id: TenantId,
    pipeline: &ExtendedPipelineDescrMonitoring,
    query_string: &str,
) -> Option<Bytes> {
    if pipeline.deployment_runtime_status != Some(RuntimeStatus::Running)
        && pipeline.deployment_runtime_status != Some(RuntimeStatus::Paused)
    {
        return None;
    }

    let name = &pipeline.name;
    match state
        .runner
        .forward_http_request_to_pipeline_by_name(
            client,
            tenant_id,
            name,
            Method::GET,
            "metrics",
            query_string,
            None,
            None,
        )
        .await
    {
        Ok(response) if response.status().is_success() => {
            response.into_body().try_into_bytes().ok()
        }
        Ok(response) => {
            debug!(
                "Pipeline {name} answered its metrics request with {}, reporting only its status",
                response.status()
            );
            None
        }
        Err(error) => {
            debug!(
                "Pipeline {name} did not answer its metrics request, reporting only its status: {error}"
            );
            None
        }
    }
}

/// List All Metrics
///
/// Retrieve the metrics of all pipelines belonging to this tenant.
#[utoipa::path(
    context_path = "/v0",
    security(("JSON web token (JWT) or API key" = [])),
    responses(
        (status = OK
        , description = "Metrics of all pipelines belonging to this tenant in Prometheus format"
        , content_type = "text/plain"
        , body = Vec<u8>),
    ),
    tag = "Metrics & Debugging"
)]
#[get("/metrics")]
pub(crate) async fn get_metrics(
    state: WebData<ServerState>,
    client: WebData<awc::Client>,
    tenant_id: ReqData<TenantId>,
) -> Result<HttpResponse, ManagerError> {
    let pipelines = state
        .db
        .lock()
        .await
        .list_pipelines_for_monitoring(*tenant_id)
        .await?;

    const NEWLINE: u8 = b'\n';
    let mut result = status_metrics(&pipelines).into_bytes();

    for pipeline in &pipelines {
        if let Some(bytes) =
            fetch_pipeline_metrics(&state, client.as_ref(), *tenant_id, pipeline, "").await
        {
            result.extend(bytes);
            result.push(NEWLINE);
        }
    }

    Ok(HttpResponse::Ok().content_type("text/plain").body(result))
}

#[cfg(test)]
mod test {
    use super::{
        PROGRAM_STATUS_HELP, PROGRAM_STATUS_METRIC, PROGRAM_STATUS_SINCE_HELP,
        PROGRAM_STATUS_SINCE_METRIC, STATUS_HELP, STATUS_METRIC, STATUS_SINCE_HELP,
        STATUS_SINCE_METRIC, family_header, status_metrics, status_metrics_json, status_since,
        write_status_metrics,
    };
    use crate::db::types::combined_status::CombinedStatus;
    use crate::db::types::pipeline::{ExtendedPipelineDescrMonitoring, PipelineId};
    use crate::db::types::program::ProgramStatus;
    use crate::db::types::resources_status::{ResourcesDesiredStatus, ResourcesStatus};
    use crate::db::types::storage::StorageStatus;
    use crate::db::types::version::Version;
    use chrono::DateTime;
    use feldera_types::runtime_status::RuntimeStatus;
    use serde_json::Value;
    use uuid::Uuid;

    fn stopped_pipeline(name: &str) -> ExtendedPipelineDescrMonitoring {
        ExtendedPipelineDescrMonitoring {
            id: PipelineId(Uuid::from_u128(1)),
            name: name.to_string(),
            description: Default::default(),
            tags: Default::default(),
            created_at: Default::default(),
            version: Version(1),
            platform_version: String::new(),
            runtime_config: Default::default(),
            program_config: Default::default(),
            program_version: Version(1),
            program_status: ProgramStatus::Pending,
            program_status_since: Default::default(),
            deployment_error: None,
            deployment_location: None,
            refresh_version: Version(1),
            storage_status: StorageStatus::Cleared,
            storage_status_details: None,
            deployment_id: None,
            deployment_initial: None,
            deployment_resources_status: ResourcesStatus::Stopped,
            deployment_resources_status_since: Default::default(),
            deployment_resources_desired_status: ResourcesDesiredStatus::Stopped,
            deployment_resources_desired_status_since: Default::default(),
            deployment_runtime_status: None,
            deployment_runtime_status_details: None,
            deployment_runtime_status_since: None,
            deployment_runtime_desired_status: None,
            bootstrap_policy: None,
            deployment_runtime_desired_status_since: None,
        }
    }

    fn family(pipeline: &ExtendedPipelineDescrMonitoring) -> String {
        let mut status_family = String::new();
        write_status_metrics(&mut status_family, pipeline);
        status_family
    }

    /// Returns the status whose line is the only one valued 1.
    fn reported(family: &str) -> String {
        let ones: Vec<&str> = family.lines().filter(|line| line.ends_with(" 1")).collect();
        assert_eq!(ones.len(), 1, "expected exactly one status in {family}");
        ones[0]
            .split_once("status=\"")
            .unwrap()
            .1
            .split_once('"')
            .unwrap()
            .0
            .to_string()
    }

    #[test]
    fn stopped_pipeline_reports_all_statuses() {
        let status_family = family(&stopped_pipeline("p1"));

        assert_eq!(
            status_family,
            r#"pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Stopped"} 1
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Provisioning"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Unavailable"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Coordination"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Standby"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="AwaitingApproval"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Initializing"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Bootstrapping"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="ConcurrentBootstrapping"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Synchronizing"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Replaying"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Paused"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Running"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Suspended"} 0
pipeline_status{pipeline="pipeline-00000000-0000-0000-0000-000000000001",pipeline_name="p1",status="Stopping"} 0
"#
        );
    }

    #[test]
    fn pipelines_share_the_family() {
        let mut status_family = String::new();
        for name in ["p1", "p2"] {
            write_status_metrics(&mut status_family, &stopped_pipeline(name));
        }

        for name in ["p1", "p2"] {
            let label = format!("pipeline_name=\"{name}\"");
            assert_eq!(
                status_family.matches(&label).count(),
                CombinedStatus::ALL.len()
            );
        }
        assert!(
            status_family
                .lines()
                .all(|line| line.starts_with("pipeline_status{"))
        );
    }

    #[test]
    fn headers_name_their_family() {
        assert_eq!(
            family_header(STATUS_METRIC, STATUS_HELP),
            format!("# HELP pipeline_status {STATUS_HELP}\n# TYPE pipeline_status gauge\n")
        );
    }

    /// A tenant without pipelines still gets well-formed, sample-less families.
    #[test]
    fn no_pipelines_yields_only_the_headers() {
        assert_eq!(
            status_metrics(&[]),
            family_header(STATUS_METRIC, STATUS_HELP)
                + &family_header(STATUS_SINCE_METRIC, STATUS_SINCE_HELP)
                + &family_header(PROGRAM_STATUS_METRIC, PROGRAM_STATUS_HELP)
                + &family_header(PROGRAM_STATUS_SINCE_METRIC, PROGRAM_STATUS_SINCE_HELP)
        );
        let families = status_metrics_json(&[]);
        assert_eq!(families.len(), 4);
        for family in families {
            assert_eq!(family["values"].as_array().unwrap().len(), 0);
        }
    }

    /// Prometheus expects one `HELP`/`TYPE` pair per family, ahead of its samples.
    #[test]
    fn every_family_is_announced_once_before_its_samples() {
        let body = status_metrics(&[stopped_pipeline("p1"), stopped_pipeline("p2")]);
        let lines: Vec<&str> = body.lines().collect();

        let families = [
            STATUS_METRIC,
            STATUS_SINCE_METRIC,
            PROGRAM_STATUS_METRIC,
            PROGRAM_STATUS_SINCE_METRIC,
        ];
        for metric in families {
            assert_eq!(body.matches(&format!("# HELP {metric} ")).count(), 1);
            assert_eq!(body.matches(&format!("# TYPE {metric} ")).count(), 1);

            let header = lines
                .iter()
                .position(|line| *line == format!("# TYPE {metric} gauge"))
                .unwrap();
            let first_sample = lines
                .iter()
                .position(|line| line.starts_with(&format!("{metric}{{")))
                .unwrap();
            assert!(
                header < first_sample,
                "{metric} is sampled before it is announced"
            );
        }

        // Two pipelines, and per pipeline: one status line per combined status,
        // one status `since` line, one program status line per program status,
        // and one program `since` line. Plus one `HELP`/`TYPE` pair per family.
        let per_pipeline = CombinedStatus::ALL.len() + 1 + ProgramStatus::ALL.len() + 1;
        assert_eq!(lines.len(), 2 * per_pipeline + 2 * families.len());
    }

    /// Renders one sample as the Prometheus line that reports it, with the value
    /// normalized to the form Prometheus prints.
    ///
    /// The two renderers group differently on purpose: the Prometheus body
    /// groups by family, because a scrape reads it as one stream, while the JSON
    /// body groups by family too but is compared order-independently here.
    fn sample_line(metric: &str, value: &Value) -> String {
        let labels = &value["labels"];
        // Each family adds its own discriminator after the two common labels:
        // the status families add `status`, the program families add
        // `program_status`, and the `since` gauge of the pipeline status adds
        // none.
        let mut discriminator = String::new();
        for key in ["status", "program_status"] {
            if let Some(label) = labels.get(key) {
                discriminator.push_str(&format!(",{key}=\"{}\"", label.as_str().unwrap()));
            }
        }
        // `serde_json` prints `0.0` for a whole-number float, Prometheus prints
        // `0`; both mean the same sample, so normalize through `f64`.
        format!(
            "{metric}{{pipeline=\"{}\",pipeline_name=\"{}\"{discriminator}}} {}",
            labels["pipeline"].as_str().unwrap(),
            labels["pipeline_name"].as_str().unwrap(),
            value["value"].as_f64().unwrap()
        )
    }

    /// Renders the JSON families as sorted Prometheus lines.
    fn json_as_prometheus(families: &[Value]) -> Vec<String> {
        let mut lines = Vec::new();
        for family in families {
            let metric = family["key"].as_str().unwrap();
            for value in family["values"].as_array().unwrap() {
                lines.push(sample_line(metric, value));
            }
        }
        lines.sort();
        lines
    }

    /// Renders the Prometheus body as sorted lines, dropping the headers.
    fn prometheus_samples(body: &str) -> Vec<String> {
        let mut lines: Vec<String> = body
            .lines()
            .filter(|line| !line.starts_with('#'))
            .map(str::to_string)
            .collect();
        lines.sort();
        lines
    }

    /// The two output formats must not disagree about any sample.
    #[test]
    fn json_reports_what_prometheus_reports() {
        let pipelines = [stopped_pipeline("p1"), stopped_pipeline("p2")];
        let from_json = json_as_prometheus(&status_metrics_json(&pipelines));
        let from_prometheus = prometheus_samples(&status_metrics(&pipelines));

        assert_eq!(from_json, from_prometheus);
    }

    /// The JSON `since` value and the Prometheus one are the same number.
    ///
    /// `serde_json` renders a whole-second timestamp as `0.0`, which would sort
    /// and compare differently from the `0` Prometheus prints even though the
    /// sample is identical; normalizing in the test would hide a real divergence
    /// between the two renderers, so the fixture keeps a sub-second value.
    #[test]
    fn json_and_prometheus_agree_on_a_sub_second_since() {
        let mut pipeline = stopped_pipeline("p1");
        pipeline.deployment_resources_status_since =
            DateTime::from_timestamp(1_000, 900_000_000).unwrap();

        let from_json = json_as_prometheus(&status_metrics_json(&[pipeline.clone()]));
        let from_prometheus = prometheus_samples(&status_metrics(&[pipeline]));

        assert_eq!(from_json, from_prometheus);
        assert!(
            from_prometheus
                .iter()
                .any(|line| line.starts_with(STATUS_SINCE_METRIC) && line.ends_with(" 1000.9")),
            "{from_prometheus:?}"
        );
    }

    /// The JSON families carry the descriptions the Prometheus headers announce.
    #[test]
    fn json_families_describe_themselves() {
        let families = status_metrics_json(&[stopped_pipeline("p1")]);
        let described: Vec<(&str, &str, &str)> = families
            .iter()
            .map(|family| {
                (
                    family["key"].as_str().unwrap(),
                    family["type"].as_str().unwrap(),
                    family["description"].as_str().unwrap(),
                )
            })
            .collect();

        assert_eq!(
            described,
            vec![
                (STATUS_METRIC, "gauge", STATUS_HELP),
                (STATUS_SINCE_METRIC, "gauge", STATUS_SINCE_HELP),
                (PROGRAM_STATUS_METRIC, "gauge", PROGRAM_STATUS_HELP),
                (
                    PROGRAM_STATUS_SINCE_METRIC,
                    "gauge",
                    PROGRAM_STATUS_SINCE_HELP
                ),
            ]
        );
    }

    /// The `since` of a running pipeline is its runtime timestamp.
    ///
    /// The "not Running for too long" alert reads this family. A running
    /// pipeline that reported the resources timestamp instead would be paged
    /// for as long as it had existed, however healthy it was.
    #[test]
    fn since_prefers_the_runtime_timestamp_once_there_is_one() {
        let mut pipeline = stopped_pipeline("p1");
        pipeline.deployment_resources_status = ResourcesStatus::Provisioned;
        pipeline.deployment_resources_status_since =
            DateTime::from_timestamp(1_000, 500_000_000).unwrap();
        pipeline.deployment_runtime_status = Some(RuntimeStatus::Running);
        pipeline.deployment_runtime_status_since =
            Some(DateTime::from_timestamp(2_000, 0).unwrap());

        assert_eq!(status_since(&pipeline), 2_000.0);
        assert_eq!(reported(&family(&pipeline)), "Running");
    }

    /// A pipeline whose resources are still being created has no runtime status,
    /// so the resources timestamp is the only one there is.
    #[test]
    fn since_falls_back_when_the_runtime_half_is_absent() {
        for resources_status in [
            ResourcesStatus::Stopped,
            ResourcesStatus::Provisioning,
            ResourcesStatus::Provisioned,
        ] {
            let mut pipeline = stopped_pipeline("p1");
            pipeline.deployment_resources_status = resources_status;
            pipeline.deployment_resources_status_since =
                DateTime::from_timestamp(1_234, 0).unwrap();
            pipeline.deployment_runtime_status = None;
            pipeline.deployment_runtime_status_since = None;

            assert_eq!(
                status_since(&pipeline),
                1_234.0,
                "{resources_status:?} must report its resources timestamp"
            );
        }
    }

    /// Sub-second precision survives: the alert thresholds are in seconds, and
    /// truncating a status that just changed would shorten it by up to one.
    #[test]
    fn since_keeps_sub_second_precision() {
        let mut pipeline = stopped_pipeline("p1");
        pipeline.deployment_resources_status_since =
            DateTime::from_timestamp(7, 250_000_000).unwrap();

        assert_eq!(status_since(&pipeline), 7.25);
    }

    /// The `since` gauge is one sample per pipeline with no status label, so that
    /// `time() - pipeline_status_since_timestamp_seconds` is a duration rather
    /// than a comparison against every status.
    #[test]
    fn since_is_one_sample_per_pipeline() {
        let body = status_metrics(&[stopped_pipeline("p1"), stopped_pipeline("p2")]);
        let since: Vec<&str> = body
            .lines()
            .filter(|line| line.starts_with(STATUS_SINCE_METRIC))
            .collect();

        assert_eq!(since.len(), 2, "{since:?}");
        for line in since {
            assert!(!line.contains("status="), "{line}");
        }
    }

    #[test]
    fn each_status_is_reported_in_turn() {
        use ResourcesStatus::*;
        use RuntimeStatus::*;

        let cases = [
            (Stopped, None, "Stopped"),
            (Provisioning, None, "Provisioning"),
            (Stopping, None, "Stopping"),
            (Provisioned, Some(Unavailable), "Unavailable"),
            (Provisioned, Some(Coordination), "Coordination"),
            (Provisioned, Some(Standby), "Standby"),
            (Provisioned, Some(AwaitingApproval), "AwaitingApproval"),
            (Provisioned, Some(Initializing), "Initializing"),
            (Provisioned, Some(Bootstrapping), "Bootstrapping"),
            (
                Provisioned,
                Some(ConcurrentBootstrapping),
                "ConcurrentBootstrapping",
            ),
            (Provisioned, Some(Synchronizing), "Synchronizing"),
            (Provisioned, Some(Replaying), "Replaying"),
            (Provisioned, Some(Paused), "Paused"),
            (Provisioned, Some(Running), "Running"),
            (Provisioned, Some(Suspended), "Suspended"),
        ];
        assert_eq!(cases.len(), CombinedStatus::ALL.len());

        for (resources_status, runtime_status, expected) in cases {
            let mut pipeline = stopped_pipeline("p1");
            pipeline.deployment_resources_status = resources_status;
            pipeline.deployment_runtime_status = runtime_status;

            let status_family = family(&pipeline);
            assert_eq!(reported(&status_family), expected);
            assert_eq!(status_family.lines().count(), CombinedStatus::ALL.len());
        }
    }

    #[test]
    fn a_status_without_a_reportable_value_becomes_unavailable() {
        let mut pipeline = stopped_pipeline("p1");
        pipeline.deployment_resources_status = ResourcesStatus::Provisioned;
        pipeline.deployment_runtime_status = None;

        assert_eq!(reported(&family(&pipeline)), "Unavailable");
    }

    /// The compile-queue alert waits for `pending` to last too long, so the
    /// `since` gauge must carry the stage the program is in right now.
    #[test]
    fn program_since_names_the_current_stage() {
        let mut pipeline = stopped_pipeline("p1");
        pipeline.program_status = ProgramStatus::Pending;
        pipeline.program_status_since = DateTime::from_timestamp(1_000, 0).unwrap();

        let body = status_metrics(&[pipeline]);
        let since: Vec<&str> = body
            .lines()
            .filter(|line| line.starts_with(PROGRAM_STATUS_SINCE_METRIC))
            .collect();

        assert_eq!(since.len(), 1, "{since:?}");
        assert!(since[0].contains("program_status=\"pending\""), "{since:?}");
        assert!(since[0].ends_with(" 1000"), "{since:?}");
    }

    /// A program is in exactly one stage, so exactly one stage series is 1.
    #[test]
    fn program_status_reports_one_stage_at_a_time() {
        for stage in ProgramStatus::ALL {
            let mut pipeline = stopped_pipeline("p1");
            pipeline.program_status = stage;

            let body = status_metrics(&[pipeline]);
            let ones: Vec<&str> = body
                .lines()
                .filter(|line| line.starts_with(PROGRAM_STATUS_METRIC) && line.ends_with(" 1"))
                .collect();

            assert_eq!(ones.len(), 1, "{stage:?}: {ones:?}");
            assert!(
                ones[0].contains(&format!("program_status=\"{}\"", stage.as_str())),
                "{stage:?}: {ones:?}"
            );
        }
    }

    /// The stage gauge reports every stage, including the ones nobody is in, so
    /// that `sum by (program_status)` shows a zero queue rather than no series.
    #[test]
    fn program_status_reports_every_stage() {
        let body = status_metrics(&[stopped_pipeline("p1")]);
        // Match on the sample's own brace: `pipeline_program_status` is also a
        // prefix of `pipeline_program_status_since_timestamp_seconds`.
        let prefix = format!("{PROGRAM_STATUS_METRIC}{{");
        let stages: Vec<&str> = body
            .lines()
            .filter(|line| line.starts_with(&prefix))
            .collect();

        assert_eq!(stages.len(), ProgramStatus::ALL.len(), "{stages:?}");
    }
}
