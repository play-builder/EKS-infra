#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/cleanup-fixture-helpers.sh"

if grep -Eq 'kubectl .*delete[[:space:]]+pvc' "$root/README.md"; then
  echo 'README bypasses guarded cleanup with direct PVC deletion' >&2
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
freeze_line=$(readme_line 'evidence/cleanup/freeze.json')
removal_line=$(readme_line 'evidence/cleanup/removal.json')
final_line=$(readme_line 'bash scripts/final-cleanup.sh')
reverse_line=$(readme_line 'environments/prod/04-workloads/argocd')
if ! (( preflight_line < decision_line && decision_line < freeze_line && freeze_line <= removal_line \
  && removal_line < final_line && final_line < reverse_line )); then
  echo 'README cleanup flow is not in guarded dependency order' >&2
  exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/evidence"
prepare_cleanup_fixtures "$root" "$tmp_dir/evidence" ap-northeast-2

plan="$root/tests/fixtures/cleanup-course-owned.json"
plan_sha=$(raw_sha256 "$plan")
inventory_sha=$(raw_sha256 "$tmp_dir/evidence/inventory.json")
jq -n --arg plan "$plan_sha" --arg inventory "$inventory_sha" '
  {schemaVersion:"course.cleanup-preflight/v1",evidenceGrade:"CLOUD_RUNTIME",status:"PASS",
   courseId:"course-2026",accountId:"123456789012",region:"ap-northeast-2",
   planSha256:$plan,inventorySha256:$inventory,observedAt:"2026-09-03T00:05:00Z",expiresAt:"2099-09-03T01:00:00Z"}
' >"$tmp_dir/evidence/preflight.json"
jq -n '
  {schemaVersion:"course.in-flight-zero/v1",evidenceGrade:"CLOUD_RUNTIME",status:"PASS",
   courseId:"course-2026",accountId:"123456789012",region:"ap-northeast-2",
   remainingWriters:{loadGenerators:0,chaosResources:0,recoveryJobs:0,migrationJobs:0},
   observedAt:"2026-09-03T00:09:00Z",expiresAt:"2099-09-03T01:00:00Z"}
' >"$tmp_dir/evidence/in-flight.json"

cat >"$tmp_dir/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_MUTATION_LOG"
if [[ "$*" == *"/02-eks destroy"* ]]; then : >"$COURSE_EKS_DELETED_SENTINEL"; fi
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
  'amp list-workspaces') printf '{"workspaces":[]}\n' ;;
  'sns list-topics') printf '{"Topics":[]}\n' ;;
  'ecr describe-repositories') printf '{"repositories":[{"repositoryArn":"arn:aws:ecr:ap-northeast-2:123456789012:repository/course/sample-app"}]}\n' ;;
  'secretsmanager describe-secret') printf '{"ARN":"arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:shared-provider"}\n' ;;
  *) echo "unexpected aws: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/terraform" "$tmp_dir/bin/kubectl" "$tmp_dir/bin/aws"
: >"$tmp_dir/mutations.log"
: >"$tmp_dir/kubectl.log"
: >"$tmp_dir/aws.log"

common=(
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
