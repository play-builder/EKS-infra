#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"
pb_prepare_commands

validate_dev_deployment_evidence() {
  local file=${1:-} now=${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} expected_grade=${3:-CLOUD_RUNTIME}
  [[ -f "$file" ]] || pb_fail "Deployment evidence file을 찾을 수 없습니다: $file" 66
  jq -e --arg now "$now" --arg grade "$expected_grade" '
    def canonical_ecr_repository:
      capture("^(?<accountId>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/(?<name>[a-z0-9]+(?:[._/-][a-z0-9]+)*)$") |
      select((.name | length) >= 2 and (.name | length) <= 256);
    def canonical_eks_cluster:
      capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<accountId>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$");
    def canonical_utc_seconds:
      . as $timestamp |
      ($timestamp | type == "string") and
      ($timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      (try (($timestamp | fromdateiso8601 | todateiso8601) == $timestamp) catch false);
    (.image.repository | canonical_ecr_repository) as $repository |
    (.clusterArn | canonical_eks_cluster) as $cluster |
    (keys | sort) == (["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","schemaVersion","source","status"] | sort) and
    .schemaVersion == "playbuilder.dev-deployment/v1" and
    .evidenceGrade == $grade and
    .status == {"sync":"Synced","health":"Healthy"} and
    (.source | keys | sort) == ["repository","sha"] and
    (.source.repository | type == "string" and length > 0) and
    (.source.sha | test("^[0-9a-f]{40}$")) and
    (.image | keys | sort) == ["indexDigest","repository"] and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.region == "ap-northeast-2" or .region == "us-east-1") and
    $repository.region == .region and
    $cluster.region == .region and
    $cluster.accountId == $repository.accountId and
    (.observedAt | canonical_utc_seconds) and
    ($now | canonical_utc_seconds) and
    ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601))
  ' "$file" >/dev/null || pb_fail "Deployment evidence schema, grade, identity, or Synced/Healthy status is invalid."
}

validate_dev_slo_evidence() {
  local deployment=${1:-} slo=${2:-} now=${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} expected_grade=${4:-CLOUD_RUNTIME}
  validate_dev_deployment_evidence "$deployment" "$now" "$expected_grade"
  [[ -f "$slo" ]] || pb_fail "SLO evidence file을 찾을 수 없습니다: $slo" 66
  jq -e --arg now "$now" --arg grade "$expected_grade" --slurpfile deployment "$deployment" '
    def canonical_utc_seconds:
      . as $timestamp |
      ($timestamp | type == "string") and
      ($timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      (try (($timestamp | fromdateiso8601 | todateiso8601) == $timestamp) catch false);
    (keys | sort) == (["clusterArn","evidenceGrade","evidenceId","expiresAt","gitopsRevision","image","observedAt","region","schemaVersion","source","status"] | sort) and
    .schemaVersion == "playbuilder.dev-slo/v1" and
    .evidenceGrade == $grade and
    .status == "PASS" and
    (.source | keys | sort) == ["repository","sha"] and
    (.image | keys | sort) == ["indexDigest","repository"] and
    (.evidenceId | test("^sha256:[0-9a-f]{64}$")) and
    .source == $deployment[0].source and
    .image == $deployment[0].image and
    .gitopsRevision == $deployment[0].gitopsRevision and
    .clusterArn == $deployment[0].clusterArn and
    .region == $deployment[0].region and
    (.observedAt | canonical_utc_seconds) and
    (.expiresAt | canonical_utc_seconds) and
    ($now | canonical_utc_seconds) and
    ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)) and
    ((.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)) and
    (($now | fromdateiso8601) < (.expiresAt | fromdateiso8601))
  ' "$slo" >/dev/null || pb_fail "SLO evidence schema, grade, PASS status, identity, or validity interval is invalid."
}

validate_evidence_output_path() {
  local output=${1:-} resolved
  [[ -n "$output" ]] || pb_fail "--output path가 필요합니다." 64
  [[ ! -L "$output" && ( ! -e "$output" || -f "$output" ) ]] || \
    pb_fail 'output must be a regular file path, not a symlink or directory' 64
  pb_require_command python3
  resolved=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$output")
  case "$resolved" in
    argocd-gitops/evidence/dev/deployment.json|argocd-gitops/evidence/dev/slo.json|*/argocd-gitops/evidence/dev/deployment.json|*/argocd-gitops/evidence/dev/slo.json)
      pb_fail "EKS-infra checker는 GitOps handoff 경로를 직접 쓰지 않습니다: $output" 64
      ;;
  esac
  [[ -d "$(dirname -- "$output")" ]] || pb_fail "output directory가 없습니다: $(dirname -- "$output")" 66
}

write_json_atomic() {
  validate_evidence_output_path "$1"
  pb_write_json "$1" "$2"
}

capture_deployment() {
  if [[ "${1:-}" == "--validate-evidence" ]]; then
    [[ $# -eq 3 ]] || pb_fail "사용법: deployment --validate-evidence <file> <now>" 64
    validate_dev_deployment_evidence "$2" "$3" CLOUD_RUNTIME
    return
  fi
  [[ $# -eq 12 && "${11}" == "--output" ]] || pb_fail "사용법: deployment <context> <app-namespace> <application> <source-repository> <source-sha> <image-repository> <image-digest> <gitops-revision> <cluster-arn> <region> --output <path>" 64
  local context=$1 namespace=$2 application=$3 source_repository=$4 source_sha=$5 image_repository=$6
  local image_digest=$7 gitops_revision=$8 cluster_arn=$9 region=${10} output=${12}
  pb_validate_region "$region"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$gitops_revision" =~ ^[0-9a-f]{40}$ ]] || pb_fail "source와 GitOps revision은 40-char SHA여야 합니다." 64
  [[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || pb_fail "image digest가 유효하지 않습니다." 64
  for command in aws kubectl jq; do pb_require_command "$command"; done
  pb_require_environment AWS_PROFILE
  validate_evidence_output_path "$output"

  local app cluster cluster_name now grade payload
  app=$(kubectl --context "$context" -n argocd get application "$application" -o json)
  jq -e --arg revision "$gitops_revision" '
    .status.sync.status == "Synced" and .status.health.status == "Healthy" and
    .status.sync.revision == $revision
  ' <<<"$app" >/dev/null || pb_fail "Dev Argo Application이 요청 GitOps revision에서 Synced/Healthy가 아닙니다."
  cluster_name=${cluster_arn##*/}
  cluster=$(aws eks describe-cluster --name "$cluster_name" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e --arg arn "$cluster_arn" --arg region "$region" \
    '.cluster.arn == $arn and .cluster.status == "ACTIVE" and (.cluster.arn | contains(":"+$region+":"))' \
    <<<"$cluster" >/dev/null || pb_fail "Dev EKS cluster ARN/Region/ACTIVE 상태가 일치하지 않습니다."
  now=${PLATFORM_CHECK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  grade=$(pb_runtime_grade)
  payload=$(jq -n --arg grade "$grade" --arg source_repository "$source_repository" --arg source_sha "$source_sha" \
    --arg image_repository "$image_repository" --arg image_digest "$image_digest" --arg gitops_revision "$gitops_revision" \
    --arg cluster_arn "$cluster_arn" --arg region "$region" --arg now "$now" '
      {schemaVersion:"playbuilder.dev-deployment/v1",evidenceGrade:$grade,status:{sync:"Synced",health:"Healthy"},
       source:{repository:$source_repository,sha:$source_sha},image:{repository:$image_repository,indexDigest:$image_digest},
       gitopsRevision:$gitops_revision,clusterArn:$cluster_arn,region:$region,observedAt:$now}')
  (
    candidate=$(mktemp "${output}.candidate.XXXXXX")
    trap 'rm -f -- "$candidate"' EXIT
    printf '%s\n' "$payload" >"$candidate"
    validate_dev_deployment_evidence "$candidate" "$now" "$grade"
  )
  write_json_atomic "$output" "$payload"
  printf 'DEV_DEPLOYMENT_EVIDENCE: %s\n' "$output"
}

capture_slo() {
  if [[ "${1:-}" == "--validate-evidence" ]]; then
    [[ $# -eq 4 ]] || pb_fail "사용법: slo --validate-evidence <deployment> <slo> <now>" 64
    validate_dev_slo_evidence "$2" "$3" "$4" CLOUD_RUNTIME
    return
  fi
  [[ $# -eq 9 && "${8}" == "--output" ]] || pb_fail "사용법: slo <deployment-evidence> <context> <k6-namespace> <testrun> <amp-workspace-id> <sns-topic-arn> <region> --output <path>" 64
  local deployment=$1 context=$2 namespace=$3 testrun=$4 workspace_id=$5 topic_arn=$6 region=$7 output=$9
  local grade now expected_grade operator crd run workspace workspace_arn workspace_account rules rule_text alertmanager alertmanager_text topic subscriptions query delivery expires evidence_id payload
  for command in aws kubectl jq; do pb_require_command "$command"; done
  pb_require_environment AWS_PROFILE
  pb_require_environment ALERT_DELIVERY_EVIDENCE
  pb_validate_region "$region"
  validate_evidence_output_path "$output"
  pb_require_file "$ALERT_DELIVERY_EVIDENCE"
  pb_assert_canonical_utc_seconds "$ALERT_DELIVERY_EVIDENCE" \
    'alert delivery observedAt' '["observedAt"]'
  now=${PLATFORM_CHECK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  pb_assert_canonical_utc_seconds_value "$now" 'SLO evaluation time'
  delivery=$(cat "$ALERT_DELIVERY_EVIDENCE")
  jq -e --arg topic "$topic_arn" --arg now "$now" '
    (keys | sort) == (["evidenceGrade","firing","observedAt","resolved","schemaVersion","topicArn"] | sort) and
    .schemaVersion == "playbuilder.alert-delivery/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    .topicArn == $topic and .firing.delivered == true and .resolved.delivered == true and
    (.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)
  ' <<<"$delivery" >/dev/null || pb_fail "Firing/Resolved SNS delivery evidence가 모두 필요합니다."
  grade=$(pb_runtime_grade)
  expected_grade=$grade
  validate_dev_deployment_evidence "$deployment" "$now" "$expected_grade"
  [[ "$(jq -r '.region' "$deployment")" == "$region" ]] || pb_fail "Deployment/SLO Region identity가 다릅니다."

  operator=$(kubectl --context "$context" -n "$namespace" get deployment k6-operator-controller-manager -o json)
  jq -e '.status.availableReplicas >= 1 and .status.availableReplicas == .status.replicas' <<<"$operator" >/dev/null || pb_fail "k6 operator Deployment가 Available이 아닙니다."
  crd=$(kubectl --context "$context" get crd testruns.k6.io -o json)
  jq -e 'any(.status.conditions[]?; .type == "Established" and .status == "True")' <<<"$crd" >/dev/null || pb_fail "k6 TestRun CRD가 Established가 아닙니다."
  run=$(kubectl --context "$context" -n "$namespace" get testrun "$testrun" -o json)
  jq -e '
    .status.stage == "finished" and
    .metadata.annotations["playbuilder.platform/max-duration"] != null and
    .metadata.annotations["playbuilder.platform/max-rate"] != null and
    .metadata.annotations["playbuilder.platform/cost-boundary"] == "existing-eks-compute"
  ' <<<"$run" >/dev/null || pb_fail "k6 run이 finished가 아니거나 duration/rate/cost boundary metadata가 없습니다."

  workspace=$(aws amp describe-workspace --workspace-id "$workspace_id" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e --arg region "$region" --arg workspace_id "$workspace_id" '
    .workspace.status.statusCode == "ACTIVE" and
    .workspace.workspaceId == $workspace_id and
    (.workspace.prometheusEndpoint | contains("." + $region + ".")) and
    (.workspace.arn | test("^arn:aws:aps:" + $region + ":[0-9]{12}:workspace/" + $workspace_id + "$"))
  ' <<<"$workspace" >/dev/null || pb_fail "AMP workspace ARN/endpoint/status/Region이 유효하지 않습니다."
  workspace_arn=$(jq -r '.workspace.arn' <<<"$workspace")
  workspace_account=$(jq -r '.workspace.arn | split(":")[4]' <<<"$workspace")
  rules=$(aws amp get-rule-groups-namespace --workspace-id "$workspace_id" --name mini-commerce-release-slo --region "$region" --profile "$AWS_PROFILE" --output json)
  rule_text=$(jq -r '.data | @base64d' <<<"$rules")
  [[ "$rule_text" == *"platform:http_success_ratio:5m"* && "$rule_text" == *"PlatformDeadman"* ]] || pb_fail "AMP recording rule/deadman alert가 없습니다."
  alertmanager=$(aws amp get-alert-manager-definition --workspace-id "$workspace_id" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e '.status.statusCode == "ACTIVE" and (.data | length > 0)' <<<"$alertmanager" >/dev/null || pb_fail "AMP Alertmanager definition이 ACTIVE가 아닙니다."
  alertmanager_text=$(jq -r '.data | @base64d' <<<"$alertmanager")
  [[ "$alertmanager_text" == *"sigv4"* && "$alertmanager_text" == *"region: $region"* && "$alertmanager_text" == *"$topic_arn"* ]] || pb_fail "Alertmanager SNS topic/SigV4 Region 설정이 일치하지 않습니다."
  topic=$(aws sns get-topic-attributes --topic-arn "$topic_arn" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e --arg topic "$topic_arn" --arg workspace "$workspace_arn" --arg account "$workspace_account" '
    .Attributes.TopicArn == $topic and
    (.Attributes.Policy | fromjson | any(.Statement[]?;
      .Principal.Service == "aps.amazonaws.com" and .Action == "sns:Publish" and
      .Resource == $topic and
      .Condition.ArnEquals["AWS:SourceArn"] == $workspace and
      .Condition.StringEquals["AWS:SourceAccount"] == $account))
  ' <<<"$topic" >/dev/null || pb_fail "SNS topic 또는 exact AMP workspace/account-scoped delivery policy가 유효하지 않습니다."
  subscriptions=$(aws sns list-subscriptions-by-topic --topic-arn "$topic_arn" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e 'any(.Subscriptions[]?; .SubscriptionArn != "PendingConfirmation" and (.SubscriptionArn | length > 0))' \
    <<<"$subscriptions" >/dev/null || pb_fail "SNS subscription이 confirmed 상태가 아닙니다."
  query=$(aws amp query-metrics --workspace-id "$workspace_id" --query-string 'platform:http_success_ratio:5m' --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e 'any(.data.result[]?; ((.value[1] | tonumber) >= 0.99))' <<<"$query" >/dev/null || pb_fail "Dev SLO success ratio가 0.99 미만입니다."
  expires=$(pb_expires_after 3600 "$now")
  evidence_id="sha256:$(printf '%s\n%s\n%s\n' "$(sha256sum "$deployment" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$deployment" | awk '{print $1}')" "$workspace_id" "$now" | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk '{print $1}')"
  payload=$(jq -n --slurpfile deployment "$deployment" --arg grade "$grade" --arg evidence_id "$evidence_id" --arg now "$now" --arg expires "$expires" '
    $deployment[0] as $d |
    {schemaVersion:"playbuilder.dev-slo/v1",evidenceGrade:$grade,status:"PASS",source:$d.source,image:$d.image,
     gitopsRevision:$d.gitopsRevision,clusterArn:$d.clusterArn,region:$d.region,evidenceId:$evidence_id,observedAt:$now,expiresAt:$expires}')
  (
    candidate=$(mktemp "${output}.candidate.XXXXXX")
    trap 'rm -f -- "$candidate"' EXIT
    printf '%s\n' "$payload" >"$candidate"
    validate_dev_slo_evidence "$deployment" "$candidate" "$now" "$grade"
  )
  write_json_atomic "$output" "$payload"
  printf 'DEV_SLO_EVIDENCE: %s\n' "$output"
}

mode=${1:-}; [[ $# -gt 0 ]] && shift
validation_only=false
[[ "${1:-}" == --validate-evidence ]] && validation_only=true
case "$mode" in
  deployment) capture_deployment "$@" ;;
  slo) capture_slo "$@" ;;
  *) pb_fail 'usage: capture-dev-evidence.sh deployment|slo <arguments> [--output path]' 64 ;;
esac
if [[ "$validation_only" == true ]]; then
  if [[ "${PLATFORM_CHECK_DETAIL_ONLY:-false}" == true ]]; then
    pb_detail "Dev $mode evidence schema verified; no cloud execution."
  else
    printf 'PASS: [STATIC] Dev %s evidence schema verified; no cloud execution.\n' "$mode"
  fi
else
  pb_emit_pass "Dev $mode evidence captured."
fi
