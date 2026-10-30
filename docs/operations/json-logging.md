# Structured logging and the audit trail

The control plane writes two streams to stdout: its ordinary log, and the audit
trail. Both are structured events; this page says what each is for, how to turn
them on, and how to query them.

## Which stream is which

| stream | target | what it answers |
|---|---|---|
| request log | `pipeline_manager` | why something was slow or failed |
| audit trail | `feldera_audit` | who did what, in what order, and who was refused |

The two are separate `tracing` targets, so a log platform can give them
different retention and different access without splitting the collector. The
audit trail is the one to keep for a year; the request log is the one to keep
for a week.

## Turning on JSON

`logJson` (default `true` in the chart) sets `FELDERA_LOG_JSON=1`, which makes
the manager emit one JSON object per line:

```json
{"timestamp":"2026-10-30T03:21:18.442Z","level":"INFO","fields":{"audit_event":"access","audit_decision":"deny","audit_principal":"apikey:ci","audit_tenant":"00000000-0000-0000-0000-000000000000","audit_tenant_scope":"tenant","audit_role":"read","audit_required_role":"write","audit_method":"POST","audit_route":"/v0/pipelines","audit_reason":"role"},"target":"feldera_audit","span":{},"spans":[],"threadId":"actix-rt|system:0|arbiter:3","threadName":"actix-server worker 0"}
```

It is on by default because an audit trail that ships off is not an audit
trail. The format is a consumer choice, and the platform ingests JSON, so the
setting that makes the trail queryable is the one that ships enabled. Turn it
off only for a deployment whose log platform takes the plain-text format:

```bash
helm upgrade feldera charts/feldera --reuse-values --set controlplane.logJson=false
```

With it off the audit events are still written -- they are no longer
*filterable*. The event becomes a formatted text line, and a query for
`audit_principal = "apikey:ci"` cannot find it. This is the one setting where
the wrong value silently removes your audit trail rather than breaking loudly,
which is why the default is on and `scripts/e2e-k8s-chart.sh` asserts the wire
in both directions.

## The fields

Every event has these keys, all flat strings so a log platform can index them
without a schema:

| key | values |
|---|---|
| `audit_event` | `access` today; the field exists so other kinds can be added |
| `audit_decision` | `allow` or `deny` |
| `audit_principal` | `apikey:<name>`, an OIDC email or subject, or `-` for none |
| `audit_tenant` | the tenant the request acted in, or `-` |
| `audit_tenant_scope` | `tenant` (one tenant's data) or `platform` (the installation) |
| `audit_role` | the principal's effective role, or `-` |
| `audit_required_role` | the minimum role the route demands |
| `audit_method`, `audit_route` | the request; the route is the table pattern |
| `audit_reason` | for a denial: `role`, `unauthenticated`, `unclassified`; else `-` |

Two of these are worth a note.

**`audit_route` is the pattern, not the path.** A tenant route records
`/v0/pipelines/{pipeline_name}`, never the name that was used. A pipeline name
can itself be sensitive, and the pattern is what a reviewer reasons about. For
the one case with no pattern -- a path the access-control table does not
classify -- the value is `(unclassified path)`, for the same reason.

**`apikey:<name>` names the key.** Every API key used to record the constant
`apikey`, which made two keys of one tenant indistinguishable and made the
replay below impossible. The name is the identity a query filters on.

## Reading it

The work order's acceptance is "an audit query can replay one principal's
sequence of operations". In a log platform that is one filter and an
order-by:

```
audit_principal = "apikey:ci" | sort by timestamp
```

Without a log platform, from the pod:

```bash
kubectl -n feldera logs -l app.kubernetes.io/name=controlplane -c api-server --tail=-1 \
  | jq -c 'select(.target == "feldera_audit" and .fields.audit_principal == "apikey:ci")
           | {t: .timestamp, m: .fields.audit_method, r: .fields.audit_route,
              d: .fields.audit_decision, why: .fields.audit_reason}'
```

```
{"t":"2026-10-30T03:21:02.114Z","m":"GET","r":"/v0/api_keys","d":"allow","why":"-"}
{"t":"2026-10-30T03:21:03.256Z","m":"POST","r":"/v0/pipelines","d":"allow","why":"-"}
{"t":"2026-10-30T03:21:04.377Z","m":"GET","r":"/v0/pipelines/{pipeline_name}","d":"allow","why":"-"}
```

That is the replay: three operations, in order, by one key.

Denials are the other query an auditor runs, and the more interesting one:

```bash
kubectl -n feldera logs -l app.kubernetes.io/name=controlplane -c api-server --tail=-1 \
  | jq -c 'select(.target == "feldera_audit" and .fields.audit_decision == "deny")
           | {t: .timestamp, p: .fields.audit_principal, m: .fields.audit_method,
              r: .fields.audit_route, why: .fields.audit_reason}'
```

An alert on `audit_reason = "unauthenticated"` firing repeatedly from one
source address is the shape of a credential-stuffing attempt;
`audit_reason = "role"` clustered on one principal is the shape of someone
probing for a permission they do not have.

## What is not recorded

Three omissions are deliberate:

* **A path no route serves.** A 404 is not a denial: no route claims it, no
  access decision was made. Recording them would bury real denials under
  probing traffic.
* **The request body and the query string.** They carry SQL, pipeline
  parameters and, in a bad day, credentials. The audit trail records *that* an
  operation ran, not its contents.
* **The source address.** The manager sees the pod network, where every request
  arrives from the ingress or the API server's own address; recording it would
  look authoritative and be useless. Put address attribution in the ingress or
  the service mesh, where the real client address is known.

## Retaining it

The trail is on stdout like everything else, so retention is the log platform's
job and this chart does not pretend to do it. The recommendation in the
platform plan (design/self-hosted-enterprise-platform-plan.md §5.8) is that the
audit target gets its own retention class, longer than the request log, because
the two answer questions with different horizons.

## Proving it works

`scripts/e2e-k8s-audit.sh` reads the running manager's stdout and asserts, in
order: JSON logs are on; two keys of one tenant are two principals; one key's
three operations appear in the log in request order; a denied request is
recorded with its reason; a request with no credential is recorded with no
principal. It reads the log, not the code, because the claim is about the log.

## A note on the build

The manager's JSON formatter is `crates/feldera-observability`'s, and it writes
every non-`message` field into a `fields` object keyed by the field's name. That
is why the audit events use underlined field names (`audit_principal`) rather
than dotted ones (`audit.principal`): `tracing` reads `a.b = v` in a macro as a
nested path and rejects it against a custom event format, while the JSON
formatter would copy whatever key the visitor saw. One spelling avoids the
ambiguity entirely.

`crates/pipeline-manager/src/api/audit.rs` carries a test
(`the_json_formatter_emits_the_audit_fields_flat`) that installs the real JSON
subscriber over an in-memory writer and parses the output, so the on-disk shape
is asserted rather than assumed.

## Unauthenticated requests

A request that carries no credential, or one the extractor rejects, is answered
401 by authentication before any access-control middleware inside it runs. An
outer guard records those too, with `audit.principal` = `-` and
`audit.reason` = `unauthenticated`: a denial with a credential that did not work
is what a brute-force attempt looks like from here, and it would otherwise be
the one case missing from the log.

Two limits are deliberate. The guard cannot name the caller, because
authentication is what failed — there is no principal to name, and inventing one
from an unverified token claim would let an attacker choose their own audit
identity. And a path the route table does not classify records nothing: it is
not an access decision, and logging it would bury real denials under probing of
invented paths.
