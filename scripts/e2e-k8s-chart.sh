#!/usr/bin/env bash
#
# P1-019 acceptance, part 1: the chart's rendered values are a reviewed record.
#
# The Helm chart is the interface between an operator and the platform: a value
# that is misspelled is silently ignored, and a value that is rendered into the
# wrong flag starts a manager that behaves unlike the one that was asked for.
# Both are invisible in `helm lint`, so this test renders the chart and compares
# it with a recorded output. A change to the template then shows up as a diff to
# review rather than as a surprise in a cluster.
#
# The recorded file is charts/feldera/tests/golden/default.yaml. Regenerate it
# deliberately with GOLDEN_UPDATE=1 and read the diff:
#
#   GOLDEN_UPDATE=1 scripts/e2e-k8s-chart.sh
#
# The second half exercises the values.schema.json rejections the P1-019 work
# added: a values file the platform cannot honour must fail at render time.
set -euo pipefail

CHART="${CHART:-charts/feldera}"
GOLDEN="${GOLDEN:-charts/feldera/tests/golden/default.yaml}"
RELEASE="${RELEASE:-feldera}"
NAMESPACE="${NAMESPACE:-feldera}"

step() { printf '\n-- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*"; }

command -v helm >/dev/null || fail "helm is not on PATH"

# The database password is generated when it is not given, which is what keeps
# an upgrade from locking the manager out of a running Postgres. A generated
# value would make every render differ, so the golden comparison pins it: the
# recorded output is about which objects and fields the chart produces, not
# about a secret that is random by design.
render() {
  helm template "$RELEASE" "$CHART" -n "$NAMESPACE" \
    --set controlplane.postgresPassword=golden-render "$@"
}

step "render the default values"
rendered="$(render)"
[ -n "$rendered" ] || fail "the chart rendered nothing"

if [ "${GOLDEN_UPDATE:-0}" = "1" ]; then
  mkdir -p "$(dirname "$GOLDEN")"
  printf '%s\n' "$rendered" >"$GOLDEN"
  info "recorded $(printf '%s\n' "$rendered" | grep -c '' ) lines in $GOLDEN"
  exit 0
fi

[ -f "$GOLDEN" ] || fail "no recorded output at $GOLDEN; run with GOLDEN_UPDATE=1"
if ! diff -u "$GOLDEN" <(printf '%s\n' "$rendered") >/tmp/p1-019-golden.diff; then
  cat /tmp/p1-019-golden.diff >&2
  fail "the rendered chart differs from $GOLDEN; review the diff, then record it with GOLDEN_UPDATE=1"
fi
info "the rendered chart matches $GOLDEN"

step "leader election is off at one replica"
if printf '%s\n' "$rendered" | grep -q FELDERA_LEADER_ELECTION; then
  fail "a single replica must not pay for an election it has nothing to elect against"
fi
if printf '%s\n' "$rendered" | grep -q podAntiAffinity; then
  fail "a single replica has nothing to spread"
fi
info "no election and no anti-affinity at replicaCount=1"

step "two replicas elect a leader and are spread over nodes"
ha="$(render --set controlplane.replicaCount=2)"
printf '%s\n' "$ha" | grep -q 'FELDERA_LEADER_ELECTION' \
  || fail "two replicas without an election would each reconcile every pipeline"
printf '%s\n' "$ha" | grep -q 'preferredDuringSchedulingIgnoredDuringExecution' \
  || fail "two replicas must be spread over nodes when there are several"

# `required` is the production setting: it must reach the manifest when asked
# for, because an operator relying on it is relying on a refused schedule
# rather than on a hint the scheduler may ignore.
strict="$(render --set controlplane.replicaCount=2 --set controlplane.apiServerAntiAffinity=required)"
printf '%s\n' "$strict" | grep -q 'requiredDuringSchedulingIgnoredDuringExecution' \
  || fail "apiServerAntiAffinity=required did not reach the manifest"

# And it must be possible to turn off, or a single-node cluster can hang a
# rollout with one Pending replica.
off="$(render --set controlplane.replicaCount=2 --set controlplane.apiServerAntiAffinity=none)"
if printf '%s\n' "$off" | grep -q 'podAntiAffinity'; then
  fail "apiServerAntiAffinity=none still rendered a rule"
fi
printf '%s\n' "$ha" | grep -q 'replicas: 2' || fail "the replica count did not reach the Deployment"
info "replicaCount=2 renders the election env and an anti-affinity"

step "the compiler egress policy admits the API server and nothing else"
# P1-026: the policy is on by default, and its "API server" rule names the
# `controlplane` chart's pod. It used to say `{{ .Chart.Name }}`, which inside
# the compiler chart is `compiler` -- the pod itself. The rule matched nothing
# and the API server was dropped along with the internet; nothing failed,
# because compilation does not call back. A rendered selector is the only thing
# that shows the mistake before a cluster does.
egress="$(render)"
printf '%s\n' "$egress" | grep -q 'kind: NetworkPolicy' \
  || fail "the compiler egress policy is no longer rendered by default"

# Extract only the NetworkPolicy document. Grepping the whole render for
# `name: controlplane` would match the API server's own Deployment labels and
# pass no matter what the policy says -- a vacuous assertion of exactly the kind
# that let the original selector bug through. The policy is the last document
# and starts at its `kind: NetworkPolicy` line.
policy_doc="$(printf '%s\n' "$egress" | sed -n '/kind: NetworkPolicy/,/^---$/p')"
[ -n "$policy_doc" ] || fail "could not extract the NetworkPolicy document"

# The egress rules are the only place a podSelector for another chart appears.
# A rule is a `- to:` block ending at the next `- to:` or the next key; the
# selector and the port must appear in the same block, because a policy with
# both values in different rules admits neither endpoint correctly.
api_rule="$(printf '%s\n' "$policy_doc" | sed -n '/egress:/,$p' | awk '
  /^    - to:/ { if (blk ~ /controlplane/ && blk ~ /port: 8080/) found=1; blk="" }
  { blk = blk "\n" $0 }
  END { if (blk ~ /controlplane/ && blk ~ /port: 8080/) found=1; exit(found ? 0 : 1) }')" \
  || fail "the egress policy has no single rule selecting the API server (name: controlplane, port: 8080)"
# And no rule may select this chart's own name except the compiler-to-compiler
# one on the compiler port; a second one would mean the API server rule regressed
# to `{{ .Chart.Name }}` again.
api_rule_count=$(printf '%s\n' "$policy_doc" | grep -c 'app.kubernetes.io/name: controlplane' || true)
[ "$api_rule_count" = "1" ] \
  || fail "expected exactly one API server selector in the policy, found ${api_rule_count}"
info "the policy selects controlplane:8080"

# The policy has to be switchable off: a CNI without NetworkPolicy support, or a
# compiler that needs an endpoint the list does not carry, otherwise has no way
# to run.
no_policy="$(render --set compiler.networkPolicy.enabled=false)"
if printf '%s\n' "$no_policy" | grep -q 'kind: NetworkPolicy'; then
  fail "compiler.networkPolicy.enabled=false still rendered a policy"
fi
info "the policy can be turned off"

step "the storage class policy reaches the manager's flags"
policy="$(render \
  --set controlplane.kubernetesRunner.enableStorageClassNamesSupported=true \
  --set 'controlplane.kubernetesRunner.storageClassNamesSupported={fast,standard}' \
  --set-string 'controlplane.kubernetesRunner.tenantNamespaces.11111111-1111-1111-1111-111111111111=tenant-a')"
printf '%s\n' "$policy" | grep -q -- '--kubernetes-runner-enable-storage-classes' \
  || fail "the allowlist switch did not reach the manager"
printf '%s\n' "$policy" | grep -q -- '--kubernetes-runner-storage-classes=fast,standard' \
  || fail "the allowed classes did not reach the manager"
printf '%s\n' "$policy" | grep -q -- '--kubernetes-runner-tenant-namespaces=tenant=11111111-1111-1111-1111-111111111111:tenant-a' \
  || fail "the tenant namespace did not reach the manager"
info "the allowlist and the tenant namespace arrive as flags"

step "the tenant quota map reaches the manager"
quota="$(render \
  --set-string 'controlplane.kubernetesRunner.tenantQuotas.11111111-1111-1111-1111-111111111111=tenant-a: requests.cpu=16\,requests.memory=32Gi' \
  --set-string 'controlplane.kubernetesRunner.tenantQuotas.22222222-2222-2222-2222-222222222222=tenant-b: persistentvolumeclaims=8')"
# The entries are joined with ';' because the comma separates a quota's own
# keys: a comma-joined pair of entries would parse as one tenant with the other
# tenant's keys folded into its quota.
printf '%s\n' "$quota" | grep -q 'FELDERA_KUBERNETES_RUNNER_TENANT_QUOTAS' \
  || fail "the tenant quota map did not reach the manager"
entry="$(printf '%s\n' "$quota" | grep -A 1 'FELDERA_KUBERNETES_RUNNER_TENANT_QUOTAS' | tail -1)"
printf '%s\n' "$entry" | grep -q 'tenant=11111111-1111-1111-1111-111111111111:tenant-a: requests.cpu=16\,requests.memory=32Gi' \
  || fail "a tenant quota lost its spec: $entry"
printf '%s\n' "$entry" | grep -q ';tenant=22222222-2222-2222-2222-222222222222:tenant-b:' \
  || fail "the entries were not joined with ';': $entry"
info "each tenant's quota arrives as one entry"

# The namespace grant is cluster-scoped, so it must be absent unless asked for.
# The runner's own ClusterRole is different: it is aggregated rather than a
# grant of its own, and it renders whenever the runner is on.
if printf '%s\n' "$quota" | grep -q -- '-tenant-namespaces'; then
  fail "the cluster-scoped namespace grant appeared without tenantNamespaceAutomation"
fi
printf '%s\n' "$quota" | grep -q 'TENANT_NAMESPACE_AUTOMATION' \
  && fail "namespace automation reached the manager without being asked for"
automated="$(render \
  --set controlplane.kubernetesRunner.tenantNamespaceAutomation=true \
  --set-string 'controlplane.kubernetesRunner.tenantQuotas.11111111-1111-1111-1111-111111111111=tenant-a: requests.cpu=16')"
for expected in 'kind: ClusterRole' 'tenant-namespaces' 'FELDERA_KUBERNETES_RUNNER_TENANT_NAMESPACE_AUTOMATION' \
  'manager-service-account' 'tenant-cluster-role'; do
  printf '%s\n' "$automated" | grep -q -- "$expected" \
    || fail "automation on did not render $expected"
done
printf '%s\n' "$automated" | grep -q 'resources: \["namespaces"\]' \
  || fail "the ClusterRole does not grant namespaces"
info "automation on renders the ClusterRole, and off does not"

step "the connector Secret allowlist reaches the manager"
# Off is the default and must render nothing at all: an environment variable
# the manager reads as "nothing allowed" and one it reads as "no restriction"
# look the same in a diff, so absence is what the test asserts.
if render | grep -q 'CONNECTOR_KUBERNETES_SECRETS_ALLOWLIST'; then
  fail "the Secret allowlist reached the manager without being asked for"
fi
allowlisted="$(render \
  --set controlplane.kubernetesRunner.connectorKubernetesSecrets.enableAllowlist=true \
  --set 'controlplane.kubernetesRunner.connectorKubernetesSecrets.allowlist={kafka-creds,s3-credentials}')"
entry="$(printf '%s\n' "$allowlisted" \
  | grep -A 1 'CONNECTOR_KUBERNETES_SECRETS_ALLOWLIST' | tail -1)"
printf '%s\n' "$entry" | grep -q '"kafka-creds;s3-credentials"' \
  || fail "the allowlist did not arrive as one ';'-joined value: $entry"
info "the allowlist arrives joined with ';'"

step "the runner Role and its ClusterRole twin match"
# The runner Role and its ClusterRole twin must grant the same thing. The API
# server aggregates only ClusterRoles, so the namespaced Role cannot be the
# source: the rules are two copies, and a permission added to one and not the
# other either breaks the release namespace or every tenant namespace.
rules_under() {
  local kind="$1" name_suffix="$2"
  awk -v kind="${kind}" -v suffix="${name_suffix}" '
    /^kind: /   { k = $2 }
    /^  name: / { n = $2 }
    /^---$/     { k = ""; n = ""; next }
    k == kind && n ~ suffix && /^  - apiGroups|^    resources|^    verbs/ { print }
  '
}
runner_role="$(render | rules_under Role '-runner$')"
runner_cluster="$(render | rules_under ClusterRole '-pipeline-runner$')"
if [ -z "${runner_role}" ] || [ -z "${runner_cluster}" ]; then
  fail "the runner RBAC did not render where the test expected it"
fi
if [ "${runner_role}" != "${runner_cluster}" ]; then
  diff <(printf '%s\n' "${runner_role}") <(printf '%s\n' "${runner_cluster}") >&2 || true
  fail "the runner Role and the pipeline-runner ClusterRole grant different things"
fi
info "the runner Role and its ClusterRole twin grant the same rules"

# The namespace grant is cluster-scoped, so it must be absent unless asked for.

step "values the platform cannot honour are rejected"
rejects() {
  local description="$1"
  shift
  if render "$@" >/dev/null 2>&1; then
    fail "the schema accepted $description"
  fi
  info "rejected: $description"
}
rejects "zero API server replicas" --set controlplane.replicaCount=0
rejects "an empty storage class name" \
  --set 'controlplane.kubernetesRunner.storageClassNamesSupported={}'
rejects "a tenant mapped to an empty namespace" --set-string \
  'controlplane.kubernetesRunner.tenantNamespaces.11111111-1111-1111-1111-111111111111='
rejects "an anti-affinity mode the chart does not have" \
  --set controlplane.apiServerAntiAffinity=sometimes

rejects "a Secret allowlist while the allowlist switch is off" \
  --set 'controlplane.kubernetesRunner.connectorKubernetesSecrets.allowlist={kafka-creds}'
rejects "a Secret name the cluster would refuse" \
  --set controlplane.kubernetesRunner.connectorKubernetesSecrets.enableAllowlist=true \
  --set 'controlplane.kubernetesRunner.connectorKubernetesSecrets.allowlist={Kafka_Creds}'
rejects "namespace automation without a tenant quota to keep in step" \
  --set controlplane.kubernetesRunner.tenantNamespaceAutomation=true

printf '\nPASS: the chart renders as recorded and rejects unhonourable values\n'
