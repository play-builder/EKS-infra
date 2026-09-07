#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

if [[ -n "${PLATFORM_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$PLATFORM_CHECK_BIN_DIR" ]] || pb_fail 'PLATFORM_CHECK_BIN_DIR is not a directory' 64
  PATH="$PLATFORM_CHECK_BIN_DIR:$PATH"
fi

[[ $# -eq 6 ]] || pb_fail 'usage: chaos-mesh-readiness-check.sh <context> <namespace> <owner-id> <allowed-namespaces-csv> <max-duration-seconds> <max-faults>' 64
context=$1
namespace=$2
owner_id=$3
allowed_csv_input=$4
max_duration=$5
max_faults=$6
IFS=',' read -r -a allowed <<<"$allowed_csv_input"
[[ -n "$context" && "$namespace" == "chaos-mesh" ]] || pb_fail 'invalid Chaos Mesh context or namespace' 64
[[ "$owner_id" =~ ^[a-z0-9][a-z0-9-]{7,62}$ ]] || pb_fail 'invalid OwnerId' 64
[[ "$max_duration" =~ ^[0-9]+$ && "$max_duration" -ge 1 && "$max_duration" -le 300 ]] || pb_fail 'max fault duration must be 1..300 seconds' 64
[[ "$max_faults" == 1 ]] || pb_fail 'A bounded fault exercise permits exactly one fault' 64
((${#allowed[@]} > 0)) || pb_fail 'at least one allowed application namespace is required' 64
for app_namespace in "${allowed[@]}"; do
  [[ "$app_namespace" =~ ^app-[a-z0-9-]+$ && "$app_namespace" != app-prod ]] || pb_fail 'only non-prod app namespaces may be fault targets' 64
done
command -v kubectl >/dev/null 2>&1 || pb_fail 'required command not found: kubectl' 127
command -v jq >/dev/null 2>&1 || pb_fail 'required command not found: jq' 127

deployment=$(kubectl --context "$context" -n "$namespace" get deployment chaos-controller-manager -o json) || pb_fail 'Chaos Mesh controller Deployment query failed'
jq -e '
  (.status.replicas // 0) >= 1 and
  (.status.availableReplicas // 0) == .status.replicas and
  any(.spec.template.spec.containers[]?.args[]?; . == "--enable-filter-namespace=true")
' <<<"$deployment" >/dev/null || pb_fail 'Chaos Mesh controller is not Available or namespace filtering is disabled'

crds=$(kubectl --context "$context" get crd podchaos.chaos-mesh.org networkchaos.chaos-mesh.org -o json) || pb_fail 'Chaos Mesh required CRD query failed'
jq -e '(.items | length) == 2 and all(.items[]; any(.status.conditions[]?; .type == "Established" and .status == "True"))' <<<"$crds" >/dev/null || \
  pb_fail 'Chaos Mesh required CRDs are not Established'

contract=$(kubectl --context "$context" -n "$namespace" get configmap chaos-mesh-fault-contract -o json) || pb_fail 'Chaos Mesh fault contract ConfigMap query failed'
allowed_csv=$(IFS=,; printf '%s' "${allowed[*]}")
jq -e --arg owner "$owner_id" --arg namespaces "$allowed_csv" --arg duration "$max_duration" --arg faults "$max_faults" '
  (.data | keys | sort) == ["allowedNamespaces","costBoundary","maxFaultDurationSeconds","maxFaults","ownerId"] and
  .data.ownerId == $owner and .data.allowedNamespaces == $namespaces and
  .data.maxFaultDurationSeconds == $duration and .data.maxFaults == $faults and
  .data.costBoundary == "existing-eks-compute"
' <<<"$contract" >/dev/null || pb_fail 'Chaos Mesh bounded fault contract metadata is invalid'

for app_namespace in "${allowed[@]}"; do
  namespace_json=$(kubectl --context "$context" get namespace "$app_namespace" -o json) || pb_fail "target namespace query failed: $app_namespace"
  jq -e '.metadata.labels["chaos-mesh.org/inject"] == "enabled"' <<<"$namespace_json" >/dev/null || \
    pb_fail "target namespace is not explicitly allowlisted for Chaos Mesh: $app_namespace"
  kubectl --context "$context" auth can-i create podchaos.chaos-mesh.org \
    --as "system:serviceaccount:${namespace}:chaos-controller-manager" --namespace "$app_namespace" \
    | grep -Fxq yes || pb_fail "Chaos Mesh controller lacks PodChaos RBAC in $app_namespace"
done

grade=$(pb_runtime_grade)
if [[ "$grade" == STATIC ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT Chaos Mesh controller readiness and bounded RBAC are valid.'
else
  echo 'PASS: [CLOUD_RUNTIME] Chaos Mesh controller readiness and bounded RBAC are valid.'
fi
