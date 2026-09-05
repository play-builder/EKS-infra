#!/usr/bin/env bash
set -Eeuo pipefail

terraform_root=${1:?terraform root is required}
backend_config=${2:?backend config is required}
artifact_dir=${3:?artifact directory is required}
repo_root=$(git -C "$terraform_root" rev-parse --show-toplevel)
source_sha=$(git -C "$repo_root" rev-parse HEAD)
backend_bucket=$(awk -F= '/^[[:space:]]*bucket[[:space:]]*=/{gsub(/[[:space:]\"]/, "", $2); print $2; exit}' "$backend_config")
backend_key=$(awk -F= '/^[[:space:]]*key[[:space:]]*=/{gsub(/[[:space:]\"]/, "", $2); print $2; exit}' "$backend_config")
[[ -n "$backend_bucket" && -n "$backend_key" ]] || { echo 'SAVED_PLAN_BACKEND_CONFIG_INVALID' >&2; exit 1; }
mkdir -p "$artifact_dir"
terraform -chdir="$terraform_root" init -input=false -backend-config="$backend_config"
terraform -chdir="$terraform_root" plan -input=false -out="$artifact_dir/tfplan"
terraform -chdir="$terraform_root" show -json "$artifact_dir/tfplan" >"$artifact_dir/tfplan.json"
plan_sha=$(shasum -a 256 "$artifact_dir/tfplan" | awk '{print $1}')
plan_json_sha=$(shasum -a 256 "$artifact_dir/tfplan.json" | awk '{print $1}')
terraform_sha=$(shasum -a 256 "$(command -v terraform)" | awk '{print $1}')
lock_file="$terraform_root/.terraform.lock.hcl"
[[ -f "$lock_file" ]] || { echo 'SAVED_PLAN_PROVIDER_LOCK_MISSING' >&2; exit 1; }
lock_sha=$(shasum -a 256 "$lock_file" | awk '{print $1}')
terraform_version=$(terraform version -json | jq -r '.terraform_version')
account_id=$(aws sts get-caller-identity --output json | jq -r '.Account')
region=${AWS_REGION:?AWS_REGION is required}
relative_root=${terraform_root#"$repo_root"/}
jq -n --arg account "$account_id" --arg region "$region" --arg root "$relative_root" \
  --arg bucket "$backend_bucket" --arg key "$backend_key" --arg source "$source_sha" --arg version "$terraform_version" \
  --arg binary "$terraform_sha" --arg lock "$lock_sha" --arg plan "$plan_sha" --arg planJson "$plan_json_sha" '
  {schemaVersion:"platform.saved-plan/v1",accountId:$account,region:$region,terraformRoot:$root,
   backendBucket:$bucket,backendKey:$key,lockIdentity:"s3-native-lockfile",sourceSha:$source,
   terraformVersion:$version,terraformBinarySha256:("sha256:"+$binary),providerLockSha256:("sha256:"+$lock),
   planSha256:("sha256:"+$plan),planJsonSha256:("sha256:"+$planJson),approvalIdentity:"pending",createdAt:(now|todateiso8601)}' \
  >"$artifact_dir/plan-identity.json"
shasum -a 256 "$artifact_dir/tfplan" >"$artifact_dir/tfplan.sha256"
shasum -a 256 "$artifact_dir/tfplan.json" >"$artifact_dir/tfplan.json.sha256"
