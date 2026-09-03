#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

[[ $# -eq 6 ]] || course_fail 'usage: prod-bootstrap-check.sh <rendered-application.json> <dev-deployment.json> <dev-slo.json> <dev-ready.json> <design-decision.json> <estimate-decision.json>' 64
application=$1
deployment=$2
slo=$3
ready=$4
design=$5
estimate=$6
for name in COURSE_ID AWS_REGION AWS_ACCOUNT_ID; do [[ -n "${!name:-}" ]] || course_fail "$name is required" 64; done
course_validate_region "$AWS_REGION"
course_validate_account "$AWS_ACCOUNT_ID"
for file in "$application" "$design" "$estimate"; do course_require_file "$file"; done
COURSE_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/dev-ready-check.sh" "$deployment" "$slo" "$ready" >/dev/null

course_assert_json "$application" '
  .apiVersion == "argoproj.io/v1alpha1" and .kind == "Application" and
  .metadata.namespace == "argocd" and (.metadata.name | test("prod")) and
  .spec.destination.server == "https://kubernetes.default.svc" and
  (.spec.source.path | test("prod")) and
  (.spec.syncPolicy | type == "object" and (has("automated") | not)) and
  (.spec.syncPolicy.syncOptions | type == "array")
' 'PROD_BOOTSTRAP_MUST_USE_MANUAL_SYNC'

validate_decision() {
  local file=$1 stage=$2 expected_grade=$3
  PREFLIGHT_STAGE="$stage" PREFLIGHT_GRADE="$expected_grade" course_assert_json "$file" '
    keys == ["accountId","bindings","courseId","decision","evidenceGrade","expiresAt","issuedAt","region","schemaVersion","stage"] and
    .schemaVersion == "course.prod-preflight/v1" and .evidenceGrade == $ENV.PREFLIGHT_GRADE and
    .stage == $ENV.PREFLIGHT_STAGE and .decision == "GO" and
    .courseId == $ENV.COURSE_ID and .accountId == $ENV.AWS_ACCOUNT_ID and .region == $ENV.AWS_REGION and
    (.bindings | keys == ["capacityInputSha256","devDeploymentSha256","devReadySha256","devSloSha256","previousDecisionSha256","savedPlanSha256"]) and
    (.bindings.devDeploymentSha256 | test("^sha256:[0-9a-f]{64}$")) and
    (.bindings.devSloSha256 | test("^sha256:[0-9a-f]{64}$")) and
    (.bindings.devReadySha256 | test("^sha256:[0-9a-f]{64}$")) and
    (.bindings.savedPlanSha256 | test("^sha256:[0-9a-f]{64}$")) and
    (.bindings.capacityInputSha256 | test("^sha256:[0-9a-f]{64}$")) and
    (.issuedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
  ' "invalid or expired $stage preflight decision"
}

validate_decision "$design" design STATIC
estimate_grade=CLOUD_RUNTIME
[[ -z "${COURSE_CHECK_BIN_DIR:-}" ]] || estimate_grade=STATIC
validate_decision "$estimate" estimate "$estimate_grade"

deployment_sha=$(course_sha256_file "$deployment")
slo_sha=$(course_sha256_file "$slo")
ready_sha=$(course_sha256_file "$ready")
design_sha=$(course_sha256_file "$design")
jq -e --arg deployment "$deployment_sha" --arg slo "$slo_sha" --arg ready "$ready_sha" '
  .bindings.devDeploymentSha256 == $deployment and
  .bindings.devSloSha256 == $slo and .bindings.devReadySha256 == $ready and
  .bindings.previousDecisionSha256 == null
' "$design" >/dev/null || course_fail 'DESIGN_EVIDENCE_BINDING_MISMATCH'
jq -e --arg deployment "$deployment_sha" --arg slo "$slo_sha" --arg ready "$ready_sha" --arg design "$design_sha" '
  .bindings.devDeploymentSha256 == $deployment and
  .bindings.devSloSha256 == $slo and .bindings.devReadySha256 == $ready and
  .bindings.previousDecisionSha256 == $design
' "$estimate" >/dev/null || course_fail 'ESTIMATE_EVIDENCE_BINDING_MISMATCH'

echo 'PASS: [STATIC] Prod bootstrap is manual and binds current DEV_READY plus design and estimate GO decisions.'
