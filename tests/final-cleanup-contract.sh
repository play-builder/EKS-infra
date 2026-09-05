#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/cleanup-fixture-helpers.sh"
source "$root/scripts/lib/terraform-plan-contract.sh"

if grep -Eq 'kubectl .*delete[[:space:]]+pvc' "$root/README.md"; then
  echo 'README bypasses guarded cleanup with direct PVC deletion' >&2
  exit 1
fi

runbook="$root/docs/runbook.md"
if grep -Fq 'GitOps Application과 Gateway를 삭제합니다.' "$runbook" || \
  grep -Fq '`04 → 03 → 02 → 01` 순서로 destroy합니다.' "$runbook"; then
  echo 'runbook bypasses the guarded Ch26 cleanup flow' >&2
  exit 1
fi
grep -Fq 'aws sts get-caller-identity --region "$AWS_REGION"' "$runbook" || {
  echo 'runbook AWS identity check must carry the selected Region explicitly' >&2
  exit 1
}
for required_argument in --saved-plan-dir --backend-bucket --request-identity --approval-run-id; do
  grep -Fq -- "$required_argument" "$root/README.md" || {
    echo "README cleanup invocation is missing $required_argument" >&2
    exit 1
  }
  grep -Fq -- "$required_argument" "$runbook" || {
    echo "runbook cleanup invocation is missing $required_argument" >&2
    exit 1
  }
done

runbook_line() {
  local marker=$1
  local line
  line=$(grep -nF -- "$marker" "$runbook" | head -n 1 | cut -d: -f1)
  [[ -n "$line" ]] || { echo "runbook cleanup marker missing: $marker" >&2; exit 1; }
  printf '%s\n' "$line"
}

runbook_preflight_line=$(runbook_line 'bash scripts/cleanup-preflight.sh')
runbook_decision_line=$(runbook_line 'evidence/cleanup/retain-decisions.json')
runbook_in_flight_line=$(runbook_line 'bash scripts/capture-in-flight-zero.sh')
runbook_freeze_line=$(runbook_line 'capture-cleanup-evidence.sh freeze')
runbook_removal_line=$(runbook_line 'capture-cleanup-evidence.sh removal')
runbook_final_line=$(runbook_line 'bash scripts/final-cleanup.sh')
runbook_reverse_line=$(runbook_line 'environments/prod/04-workloads/argocd')
if ! (( runbook_preflight_line < runbook_decision_line \
  && runbook_decision_line < runbook_in_flight_line \
  && runbook_in_flight_line < runbook_freeze_line \
  && runbook_freeze_line < runbook_removal_line \
  && runbook_removal_line < runbook_final_line \
  && runbook_final_line < runbook_reverse_line )); then
  echo 'runbook cleanup flow is not in guarded dependency order' >&2
  exit 1
fi

readme_line() {
  local marker=$1
  local line
  line=$(grep -nF -- "$marker" "$root/README.md" | head -n 1 | cut -d: -f1)
  [[ -n "$line" ]] || { echo "README cleanup marker missing: $marker" >&2; exit 1; }
  printf '%s\n' "$line"
}

preflight_line=$(readme_line 'bash scripts/cleanup-preflight.sh')
decision_line=$(readme_line 'evidence/cleanup/retain-decisions.json')
in_flight_capture_line=$(readme_line 'bash scripts/capture-in-flight-zero.sh')
in_flight_path_line=$(readme_line 'evidence/cleanup/in-flight-zero.json')
freeze_line=$(readme_line 'evidence/cleanup/freeze.json')
removal_line=$(readme_line 'evidence/cleanup/removal.json')
final_line=$(readme_line 'bash scripts/final-cleanup.sh')
reverse_line=$(readme_line 'environments/prod/04-workloads/argocd')
if ! (( preflight_line < decision_line && decision_line < in_flight_capture_line \
  && decision_line < in_flight_path_line && in_flight_capture_line < freeze_line \
  && in_flight_path_line < freeze_line && freeze_line <= removal_line \
  && removal_line < final_line && final_line < reverse_line )); then
  echo 'README cleanup flow is not in guarded dependency order' >&2
  exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/evidence" "$tmp_dir/saved-plan"
prepare_cleanup_fixtures "$root" "$tmp_dir/evidence" ap-northeast-2

plan="$root/tests/fixtures/cleanup-course-owned.json"
cleanup_layers=(
  environments/prod/04-workloads/argocd environments/dev/04-workloads/argocd
  environments/prod/03-platform environments/dev/03-platform
  environments/prod/02-eks environments/dev/02-eks
  environments/prod/01-network environments/dev/01-network
)
for layer in "${cleanup_layers[@]}"; do
  plan_dir="$tmp_dir/saved-plan/${layer//\//_}"
  mkdir -p "$plan_dir"
  cp "$plan" "$plan_dir/tfplan"
  jq '.terraform_version="1.16.0"' "$plan" >"$plan_dir/tfplan.json"
done
plan_sha=$(raw_sha256 "$plan")
inventory_sha=$(raw_sha256 "$tmp_dir/evidence/inventory.json")
observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
expires=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg plan "$plan_sha" --arg inventory "$inventory_sha" --arg observed "$observed" --arg expires "$expires" '
  {schemaVersion:"course.cleanup-preflight/v1",evidenceGrade:"CLOUD_RUNTIME",status:"PASS",
   courseId:"course-2026",accountId:"123456789012",region:"ap-northeast-2",
   planSha256:$plan,inventorySha256:$inventory,observedAt:$observed,expiresAt:$expires}
' >"$tmp_dir/evidence/preflight.json"
jq -n --arg observed "$observed" --arg expires "$expires" '
  {schemaVersion:"course.in-flight-zero/v1",evidenceGrade:"CLOUD_RUNTIME",status:"PASS",
   courseId:"course-2026",accountId:"123456789012",region:"ap-northeast-2",
   clusters:[
     {environment:"dev",context:"course-dev",clusterArn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/dev-playdevops-eks"},
     {environment:"prod",context:"course-prod",clusterArn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/prod-playdevops-eks"}],
   remainingWriters:{loadGenerators:0,chaosResources:0,recoveryJobs:0,migrationJobs:0},
   observedAt:$observed,expiresAt:$expires}
' >"$tmp_dir/evidence/in-flight.json"

cat >"$tmp_dir/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == 'version -json' ]]; then
  printf '{"terraform_version":"1.16.0"}\n'
  exit 0
fi
printf '%s\n' "$*" >>"$COURSE_FAKE_MUTATION_LOG"
if [[ "$*" == *"/02-eks apply"* ]]; then : >"$COURSE_EKS_DELETED_SENTINEL"; fi
EOF
cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ! -e "$COURSE_EKS_DELETED_SENTINEL" ]] || { echo 'kubectl called after EKS deletion' >&2; exit 99; }
[[ "${COURSE_FAKE_KUBECTL_FAIL:-false}" != true ]] || { echo 'simulated Kubernetes API failure' >&2; exit 96; }
printf '%s\n' "$*" >>"$COURSE_FAKE_KUBECTL_LOG"
printf '{"apiVersion":"v1","items":[]}\n'
EOF
cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_AWS_LOG"
case "$1 $2" in
  'sts get-caller-identity') printf '{"Account":"123456789012"}\n' ;;
  'elbv2 describe-load-balancers') printf '{"LoadBalancers":[]}\n' ;;
  'ec2 describe-nat-gateways') printf '{"NatGateways":[]}\n' ;;
  'eks list-clusters') printf '{"clusters":[]}\n' ;;
  'ec2 describe-volumes') printf '{"Volumes":[]}\n' ;;
  'ec2 describe-snapshots') printf '{"Snapshots":[{"SnapshotId":"snap-retained-001"}]}\n' ;;
  'resourcegroupstaggingapi get-resources') printf '{"ResourceTagMappingList":[]}\n' ;;
  'amp list-workspaces') printf '{"workspaces":[]}\n' ;;
  'sns list-topics') printf '{"Topics":[]}\n' ;;
  'ecr describe-repositories') printf '{"repositories":[{"repositoryArn":"arn:aws:ecr:ap-northeast-2:123456789012:repository/course/sample-app"}]}\n' ;;
  'secretsmanager describe-secret') printf '{"ARN":"arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:shared-provider"}\n' ;;
  *) echo "unexpected aws: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/terraform" "$tmp_dir/bin/kubectl" "$tmp_dir/bin/aws"

request_identity=release-requester
approval_identity=platform-approver
approval_run_id=987654321
for layer in "${cleanup_layers[@]}"; do
  plan_dir="$tmp_dir/saved-plan/${layer//\//_}"
  backend_key=$(terraform_plan_expected_backend_key_for_root "$layer")
  jq -n --arg request "$request_identity" --arg run "$approval_run_id" --arg approver "$approval_identity" '
    {schemaVersion:"platform.saved-plan-approval/v1",source:"github-actions-review-history",
     environment:"production",state:"approved",runId:$run,requestIdentity:$request,
     approvalIdentity:$approver}' >"$plan_dir/approval-evidence.json"
  saved_plan_sha=$(raw_sha256 "$plan_dir/tfplan")
  saved_plan_json_sha=$(raw_sha256 "$plan_dir/tfplan.json")
  binary_sha=$(raw_sha256 "$tmp_dir/bin/terraform")
  lock_sha=$(raw_sha256 "$root/$layer/.terraform.lock.hcl")
  approval_sha=$(raw_sha256 "$plan_dir/approval-evidence.json")
  printf '%s  tfplan\n' "$saved_plan_sha" >"$plan_dir/tfplan.sha256"
  printf '%s  tfplan.json\n' "$saved_plan_json_sha" >"$plan_dir/tfplan.json.sha256"
  jq -n --arg plan "$saved_plan_sha" --arg planJson "$saved_plan_json_sha" \
    --arg source "$(git -C "$root" rev-parse HEAD)" --arg layer "$layer" \
    --arg backend "$backend_key" --arg binary "$binary_sha" --arg lock "$lock_sha" \
    --arg request "$request_identity" --arg approver "$approval_identity" --arg run "$approval_run_id" \
    --arg approval "$approval_sha" '
    {schemaVersion:"platform.saved-plan/v1",accountId:"123456789012",region:"ap-northeast-2",
     terraformRoot:$layer,backendBucket:"cleanup-state",backendKey:$backend,
     lockIdentity:"s3-native-lockfile",sourceSha:$source,terraformVersion:"1.16.0",
     terraformBinarySha256:("sha256:"+$binary),providerLockSha256:("sha256:"+$lock),
     planSha256:("sha256:"+$plan),planJsonSha256:("sha256:"+$planJson),operation:"destroy",
     requestIdentity:$request,approvalIdentity:$approver,approvalRunId:$run,
     approvalEvidenceSha256:("sha256:"+$approval),createdAt:(now|todateiso8601)}
  ' >"$plan_dir/plan-identity.json"
done
: >"$tmp_dir/mutations.log"
: >"$tmp_dir/kubectl.log"
: >"$tmp_dir/aws.log"

common=(
  --saved-plan-dir "$tmp_dir/saved-plan"
  --backend-bucket cleanup-state
  --request-identity "$request_identity"
  --approval-run-id "$approval_run_id"
  --plan "$plan"
  --inventory "$tmp_dir/evidence/inventory.json"
  --retain-decisions "$tmp_dir/evidence/decisions.json"
  --preflight-evidence "$tmp_dir/evidence/preflight.json"
  --in-flight-evidence "$tmp_dir/evidence/in-flight.json"
  --gitops-freeze-evidence "$tmp_dir/evidence/freeze.json"
  --gitops-removal-evidence "$tmp_dir/evidence/removal.json"
  --dev-context course-dev --prod-context course-prod
  --kubernetes-pre-destroy-output "$tmp_dir/evidence/generated-pre-destroy.json"
  --residual-output "$tmp_dir/evidence/generated-residual.json"
)

first_plan="$tmp_dir/saved-plan/environments_prod_04-workloads_argocd"
cp "$first_plan/tfplan.json" "$first_plan/tfplan.json.valid"
cp "$first_plan/tfplan.json.sha256" "$first_plan/tfplan.json.sha256.valid"
cp "$first_plan/plan-identity.json" "$first_plan/plan-identity.json.valid"
jq '.resource_changes[0].change.actions=["update"]' "$first_plan/tfplan.json.valid" >"$first_plan/tfplan.json"
changed_sha=$(raw_sha256 "$first_plan/tfplan.json")
printf '%s  tfplan.json\n' "$changed_sha" >"$first_plan/tfplan.json.sha256"
jq --arg digest "$changed_sha" '.planJsonSha256=("sha256:"+$digest)' \
  "$first_plan/plan-identity.json.valid" >"$first_plan/plan-identity.json"
set +e
output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  bash "$root/scripts/final-cleanup.sh" "${common[@]}" 2>&1)
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *CLEANUP_PLAN_ACTION_NOT_ALLOWED* && ! -s "$tmp_dir/mutations.log" ]]
mv "$first_plan/tfplan.json.valid" "$first_plan/tfplan.json"
mv "$first_plan/tfplan.json.sha256.valid" "$first_plan/tfplan.json.sha256"
mv "$first_plan/plan-identity.json.valid" "$first_plan/plan-identity.json"

cp "$first_plan/plan-identity.json" "$first_plan/plan-identity.json.valid"
jq '.backendKey="attacker/other.tfstate"' "$first_plan/plan-identity.json.valid" >"$first_plan/plan-identity.json"
set +e
output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  bash "$root/scripts/final-cleanup.sh" "${common[@]}" 2>&1)
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *SAVED_PLAN_BACKEND_KEY_MISMATCH* && ! -s "$tmp_dir/mutations.log" ]]
mv "$first_plan/plan-identity.json.valid" "$first_plan/plan-identity.json"

cp "$tmp_dir/evidence/preflight.json" "$tmp_dir/evidence/preflight-valid.json"
assert_preflight_timestamp_rejected_before_cloud_calls() {
  local label=$1 field=$2 value=$3 status
  jq --arg field "$field" --arg value "$value" '.[$field]=$value' \
    "$tmp_dir/evidence/preflight-valid.json" >"$tmp_dir/evidence/preflight.json"
  : >"$tmp_dir/mutations.log"
  : >"$tmp_dir/kubectl.log"
  : >"$tmp_dir/aws.log"
  rm -f "$tmp_dir/eks-deleted"
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
  COURSE_EKS_DELETED_SENTINEL="$tmp_dir/eks-deleted" AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_ID=course-2026 \
    bash "$root/scripts/final-cleanup.sh" --execute "${common[@]}" \
      --confirm-account-id 123456789012 --confirm-region ap-northeast-2 --confirm-course-id course-2026 \
      >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 || -s "$tmp_dir/mutations.log" || -s "$tmp_dir/kubectl.log" || -s "$tmp_dir/aws.log" ]]; then
    echo "invalid cleanup preflight timestamp reached a cloud or mutation command: $label" >&2
    exit 1
  fi
}

for timestamp_case in \
  'observed-calendar|observedAt|2020-02-30T00:00:00Z' \
  'observed-fractional|observedAt|2020-03-01T00:00:00.123Z' \
  'observed-offset|observedAt|2020-03-01T09:00:00+09:00' \
  'expires-calendar|expiresAt|2099-02-31T00:00:00Z' \
  'expires-fractional|expiresAt|2099-03-01T00:00:00.123Z' \
  'expires-offset|expiresAt|2099-03-01T09:00:00+09:00'; do
  IFS='|' read -r label field value <<<"$timestamp_case"
  assert_preflight_timestamp_rejected_before_cloud_calls "$label" "$field" "$value"
done
cp "$tmp_dir/evidence/preflight-valid.json" "$tmp_dir/evidence/preflight.json"

cp "$tmp_dir/evidence/in-flight.json" "$tmp_dir/evidence/in-flight-valid.json"
assert_in_flight_rejected_before_cloud_calls() {
  local label=$1 filter=$2
  jq "$filter" "$tmp_dir/evidence/in-flight-valid.json" >"$tmp_dir/evidence/in-flight.json"
  : >"$tmp_dir/mutations.log"
  : >"$tmp_dir/kubectl.log"
  : >"$tmp_dir/aws.log"
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
  COURSE_EKS_DELETED_SENTINEL="$tmp_dir/eks-deleted" AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_ID=course-2026 \
    bash "$root/scripts/final-cleanup.sh" --execute "${common[@]}" \
      --confirm-account-id 123456789012 --confirm-region ap-northeast-2 --confirm-course-id course-2026 \
      >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 || -s "$tmp_dir/mutations.log" || -s "$tmp_dir/kubectl.log" || -s "$tmp_dir/aws.log" ]]; then
    echo "invalid in-flight evidence reached a cloud or mutation command: $label" >&2
    exit 1
  fi
}

assert_in_flight_rejected_before_cloud_calls stale '.expiresAt="2020-09-03T01:00:00Z"'
assert_in_flight_rejected_before_cloud_calls old-schema '.schemaVersion="course.in-flight-zero/v0"'
assert_in_flight_rejected_before_cloud_calls wrong-cluster \
  '.clusters[1].clusterArn="arn:aws:eks:ap-northeast-2:123456789012:cluster/other-prod"'
assert_in_flight_rejected_before_cloud_calls wrong-context '.clusters[1].context="not-course-prod"'
cp "$tmp_dir/evidence/in-flight-valid.json" "$tmp_dir/evidence/in-flight.json"

: >"$tmp_dir/mutations.log"
: >"$tmp_dir/kubectl.log"
: >"$tmp_dir/aws.log"
rm -f "$tmp_dir/eks-deleted" "$tmp_dir/evidence/runtime-pre-destroy.json" "$tmp_dir/evidence/runtime-residual.json"
set +e
output=$(PATH="$tmp_dir/bin:$PATH" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
  COURSE_EKS_DELETED_SENTINEL="$tmp_dir/eks-deleted" AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_ID=course-2026 \
    bash "$root/scripts/final-cleanup.sh" --execute "${common[@]}" \
      --kubernetes-pre-destroy-output "$tmp_dir/evidence/runtime-pre-destroy.json" \
      --residual-output "$tmp_dir/evidence/runtime-residual.json" \
      --confirm-account-id 123456789012 --confirm-region ap-northeast-2 --confirm-course-id course-2026 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'NONCANONICAL_RUNTIME_OUTPUT' <<<"$output"; then
  echo 'real final cleanup accepted noncanonical evidence outputs' >&2
  exit 1
fi
[[ ! -s "$tmp_dir/mutations.log" && ! -s "$tmp_dir/kubectl.log" && ! -s "$tmp_dir/aws.log" ]]
[[ ! -e "$tmp_dir/evidence/runtime-pre-destroy.json" && ! -e "$tmp_dir/evidence/runtime-residual.json" ]]

: >"$tmp_dir/mutations.log"
: >"$tmp_dir/kubectl.log"
: >"$tmp_dir/aws.log"
rm -f "$tmp_dir/eks-deleted"
set +e
output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
  COURSE_EKS_DELETED_SENTINEL="$tmp_dir/eks-deleted" AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_ID=course-2026 \
    bash "$root/scripts/final-cleanup.sh" --execute "${common[@]}" \
      --kubernetes-pre-destroy-output "$root/evidence/cleanup/../cleanup/kubernetes-pre-destroy.json" \
      --confirm-account-id 123456789012 --confirm-region ap-northeast-2 --confirm-course-id course-2026 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'FIXTURE_RUNTIME_OUTPUT_BLOCKED' <<<"$output"; then
  echo 'fixture final cleanup did not block a canonical output alias' >&2
  exit 1
fi
[[ ! -s "$tmp_dir/mutations.log" && ! -s "$tmp_dir/kubectl.log" && ! -s "$tmp_dir/aws.log" ]]

COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  bash "$root/scripts/course-check.sh" ch26 --final-cleanup "${common[@]}"
[[ ! -s "$tmp_dir/mutations.log" && ! -e "$tmp_dir/evidence/generated-residual.json" ]]

set +e
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  bash "$root/scripts/course-check.sh" ch26 --execute "${common[@]}" \
    --confirm-account-id 123456789012 --confirm-region ap-northeast-2 >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -s "$tmp_dir/mutations.log" ]]; then
  echo 'incomplete final-cleanup guards must fail before mutation' >&2
  exit 1
fi

set +e
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
COURSE_EKS_DELETED_SENTINEL="$tmp_dir/eks-deleted" COURSE_FAKE_KUBECTL_FAIL=true \
AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_ID=course-2026 \
  bash "$root/scripts/course-check.sh" ch26 --execute "${common[@]}" \
    --confirm-account-id 123456789012 --confirm-region ap-northeast-2 --confirm-course-id course-2026 \
    >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -s "$tmp_dir/mutations.log" ]]; then
  echo 'failed Kubernetes pre-destroy scan must stop before Terraform mutation' >&2
  exit 1
fi
rm -f "$tmp_dir/stages.log" "$tmp_dir/evidence/generated-pre-destroy.json"

COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
COURSE_EKS_DELETED_SENTINEL="$tmp_dir/eks-deleted" COURSE_CLEANUP_STAGE_LOG="$tmp_dir/stages.log" \
AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_ID=course-2026 \
  bash "$root/scripts/course-check.sh" ch26 --execute "${common[@]}" \
    --confirm-account-id 123456789012 --confirm-region ap-northeast-2 --confirm-course-id course-2026

jq -e '.evidenceGrade == "STATIC" and .status == "PASS" and .unapprovedCourseOwned.total == 0' \
  "$tmp_dir/evidence/generated-residual.json" >/dev/null
[[ $(paste -sd',' "$tmp_dir/stages.log") == '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15' ]]
[[ -s "$tmp_dir/kubectl.log" ]]
grep -Fq -- '--region ap-northeast-2' "$tmp_dir/aws.log"

echo 'PASS: guarded ordered final cleanup contract'
