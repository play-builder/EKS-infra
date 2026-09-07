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
  resolved=$(python3 -I -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$output")
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

capture_runtime() {
  local mode=$1 output=$2 payload candidate now
  shift 2
  [[ -z "${PLATFORM_CHECK_BIN_DIR:-}" && -z "${PLATFORM_CHECK_NOW:-}" ]] || \
    pb_fail 'Runtime capture rejects fake commands/clock overrides; offline fixtures cannot produce cloud evidence.' 64
  validate_evidence_output_path "$output"
  pb_require_environment AWS_PROFILE
  pb_require_command python3
  pb_require_command jq
  # A single Python owner handles SDK, signing and semantic checks. No CLI AWS fakes.
  payload=$(python3 -I -B "$SCRIPT_DIR/lib/dev-evidence.py" "$mode" "$@")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  (
    candidate=$(mktemp "${output}.candidate.XXXXXX")
    trap 'rm -f -- "$candidate"' EXIT
    printf '%s\n' "$payload" >"$candidate"
    if [[ "$mode" == deployment ]]; then
      validate_dev_deployment_evidence "$candidate" "$now" CLOUD_RUNTIME
    else
      validate_dev_slo_evidence "$1" "$candidate" "$now" CLOUD_RUNTIME
    fi
  )
  write_json_atomic "$output" "$payload"
  printf 'DEV_%s_EVIDENCE: %s\n' "$(printf '%s' "$mode" | tr '[:lower:]' '[:upper:]')" "$output"
}

capture_deployment() {
  if [[ "${1:-}" == "--validate-evidence" ]]; then
    [[ $# -eq 3 ]] || pb_fail 'usage: deployment --validate-evidence <file> <now>' 64
    validate_dev_deployment_evidence "$2" "$3" CLOUD_RUNTIME
    return
  fi
  [[ $# -eq 12 && "${11}" == "--output" ]] || pb_fail 'usage: deployment <context> <app-namespace> <application> <source-repository> <source-sha> <image-repository> <image-digest> <gitops-revision> <cluster-arn> <region> --output <path>' 64
  capture_runtime deployment "${12}" "${@:1:10}"
}

capture_slo() {
  if [[ "${1:-}" == "--validate-evidence" ]]; then
    [[ $# -eq 4 ]] || pb_fail 'usage: slo --validate-evidence <deployment> <slo> <now>' 64
    validate_dev_slo_evidence "$2" "$3" "$4" CLOUD_RUNTIME
    return
  fi
  [[ $# -eq 9 && "${8}" == "--output" ]] || pb_fail 'usage: slo <deployment-evidence> <context> <k6-namespace> <testrun> <amp-workspace-id> <sns-topic-arn> <region> --output <path>' 64
  pb_require_environment ALERT_DELIVERY_EVIDENCE
  validate_dev_deployment_evidence "$1"
  capture_runtime slo "$9" "${@:1:7}"
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
