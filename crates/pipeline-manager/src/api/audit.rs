//! The control-plane audit trail.
//!
//! Every `/v0` decision the access-control middleware makes -- allow or deny --
//! is recorded here as one structured event, so an operator can answer "what
//! did this principal do, in order" from the log platform rather than from the
//! database. The work order's acceptance test is exactly that: replay one
//! principal's sequence of operations by querying the log.
//!
//! The events are `tracing` events at `info` on target [`AUDIT_TARGET`], which
//! makes them a separate stream an operator can route on their own: the
//! platform's request log is `info` too, but these carry `audit.*` fields and a
//! fixed target, so a log platform filter can keep them out of the noise and
//! give them their own retention.
//!
//! Fields, all flat strings so a log platform can index and filter them without
//! knowing the schema:
//!
//! | field | meaning |
//! |---|---|
//! | `audit.event` | `"access"`; one value today, room for others (config changes, key minting) |
//! | `audit.decision` | `"allow"` or `"deny"` |
//! | `audit.principal` | who: `apikey:<name>`, an OIDC email/sub, or `oidc:<sub>` |
//! | `audit.tenant` | the tenant the request acted in |
//! | `audit.tenant_scope` | `"tenant"` (one tenant's data) or `"platform"` (the installation) |
//! | `audit.role` | the principal's effective role there, or `"-"` when unauthenticated |
//! | `audit.required_role` | the minimum role the route demands |
//! | `audit.method`, `audit.route` | the request; `audit.route` is the table pattern, never the raw path |
//! | `audit.reason` | for a denial, why (`role`, `unauthenticated`, `unclassified`) |
//!
//! Two properties are deliberate:
//!
//! * The raw request path is not recorded for tenant routes, only the pattern
//!   (`/v0/pipelines/{pipeline_name}`). A pipeline name can itself be sensitive,
//!   and the pattern is what a reviewer reasons about.
//! * An unauthenticated denial still records the method and route, with
//!   `principal = "-"`. Denials are the events an auditor most wants, and they
//!   are the ones most likely to involve a principal that failed to
//!   authenticate.

use crate::auth::AuthenticatedPrincipal;
use crate::db::types::role::Role;

/// The `tracing` target every audit event carries. Log configuration and the
/// log platform filter on this value.
pub const AUDIT_TARGET: &str = "feldera_audit";

/// The decision an access-control check reached.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny,
}

impl Decision {
    pub fn as_str(self) -> &'static str {
        match self {
            Decision::Allow => "allow",
            Decision::Deny => "deny",
        }
    }
}

/// Why a request was denied. Kept as a small closed set so a log platform can
/// alert on a reason without parsing prose.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DenyReason {
    /// The principal's role is below the route's minimum.
    Role,
    /// No principal was installed: the request carried no usable credential.
    Unauthenticated,
    /// The path is served by a route the access-control table does not classify.
    Unclassified,
}

impl DenyReason {
    pub fn as_str(self) -> &'static str {
        match self {
            DenyReason::Role => "role",
            DenyReason::Unauthenticated => "unauthenticated",
            DenyReason::Unclassified => "unclassified",
        }
    }
}

/// Whether a route draws on one tenant's data or the installation's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TenantScope {
    Tenant,
    Platform,
}

impl TenantScope {
    pub fn as_str(self) -> &'static str {
        match self {
            TenantScope::Tenant => "tenant",
            TenantScope::Platform => "platform",
        }
    }
}

/// One access-control decision, ready to record.
///
/// Built by the middleware and passed to [`record`]. Holding it as a value
/// rather than calling `info!` at each decision point keeps the field set in
/// one place, so an allow and a deny cannot drift into different shapes -- a
/// log platform query that filters on `audit.decision` then sees every event.
#[derive(Clone, Copy, Debug)]
pub struct AccessEvent<'a> {
    pub decision: Decision,
    pub principal: Option<&'a AuthenticatedPrincipal>,
    pub method: &'a str,
    /// The access-control table pattern, e.g. `/v0/pipelines/{pipeline_name}`.
    pub route: &'a str,
    pub scope: Option<TenantScope>,
    /// The route's minimum role, `None` when the route is unclassified.
    pub required_role: Option<Role>,
    pub reason: Option<DenyReason>,
}

/// What one recorded event looked like, flattened the way the log shows it.
///
/// Tests assert against this rather than against emitted `tracing` output: the
/// question a middleware test asks is "was a decision of this shape recorded",
/// and a subscriber that captures formatted fields answers a different one.
#[cfg(test)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Recorded {
    pub decision: &'static str,
    pub principal: String,
    pub method: String,
    pub route: String,
    pub scope: &'static str,
    pub required_role: &'static str,
    pub reason: &'static str,
}

#[cfg(test)]
thread_local! {
    /// Events recorded on the current test thread, so concurrent tests do not
    /// read each other's audit trails.
    static RECORDED: std::cell::RefCell<Vec<Recorded>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Take and clear what the current test thread recorded.
#[cfg(test)]
pub fn take_recorded() -> Vec<Recorded> {
    RECORDED.with(|r| std::mem::take(&mut *r.borrow_mut()))
}

/// Record the event. Emits one `info` event on [`AUDIT_TARGET`] carrying only
/// flat fields, so a log platform can index each without a schema.
pub fn record(event: &AccessEvent<'_>) {
    let (principal, tenant, role) = match event.principal {
        Some(p) => (
            p.label.as_str(),
            p.acting_tenant.to_string(),
            p.role.as_str(),
        ),
        None => ("-", "-".to_string(), "-"),
    };
    let scope = event.scope.map(TenantScope::as_str).unwrap_or("-");
    let required = event.required_role.map(|r| r.as_str()).unwrap_or("-");
    let reason = event.reason.map(DenyReason::as_str).unwrap_or("-");

    #[cfg(test)]
    {
        let flattened = Recorded {
            decision: event.decision.as_str(),
            principal: principal.to_string(),
            method: event.method.to_string(),
            route: event.route.to_string(),
            scope,
            required_role: required,
            reason,
        };
        RECORDED.with(|r| r.borrow_mut().push(flattened));
    }

    // Field names use underscores, not dots: a dotted name is valid JSON either
    // way, but the tracing macro reads `a.b = v` as a nested field path, and the
    // JSON formatter writes the visitor's keys verbatim -- so a dot would arrive
    // as a literal `audit.decision` key while the macro saw `audit` -> `decision`.
    // One spelling, no ambiguity.
    tracing::info!(
        target: AUDIT_TARGET,
        audit_event = "access",
        audit_decision = event.decision.as_str(),
        audit_principal = principal,
        audit_tenant = tenant.as_str(),
        audit_tenant_scope = scope,
        audit_role = role,
        audit_required_role = required,
        audit_method = event.method,
        audit_route = event.route,
        audit_reason = reason,
        "audit"
    );
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::db::types::tenant::TenantId;
    use uuid::Uuid;

    fn principal(label: &str, role: Role) -> AuthenticatedPrincipal {
        AuthenticatedPrincipal {
            acting_tenant: TenantId(Uuid::nil()),
            role,
            label: label.to_string(),
        }
    }

    /// Every decision shape must name a principal or say it has none, and must
    /// carry a route. These are the fields a replay query filters on, so a
    /// missing one silently drops the event from that query.
    #[test]
    fn every_event_carries_the_fields_a_replay_query_filters_on() {
        let p = principal("apikey:ci", Role::Write);
        let allow = AccessEvent {
            decision: Decision::Allow,
            principal: Some(&p),
            method: "POST",
            route: "/v0/pipelines",
            scope: Some(TenantScope::Tenant),
            required_role: Some(Role::Write),
            reason: None,
        };
        assert_eq!(allow.decision.as_str(), "allow");
        assert_eq!(allow.scope.unwrap().as_str(), "tenant");
        assert_eq!(allow.required_role.unwrap().as_str(), "write");
        assert_eq!(allow.reason.map(DenyReason::as_str).unwrap_or("-"), "-");

        // An unauthenticated denial is the event an auditor most wants, so it
        // must have a shape, not be skipped for lack of a principal.
        let deny = AccessEvent {
            decision: Decision::Deny,
            principal: None,
            method: "GET",
            route: "/v0/pipelines",
            scope: Some(TenantScope::Tenant),
            required_role: Some(Role::Read),
            reason: Some(DenyReason::Unauthenticated),
        };
        assert_eq!(deny.decision.as_str(), "deny");
        assert_eq!(deny.reason.unwrap().as_str(), "unauthenticated");
    }

    /// The event must survive the formatter the deployment actually runs, as
    /// JSON with the fields a log platform filters on.
    ///
    /// Checking the struct alone would not prove this: `tracing` turns a
    /// `field = value` argument into a *recorded field*, and the JSON formatter
    /// writes whatever the visitor collected. A field name the formatter rewrites,
    /// or a value it drops, would leave a struct that looks right and a log
    /// platform query that silently matches nothing.
    #[test]
    fn the_json_formatter_emits_the_audit_fields_flat() {
        use std::io::Write;
        use std::sync::{Arc, Mutex};

        // A writer that keeps the bytes so the test can parse them.
        #[derive(Clone)]
        struct Buffer(Arc<Mutex<Vec<u8>>>);
        impl Write for Buffer {
            fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(buf);
                Ok(buf.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }

        let buffer = Buffer(Arc::new(Mutex::new(Vec::new())));
        let writer = buffer.clone();
        let subscriber = tracing_subscriber::fmt()
            .json()
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .finish();

        let p = principal("apikey:ci", Role::Write);
        tracing::subscriber::with_default(subscriber, || {
            record(&AccessEvent {
                decision: Decision::Deny,
                principal: Some(&p),
                method: "DELETE",
                route: "/v0/pipelines/{pipeline_name}",
                scope: Some(TenantScope::Tenant),
                required_role: Some(Role::Admin),
                reason: Some(DenyReason::Role),
            });
        });

        let bytes = buffer.0.lock().unwrap().clone();
        let line = String::from_utf8(bytes).expect("the formatter wrote valid UTF-8");
        let json: serde_json::Value =
            serde_json::from_str(line.trim()).expect("the formatter wrote one JSON object");

        let field = |name: &str| {
            json.get("fields")
                .and_then(|f| f.get(name))
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| panic!("no `{name}` field in {json}"))
        };
        assert_eq!(field("audit_event"), "access");
        assert_eq!(field("audit_decision"), "deny");
        assert_eq!(field("audit_principal"), "apikey:ci");
        assert_eq!(field("audit_role"), "write");
        assert_eq!(field("audit_required_role"), "admin");
        assert_eq!(field("audit_method"), "DELETE");
        assert_eq!(field("audit_route"), "/v0/pipelines/{pipeline_name}");
        assert_eq!(field("audit_reason"), "role");
        assert_eq!(field("audit_tenant_scope"), "tenant");
        // The tenant is recorded from the principal, so a replay can confine a
        // query to one tenant without joining anything.
        assert!(!field("audit_tenant").is_empty());
    }

    /// The reason set is what alerts are written against, so each variant must
    /// render to a distinct stable token.
    #[test]
    fn deny_reasons_are_distinct_stable_tokens() {
        let tokens = [
            DenyReason::Role.as_str(),
            DenyReason::Unauthenticated.as_str(),
            DenyReason::Unclassified.as_str(),
        ];
        let unique: std::collections::HashSet<_> = tokens.iter().collect();
        assert_eq!(unique.len(), tokens.len(), "reasons collide: {tokens:?}");
        for t in tokens {
            assert!(
                t.chars().all(|c| c.is_ascii_lowercase() || c == '_'),
                "{t} is not a stable lowercase token"
            );
        }
    }
}
