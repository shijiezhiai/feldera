//! Role-based access-control enforcement.
//!
//! A single middleware over the authenticated `/v0` scope reads the
//! `AuthenticatedPrincipal` that `auth_validator` installed and compares its
//! role against the minimum role declared for the matched route. The
//! `ROUTE_MIN_ROLE` table below is the single source of truth for the
//! access-control model. Enforcement is deny-by-default with no pass-through:
//! a handler runs only after a table entry admits the request. A registered
//! route absent from the table is refused, so a newly added endpoint cannot
//! ship silently world-accessible, and a path no route claims is answered 404
//! here rather than handed on.

use crate::api::audit::DenyReason;
use crate::auth::AuthenticatedPrincipal;
use crate::config::BasePath;
use crate::db::error::DBError;
use crate::db::types::role::Role;
use actix_web::body::{BoxBody, MessageBody};
use actix_web::dev::{ServiceRequest, ServiceResponse};
use actix_web::http::Method;
use actix_web::middleware::Next;
use actix_web::{HttpMessage, HttpResponse, ResponseError};
use std::collections::HashMap;
use std::sync::OnceLock;
use tracing::error;

/// The access-control rule for each `/v0` route: the minimum role that may
/// reach it, and whether it draws on one tenant's data or the installation's.
///
/// A `(method, path)` absent from this table is denied by the middleware. The
/// two axes are deliberately one row rather than two tables: a route cannot be
/// classified on the role axis and left unclassified on the tenant axis, and
/// the tenant scope travels out of [`classify`] with no second lookup.
///
/// See [`TenantScope`] for what the second column means and why the split is
/// enforced rather than advisory.
/// Whether a route draws on data belonging to exactly one tenant, or on the
/// installation as a whole.
///
/// The role column answers "may this principal do it at all"; this column
/// answers "whose data does it touch". A [`TenantScope::Tenant`] route must be
/// served by a handler that takes `ReqData<TenantId>` and filters on it, which
/// [`every_tenant_scoped_route_reaches_a_handler_that_reads_the_acting_tenant`]
/// checks against the endpoint sources. A [`TenantScope::Platform`] route has no
/// owning tenant and is scoped by role alone.
///
/// The type lives in [`crate::api::audit`] because the audit line is what
/// carries it out of the middleware: one definition keeps the table's column
/// and the recorded field from drifting apart.
use crate::api::audit::TenantScope;

#[rustfmt::skip]
static ROUTE_MIN_ROLE: &[(&str, &str, Role, TenantScope)] = &[
    ("GET", "/v0/api_keys", Role::Write, TenantScope::Tenant), // list_api_keys
    ("POST", "/v0/api_keys", Role::Write, TenantScope::Tenant), // post_api_key
    ("DELETE", "/v0/api_keys/{api_key_name}", Role::Write, TenantScope::Tenant), // delete_api_key
    ("GET", "/v0/api_keys/{api_key_name}", Role::Write, TenantScope::Tenant), // get_api_key
    ("GET", "/v0/cluster/events", Role::Read, TenantScope::Platform), // list_cluster_events
    ("GET", "/v0/cluster/events/{event_id}", Role::Read, TenantScope::Platform), // get_cluster_event
    ("GET", "/v0/cluster_healthz", Role::Read, TenantScope::Platform), // get_cluster_health
    ("GET", "/v0/config", Role::Read, TenantScope::Platform), // get_config
    ("GET", "/v0/config/demos", Role::Read, TenantScope::Platform), // get_config_demos
    ("GET", "/v0/config/session", Role::Read, TenantScope::Tenant), // get_config_session
    ("GET", "/v0/config/owners", Role::Owner, TenantScope::Platform), // get_config_owners
    ("GET", "/v0/metrics", Role::Read, TenantScope::Tenant), // get_metrics
    ("GET", "/v0/oidc_trust", Role::Admin, TenantScope::Tenant), // list_oidc_trust
    ("POST", "/v0/oidc_trust", Role::Admin, TenantScope::Tenant), // post_oidc_trust
    ("DELETE", "/v0/oidc_trust/{name}", Role::Admin, TenantScope::Tenant), // delete_oidc_trust
    ("GET", "/v0/oidc_trust/{name}", Role::Admin, TenantScope::Tenant), // get_oidc_trust
    ("GET", "/v0/pipelines", Role::Read, TenantScope::Tenant), // list_pipelines
    ("POST", "/v0/pipelines", Role::Write, TenantScope::Tenant), // post_pipeline
    ("DELETE", "/v0/pipelines/{pipeline_name}", Role::Write, TenantScope::Tenant), // delete_pipeline
    ("GET", "/v0/pipelines/{pipeline_name}", Role::Read, TenantScope::Tenant), // get_pipeline
    ("PATCH", "/v0/pipelines/{pipeline_name}", Role::Write, TenantScope::Tenant), // patch_pipeline
    ("PUT", "/v0/pipelines/{pipeline_name}", Role::Write, TenantScope::Tenant), // put_pipeline
    ("POST", "/v0/pipelines/{pipeline_name}/activate", Role::Write, TenantScope::Tenant), // post_pipeline_activate
    ("POST", "/v0/pipelines/{pipeline_name}/approve", Role::Write, TenantScope::Tenant), // post_pipeline_approve
    ("POST", "/v0/pipelines/{pipeline_name}/checkpoint", Role::Write, TenantScope::Tenant), // checkpoint_pipeline
    ("POST", "/v0/pipelines/{pipeline_name}/checkpoint/sync", Role::Write, TenantScope::Tenant), // sync_checkpoint
    ("GET", "/v0/pipelines/{pipeline_name}/checkpoint/sync_status", Role::Read, TenantScope::Tenant), // get_checkpoint_sync_status
    ("GET", "/v0/pipelines/{pipeline_name}/checkpoint_status", Role::Read, TenantScope::Tenant), // get_checkpoint_status
    ("GET", "/v0/pipelines/{pipeline_name}/checkpoints", Role::Read, TenantScope::Tenant), // get_checkpoints
    ("GET", "/v0/pipelines/{pipeline_name}/checkpoints/remote", Role::Read, TenantScope::Tenant), // get_remote_checkpoints
    ("GET", "/v0/pipelines/{pipeline_name}/circuit_json_profile", Role::Read, TenantScope::Tenant), // get_pipeline_circuit_json_profile
    ("GET", "/v0/pipelines/{pipeline_name}/circuit_profile", Role::Read, TenantScope::Tenant), // get_pipeline_circuit_profile
    ("POST", "/v0/pipelines/{pipeline_name}/clear", Role::Write, TenantScope::Tenant), // post_pipeline_clear
    ("POST", "/v0/pipelines/{pipeline_name}/clock/advance", Role::Write, TenantScope::Tenant), // clock_advance
    ("POST", "/v0/pipelines/{pipeline_name}/commit_transaction", Role::Write, TenantScope::Tenant), // commit_transaction
    ("GET", "/v0/pipelines/{pipeline_name}/completion_status", Role::Read, TenantScope::Tenant), // completion_status
    ("GET", "/v0/pipelines/{pipeline_name}/dataflow_graph", Role::Read, TenantScope::Tenant), // get_pipeline_dataflow_graph
    ("POST", "/v0/pipelines/{pipeline_name}/diff", Role::Write, TenantScope::Tenant), // post_pipeline_diff (submits a candidate program to the shared compiler)
    ("POST", "/v0/pipelines/{pipeline_name}/dismiss_error", Role::Write, TenantScope::Tenant), // post_pipeline_dismiss_error
    ("POST", "/v0/pipelines/{pipeline_name}/egress/{table_name}", Role::Write, TenantScope::Tenant), // http_output
    ("GET", "/v0/pipelines/{pipeline_name}/events", Role::Read, TenantScope::Tenant), // list_pipeline_events
    ("GET", "/v0/pipelines/{pipeline_name}/events/{event_id}", Role::Read, TenantScope::Tenant), // get_pipeline_event
    ("GET", "/v0/pipelines/{pipeline_name}/heap_profile", Role::Read, TenantScope::Tenant), // get_pipeline_heap_profile
    ("POST", "/v0/pipelines/{pipeline_name}/ingress/{table_name}", Role::Write, TenantScope::Tenant), // http_input
    ("GET", "/v0/pipelines/{pipeline_name}/logs", Role::Read, TenantScope::Tenant), // get_pipeline_logs
    ("GET", "/v0/pipelines/{pipeline_name}/metrics", Role::Read, TenantScope::Tenant), // get_pipeline_metrics
    ("POST", "/v0/pipelines/{pipeline_name}/pause", Role::Write, TenantScope::Tenant), // post_pipeline_pause
    ("GET", "/v0/pipelines/{pipeline_name}/query", Role::Write, TenantScope::Tenant), // pipeline_adhoc_sql
    ("POST", "/v0/pipelines/{pipeline_name}/rebalance", Role::Write, TenantScope::Tenant), // post_pipeline_rebalance
    ("POST", "/v0/pipelines/{pipeline_name}/resume", Role::Write, TenantScope::Tenant), // post_pipeline_resume
    ("GET", "/v0/pipelines/{pipeline_name}/samply_profile", Role::Read, TenantScope::Tenant), // get_pipeline_samply_profile
    ("POST", "/v0/pipelines/{pipeline_name}/samply_profile", Role::Read, TenantScope::Tenant), // start_samply_profile
    ("POST", "/v0/pipelines/{pipeline_name}/start", Role::Write, TenantScope::Tenant), // post_pipeline_start
    ("POST", "/v0/pipelines/{pipeline_name}/start_compaction", Role::Write, TenantScope::Tenant), // post_pipeline_start_compaction
    ("POST", "/v0/pipelines/{pipeline_name}/start_transaction", Role::Write, TenantScope::Tenant), // start_transaction
    ("GET", "/v0/pipelines/{pipeline_name}/stats", Role::Read, TenantScope::Tenant), // get_pipeline_stats
    ("POST", "/v0/pipelines/{pipeline_name}/stop", Role::Write, TenantScope::Tenant), // post_pipeline_stop
    ("GET", "/v0/pipelines/{pipeline_name}/support_bundle", Role::Read, TenantScope::Tenant), // get_pipeline_support_bundle
    ("GET", "/v0/pipelines/{pipeline_name}/tables/{table_name}/connectors/{connector_name}/completion_token", Role::Write, TenantScope::Tenant), // completion_token
    ("GET", "/v0/pipelines/{pipeline_name}/tables/{table_name}/connectors/{connector_name}/stats", Role::Read, TenantScope::Tenant), // get_pipeline_input_connector_status
    ("POST", "/v0/pipelines/{pipeline_name}/tables/{table_name}/connectors/{connector_name}/{action}", Role::Write, TenantScope::Tenant), // post_pipeline_input_connector_action
    ("POST", "/v0/pipelines/{pipeline_name}/testing", Role::Write, TenantScope::Tenant), // post_pipeline_testing
    ("GET", "/v0/pipelines/{pipeline_name}/time_series", Role::Read, TenantScope::Tenant), // get_pipeline_time_series
    ("GET", "/v0/pipelines/{pipeline_name}/time_series_stream", Role::Read, TenantScope::Tenant), // get_pipeline_time_series_stream
    ("POST", "/v0/pipelines/{pipeline_name}/update_runtime", Role::Write, TenantScope::Tenant), // post_update_runtime
    ("POST", "/v0/validate_program", Role::Write, TenantScope::Tenant), // post_validate_program (submits a program to the shared compiler)
    ("POST", "/v0/pipelines/{pipeline_name}/views/{view_name}/connectors/{connector_name}/command", Role::Write, TenantScope::Tenant), // post_pipeline_output_connector_command
    ("GET", "/v0/pipelines/{pipeline_name}/views/{view_name}/connectors/{connector_name}/stats", Role::Read, TenantScope::Tenant), // get_pipeline_output_connector_status
    ("POST", "/v0/pipelines/{pipeline_name}/views/{view_name}/connectors/{connector_name}/{action}", Role::Write, TenantScope::Tenant), // post_pipeline_output_connector_action
    // RBAC tenant/user management
    ("GET", "/v0/tenant/users", Role::Admin, TenantScope::Tenant), // list_tenant_users
    ("POST", "/v0/tenant/users", Role::Admin, TenantScope::Tenant), // add_tenant_user (pre-provision)
    ("PUT", "/v0/tenant/users/{user_id}", Role::Admin, TenantScope::Tenant), // put_tenant_user
    ("DELETE", "/v0/tenant/users/{user_id}", Role::Admin, TenantScope::Tenant), // delete_tenant_user
    ("GET", "/v0/tenants", Role::Owner, TenantScope::Platform), // list_tenants
    ("POST", "/v0/tenants", Role::Owner, TenantScope::Platform), // create_tenant
    ("GET", "/v0/tenants/{tenant_id}", Role::Owner, TenantScope::Platform), // get_tenant
    ("PATCH", "/v0/tenants/{tenant_id}", Role::Owner, TenantScope::Platform), // patch_tenant
    ("DELETE", "/v0/tenants/{tenant_id}", Role::Owner, TenantScope::Platform), // delete_tenant
];

/// [`ROUTE_MIN_ROLE`] indexed by `(method, pattern)`, built once on first use,
/// for callers that already hold a route template rather than a request path.
fn route_table() -> &'static HashMap<(&'static str, &'static str), (Role, TenantScope)> {
    static TABLE: OnceLock<HashMap<(&'static str, &'static str), (Role, TenantScope)>> =
        OnceLock::new();
    TABLE.get_or_init(|| {
        ROUTE_MIN_ROLE
            .iter()
            .map(|(m, p, r, s)| ((*m, *p), (*r, *s)))
            .collect()
    })
}

/// The minimum role for a route template, or `None` when the table does not
/// classify it, which the middleware treats as a denial.
///
/// ```text
/// min_role_for("POST", "/v0/tenants")     => Some(Role::Owner)
/// min_role_for("GET",  "/v0/not-a-route") => None
/// ```
///
/// The OpenAPI annotation reads the same table as the middleware, so the API
/// reference cannot drift from the enforced policy.
pub(crate) fn min_role_for(method: &str, pattern: &str) -> Option<Role> {
    route_table().get(&(method, pattern)).map(|(role, _)| *role)
}

/// Resolve a request path to its table entry, returning the pattern it matched
/// and that pattern's rule.
///
/// Actix's `match_pattern()` cannot serve here: it resolves by path alone,
/// ignoring the method, so it reports whichever registered pattern claims the
/// path first. Matching the table directly, method first, keeps the enforced
/// rule and the authored rule the same thing.
///
/// A literal segment beats a placeholder, as in any router:
///
/// ```text
/// GET  /v0/pipelines/p/tables/t/connectors/c/completion_token
///   => .../connectors/{connector_name}/completion_token   (literal wins)
/// POST /v0/pipelines/p/tables/t/connectors/c/start
///   => .../connectors/{connector_name}/{action}           (no literal claims it)
/// ```
fn classify(method: &str, path: &str) -> Option<(&'static str, Role, TenantScope)> {
    let segments: Vec<&str> = path.split('/').collect();
    let candidates = candidates_by_shape().get(&(method, segments.len()))?;
    let mut best: Option<(usize, &'static str, Role, TenantScope)> = None;
    for (pattern, role, scope) in candidates {
        let Some(literals) = literal_segments_if_match(pattern, &segments) else {
            continue;
        };
        if best.is_none_or(|(best_literals, _, _, _)| literals > best_literals) {
            best = Some((literals, pattern, *role, *scope));
        }
    }
    best.map(|(_, pattern, role, scope)| (pattern, role, scope))
}

/// [`ROUTE_MIN_ROLE`] bucketed by `(method, segment count)`, built once on first
/// use. A path can only match a pattern of the same shape, so a request compares
/// itself against a handful of candidates rather than the whole table.
#[allow(clippy::type_complexity)]
fn candidates_by_shape()
-> &'static HashMap<(&'static str, usize), Vec<(&'static str, Role, TenantScope)>> {
    static SHAPES: OnceLock<
        HashMap<(&'static str, usize), Vec<(&'static str, Role, TenantScope)>>,
    > = OnceLock::new();
    SHAPES.get_or_init(|| {
        let mut shapes: HashMap<(&'static str, usize), Vec<(&'static str, Role, TenantScope)>> =
            HashMap::new();
        for (method, pattern, role, scope) in ROUTE_MIN_ROLE {
            shapes
                .entry((method, pattern.split('/').count()))
                .or_default()
                .push((pattern, *role, *scope));
        }
        shapes
    })
}

/// Whether any route pattern matches `path`, disregarding the method. Tells a
/// wrong-method request for a real path apart from a path the table describes
/// under no method at all.
fn path_matches_any_route(path: &str) -> bool {
    let segments: Vec<&str> = path.split('/').collect();
    ROUTE_MIN_ROLE
        .iter()
        .any(|(_, pattern, _, _)| literal_segments_if_match(pattern, &segments).is_some())
}

/// How many literal segments `pattern` matches `segments` with, or `None` when
/// it does not match. A `{name}` segment matches any one non-empty segment.
fn literal_segments_if_match(pattern: &str, segments: &[&str]) -> Option<usize> {
    let parts: Vec<&str> = pattern.split('/').collect();
    if parts.len() != segments.len() {
        return None;
    }
    let mut literals = 0;
    for (part, segment) in parts.iter().zip(segments) {
        if part.starts_with('{') && part.ends_with('}') {
            if segment.is_empty() {
                return None;
            }
        } else if part != segment {
            return None;
        } else {
            literals += 1;
        }
    }
    Some(literals)
}

/// A 403 in the same JSON shape the rest of the API returns, so clients can
/// parse a permission denial the same way whether it came from here or a handler.
fn forbidden(message: &str) -> HttpResponse<BoxBody> {
    HttpResponse::Forbidden().json(serde_json::json!({
        "message": message,
        "error_code": "InsufficientPermissions",
    }))
}

/// The 404 for a `/v0` path no route claims, answered by the guard itself so
/// that an unknown path never reaches a handler. Carries the `details` field
/// that `feldera_types::error::ErrorResponse` requires, so a strict client can
/// deserialize it like any other API error.
fn not_found(method: &str, path: &str) -> HttpResponse<BoxBody> {
    HttpResponse::NotFound().json(serde_json::json!({
        "message": format!(
            "No endpoint for {method} {path}; see the API reference for the available /v0 endpoints"
        ),
        "error_code": "UnknownEndpoint",
        "details": {},
    }))
}

/// Decide whether the principal may proceed, returning the pattern the request
/// resolved to for the audit line. `Ok` allows; `Err(resp)` is the response
/// to return instead of calling the handler.
///
/// The handler is reachable only through `Ok`, which requires a table entry
/// for the request and a role that meets it. There is no pass-through: a path
/// the table cannot classify for this method is answered here. It is a 404
/// when no route serves that method on the path, whether the path is unknown
/// or exists only for other methods, and a 403 only when the path is one actix
/// would dispatch yet the table classifies under no method, a registered route
/// missing from the table that the guard denies rather than serve unchecked.
///
/// ```text
/// // a writer posting a pipeline
/// authorize("POST", true,  "/v0/pipelines", Some(&writer))  => Ok(..)
/// // a reader posting a pipeline
/// authorize("POST", true,  "/v0/pipelines", Some(&reader))  => Err(403)
/// // an admin listing tenants, which is owner-only
/// authorize("GET",  true,  "/v0/tenants",   Some(&admin))   => Err(403)
/// // a real path, wrong method: answered 404, no error logged
/// authorize("POST", true,  "/v0/cluster_healthz", Some(&r)) => Err(404)
/// // no route and no table entry: answered as 404, never passed through
/// authorize("GET",  false, "/v0/nonesuch",  Some(&reader))  => Err(404)
/// ```
fn authorize(
    method: &str,
    routed: bool,
    path: &str,
    principal: Option<&AuthenticatedPrincipal>,
) -> Result<(&'static str, TenantScope), Refusal> {
    let Some((pattern, required, scope)) = classify(method, path) else {
        // No table entry for this method on this path. A path the table
        // describes under other methods is a wrong-method request (`routed` is
        // method-blind, so it is true here even for a method the path does not
        // serve). Answer it 404 like an unknown path: neither reaches a
        // handler, and a legitimate HEAD or an unsupported verb must not log an
        // error. Only a path actix would dispatch yet the table classifies
        // under no method is the registered-route bug.
        if !routed || path_matches_any_route(path) {
            // Not a denial, and not an audit event: no route serves this method
            // on this path, so there was no access decision to record. Logging
            // it as one would bury real denials under 404s from probing.
            return Err(Refusal::NotFound(not_found(method, path)));
        }
        error!("RBAC: route {method} {path} has no access-control entry; denying");
        return Err(Refusal::Denied(Denial {
            reason: DenyReason::Unclassified,
            route: BOXED_PATH,
            required_role: None,
            scope: None,
            response: forbidden("This endpoint has no access-control classification and is denied"),
        }));
    };
    match principal {
        Some(p) if p.role.satisfies(required) => Ok((pattern, scope)),
        Some(p) => Err(Refusal::Denied(Denial {
            reason: DenyReason::Role,
            route: pattern,
            required_role: Some(required),
            scope: Some(scope),
            response: DBError::InsufficientPermissions {
                required,
                actual: p.role,
            }
            .error_response(),
        })),
        None => {
            error!("RBAC: no authenticated principal for {method} {pattern}; denying");
            Err(Refusal::Denied(Denial {
                reason: DenyReason::Unauthenticated,
                route: pattern,
                required_role: Some(required),
                scope: Some(scope),
                response: forbidden("No authenticated principal"),
            }))
        }
    }
}

/// A route string for a denial on a path the table does not classify: there is
/// no pattern to record, and the raw path may name an object the caller is not
/// entitled to see. A reviewer reads the method plus the denial reason instead.
const BOXED_PATH: &str = "(unclassified path)";

/// An access-control refusal, carried out of [`authorize`] so the middleware can
/// record it before the response is returned.
///
/// The response is built where the reason is known, because each refusal has
/// its own body; this type adds the fields the audit line needs, without
/// making the middleware re-derive which branch fired.
struct Denial {
    reason: DenyReason,
    route: &'static str,
    required_role: Option<Role>,
    scope: Option<TenantScope>,
    response: HttpResponse<BoxBody>,
}

/// Either a refusal, or a request answered without an access decision (404).
///
/// A 404 is not a denial: no route serves that method on that path, so no
/// access decision was made and nothing is recorded. Kept distinct so the
/// middleware cannot mistake a probe for an authorization failure and bury real
/// denials under them.
enum Refusal {
    Denied(Denial),
    NotFound(HttpResponse<BoxBody>),
}

impl Refusal {
    /// The status the caller will receive. Exists so a test can assert the
    /// decision without consuming the response.
    fn status(&self) -> actix_web::http::StatusCode {
        match self {
            Refusal::Denied(d) => d.response.status(),
            Refusal::NotFound(r) => r.status(),
        }
    }

    /// The audit reason this refusal carries, `None` for a 404 that made no
    /// access decision.
    fn reason(&self) -> Option<DenyReason> {
        match self {
            Refusal::Denied(d) => Some(d.reason),
            Refusal::NotFound(_) => None,
        }
    }
}

/// Record who reached which route, in which tenant, at what role, and whether
/// the route draws on one tenant's data or the installation's.
///
/// The tenant scope is carried into the audit line rather than enforced here:
/// enforcement is the handler's tenant predicate, which
/// [`every_tenant_scoped_route_reaches_a_handler_that_reads_the_acting_tenant`]
/// keeps in place. Recording it lets an auditor separate "this principal read
/// its own tenant's pipelines" from "this principal read the installation's
/// configuration" without a second lookup.
fn audit_allow(
    method: &Method,
    pattern: &'static str,
    principal: Option<&AuthenticatedPrincipal>,
    scope: TenantScope,
    required_role: Role,
) {
    crate::api::audit::record(&crate::api::audit::AccessEvent {
        decision: crate::api::audit::Decision::Allow,
        principal,
        method: method.as_str(),
        route: pattern,
        scope: Some(scope),
        required_role: Some(required_role),
        reason: None,
    });
}

/// Refuse any `/v0` request whose principal is below the role its route
/// requires, and record the ones that pass. Runs after `auth_validator` has
/// installed the principal, so the role is already resolved here.
///
/// The route table is authored against root-relative patterns, so a deployment
/// mounted on a subpath has its base path stripped off the request path first:
/// `/feldera/v0/pipelines` classifies as `/v0/pipelines`. Left on, the prefix
/// makes every path miss the table and denies the entire API.
pub(crate) async fn rbac_middleware(
    req: ServiceRequest,
    next: Next<impl MessageBody + 'static>,
) -> Result<ServiceResponse<BoxBody>, actix_web::Error> {
    let principal = req.extensions().get::<AuthenticatedPrincipal>().cloned();
    let method = req.method().clone();
    // Classify the path actix routes on. actix dispatches on the
    // percent-decoded path, so the guard reads that same view rather than the
    // raw URI, which the router could spell differently. `match_info().as_str()`
    // is actix's decoded path.
    let routed_path = req.match_info().as_str().to_string();
    // Only picks 404 versus 403 for an unclassified path; it never lets a
    // request through, so a wrong answer here cannot reach a handler. The
    // resource map is keyed by mounted path, so this matches before the strip.
    let routed = req.resource_map().match_pattern(&routed_path).is_some();
    let path = BasePath::strip_from(&req, &routed_path).to_string();

    match authorize(method.as_str(), routed, &path, principal.as_ref()) {
        Ok((pattern, scope)) => {
            let required_role = min_role_for(method.as_str(), pattern)
                .expect("a classified route has a table row with a minimum role");
            audit_allow(&method, pattern, principal.as_ref(), scope, required_role);
            Ok(next.call(req).await?.map_into_boxed_body())
        }
        Err(Refusal::Denied(denial)) => {
            crate::api::audit::record(&crate::api::audit::AccessEvent {
                decision: crate::api::audit::Decision::Deny,
                principal: principal.as_ref(),
                method: method.as_str(),
                route: denial.route,
                scope: denial.scope,
                required_role: denial.required_role,
                reason: Some(denial.reason),
            });
            Ok(req.into_response(denial.response))
        }
        Err(Refusal::NotFound(response)) => Ok(req.into_response(response)),
    }
}

/// Record a request that failed authentication, which the guard above never
/// sees.
///
/// `auth_validator` is an actix credential extractor: a request that carries no
/// `Authorization` header at all is refused with 401 *by the extractor*, before
/// any middleware inside it runs -- so without this layer an attempt with no
/// credential, or with one in a shape the extractor rejects, leaves no trace.
/// Those are the events an auditor most wants: a denial with a credential that
/// did not work is what a brute-force attempt looks like from here.
///
/// This layer sits outside authentication, so it cannot know who called -- it
/// has no principal to name, by construction. It records only requests that
/// were answered 401 and that the route table classifies; an unknown path is
/// answered without an event, for the reason given in [`authorize`]. Everything
/// else is left to the inner layer, which knows the decision.
pub(crate) async fn rbac_authentication_guard(
    req: ServiceRequest,
    next: Next<impl MessageBody + 'static>,
) -> Result<ServiceResponse<BoxBody>, actix_web::Error> {
    let method = req.method().clone();
    // Same view of the path as the inner layer: actix dispatches on the decoded
    // path, and a deployment on a subpath is classified relative to its root.
    let routed_path = req.match_info().as_str().to_string();
    let path = BasePath::strip_from(&req, &routed_path).to_string();

    let response = next.call(req).await?.map_into_boxed_body();
    if response.status() != actix_web::http::StatusCode::UNAUTHORIZED {
        return Ok(response);
    }
    if let Some((pattern, required, scope)) = classify(method.as_str(), &path) {
        crate::api::audit::record(&crate::api::audit::AccessEvent {
            decision: crate::api::audit::Decision::Deny,
            // No principal: authentication is what failed. The inner layer
            // records a rejected *credential* (an unknown key, a bad
            // signature); this one records its absence.
            principal: None,
            method: method.as_str(),
            route: pattern,
            scope: Some(scope),
            required_role: Some(required),
            reason: Some(DenyReason::Unauthenticated),
        });
    }
    Ok(response)
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn table_has_no_duplicate_entries() {
        let mut seen = std::collections::HashSet::new();
        for (m, p, _, _) in ROUTE_MIN_ROLE {
            assert!(seen.insert((*m, *p)), "duplicate route entry: {m} {p}");
        }
    }

    /// A route classified tenant-scoped must be served by a handler that takes
    /// `ReqData<TenantId>`, because that extractor is what supplies the
    /// predicate the handler's query filters on. A tenant-scoped route whose
    /// handler never reads the acting tenant reads every tenant's rows.
    ///
    /// The table classifies the route, the endpoint sources are the ground
    /// truth for what the handler reads, and the trailing comment on each row
    /// names the handler -- so this also catches a comment that has drifted
    /// away from the endpoint it claims to describe.
    #[test]
    fn every_tenant_scoped_route_reaches_a_handler_that_reads_the_acting_tenant() {
        let handlers = handlers_that_take_a_tenant();
        assert!(
            handlers.len() > 50,
            "parsed only {} handlers; the source scan is not finding them",
            handlers.len()
        );
        let mut offenders = vec![];
        for (method, pattern) in ROUTE_MIN_ROLE
            .iter()
            .filter(|(_, _, _, scope)| *scope == TenantScope::Tenant)
            .map(|(m, p, _, _)| (*m, *p))
        {
            let Some(handler) = handler_named_in_comment(method, pattern) else {
                offenders.push(format!("{method} {pattern}: the row names no handler"));
                continue;
            };
            match handlers.get(handler) {
                Some(true) => {}
                Some(false) => offenders.push(format!(
                    "{method} {pattern}: handler `{handler}` does not take ReqData<TenantId>"
                )),
                None => offenders.push(format!(
                    "{method} {pattern}: handler `{handler}` was not found in the endpoint sources"
                )),
            }
        }
        offenders.sort();
        assert!(
            offenders.is_empty(),
            "tenant-scoped routes without a tenant predicate:\n  {}",
            offenders.join("\n  ")
        );
    }

    /// The handler a table row names in its trailing comment. The comment is how
    /// a row says which endpoint it governs, so reading it back lets the test
    /// above check the route against the code rather than trusting a label.
    fn handler_named_in_comment(method: &str, pattern: &str) -> Option<&'static str> {
        let source = include_str!("rbac.rs");
        let needle = format!("\"{pattern}\",");
        source.lines().find_map(|line| {
            if !line.contains(&needle) || !line.contains(method) {
                return None;
            }
            let (_, comment) = line.rsplit_once("//")?;
            // Only a bare identifier is a handler: `post_pipeline_diff (submits
            // a candidate program to the shared compiler)` explains itself
            // instead of naming one, and such a row must be checked another way.
            let name = comment.split_whitespace().next()?;
            name.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_')
                .then_some(name)
        })
    }

    /// Handler name to "does its signature take `ReqData<TenantId>`", read from
    /// the endpoint sources. Parsing signatures keeps the check honest: a
    /// handler that drops the extractor cannot be overlooked the way a
    /// hand-maintained list would let it.
    fn handlers_that_take_a_tenant() -> std::collections::HashMap<String, bool> {
        fn index_signatures(text: &str, out: &mut std::collections::HashMap<String, bool>) {
            let marker = "async fn ";
            let mut rest = text;
            while let Some(at) = rest.find(marker) {
                rest = &rest[at + marker.len()..];
                let name: String = rest
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                    .collect();
                if name.is_empty() {
                    continue;
                }
                let Some(open) = rest.find('(') else { continue };
                // Take the parenthesised parameter list, tracking nesting so a
                // generic argument such as `web::Json<Vec<T>>` does not end it.
                let mut depth = 0usize;
                let mut params = String::new();
                for c in rest[open..].chars() {
                    match c {
                        '(' => depth += 1,
                        ')' => {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                    params.push(c);
                }
                if depth == 0 {
                    out.insert(name, params.contains("ReqData<TenantId>"));
                }
            }
        }

        fn collect(dir: &std::path::Path, out: &mut std::collections::HashMap<String, bool>) {
            let Ok(entries) = std::fs::read_dir(dir) else {
                return;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    collect(&path, out);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    if let Ok(text) = std::fs::read_to_string(&path) {
                        index_signatures(&text, out);
                    }
                }
            }
        }

        let endpoints = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/api/endpoints");
        let mut handlers = std::collections::HashMap::new();
        collect(&endpoints, &mut handlers);
        handlers
    }

    /// The tenant column is meaningful only if it is exhaustive: every route
    /// states its scope, and the platform routes are exactly the ones that were
    /// reasoned about. A route that slips into `Platform` without justification
    /// is how a per-tenant endpoint becomes installation-wide by accident, so
    /// the platform set is pinned here and a new one must be added deliberately.
    #[test]
    fn only_the_known_installation_wide_routes_are_platform_scoped() {
        let mut platform: Vec<(&str, &str)> = ROUTE_MIN_ROLE
            .iter()
            .filter(|(_, _, _, scope)| *scope == TenantScope::Platform)
            .map(|(m, p, _, _)| (*m, *p))
            .collect();
        platform.sort();
        assert_eq!(
            platform,
            vec![
                // Tenant administration acts *on* tenants, so it has no owning
                // tenant; it is owner-gated instead.
                ("DELETE", "/v0/tenants/{tenant_id}"),
                // Cluster health and events describe the installation, not a
                // tenant's pipelines.
                ("GET", "/v0/cluster/events"),
                ("GET", "/v0/cluster/events/{event_id}"),
                ("GET", "/v0/cluster_healthz"),
                // Instance configuration: the same answer for every tenant.
                ("GET", "/v0/config"),
                ("GET", "/v0/config/demos"),
                // Operators named in the deployment config, not tenant data.
                ("GET", "/v0/config/owners"),
                ("GET", "/v0/tenants"),
                ("GET", "/v0/tenants/{tenant_id}"),
                ("PATCH", "/v0/tenants/{tenant_id}"),
                ("POST", "/v0/tenants"),
            ]
        );
    }

    #[test]
    fn unknown_route_is_denied() {
        let p = AuthenticatedPrincipal::for_test(Role::Owner);
        assert!(authorize("GET", true, "/v0/does/not/exist", Some(&p)).is_err());
    }

    /// A path with no route and no table entry is answered by the guard as a
    /// 404 rather than handed on, so nothing reaches a handler unclassified.
    #[test]
    fn unrouted_path_is_answered_not_passed_through() {
        let p = AuthenticatedPrincipal::for_test(Role::Owner);
        let resp = authorize("GET", false, "/v0/nonesuch", Some(&p)).unwrap_err();
        assert_eq!(resp.status(), actix_web::http::StatusCode::NOT_FOUND);
    }

    /// A real path reached with a method it does not serve is a 404, not a 403:
    /// `routed` is method-blind, but a wrong-method request is neither a
    /// permission denial nor the registered-route bug that logs an error.
    #[test]
    fn wrong_method_on_a_real_path_is_not_found() {
        let p = AuthenticatedPrincipal::for_test(Role::Owner);
        // `/v0/cluster_healthz` exists for GET only.
        let resp = authorize("POST", true, "/v0/cluster_healthz", Some(&p)).unwrap_err();
        assert_eq!(resp.status(), actix_web::http::StatusCode::NOT_FOUND);
    }

    /// Each refusal must carry the reason the audit line records, and a 404 must
    /// carry none. The middleware writes `denial.reason` straight into the log,
    /// so a branch that forgets to set it would emit `audit_reason = "-"` for a
    /// real denial and drop out of an alert written against `reason = "role"`.
    #[test]
    fn every_refusal_names_its_reason() {
        use actix_web::http::StatusCode;
        let reader = AuthenticatedPrincipal::for_test(Role::Read);

        let below = authorize("POST", true, "/v0/pipelines", Some(&reader)).unwrap_err();
        assert_eq!(below.status(), StatusCode::FORBIDDEN);
        assert_eq!(below.reason(), Some(DenyReason::Role));

        let anonymous = authorize("GET", true, "/v0/pipelines", None).unwrap_err();
        assert_eq!(anonymous.status(), StatusCode::FORBIDDEN);
        assert_eq!(anonymous.reason(), Some(DenyReason::Unauthenticated));

        // No route and no table entry: answered, not denied.
        let missing = authorize("GET", false, "/v0/nonesuch", Some(&reader)).unwrap_err();
        assert_eq!(missing.status(), StatusCode::NOT_FOUND);
        assert_eq!(missing.reason(), None);
    }

    #[test]
    fn role_floor_is_enforced() {
        let reader = AuthenticatedPrincipal::for_test(Role::Read);
        let writer = AuthenticatedPrincipal::for_test(Role::Write);
        // A write route rejects a reader and admits a writer.
        assert!(authorize("POST", true, "/v0/pipelines", Some(&reader)).is_err());
        assert!(authorize("POST", true, "/v0/pipelines", Some(&writer)).is_ok());
        // A read route admits a reader.
        assert!(authorize("GET", true, "/v0/pipelines", Some(&reader)).is_ok());
        // An owner-only route rejects an admin.
        let admin = AuthenticatedPrincipal::for_test(Role::Admin);
        assert!(authorize("GET", true, "/v0/tenants", Some(&admin)).is_err());
    }

    /// A concrete request path for a route template, with each `{name}`
    /// placeholder filled by a value that cannot be mistaken for a literal
    /// segment of some other pattern.
    fn concrete_path(pattern: &str) -> String {
        pattern
            .split('/')
            .map(|part| {
                if part.starts_with('{') && part.ends_with('}') {
                    format!("sample-{}", part.trim_matches(|c| c == '{' || c == '}'))
                } else {
                    part.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("/")
    }

    /// Every entry must be reachable from a real request path, under its own
    /// method: an entry that another pattern shadows is enforced with the wrong
    /// rule, or denied as unclassified. For example, `GET
    /// .../connectors/{connector_name}/completion_token` shares a path shape
    /// with `POST .../connectors/{connector_name}/{action}`.
    #[test]
    fn every_table_entry_resolves_from_a_concrete_path() {
        for (method, pattern, role, _) in ROUTE_MIN_ROLE {
            let path = concrete_path(pattern);
            let resolved = classify(method, &path);
            assert_eq!(
                resolved.map(|(p, r, _)| (p, r)),
                Some((*pattern, *role)),
                "{method} {path} resolved to {resolved:?}, expected {pattern}"
            );
        }
    }

    /// A literal segment wins over a placeholder, and a placeholder still
    /// catches everything else, so both siblings keep their own rule.
    #[test]
    fn a_literal_route_wins_over_a_placeholder_sibling() {
        let base = "/v0/pipelines/p/tables/t/connectors/c";
        assert_eq!(
            classify("GET", &format!("{base}/completion_token")).map(|(p, r, _)| (p, r)),
            Some((
                "/v0/pipelines/{pipeline_name}/tables/{table_name}/connectors/{connector_name}/completion_token",
                Role::Write
            ))
        );
        assert_eq!(
            classify("GET", &format!("{base}/stats")).map(|(p, r, _)| (p, r)),
            Some((
                "/v0/pipelines/{pipeline_name}/tables/{table_name}/connectors/{connector_name}/stats",
                Role::Read
            ))
        );
        assert_eq!(
            classify("POST", &format!("{base}/start")).map(|(p, r, _)| (p, r)),
            Some((
                "/v0/pipelines/{pipeline_name}/tables/{table_name}/connectors/{connector_name}/{action}",
                Role::Write
            ))
        );
        // The method is part of the match: no GET entry has that shape.
        assert_eq!(classify("GET", &format!("{base}/start")), None);

        // The output connector routes overlap the same way, with `command` as
        // the literal sibling of the action placeholder.
        let view_base = "/v0/pipelines/p/views/v/connectors/c";
        assert_eq!(
            classify("POST", &format!("{view_base}/command")).map(|(p, r, _)| (p, r)),
            Some((
                "/v0/pipelines/{pipeline_name}/views/{view_name}/connectors/{connector_name}/command",
                Role::Write
            ))
        );
        assert_eq!(
            classify("POST", &format!("{view_base}/pause")).map(|(p, r, _)| (p, r)),
            Some((
                "/v0/pipelines/{pipeline_name}/views/{view_name}/connectors/{connector_name}/{action}",
                Role::Write
            ))
        );
    }

    /// Systematic matrix: for every classified route and every role, a request
    /// is admitted iff the role meets the route's minimum, and refused
    /// otherwise. This is the exhaustive "only the correct role can access each
    /// endpoint" check. Reverting any `Role::*` in the table, or breaking the
    /// `>=` comparison, makes this fail.
    #[test]
    fn every_route_admits_exactly_its_minimum_role() {
        let all_roles = [Role::Read, Role::Write, Role::Admin, Role::Owner];
        for (method, pattern, required, _) in ROUTE_MIN_ROLE {
            for role in all_roles {
                let principal = AuthenticatedPrincipal::for_test(role);
                let allowed =
                    authorize(method, true, &concrete_path(pattern), Some(&principal)).is_ok();
                let expected = role >= *required;
                assert_eq!(
                    allowed, expected,
                    "{method} {pattern}: role {role} allowed={allowed}, expected={expected} (min={required})"
                );
            }
            // A request with no principal at all is always refused on a
            // classified route.
            assert!(
                authorize(method, true, &concrete_path(pattern), None).is_err(),
                "{method} {pattern}: missing principal must be denied"
            );
        }
    }

    /// A route that can change something never admits `read`. The exceptions
    /// are the POSTs that compile or profile: they take a body but leave no
    /// data or state behind.
    /// Profiling is the one POST a reader may reach: it acts on a pipeline the
    /// reader can already observe, and a bounded duration, not the role, is
    /// what limits its cost. The compile routes are not exempt, because they
    /// hand a caller-supplied program to the shared compiler.
    #[test]
    fn a_mutating_route_never_admits_read() {
        let posts_a_reader_may_make = ["/v0/pipelines/{pipeline_name}/samply_profile"];
        for (method, pattern, required, _) in ROUTE_MIN_ROLE {
            if *method == "GET" || posts_a_reader_may_make.contains(pattern) {
                continue;
            }
            assert!(
                *required >= Role::Write,
                "{method} {pattern} admits {required}; a mutating route needs at least write"
            );
        }
    }

    /// Independent pin of the most security-sensitive classifications, so an
    /// accidental downgrade in the table is caught here regardless of the
    /// self-consistent matrix test above. Revert any of these table entries and
    /// this fails.
    #[test]
    fn security_critical_routes_have_expected_minimums() {
        let expect = |method, pattern, role| {
            assert_eq!(
                min_role_for(method, pattern),
                Some(role),
                "{method} {pattern}"
            );
        };
        // Data plane and mutations require write; read must never reach them.
        expect("POST", "/v0/pipelines", Role::Write);
        expect("DELETE", "/v0/pipelines/{pipeline_name}", Role::Write);
        expect("POST", "/v0/pipelines/{pipeline_name}/start", Role::Write);
        expect("POST", "/v0/pipelines/{pipeline_name}/stop", Role::Write);
        expect("POST", "/v0/pipelines/{pipeline_name}/clear", Role::Write);
        expect(
            "POST",
            "/v0/pipelines/{pipeline_name}/ingress/{table_name}",
            Role::Write,
        );
        expect(
            "POST",
            "/v0/pipelines/{pipeline_name}/egress/{table_name}",
            Role::Write,
        );
        expect("GET", "/v0/pipelines/{pipeline_name}/query", Role::Write);
        // Compiling a caller-supplied program is write authority, even though
        // neither route persists anything.
        expect("POST", "/v0/validate_program", Role::Write);
        expect("POST", "/v0/pipelines/{pipeline_name}/diff", Role::Write);
        expect(
            "POST",
            "/v0/pipelines/{pipeline_name}/start_transaction",
            Role::Write,
        );
        // Monitoring is read.
        expect("GET", "/v0/pipelines", Role::Read);
        expect("GET", "/v0/pipelines/{pipeline_name}/stats", Role::Read);
        expect("GET", "/v0/pipelines/{pipeline_name}/logs", Role::Read);
        // Identity administration is admin.
        expect("POST", "/v0/oidc_trust", Role::Admin);
        expect("GET", "/v0/tenant/users", Role::Admin);
        // Platform administration is owner.
        expect("GET", "/v0/tenants", Role::Owner);
        expect("POST", "/v0/tenants", Role::Owner);
        expect("GET", "/v0/tenants/{tenant_id}", Role::Owner);
    }

    /// End-to-end through a real actix pipeline: the middleware short-circuits
    /// with 403 below the minimum role and passes through at or above it. This
    /// exercises `match_pattern`, the response/body unification, and the wrap
    /// ordering that the unit tests above cannot. Reverting the `.wrap(rbac)` in
    /// `build_app` would make the deny cases return 200 here.
    #[actix_web::test]
    async fn middleware_enforces_in_a_real_pipeline() {
        use actix_web::middleware::from_fn;
        use actix_web::{App, HttpResponse, test, web};
        use std::str::FromStr;

        // Installs a principal whose role comes from the `x-test-role` header,
        // standing in for `auth_validator`.
        async fn install_principal(
            req: ServiceRequest,
            next: Next<impl MessageBody + 'static>,
        ) -> Result<ServiceResponse<BoxBody>, actix_web::Error> {
            if let Some(role) = req
                .headers()
                .get("x-test-role")
                .and_then(|h| h.to_str().ok())
                .and_then(|s| Role::from_str(s).ok())
            {
                req.extensions_mut()
                    .insert(AuthenticatedPrincipal::for_test(role));
            }
            Ok(next.call(req).await?.map_into_boxed_body())
        }

        let app = test::init_service(
            App::new().service(
                web::scope("/v0")
                    .wrap(from_fn(rbac_middleware))
                    .wrap(from_fn(install_principal))
                    .route(
                        "/pipelines",
                        web::get().to(|| async { HttpResponse::Ok().finish() }),
                    )
                    .route(
                        "/pipelines",
                        web::post().to(|| async { HttpResponse::Ok().finish() }),
                    )
                    .route(
                        "/tenants",
                        web::get().to(|| async { HttpResponse::Ok().finish() }),
                    )
                    // Registered in the same order as the real app: the
                    // placeholder route first, the literal one behind it.
                    .route(
                        "/pipelines/{pipeline_name}/tables/{table_name}/connectors/{connector_name}/{action}",
                        web::post().to(|| async { HttpResponse::Ok().finish() }),
                    )
                    .route(
                        "/pipelines/{pipeline_name}/tables/{table_name}/connectors/{connector_name}/completion_token",
                        web::get().to(|| async { HttpResponse::Ok().finish() }),
                    )
                    // Stands in for "a handler ran": a request the guard
                    // passes through without classifying lands here as 200.
                    .default_service(web::to(|| async { HttpResponse::Ok().finish() })),
            ),
        )
        .await;

        let call = |method: &str, path: &str, role: &str| {
            let req = match method {
                "POST" => test::TestRequest::post(),
                _ => test::TestRequest::get(),
            }
            .uri(path)
            .insert_header(("x-test-role", role))
            .to_request();
            test::call_service(&app, req)
        };

        // read may GET pipelines but not POST; write may POST.
        assert_eq!(call("GET", "/v0/pipelines", "read").await.status(), 200);
        assert_eq!(call("POST", "/v0/pipelines", "read").await.status(), 403);
        assert_eq!(call("POST", "/v0/pipelines", "write").await.status(), 200);
        // owner-only tenant list: admin refused, owner admitted.
        assert_eq!(call("GET", "/v0/tenants", "admin").await.status(), 403);
        assert_eq!(call("GET", "/v0/tenants", "owner").await.status(), 200);

        // Shadowed route: `GET .../completion_token` shares its path shape with
        // `POST .../{action}`, registered first, and keeps its own rule anyway.
        let token = "/v0/pipelines/p/tables/t/connectors/c/completion_token";
        assert_eq!(call("GET", token, "write").await.status(), 200);
        assert_eq!(call("GET", token, "read").await.status(), 403);
        assert_eq!(
            call(
                "POST",
                "/v0/pipelines/p/tables/t/connectors/c/start",
                "write"
            )
            .await
            .status(),
            200
        );

        // An alternate spelling of a route that actix still dispatches to the
        // same handler carries the same role floor: the guard classifies the
        // decoded path the router uses, so it holds for either spelling.
        assert_eq!(call("POST", "/v0/%70ipelines", "read").await.status(), 403);
        assert_eq!(call("POST", "/v0/%70ipelines", "write").await.status(), 200);
        assert_eq!(call("GET", "/v0/%74enants", "admin").await.status(), 403);
        assert_eq!(call("GET", "/v0/%74enants", "owner").await.status(), 200);

        // No pass-through: a path nothing routes is answered 404 by the guard
        // and never reaches the scope's fallback handler, even for an owner.
        assert_eq!(call("GET", "/v0/nonesuch", "owner").await.status(), 404);
    }

    /// The authenticated `/v0` surface, enumerated from the generated OpenAPI
    /// document (the single source of truth for what `api_scope()` registers).
    /// Paths outside `/v0` are unauthenticated (public scope) and not gated.
    fn openapi_v0_routes() -> Vec<(String, String)> {
        use crate::api::main::ApiDoc;
        use utoipa::OpenApi;
        use utoipa::openapi::PathItemType;

        let method = |t: &PathItemType| match t {
            PathItemType::Get => "GET",
            PathItemType::Post => "POST",
            PathItemType::Put => "PUT",
            PathItemType::Delete => "DELETE",
            PathItemType::Patch => "PATCH",
            PathItemType::Head => "HEAD",
            PathItemType::Options => "OPTIONS",
            PathItemType::Trace => "TRACE",
            PathItemType::Connect => "CONNECT",
        };
        ApiDoc::openapi()
            .paths
            .paths
            .into_iter()
            .filter(|(path, _)| path.starts_with("/v0"))
            .flat_map(|(path, item)| {
                item.operations
                    .keys()
                    .map(|t| (method(t).to_string(), path.clone()))
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    /// Routes registered in `api_scope()` but absent from the OpenAPI document
    /// (`ApiDoc::paths()`), so the OpenAPI-driven meta-tests must account for
    /// them explicitly. They are still classified in `ROUTE_MIN_ROLE`, so RBAC
    /// covers them; they are only invisible to the OpenAPI enumeration:
    /// - `.../testing`: a test-only hook intentionally hidden from the spec.
    const REGISTERED_BUT_UNDOCUMENTED: &[(&str, &str)] =
        &[("POST", "/v0/pipelines/{pipeline_name}/testing")];

    /// Deny-by-default has teeth only if every registered route is classified.
    /// Enumerate the `/v0` surface from the OpenAPI document (which mirrors
    /// `api_scope()`, save the explicit `REGISTERED_BUT_UNDOCUMENTED` set) and
    /// fail the build if any route lacks a `ROUTE_MIN_ROLE` entry. A new endpoint
    /// added without a classification breaks this test rather than silently
    /// shipping 403.
    #[test]
    fn every_registered_v0_route_is_classified() {
        let table: std::collections::HashSet<(&str, &str)> =
            ROUTE_MIN_ROLE.iter().map(|(m, p, _, _)| (*m, *p)).collect();
        let mut unclassified = vec![];
        for (method, path) in openapi_v0_routes() {
            if !table.contains(&(method.as_str(), path.as_str())) {
                unclassified.push(format!("{method} {path}"));
            }
        }
        unclassified.sort();
        assert!(
            unclassified.is_empty(),
            "these registered /v0 routes have no ROUTE_MIN_ROLE entry (add one, or they 403 for everyone):\n  {}",
            unclassified.join("\n  ")
        );
    }

    /// The reverse guard: every table entry must name a real registered route,
    /// so a stale entry (renamed/removed endpoint) is caught instead of lingering.
    #[test]
    fn no_stale_route_table_entries() {
        let mut registered: std::collections::HashSet<(String, String)> =
            openapi_v0_routes().into_iter().collect();
        registered.extend(
            REGISTERED_BUT_UNDOCUMENTED
                .iter()
                .map(|(m, p)| (m.to_string(), p.to_string())),
        );
        let mut stale = vec![];
        for (method, path, _, _) in ROUTE_MIN_ROLE {
            if !registered.contains(&(method.to_string(), path.to_string())) {
                stale.push(format!("{method} {path}"));
            }
        }
        stale.sort();
        assert!(
            stale.is_empty(),
            "these ROUTE_MIN_ROLE entries do not match any registered /v0 route (remove or fix them):\n  {}",
            stale.join("\n  ")
        );
    }

    /// The tenant dimension costs nothing on the request path: it rides out of
    /// the same classification that resolves the role, as a field of the row
    /// rather than a second lookup.
    ///
    /// This measures that claim instead of asserting it. If someone re-adds a
    /// separate tenant lookup, or turns the scope into an allocation, the
    /// classification stops being a single pass over the candidates and this
    /// ratio moves. The work order for the feature allows a 3% regression.
    #[test]
    fn the_tenant_dimension_adds_nothing_to_classification() {
        use std::hint::black_box;
        use std::time::Instant;

        // The busiest shape in the table, so each iteration compares against a
        // realistic candidate set rather than a single entry.
        let path = "/v0/pipelines/sample-pipeline/metrics";
        let method = "GET";

        // Warm the shape index so its construction is not measured.
        assert!(classify(method, path).is_some());

        let run = |baseline: bool| {
            let mut sink = 0usize;
            // Short loops so the minimum of many runs can be used; the noise
            // this guards against (a scheduler slice, a collection from another
            // test) only ever adds time, so the minimum is the cleanest
            // estimate of what the code actually costs.
            let start = Instant::now();
            for _ in 0..1_000 {
                if let Some((pattern, role, scope)) = classify(black_box(method), black_box(path)) {
                    sink += pattern.len();
                    // The baseline reads only what the role axis already needed;
                    // the measured arm also reads the tenant axis. Both are
                    // fields of the same row, so a difference means the scope
                    // stopped being free.
                    sink += role as usize;
                    if !baseline {
                        sink += match scope {
                            TenantScope::Tenant => 1,
                            TenantScope::Platform => 2,
                        };
                    }
                }
            }
            black_box(sink);
            start.elapsed()
        };

        // The fastest run of each arm. A ratio of two medians is not usable
        // here: the two arms differ by a field read, which is well under the
        // resolution of a clock sample, so any consistent bias in the loop
        // shows up as noise either way.
        let floor = |baseline: bool| -> std::time::Duration {
            (0..31).map(|_| run(baseline)).min().expect("the loop runs")
        };
        let base = floor(true);
        let scoped = floor(false);

        // The work order allows a 3% regression, and the field read measured
        // against that. This assertion is deliberately looser than 3%: a wall
        // clock in a unit test cannot certify 3% (the whole difference is one
        // field read against a clock whose resolution is larger than it, and
        // a loaded test binary adds tens of percent of jitter at random). What
        // it can do reliably is catch the regression it was written for -- a
        // second lookup -- which roughly doubles the work per request.
        let budget = base.mul_f64(0.30);
        let added = scoped.saturating_sub(base);
        assert!(
            added <= budget,
            "reading the tenant scope added {added:?} to classification (baseline {base:?}, \
             with scope {scoped:?}); this is far more than reading one field, so the scope has \
             stopped being a field of the route row and become a second lookup.",
        );
    }

    fn every_v0_operation_documents_its_min_role() {
        use crate::api::main::ApiDoc;
        use utoipa::OpenApi;
        use utoipa::openapi::PathItemType;

        let method = |t: &PathItemType| match t {
            PathItemType::Get => "GET",
            PathItemType::Post => "POST",
            PathItemType::Put => "PUT",
            PathItemType::Delete => "DELETE",
            PathItemType::Patch => "PATCH",
            PathItemType::Head => "HEAD",
            PathItemType::Options => "OPTIONS",
            PathItemType::Trace => "TRACE",
            PathItemType::Connect => "CONNECT",
        };
        let doc = ApiDoc::openapi();
        let mut missing = vec![];
        for (path, item) in doc.paths.paths.iter() {
            if !path.starts_with("/v0") {
                continue;
            }
            for (t, operation) in item.operations.iter() {
                let has_note = operation
                    .description
                    .as_deref()
                    .is_some_and(|d| d.contains("Required role:"));
                if !has_note {
                    missing.push(format!("{} {path}", method(t)));
                }
            }
        }
        missing.sort();
        assert!(
            missing.is_empty(),
            "these /v0 operations are missing the minimum-role annotation:\n  {}",
            missing.join("\n  ")
        );
    }
    /// A request that fails authentication is recorded, even though the guard
    /// that records the decision never sees it.
    ///
    /// This is the case the audit trail is most likely to miss and least able
    /// to afford missing: `auth_validator` answers 401 from inside actix's
    /// credential extractor, before any middleware wrapped inside it runs, so a
    /// caller who sends no credential -- or a malformed one -- would otherwise
    /// leave no trace at all.
    ///
    /// The test drives `build_app`, the same composition that ships, so it pins
    /// the wiring and not just the function: unwrap the guard from `build_app`
    /// (or wrap it anywhere but outermost) and this fails, because no event is
    /// recorded for the 401.
    #[actix_web::test]
    async fn an_unauthenticated_request_is_recorded_by_the_outer_guard() {
        use crate::auth::{AuthConfiguration, AuthProvider, ProviderGenericOidc};
        use crate::config::ApiServerConfig;

        let issuer = "http://issuer.invalid/realms/test";
        let auth_configuration = Some(AuthConfiguration {
            provider: AuthProvider::GenericOidc(ProviderGenericOidc {
                issuer: issuer.to_string(),
                client_id: "feldera-console".to_string(),
                extra_oidc_scopes: vec![],
                jwk_uri: format!("{issuer}/protocol/openid-connect/certs"),
            }),
            validation: crate::auth::login_validation(issuer, Some("feldera-console")),
            client_id: "feldera-console".to_string(),
        });
        let app = actix_web::test::init_service(crate::api::main::build_app(
            &ApiServerConfig::test_config(),
            &auth_configuration,
        ))
        .await;

        let _ = crate::api::audit::take_recorded();
        let response = actix_web::test::call_service(
            &app,
            actix_web::test::TestRequest::get()
                .uri("/v0/pipelines")
                .to_request(),
        )
        .await;
        assert_eq!(
            response.status(),
            actix_web::http::StatusCode::UNAUTHORIZED,
            "a request with no credential is refused by authentication, not by the guard"
        );

        let recorded = crate::api::audit::take_recorded();
        assert_eq!(
            recorded.len(),
            1,
            "the 401 left no audit event; an attempt with no credential is the \
             one an auditor most wants, and without the outer guard it is invisible"
        );
        let event = &recorded[0];
        assert_eq!(event.decision, "deny");
        assert_eq!(event.reason, "unauthenticated");
        assert_eq!(event.principal, "-", "no principal was established");
        assert_eq!(event.method, "GET");
        assert_eq!(event.route, "/v0/pipelines");
        assert_eq!(event.required_role, "read");
    }

    /// A path the table cannot classify is refused before any route is
    /// resolved, so it reaches the guard as a 401 too -- and records nothing,
    /// because there was no access decision to record. Without this the audit
    /// trail would fill with probing of invented paths.
    #[actix_web::test]
    async fn an_unclaimed_path_is_recorded_by_nothing() {
        use crate::auth::{AuthConfiguration, AuthProvider, ProviderGenericOidc};
        use crate::config::ApiServerConfig;

        let issuer = "http://issuer.invalid/realms/test";
        let auth_configuration = Some(AuthConfiguration {
            provider: AuthProvider::GenericOidc(ProviderGenericOidc {
                issuer: issuer.to_string(),
                client_id: "feldera-console".to_string(),
                extra_oidc_scopes: vec![],
                jwk_uri: format!("{issuer}/protocol/openid-connect/certs"),
            }),
            validation: crate::auth::login_validation(issuer, Some("feldera-console")),
            client_id: "feldera-console".to_string(),
        });
        let app = actix_web::test::init_service(crate::api::main::build_app(
            &ApiServerConfig::test_config(),
            &auth_configuration,
        ))
        .await;

        let _ = crate::api::audit::take_recorded();
        let response = actix_web::test::call_service(
            &app,
            actix_web::test::TestRequest::get()
                .uri("/v0/nonesuch")
                .to_request(),
        )
        .await;
        assert_eq!(response.status(), actix_web::http::StatusCode::UNAUTHORIZED);
        assert!(
            crate::api::audit::take_recorded().is_empty(),
            "an unclaimed path is not an access decision and must not be recorded"
        );
    }
}
