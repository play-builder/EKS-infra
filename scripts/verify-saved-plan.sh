#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
source "$script_dir/lib/terraform-plan-contract.sh"
source "$script_dir/lib/evidence-common.sh"

artifact_dir=${1:?artifact directory is required}
terraform_root=${2:?terraform root is required}
account_id=${3:?account id is required}
region=${4:?region is required}
backend_bucket=${5:?backend bucket is required}
backend_key=${6:?backend key is required}
lock_identity=${7:?lock identity is required}
source_sha=${8:?source sha is required}
request_identity=${9:?request identity is required}
approval_run_id=${10:?approval run ID is required}
expected_operation=${11:?expected operation is required}

fail() { printf 'SAVED_PLAN_%s\n' "$1" >&2; exit 1; }
[[ "$terraform_root" != /* && "$terraform_root" != *..* ]] || fail ROOT_NOT_ALLOWED
expected_backend_key=$(terraform_plan_expected_backend_key_for_root "$terraform_root")
[[ "$backend_key" == "$expected_backend_key" ]] || fail BACKEND_KEY_NOT_ALLOWED
[[ "$expected_operation" == apply || "$expected_operation" == destroy ]] || fail OPERATION_INVALID
[[ "$request_identity" =~ [^[:space:]] && "$request_identity" != pending ]] || fail REQUEST_IDENTITY_INVALID
[[ "$approval_run_id" =~ ^[1-9][0-9]*$ ]] || fail APPROVAL_RUN_ID_INVALID
course_validate_account "$account_id"
course_validate_region "$region"

manifest="$artifact_dir/plan-identity.json"
plan="$artifact_dir/tfplan"
plan_json="$artifact_dir/tfplan.json"
plan_checksum="$artifact_dir/tfplan.sha256"
plan_json_checksum="$artifact_dir/tfplan.json.sha256"
approval_evidence="$artifact_dir/approval-evidence.json"
for file in "$manifest" "$plan" "$plan_json" "$plan_checksum" "$plan_json_checksum" "$approval_evidence"; do
  [[ -f "$file" && ! -L "$file" ]] || fail ARTIFACT_MISSING
done
jq -e . "$manifest" >/dev/null || fail MANIFEST_INVALID
jq -e . "$plan_json" >/dev/null || fail PLAN_JSON_INVALID
jq -e . "$approval_evidence" >/dev/null || fail APPROVAL_EVIDENCE_INVALID

[[ $(jq -r '.schemaVersion' "$manifest") == platform.saved-plan/v1 ]] || fail SCHEMA_INVALID
[[ $(jq -r '.accountId' "$manifest") == "$account_id" ]] || fail ACCOUNT_MISMATCH
[[ $(jq -r '.region' "$manifest") == "$region" ]] || fail REGION_MISMATCH
[[ $(jq -r '.terraformRoot' "$manifest") == "$terraform_root" ]] || fail ROOT_MISMATCH
[[ $(jq -r '.backendBucket' "$manifest") == "$backend_bucket" ]] || fail BACKEND_BUCKET_MISMATCH
[[ $(jq -r '.backendKey' "$manifest") == "$backend_key" ]] || fail BACKEND_KEY_MISMATCH
[[ $(jq -r '.lockIdentity' "$manifest") == "$lock_identity" ]] || fail LOCK_IDENTITY_MISMATCH
[[ $(jq -r '.sourceSha' "$manifest") == "$source_sha" ]] || fail SOURCE_SHA_MISMATCH
[[ $(jq -r '.operation' "$manifest") == "$expected_operation" ]] || fail OPERATION_MISMATCH
[[ $(jq -r '.requestIdentity' "$manifest") == "$request_identity" ]] || fail REQUEST_IDENTITY_MISMATCH

approval_identity=$(jq -r '.approvalIdentity // empty' "$manifest")
[[ "$approval_identity" =~ [^[:space:]] && "$approval_identity" != pending ]] || fail APPROVAL_INVALID
approval_lower=$(printf '%s' "$approval_identity" | tr '[:upper:]' '[:lower:]')
request_lower=$(printf '%s' "$request_identity" | tr '[:upper:]' '[:lower:]')
[[ "$approval_lower" != "$request_lower" ]] || fail SELF_APPROVAL
[[ $(jq -r '.approvalRunId // empty' "$manifest") == "$approval_run_id" ]] || fail APPROVAL_RUN_ID_MISMATCH

approval_sha="sha256:$(course_raw_sha256_file "$approval_evidence")"
[[ $(jq -r '.approvalEvidenceSha256 // empty' "$manifest") == "$approval_sha" ]] || fail APPROVAL_EVIDENCE_DIGEST_MISMATCH
jq -e --arg approver "$approval_identity" --arg requester "$request_identity" --arg run "$approval_run_id" '
  .schemaVersion == "platform.saved-plan-approval/v1" and
  .source == "github-actions-review-history" and .environment == "production" and
  .state == "approved" and .runId == $run and .requestIdentity == $requester and
  .approvalIdentity == $approver and
  (.approvalIdentity | type == "string" and test("[^[:space:]\\uFEFF]")) and
  ((.approvalIdentity | ascii_downcase) != (.requestIdentity | ascii_downcase))
' "$approval_evidence" >/dev/null || fail APPROVAL_EVIDENCE_INVALID

# Reject stale/tampered FinOps evidence and re-read actual configuration before
# any Terraform invocation (including provider initialization in the workflow).
python3 -I "$script_dir/lib/finops-plan.py" verify --artifact "$artifact_dir" \
  --root "$terraform_root" --operation "$expected_operation" --account "$account_id" --region "$region" >/dev/null

terraform_binary=$(terraform_plan_binary_path)
current_version=$("$terraform_binary" version -json | jq -er '.terraform_version | select(type == "string" and length > 0)') || \
  fail TERRAFORM_VERSION_UNAVAILABLE
current_binary_sha="sha256:$(course_raw_sha256_file "$terraform_binary")"
lock_file="$repo_root/$terraform_root/.terraform.lock.hcl"
[[ -f "$lock_file" && ! -L "$lock_file" ]] || fail PROVIDER_LOCK_MISSING
git -C "$repo_root" ls-files --error-unmatch "$terraform_root/.terraform.lock.hcl" >/dev/null 2>&1 || \
  fail PROVIDER_LOCK_NOT_TRACKED
current_lock_sha="sha256:$(course_raw_sha256_file "$lock_file")"
[[ $(jq -r '.terraformVersion' "$manifest") == "$current_version" ]] || fail TERRAFORM_VERSION_MISMATCH
[[ $(jq -r '.terraformBinarySha256' "$manifest") == "$current_binary_sha" ]] || fail TERRAFORM_BINARY_MISMATCH
[[ $(jq -r '.providerLockSha256' "$manifest") == "$current_lock_sha" ]] || fail PROVIDER_LOCK_MISMATCH
[[ $(jq -r '.terraform_version // empty' "$plan_json") == "$current_version" ]] || fail PLAN_JSON_TERRAFORM_VERSION_MISMATCH

plan_sha="sha256:$(course_raw_sha256_file "$plan")"
plan_json_sha="sha256:$(course_raw_sha256_file "$plan_json")"
[[ $(jq -r '.planSha256' "$manifest") == "$plan_sha" ]] || fail PLAN_DIGEST_MISMATCH
[[ $(jq -r '.planJsonSha256' "$manifest") == "$plan_json_sha" ]] || fail PLAN_JSON_DIGEST_MISMATCH
[[ $(<"$plan_checksum") == "${plan_sha#sha256:}  tfplan" ]] || fail PLAN_CHECKSUM_INVALID
[[ $(<"$plan_json_checksum") == "${plan_json_sha#sha256:}  tfplan.json" ]] || fail PLAN_JSON_CHECKSUM_INVALID

if [[ "$expected_operation" == destroy ]]; then
  jq -e '
    (.resource_changes | type == "array") and
    all(.resource_changes[]?;
      (.change.actions | type == "array") and
      all(.change.actions[]; . == "delete" or . == "no-op" or . == "read"))
  ' "$plan_json" >/dev/null || fail DESTROY_ACTION_NOT_ALLOWED
fi

echo 'PASS: saved Terraform plan identity and approval history verified without recalculation.'
