#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_dir/lib/terraform-plan-contract.sh"
source "$script_dir/lib/evidence-common.sh"

terraform_root_input=${1:?terraform root is required}
backend_config_input=${2:?backend config is required}
artifact_dir_input=${3:?artifact directory is required}
operation=${4:-apply}
[[ "$operation" == apply || "$operation" == destroy ]] || terraform_plan_fail OPERATION_INVALID
: "${AWS_REGION:?AWS_REGION is required}"
: "${BACKEND_BUCKET:?BACKEND_BUCKET is required}"
: "${PLAN_REQUEST_IDENTITY:?PLAN_REQUEST_IDENTITY is required}"
: "${PLAN_RUN_ID:?PLAN_RUN_ID is required}"
course_validate_region "$AWS_REGION"
caller_identity=$(aws sts get-caller-identity --region "$AWS_REGION" --output json)
account_id=$(jq -r '.Account' <<<"$caller_identity")
course_validate_account "$account_id"
[[ "$PLAN_REQUEST_IDENTITY" =~ [^[:space:]] && "$PLAN_REQUEST_IDENTITY" != pending ]] || \
  terraform_plan_fail REQUEST_IDENTITY_INVALID
[[ "$PLAN_RUN_ID" =~ ^[1-9][0-9]*$ ]] || terraform_plan_fail RUN_ID_INVALID

repo_root=$(git -C "$terraform_root_input" rev-parse --show-toplevel)
repo_root=$(cd -- "$repo_root" && pwd -P)
terraform_root=$(terraform_plan_canonical_directory "$terraform_root_input")
backend_config=$(terraform_plan_canonical_file "$backend_config_input")
relative_root=$(terraform_plan_relative_to_repo "$repo_root" "$terraform_root")
relative_backend=$(terraform_plan_relative_to_repo "$repo_root" "$backend_config")
terraform_plan_assert_root_backend_pair "$repo_root" "$relative_root" "$relative_backend"
artifact_dir=$(terraform_plan_assert_artifact_path "$repo_root" "$artifact_dir_input")
artifact_parent=$(dirname -- "$artifact_dir")
[[ -d "$artifact_parent" ]] || terraform_plan_fail ARTIFACT_PARENT_NOT_FOUND 66

lock_file="$terraform_root/.terraform.lock.hcl"
[[ -f "$lock_file" && ! -L "$lock_file" ]] || terraform_plan_fail PROVIDER_LOCK_MISSING
git -C "$repo_root" ls-files --error-unmatch "$relative_root/.terraform.lock.hcl" >/dev/null 2>&1 || \
  terraform_plan_fail PROVIDER_LOCK_NOT_TRACKED

source_sha=$(git -C "$repo_root" rev-parse HEAD)
backend_key=$(terraform_plan_expected_backend_key_for_root "$relative_root")
staging_dir=$(mktemp -d "$artifact_parent/.${artifact_dir##*/}.staging.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT

finops_binding=$(python3 -I "$script_dir/lib/finops-plan.py" capture --artifact "$staging_dir" \
  --root "$relative_root" --operation "$operation" --account "$account_id" --region "$AWS_REGION")

terraform -chdir="$terraform_root" init -input=false \
  -lockfile=readonly \
  -backend-config="$backend_config" -backend-config="bucket=$BACKEND_BUCKET" \
  -backend-config="region=$AWS_REGION"
plan_args=(-input=false -out="$staging_dir/tfplan")
[[ "$operation" == apply ]] || plan_args=(-destroy "${plan_args[@]}")
terraform -chdir="$terraform_root" plan "${plan_args[@]}"
terraform -chdir="$terraform_root" show -json "$staging_dir/tfplan" >"$staging_dir/tfplan.json"
jq -e '.format_version | type == "string"' "$staging_dir/tfplan.json" >/dev/null || \
  terraform_plan_fail PLAN_JSON_INVALID

plan_sha=$(course_raw_sha256_file "$staging_dir/tfplan")
plan_json_sha=$(course_raw_sha256_file "$staging_dir/tfplan.json")
terraform_binary=$(terraform_plan_binary_path)
terraform_sha=$(course_raw_sha256_file "$terraform_binary")
lock_sha=$(course_raw_sha256_file "$lock_file")
terraform_version=$("$terraform_binary" version -json | jq -er '.terraform_version | select(type == "string" and length > 0)')

jq -n --arg account "$account_id" --arg region "$AWS_REGION" --arg root "$relative_root" \
  --arg bucket "$BACKEND_BUCKET" --arg key "$backend_key" --arg source "$source_sha" \
  --arg version "$terraform_version" --arg binary "$terraform_sha" --arg lock "$lock_sha" \
  --arg plan "$plan_sha" --arg plan_json "$plan_json_sha" --arg operation "$operation" \
  --arg request "$PLAN_REQUEST_IDENTITY" --argjson finops "$finops_binding" '
  {schemaVersion:"platform.saved-plan/v1",accountId:$account,region:$region,terraformRoot:$root,
   backendBucket:$bucket,backendKey:$key,lockIdentity:"s3-native-lockfile",sourceSha:$source,
   terraformVersion:$version,terraformBinarySha256:("sha256:"+$binary),providerLockSha256:("sha256:"+$lock),
   planSha256:("sha256:"+$plan),planJsonSha256:("sha256:"+$plan_json),operation:$operation,
   requestIdentity:$request,approvalIdentity:null,approvalRunId:null,approvalEvidenceSha256:null,
   createdAt:(now|todateiso8601)} + (if $finops == null then {} else {finops:$finops} end)' >"$staging_dir/plan-identity.json"
printf '%s  tfplan\n' "$plan_sha" >"$staging_dir/tfplan.sha256"
printf '%s  tfplan.json\n' "$plan_json_sha" >"$staging_dir/tfplan.json.sha256"

for file in tfplan tfplan.json tfplan.sha256 tfplan.json.sha256 plan-identity.json; do
  [[ -s "$staging_dir/$file" ]] || terraform_plan_fail ARTIFACT_INCOMPLETE
done
(cd "$staging_dir" && shasum -a 256 -c tfplan.sha256 && shasum -a 256 -c tfplan.json.sha256) >/dev/null || \
  terraform_plan_fail ARTIFACT_CHECKSUM_INVALID
publish_backup=''
if [[ -e "$artifact_dir" ]]; then
  publish_backup="$artifact_parent/.${artifact_dir##*/}.previous.$$"
  mv -- "$artifact_dir" "$publish_backup"
fi
if ! mv -- "$staging_dir" "$artifact_dir"; then
  [[ -z "$publish_backup" ]] || mv -- "$publish_backup" "$artifact_dir"
  terraform_plan_fail ARTIFACT_PUBLISH_FAILED
fi
trap - EXIT
[[ -z "$publish_backup" ]] || rm -rf -- "$publish_backup"
