#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

fail() {
  printf 'PLATFORM_OWNER_HANDOFF_BLOCKED: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

temporary_plan_file=
temporary_output_file=
cleanup_temporary_files() {
  [[ -z "$temporary_plan_file" ]] || rm -f -- "$temporary_plan_file"
  [[ -z "$temporary_output_file" ]] || rm -f -- "$temporary_output_file"
}
trap cleanup_temporary_files EXIT

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

validate_handoff() {
  local file=$1 now=${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  [[ -f "$file" ]] || fail "handoff evidence not found: $file"
  course_assert_canonical_utc_seconds_value "$now" 'platform release handoff evaluation time'
  course_assert_canonical_utc_seconds "$file" 'platform release handoff timestamps' \
    '["observedAt"]' '["expiresAt"]'
  jq -e --arg now "$now" '
    (.clusterArn |
      capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
    (keys | sort) == (["application","clusterArn","environment","evidenceGrade","expiresAt","gitopsRevision","observedAt","ownership","readiness","region","release","schemaVersion"] | sort) and
    .schemaVersion == "course.platform-release-handoff/v1" and
    .evidenceGrade == "CLOUD_RUNTIME" and
    (.environment == "dev" or .environment == "prod") and
    (.region == "ap-northeast-2" or .region == "us-east-1") and
    $cluster.region == .region and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.application | keys | sort) == (["automated","name","operationInProgress","present","resourcesFinalizerPresent","uid"] | sort) and
    .application.name == ("external-secrets-" + .environment) and
    .application.present == true and
    .application.automated == false and
    .application.resourcesFinalizerPresent == false and
    .application.operationInProgress == false and
    (.application.uid | type == "string" and length > 0) and
    (.release | keys | sort) == (["chart","crdUids","helmStorageObjectUid","name","namespace","revision","status","valuesSha256","version","workloadUids"] | sort) and
    .release.namespace == "external-secrets" and
    .release.name == "external-secrets" and
    .release.chart == "external-secrets" and
    .release.status == "deployed" and
    (.release.version | type == "string" and length > 0) and
    (.release.revision | type == "number" and . >= 1) and
    (.release.valuesSha256 | test("^sha256:[0-9a-f]{64}$")) and
    (.release.helmStorageObjectUid | type == "string" and length > 0) and
    (.release.workloadUids | type == "array" and length > 0 and all(.[]; (keys | sort) == ["kind","name","uid"] and (.uid | length > 0))) and
    (.release.crdUids | type == "array" and length > 0 and all(.[]; (keys | sort) == ["name","uid"] and (.uid | length > 0))) and
    .readiness == {"deploymentsAvailable":true,"crdsEstablished":true} and
    .ownership == {"from":"argocd","to":"terraform","terraformAddress":"module.external_secrets[0].helm_release.this"} and
    ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)) and
    (($now | fromdateiso8601) < (.expiresAt | fromdateiso8601))
  ' "$file" >/dev/null || fail "handoff is stale, malformed, unready, or leaves two active reconcilers"
}

validate_adoption() {
  local handoff=$1 adoption=$2 now=${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} handoff_sha
  validate_handoff "$handoff" "$now"
  [[ -f "$adoption" ]] || fail "adoption evidence not found: $adoption"
  handoff_sha="sha256:$(sha256_file "$handoff")"
  jq -e --arg now "$now" --arg handoff_sha "$handoff_sha" --slurpfile handoff "$handoff" '
    def canonical_utc_seconds:
      . as $value |
      ($value | type == "string") and
      ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      ((try ($value | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) catch "") == $value);
    def release_keys:
      ["chart","crdUids","helmStorageObjectUid","name","namespace","revision","status","valuesSha256","version","workloadUids"];
    (keys | sort) == (["clusterArn","environment","evidenceGrade","expiresAt","handoffSha256","observedAt","region","release","schemaVersion","terraform"] | sort) and
    .schemaVersion == "course.platform-release-adoption/v1" and
    .evidenceGrade == "CLOUD_RUNTIME" and
    .handoffSha256 == $handoff_sha and
    .environment == $handoff[0].environment and
    .region == $handoff[0].region and
    .clusterArn == $handoff[0].clusterArn and
    (.release | keys) == ["after","before"] and
    (.release.before | keys) == release_keys and
    (.release.after | keys) == release_keys and
    .release.before == $handoff[0].release and
    .release.after == .release.before and
    (.terraform | keys | sort) == (["address","imported","planActions","stateLineage","stateSerial"] | sort) and
    .terraform.address == "module.external_secrets[0].helm_release.this" and
    .terraform.imported == true and
    .terraform.planActions == [] and
    (.terraform.stateLineage | type == "string" and test("^[0-9a-fA-F-]{36}$")) and
    (.terraform.stateSerial | type == "number" and . == floor and . >= 1) and
    (.observedAt | canonical_utc_seconds) and
    (.expiresAt | canonical_utc_seconds) and
    (($handoff[0].observedAt | fromdateiso8601) <= (.observedAt | fromdateiso8601)) and
    ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)) and
    ((.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)) and
    (($now | fromdateiso8601) < (.expiresAt | fromdateiso8601))
  ' "$adoption" >/dev/null || fail "adoption must be an exact no-op import with unchanged release and object UIDs"
}

verify_frozen_application() {
  local context=$1 handoff=$2 app namespace app_json
  app=$(jq -r '.application.name' "$handoff")
  namespace=argocd
  app_json=$(kubectl --context "$context" -n "$namespace" get application "$app" -o json)
  jq -e --slurpfile handoff "$handoff" '
    .metadata.uid == $handoff[0].application.uid and
    ((.metadata.finalizers // []) | index("resources-finalizer.argocd.argoproj.io") | not) and
    (.spec.syncPolicy.automated? == null) and
    ((.operation? == null) or (.status.operationState.phase? != "Running"))
  ' <<<"$app_json" >/dev/null || fail "live Argo Application is not frozen or its UID changed"
}

capture_workload_uids() {
  local context=$1 release_json=$2 actual kind name uid
  while IFS=$'\t' read -r kind name uid; do
    actual=$(kubectl --context "$context" -n external-secrets get "$kind" "$name" -o json | jq -r '.metadata.uid')
    [[ -n "$actual" && "$actual" != null ]] || fail "workload UID is missing during ownership transfer: $kind/$name"
    jq -cn --arg kind "$kind" --arg name "$name" --arg uid "$actual" \
      '{kind:$kind,name:$name,uid:$uid}'
  done < <(jq -r '.workloadUids[] | [.kind,.name,.uid] | @tsv' <<<"$release_json")
}

capture_crd_uids() {
  local context=$1 release_json=$2 actual name uid
  while IFS=$'\t' read -r name uid; do
    actual=$(kubectl --context "$context" get crd "$name" -o json | jq -r '.metadata.uid')
    [[ -n "$actual" && "$actual" != null ]] || fail "CRD UID is missing during ownership transfer: $name"
    jq -cn --arg name "$name" --arg uid "$actual" '{name:$name,uid:$uid}'
  done < <(jq -r '.crdUids[] | [.name,.uid] | @tsv' <<<"$release_json")
}

capture_live_release() {
  local context=$1 release_selectors=$2 helm_status live_values_sha storage_uid workload_uids crd_uids revision
  helm_status=$(helm --kube-context "$context" -n external-secrets status external-secrets -o json)
  revision=$(jq -er '.version | select(type == "number" and . == floor and . >= 1)' <<<"$helm_status") || \
    fail "live Helm release revision is invalid"
  live_values_sha=$(helm --kube-context "$context" -n external-secrets get values external-secrets -a -o json \
    | jq -S -c . | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk '{print "sha256:"$1}')
  storage_uid=$(kubectl --context "$context" -n external-secrets get secret \
    -l "owner=helm,name=external-secrets,status=deployed,version=$revision" -o json \
    | jq -er '.items | select(type == "array" and length == 1) | .[0].metadata.uid | select(type == "string" and length > 0)') || \
    fail "exact live Helm storage object could not be resolved"
  workload_uids=$(capture_workload_uids "$context" "$release_selectors" | jq -cs '.')
  crd_uids=$(capture_crd_uids "$context" "$release_selectors" | jq -cs '.')

  jq -ce --arg valuesSha256 "$live_values_sha" --arg storageUid "$storage_uid" \
    --argjson workloadUids "$workload_uids" --argjson crdUids "$crd_uids" '
      {
        namespace:.namespace,
        name:.name,
        chart:.chart.metadata.name,
        version:.chart.metadata.version,
        revision:.version,
        status:.info.status,
        valuesSha256:$valuesSha256,
        helmStorageObjectUid:$storageUid,
        workloadUids:$workloadUids,
        crdUids:$crdUids
      } as $release |
      $release |
      select(
        .namespace == "external-secrets" and .name == "external-secrets" and
        .chart == "external-secrets" and (.version | type == "string" and length > 0) and
        (.revision | type == "number" and . == floor and . >= 1) and .status == "deployed" and
        (.valuesSha256 | test("^sha256:[0-9a-f]{64}$")) and
        (.workloadUids | type == "array" and length > 0) and
        (.crdUids | type == "array" and length > 0)
      )
    ' <<<"$helm_status" || fail "live Helm release identity is malformed or not deployed"
}

verify_release_uids() {
  local context=$1 evidence=$2 release_filter=${3:-.release} release_json live_json
  release_json=$(jq -ce "$release_filter" "$evidence") || fail "release identity is missing from evidence"
  live_json=$(capture_live_release "$context" "$release_json")
  [[ "$(jq -cS . <<<"$live_json")" == "$(jq -cS . <<<"$release_json")" ]] || \
    fail "release identity or UID changed during ownership transfer"
}

verify_terraform_state_owner() {
  local state_json=$1 expected_release=$2
  jq -e --argjson release "$expected_release" '
    [.resources[]? |
      select(
        .module == "module.external_secrets[0]" and
        .mode == "managed" and .type == "helm_release" and .name == "this"
      )] as $resources |
    ($resources[0].instances[0].attributes // {}) as $attributes |
    ($resources | length) == 1 and
    $resources[0].provider == "provider[\"registry.terraform.io/hashicorp/helm\"]" and
    ($resources[0].instances | length) == 1 and
    $attributes.name == $release.name and
    $attributes.namespace == $release.namespace and
    $attributes.chart == $release.chart and
    $attributes.version == $release.version and
    $attributes.status == $release.status and
    (.lineage | type == "string" and test("^[0-9a-fA-F-]{36}$")) and
    (.serial | type == "number" and . == floor and . >= 1)
  ' <<<"$state_json" >/dev/null || fail "Terraform state does not contain the exact adopted Helm release owner"
}

adopt_release() {
  local terraform_root=$1 handoff=$2 output=$3 context=$4 validation_now observed_at expires_at
  local state_json handoff_sha before_release live_before after_release plan_json
  validation_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  validate_handoff "$handoff" "$validation_now"
  for command in jq kubectl helm terraform; do require_command "$command"; done
  verify_frozen_application "$context" "$handoff"
  before_release=$(jq -cS '.release' "$handoff")
  live_before=$(capture_live_release "$context" "$before_release")
  [[ "$(jq -cS . <<<"$live_before")" == "$before_release" ]] || \
    fail "live Helm release identity or UID changed after Phase A"

  terraform -chdir="$terraform_root" import 'module.external_secrets[0].helm_release.this' external-secrets/external-secrets
  temporary_plan_file=$(mktemp "${TMPDIR:-/tmp}/external-secrets-adoption-plan.XXXXXX")
  terraform -chdir="$terraform_root" plan -input=false -out="$temporary_plan_file"
  plan_json=$(terraform -chdir="$terraform_root" show -json "$temporary_plan_file")
  jq -e '
    [.resource_changes[]? |
      select(.address == "module.external_secrets[0].helm_release.this")] as $release |
    ($release | length) == 1 and
    $release[0].mode == "managed" and
    $release[0].type == "helm_release" and
    $release[0].name == "this" and
    $release[0].change.actions == ["no-op"] and
    all(.resource_changes[]?; .change.actions == ["no-op"])
  ' <<<"$plan_json" >/dev/null || \
    fail "post-import Terraform plan is not a no-op"

  state_json=$(terraform -chdir="$terraform_root" state pull)
  verify_terraform_state_owner "$state_json" "$before_release"
  after_release=$(capture_live_release "$context" "$before_release")
  verify_frozen_application "$context" "$handoff"
  [[ "$(jq -cS . <<<"$after_release")" == "$before_release" ]] || \
    fail "release identity or UID changed during Terraform adoption"

  observed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  expires_at=$(date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')
  validate_handoff "$handoff" "$observed_at"
  handoff_sha="sha256:$(sha256_file "$handoff")"
  temporary_output_file=$(mktemp "${output}.tmp.XXXXXX")
  jq -n --slurpfile handoff "$handoff" --arg handoffSha "$handoff_sha" \
    --arg lineage "$(jq -r '.lineage' <<<"$state_json")" \
    --argjson serial "$(jq -r '.serial' <<<"$state_json")" \
    --argjson before "$before_release" --argjson after "$after_release" \
    --arg observedAt "$observed_at" --arg expiresAt "$expires_at" '
      {
        schemaVersion:"course.platform-release-adoption/v1", evidenceGrade:"CLOUD_RUNTIME",
        environment:$handoff[0].environment, region:$handoff[0].region, clusterArn:$handoff[0].clusterArn,
        handoffSha256:$handoffSha,
        release:{before:$before,after:$after},
        terraform:{address:"module.external_secrets[0].helm_release.this",stateLineage:$lineage,stateSerial:$serial,imported:true,planActions:[]},
        observedAt:$observedAt, expiresAt:$expiresAt
      }
    ' >"$temporary_output_file"
  chmod 600 "$temporary_output_file"
  validate_adoption "$handoff" "$temporary_output_file" "$observed_at"
  mv -- "$temporary_output_file" "$output"
  temporary_output_file=
  rm -f -- "$temporary_plan_file"
  temporary_plan_file=
  printf 'ADOPTED: external-secrets/external-secrets is Terraform-owned; no apply was run.\n'
}

verify_phase_b() {
  local handoff=$1 adoption=$2 context=$3 now app
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  validate_adoption "$handoff" "$adoption" "$now"
  app=$(jq -r '.application.name' "$handoff")
  if kubectl --context "$context" -n argocd get application "$app" >/dev/null 2>&1; then
    fail "Phase B Application must be absent after Terraform adoption"
  fi
  verify_release_uids "$context" "$adoption" '.release.after'
  printf 'PHASE_B_READY: Application absent and imported UIDs unchanged.\n'
}

usage() {
  printf '%s\n' \
    'Usage:' \
    '  external-secrets-owner-handoff.sh validate-handoff <handoff.json> [now]' \
    '  external-secrets-owner-handoff.sh validate-adoption <handoff.json> <adoption.json> [now]' \
    '  external-secrets-owner-handoff.sh adopt <terraform-root> <handoff.json> <adoption-output.json> <kubectl-context>' \
    '  external-secrets-owner-handoff.sh verify-phase-b <handoff.json> <adoption.json> <kubectl-context>'
}

command=${1:-}
shift || true
case "$command" in
  validate-handoff) [[ $# -ge 1 ]] || { usage >&2; exit 64; }; validate_handoff "$@" ;;
  validate-adoption) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; validate_adoption "$@" ;;
  adopt) [[ $# -eq 4 ]] || { usage >&2; exit 64; }; adopt_release "$@" ;;
  verify-phase-b) [[ $# -eq 3 ]] || { usage >&2; exit 64; }; verify_phase_b "$@" ;;
  *) usage >&2; exit 64 ;;
esac
