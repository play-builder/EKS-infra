#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_dir/lib/terraform-plan-contract.sh"
source "$script_dir/lib/evidence-common.sh"

terraform_root_input=${1:?terraform root is required}
backend_config_input=${2:?backend config is required}
artifact_dir_input=${3:?artifact directory is required}
: "${BACKEND_BUCKET:?BACKEND_BUCKET is required}"
: "${AWS_REGION:?AWS_REGION is required}"
course_validate_region "$AWS_REGION"

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

staging_dir=$(mktemp -d "$artifact_parent/.${artifact_dir##*/}.staging.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
terraform -chdir="$terraform_root" init -input=false \
  -lockfile=readonly \
  -backend-config="$backend_config" -backend-config="bucket=$BACKEND_BUCKET" \
  -backend-config="region=$AWS_REGION"
set +e
terraform -chdir="$terraform_root" plan -input=false -detailed-exitcode -out="$staging_dir/drift.tfplan"
plan_status=$?
set -e
[[ "$plan_status" -eq 0 || "$plan_status" -eq 2 ]] || exit "$plan_status"

decision=NO_DRIFT
[[ "$plan_status" -eq 0 ]] || decision=DRIFT_DETECTED
jq -n --arg decision "$decision" --arg root "$relative_root" \
  --arg source "$(git -C "$repo_root" rev-parse HEAD)" '
  {schemaVersion:"platform.terraform-drift/v1",evidenceGrade:"CLOUD_RUNTIME",terraformRoot:$root,
   sourceSha:$source,decision:$decision,observedAt:(now|todateiso8601)}' >"$staging_dir/drift.json"
jq -e . "$staging_dir/drift.json" >/dev/null || terraform_plan_fail DRIFT_EVIDENCE_INVALID
[[ -s "$staging_dir/drift.tfplan" ]] || terraform_plan_fail DRIFT_PLAN_MISSING

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
exit "$plan_status"
