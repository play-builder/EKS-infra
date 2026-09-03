#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/task5-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

cat >"$tmp_dir/manual.json" <<'JSON'
{"apiVersion":"argoproj.io/v1alpha1","kind":"Application","metadata":{"name":"course-prod-bootstrap","namespace":"argocd"},"spec":{"project":"default","source":{"repoURL":"https://github.com/play-builder/argocd-gitops.git","targetRevision":"main","path":"argocd/bootstrap/prod"},"destination":{"server":"https://kubernetes.default.svc","namespace":"argocd"},"syncPolicy":{"syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}
JSON
jq '.spec.syncPolicy.automated={"prune":true,"selfHeal":true}' "$tmp_dir/manual.json" >"$tmp_dir/automated.json"

ready="$root/tests/fixtures/dev-ready-ap-northeast-2.json"
make_dev_handoff "$ready" "$tmp_dir/deployment.json" "$tmp_dir/slo.json"
deployment_sha=$(sha256_file "$tmp_dir/deployment.json")
slo_sha=$(sha256_file "$tmp_dir/slo.json")
ready_sha=$(sha256_file "$ready")
jq -n --arg deployment "$deployment_sha" --arg slo "$slo_sha" --arg ready "$ready_sha" '
  {
    schemaVersion:"course.prod-preflight/v1",evidenceGrade:"STATIC",stage:"design",decision:"GO",
    courseId:"course-2026",accountId:"123456789012",region:"ap-northeast-2",
    bindings:{devDeploymentSha256:$deployment,devSloSha256:$slo,devReadySha256:$ready,
      savedPlanSha256:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      capacityInputSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      previousDecisionSha256:null},
    issuedAt:"2026-09-03T00:00:00Z",expiresAt:"2099-09-03T01:00:00Z"
  }
' >"$tmp_dir/design.json"
design_sha=$(sha256_file "$tmp_dir/design.json")
jq --arg previous "$design_sha" '.stage="estimate" | .evidenceGrade="STATIC" | .bindings.previousDecisionSha256=$previous' \
  "$tmp_dir/design.json" >"$tmp_dir/estimate.json"

COURSE_ID=course-2026 AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_CHECK_BIN_DIR="$tmp_dir" \
  bash "$root/scripts/prod-bootstrap-check.sh" "$tmp_dir/manual.json" "$tmp_dir/deployment.json" \
    "$tmp_dir/slo.json" "$ready" "$tmp_dir/design.json" "$tmp_dir/estimate.json"
set +e
COURSE_ID=course-2026 AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_CHECK_BIN_DIR="$tmp_dir" \
  bash "$root/scripts/prod-bootstrap-check.sh" "$tmp_dir/automated.json" "$tmp_dir/deployment.json" \
    "$tmp_dir/slo.json" "$ready" "$tmp_dir/design.json" "$tmp_dir/estimate.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo 'expected automated Prod bootstrap to fail' >&2
  exit 1
fi

expect_decision_timestamp_rejected() {
  local label=$1 decision_kind=$2 field=$3 value=$4
  local design_candidate="$tmp_dir/design-$label.json"
  local estimate_candidate="$tmp_dir/estimate-$label.json"
  local updated_design_sha
  jq . "$tmp_dir/design.json" >"$design_candidate"
  jq . "$tmp_dir/estimate.json" >"$estimate_candidate"
  if [[ "$decision_kind" == design ]]; then
    jq --arg field "$field" --arg value "$value" '.[$field]=$value' "$tmp_dir/design.json" >"$design_candidate"
    updated_design_sha=$(sha256_file "$design_candidate")
    jq --arg previous "$updated_design_sha" '.bindings.previousDecisionSha256=$previous' \
      "$tmp_dir/estimate.json" >"$estimate_candidate"
  else
    jq --arg field "$field" --arg value "$value" '.[$field]=$value' "$tmp_dir/estimate.json" >"$estimate_candidate"
  fi
  if COURSE_ID=course-2026 AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_CHECK_BIN_DIR="$tmp_dir" \
    bash "$root/scripts/prod-bootstrap-check.sh" "$tmp_dir/manual.json" "$tmp_dir/deployment.json" \
      "$tmp_dir/slo.json" "$ready" "$design_candidate" "$estimate_candidate" >/dev/null 2>&1; then
    echo "expected $label decision timestamp to fail" >&2
    exit 1
  fi
}

expect_decision_timestamp_rejected design-issued-invalid-calendar design issuedAt '2020-02-30T00:00:00Z'
expect_decision_timestamp_rejected design-expires-invalid-calendar design expiresAt '2099-02-31T00:00:00Z'
expect_decision_timestamp_rejected estimate-issued-invalid-calendar estimate issuedAt '2020-02-30T00:00:00Z'
expect_decision_timestamp_rejected estimate-expires-invalid-calendar estimate expiresAt '2099-02-31T00:00:00Z'

jq '.expiresAt="2026-01-01T00:00:00Z"' "$tmp_dir/estimate.json" >"$tmp_dir/stale-estimate.json"
set +e
COURSE_ID=course-2026 AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_CHECK_BIN_DIR="$tmp_dir" \
  bash "$root/scripts/prod-bootstrap-check.sh" "$tmp_dir/manual.json" "$tmp_dir/deployment.json" \
    "$tmp_dir/slo.json" "$ready" "$tmp_dir/design.json" "$tmp_dir/stale-estimate.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo 'expected expired estimate evidence to fail' >&2
  exit 1
fi

echo 'PASS: Prod bootstrap requires manual sync'
