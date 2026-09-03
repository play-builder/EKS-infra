#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'PLATFORM_OWNER_HANDOFF_BLOCKED: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

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
    (keys | sort) == (["clusterArn","environment","evidenceGrade","expiresAt","handoffSha256","observedAt","region","release","schemaVersion","terraform"] | sort) and
    .schemaVersion == "course.platform-release-adoption/v1" and
    .evidenceGrade == "CLOUD_RUNTIME" and
    .handoffSha256 == $handoff_sha and
    .environment == $handoff[0].environment and
    .region == $handoff[0].region and
    .clusterArn == $handoff[0].clusterArn and
    (.release | keys | sort) == (["chart","crdUids","helmStorageObjectUid","name","namespace","valuesSha256","version","workloadUids"] | sort) and
    .release.namespace == $handoff[0].release.namespace and
    .release.name == $handoff[0].release.name and
    .release.chart == $handoff[0].release.chart and
    .release.version == $handoff[0].release.version and
    .release.valuesSha256 == $handoff[0].release.valuesSha256 and
    .release.helmStorageObjectUid == $handoff[0].release.helmStorageObjectUid and
    (.release.workloadUids | sort_by(.kind,.name,.uid)) == ($handoff[0].release.workloadUids | sort_by(.kind,.name,.uid)) and
    (.release.crdUids | sort_by(.name,.uid)) == ($handoff[0].release.crdUids | sort_by(.name,.uid)) and
    (.terraform | keys | sort) == (["address","imported","planActions","stateLineage","stateSerial"] | sort) and
    .terraform.address == "module.external_secrets[0].helm_release.this" and
    .terraform.imported == true and
    .terraform.planActions == [] and
    (.terraform.stateLineage | type == "string" and length > 0) and
    (.terraform.stateSerial | type == "number" and . >= 0) and
    ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)) and
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

verify_release_uids() {
  local context=$1 evidence=$2 item actual kind name uid
  while IFS=$'\t' read -r kind name uid; do
    actual=$(kubectl --context "$context" -n external-secrets get "$kind" "$name" -o json | jq -r '.metadata.uid')
    [[ "$actual" == "$uid" ]] || fail "workload UID changed during ownership transfer: $kind/$name"
  done < <(jq -r '.release.workloadUids[] | [.kind,.name,.uid] | @tsv' "$evidence")
  while IFS=$'\t' read -r name uid; do
    actual=$(kubectl --context "$context" get crd "$name" -o json | jq -r '.metadata.uid')
    [[ "$actual" == "$uid" ]] || fail "CRD UID changed during ownership transfer: $name"
  done < <(jq -r '.release.crdUids[] | [.name,.uid] | @tsv' "$evidence")
}

adopt_release() {
  local terraform_root=$1 handoff=$2 output=$3 context=$4 now tmp plan_file state_json handoff_sha
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  validate_handoff "$handoff" "$now"
  for command in jq kubectl helm terraform; do require_command "$command"; done
  verify_frozen_application "$context" "$handoff"
  verify_release_uids "$context" "$handoff"

  local values_sha live_values_sha helm_status
  live_values_sha=$(helm --kube-context "$context" -n external-secrets get values external-secrets -a -o json \
    | jq -S -c . | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk '{print "sha256:"$1}')
  values_sha=$(jq -r '.release.valuesSha256' "$handoff")
  [[ "$live_values_sha" == "$values_sha" ]] || fail "live Helm values digest changed after Phase A"
  helm_status=$(helm --kube-context "$context" -n external-secrets status external-secrets -o json)
  jq -e --slurpfile handoff "$handoff" '
    .info.status == "deployed" and
    .version == $handoff[0].release.revision
  ' <<<"$helm_status" >/dev/null || fail "live Helm release status/revision changed"

  terraform -chdir="$terraform_root" import 'module.external_secrets[0].helm_release.this' external-secrets/external-secrets
  plan_file=$(mktemp "${TMPDIR:-/tmp}/external-secrets-adoption-plan.XXXXXX")
  terraform -chdir="$terraform_root" plan -input=false -out="$plan_file"
  terraform -chdir="$terraform_root" show -json "$plan_file" \
    | jq -e '[.resource_changes[]? | select(.change.actions != ["no-op"])] | length == 0' >/dev/null || \
    fail "post-import Terraform plan is not a no-op"

  state_json=$(terraform -chdir="$terraform_root" state pull)
  handoff_sha="sha256:$(sha256_file "$handoff")"
  tmp=$(mktemp "${output}.tmp.XXXXXX")
  trap 'rm -f -- "$tmp" "$plan_file"' EXIT
  jq -n --slurpfile handoff "$handoff" --arg handoffSha "$handoff_sha" \
    --arg lineage "$(jq -r '.lineage' <<<"$state_json")" \
    --argjson serial "$(jq -r '.serial' <<<"$state_json")" \
    --arg observedAt "$now" --arg expiresAt "$(date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" '
      {
        schemaVersion:"course.platform-release-adoption/v1", evidenceGrade:"CLOUD_RUNTIME",
        environment:$handoff[0].environment, region:$handoff[0].region, clusterArn:$handoff[0].clusterArn,
        handoffSha256:$handoffSha,
        release:($handoff[0].release | del(.revision,.status)),
        terraform:{address:"module.external_secrets[0].helm_release.this",stateLineage:$lineage,stateSerial:$serial,imported:true,planActions:[]},
        observedAt:$observedAt, expiresAt:$expiresAt
      }
    ' >"$tmp"
  mv -- "$tmp" "$output"
  validate_adoption "$handoff" "$output" "$now"
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
  verify_release_uids "$context" "$adoption"
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
