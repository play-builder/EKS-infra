#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_KUBECTL_LOG"
if [[ "$*" == *"get rollout sample-app"* ]]; then
  jq '.rollout' "$COURSE_BASELINE_FIXTURE"
elif [[ "$*" == *"get replicasets"* ]]; then
  jq '.replicaSets' "$COURSE_BASELINE_FIXTURE"
elif [[ "$*" == *"get analysisruns"* ]]; then
  jq '.analysisRuns' "$COURSE_BASELINE_FIXTURE"
else
  exit 97
fi
EOF
chmod +x "$tmp_dir/bin/kubectl"

grep -Fq '`course.prod-rollout-baseline/v1`' "$root/README.md" || {
  echo 'README does not identify the EKS-only Rollout baseline assertion schema' >&2
  exit 1
}
grep -Fq '`argocd-gitops/scripts/capture-prod-baseline-evidence.sh`' "$root/README.md" || {
  echo 'README does not identify the canonical promotion baseline producer' >&2
  exit 1
}

for region in ap-northeast-2 us-east-1; do
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_BASELINE_FIXTURE="$root/tests/fixtures/prod-baseline-rollout-healthy.json" \
  COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kube-$region.log" AWS_REGION="$region" AWS_ACCOUNT_ID=123456789012 \
    bash "$root/scripts/prod-baseline-check.sh" course-prod sample-app "$tmp_dir/baseline-$region.json"
  jq -e '
    keys == ["analysisRunsStarted","evidenceGrade","kubectlContext","namespace","observedAt","region","replicas","rolloutName","rolloutUid","schemaVersion","stablePodHash","stableRevision","status"] and
    .schemaVersion == "course.prod-rollout-baseline/v1" and
    .evidenceGrade == "STATIC" and .status == "HEALTHY" and .namespace == "app-prod" and
    .stableRevision == 1 and .analysisRunsStarted == 0
  ' \
    "$tmp_dir/baseline-$region.json" >/dev/null
  grep -Fq -- '--context course-prod -n app-prod get rollout sample-app -o json' "$tmp_dir/kube-$region.log"
done

set +e
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_BASELINE_FIXTURE="$root/tests/fixtures/prod-baseline-rollout-healthy.json" \
COURSE_FAKE_KUBECTL_LOG="$tmp_dir/wrong-namespace.log" AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 \
  bash "$root/scripts/prod-baseline-check.sh" course-prod prod sample-app "$tmp_dir/wrong-namespace.json" \
  >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$tmp_dir/wrong-namespace.json" || -s "$tmp_dir/wrong-namespace.log" ]]; then
  echo 'caller-selected Prod namespace was not rejected before kubectl' >&2
  exit 1
fi

jq '.analysisRuns.items=[{"metadata":{"name":"unexpected-analysis","ownerReferences":[{"kind":"Rollout","name":"sample-app","uid":"rollout-uid-1"}]},"status":{"phase":"Successful"}}]' \
  "$root/tests/fixtures/prod-baseline-rollout-healthy.json" >"$tmp_dir/analysis-started.json"
set +e
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_BASELINE_FIXTURE="$tmp_dir/analysis-started.json" \
COURSE_FAKE_KUBECTL_LOG="$tmp_dir/bad.log" AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 \
  bash "$root/scripts/prod-baseline-check.sh" course-prod sample-app "$tmp_dir/rejected.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$tmp_dir/rejected.json" ]]; then
  echo 'expected baseline AnalysisRun to block baseline evidence' >&2
  exit 1
fi

jq '.replicaSets.items[0].metadata.annotations["rollout.argoproj.io/revision"]="2"' \
  "$root/tests/fixtures/prod-baseline-rollout-healthy.json" >"$tmp_dir/wrong-revision.json"
set +e
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_BASELINE_FIXTURE="$tmp_dir/wrong-revision.json" \
COURSE_FAKE_KUBECTL_LOG="$tmp_dir/revision.log" AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 \
  bash "$root/scripts/prod-baseline-check.sh" course-prod sample-app "$tmp_dir/rejected-revision.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$tmp_dir/rejected-revision.json" ]]; then
  echo 'expected non-revision-1 stable ReplicaSet to fail' >&2
  exit 1
fi

echo 'PASS: manual-sync Prod baseline Rollout contract'
