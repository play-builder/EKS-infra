#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$COURSE_CHECK_BIN_DIR" ]] || course_fail 'COURSE_CHECK_BIN_DIR is not a directory' 64
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

[[ $# -eq 6 ]] || course_fail 'usage: chaos-mesh-readiness-check.sh <context> <namespace> <course-id> <allowed-namespaces-csv> <max-duration-seconds> <max-faults>' 64
context=$1
namespace=$2
course_id=$3
allowed_csv_input=$4
max_duration=$5
max_faults=$6
IFS=',' read -r -a allowed <<<"$allowed_csv_input"
[[ -n "$context" && "$namespace" == "chaos-mesh" ]] || course_fail 'invalid Chaos Mesh context or namespace' 64
[[ "$course_id" =~ ^[a-z0-9][a-z0-9-]{7,62}$ ]] || course_fail 'invalid CourseId' 64
[[ "$max_duration" =~ ^[0-9]+$ && "$max_duration" -ge 1 && "$max_duration" -le 300 ]] || course_fail 'max fault duration must be 1..300 seconds' 64
[[ "$max_faults" == 1 ]] || course_fail 'Ch25 permits exactly one fault' 64
((${#allowed[@]} > 0)) || course_fail 'at least one allowed application namespace is required' 64
for app_namespace in "${allowed[@]}"; do
  [[ "$app_namespace" =~ ^app-[a-z0-9-]+$ && "$app_namespace" != app-prod ]] || course_fail 'only non-prod app namespaces may be fault targets' 64
done
command -v kubectl >/dev/null 2>&1 || course_fail 'required command not found: kubectl' 127
command -v jq >/dev/null 2>&1 || course_fail 'required command not found: jq' 127

deployment=$(kubectl --context "$context" -n "$namespace" get deployment chaos-controller-manager -o json) || course_fail 'Chaos Mesh controller Deployment query failed'
jq -e '
  (.status.replicas // 0) >= 1 and
  (.status.availableReplicas // 0) == .status.replicas and
  any(.spec.template.spec.containers[]?.args[]?; . == "--enable-filter-namespace=true")
' <<<"$deployment" >/dev/null || course_fail 'Chaos Mesh controller is not Available or namespace filtering is disabled'

crds=$(kubectl --context "$context" get crd podchaos.chaos-mesh.org networkchaos.chaos-mesh.org -o json) || course_fail 'Chaos Mesh required CRD query failed'
jq -e '(.items | length) == 2 and all(.items[]; any(.status.conditions[]?; .type == "Established" and .status == "True"))' <<<"$crds" >/dev/null || \
  course_fail 'Chaos Mesh required CRDs are not Established'

contract=$(kubectl --context "$context" -n "$namespace" get configmap chaos-mesh-course-contract -o json) || course_fail 'Chaos Mesh course contract ConfigMap query failed'
allowed_csv=$(IFS=,; printf '%s' "${allowed[*]}")
jq -e --arg course "$course_id" --arg namespaces "$allowed_csv" --arg duration "$max_duration" --arg faults "$max_faults" '
  (.data | keys | sort) == ["allowedNamespaces","costBoundary","courseId","maxFaultDurationSeconds","maxFaults"] and
  .data.courseId == $course and .data.allowedNamespaces == $namespaces and
  .data.maxFaultDurationSeconds == $duration and .data.maxFaults == $faults and
  .data.costBoundary == "existing-eks-compute"
' <<<"$contract" >/dev/null || course_fail 'Chaos Mesh bounded course contract metadata is invalid'

for app_namespace in "${allowed[@]}"; do
  namespace_json=$(kubectl --context "$context" get namespace "$app_namespace" -o json) || course_fail "target namespace query failed: $app_namespace"
  jq -e '.metadata.labels["chaos-mesh.org/inject"] == "enabled"' <<<"$namespace_json" >/dev/null || \
    course_fail "target namespace is not explicitly allowlisted for Chaos Mesh: $app_namespace"
  kubectl --context "$context" auth can-i create podchaos.chaos-mesh.org \
    --as "system:serviceaccount:${namespace}:chaos-controller-manager" --namespace "$app_namespace" \
    | grep -Fxq yes || course_fail "Chaos Mesh controller lacks PodChaos RBAC in $app_namespace"
done

grade=$(course_runtime_grade)
if [[ "$grade" == STATIC ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT Chaos Mesh controller readiness and bounded RBAC are valid.'
else
  echo 'PASS: [CLOUD_RUNTIME] Chaos Mesh controller readiness and bounded RBAC are valid.'
fi
