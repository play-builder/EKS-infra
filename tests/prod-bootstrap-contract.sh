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
