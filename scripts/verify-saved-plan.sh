#!/usr/bin/env bash
set -Eeuo pipefail

artifact_dir=${1:?artifact directory is required}
terraform_root=${2:?terraform root is required}
account_id=${3:?account id is required}
region=${4:?region is required}
backend_bucket=${5:?backend bucket is required}
backend_key=${6:?backend key is required}
lock_identity=${7:?lock identity is required}
source_sha=${8:?source sha is required}
manifest="$artifact_dir/plan-identity.json"
plan="$artifact_dir/tfplan"
plan_json="$artifact_dir/tfplan.json"

fail() { echo "SAVED_PLAN_$1" >&2; exit 1; }
[[ -f "$manifest" && -f "$plan" && -f "$plan_json" ]] || fail ARTIFACT_MISSING
[[ $(jq -r '.schemaVersion' "$manifest") == platform.saved-plan/v1 ]] || fail SCHEMA_INVALID
[[ $(jq -r '.accountId' "$manifest") == "$account_id" ]] || fail ACCOUNT_MISMATCH
[[ $(jq -r '.region' "$manifest") == "$region" ]] || fail REGION_MISMATCH
[[ $(jq -r '.terraformRoot' "$manifest") == "$terraform_root" ]] || fail ROOT_MISMATCH
[[ $(jq -r '.backendBucket' "$manifest") == "$backend_bucket" ]] || fail BACKEND_BUCKET_MISMATCH
[[ $(jq -r '.backendKey' "$manifest") == "$backend_key" ]] || fail BACKEND_KEY_MISMATCH
[[ $(jq -r '.lockIdentity' "$manifest") == "$lock_identity" ]] || fail LOCK_IDENTITY_MISMATCH
[[ $(jq -r '.sourceSha' "$manifest") == "$source_sha" ]] || fail SOURCE_SHA_MISMATCH
[[ $(jq -r '.approvalIdentity // empty' "$manifest") =~ [^[:space:]] ]] || fail APPROVAL_IDENTITY_MISSING

plan_sha="sha256:$(shasum -a 256 "$plan" | awk '{print $1}')"
plan_json_sha="sha256:$(shasum -a 256 "$plan_json" | awk '{print $1}')"
[[ $(jq -r '.planSha256' "$manifest") == "$plan_sha" ]] || fail PLAN_DIGEST_MISMATCH
[[ $(jq -r '.planJsonSha256' "$manifest") == "$plan_json_sha" ]] || fail PLAN_JSON_DIGEST_MISMATCH
echo 'PASS: saved Terraform plan identity verified without apply.'
