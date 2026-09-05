#!/usr/bin/env bash
set -Eeuo pipefail

terraform_root=${1:?terraform root is required}
backend_config=${2:?backend config is required}
artifact_dir=${3:?artifact directory is required}
mkdir -p "$artifact_dir"
terraform -chdir="$terraform_root" init -input=false -backend-config="$backend_config"
set +e
terraform -chdir="$terraform_root" plan -input=false -detailed-exitcode -out="$artifact_dir/drift.tfplan"
plan_status=$?
set -e
[[ "$plan_status" -eq 0 || "$plan_status" -eq 2 ]] || exit "$plan_status"
decision=NO_DRIFT
[[ "$plan_status" -eq 0 ]] || decision=DRIFT_DETECTED
jq -n --arg decision "$decision" --arg root "$terraform_root" --arg source "$(git -C "$terraform_root" rev-parse HEAD)" '
  {schemaVersion:"platform.terraform-drift/v1",evidenceGrade:"CLOUD_RUNTIME",terraformRoot:$root,
   sourceSha:$source,decision:$decision,observedAt:(now|todateiso8601)}' >"$artifact_dir/drift.json"
[[ "$plan_status" -eq 0 ]]
