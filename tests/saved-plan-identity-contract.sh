#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/plan"
printf 'binary-plan\n' >"$tmp_dir/plan/tfplan"
printf '{"format_version":"1.2","resource_changes":[]}' >"$tmp_dir/plan/tfplan.json"
plan_sha=$(shasum -a 256 "$tmp_dir/plan/tfplan" | awk '{print $1}')
plan_json_sha=$(shasum -a 256 "$tmp_dir/plan/tfplan.json" | awk '{print $1}')
jq -n --arg plan "$plan_sha" --arg planJson "$plan_json_sha" '
  {schemaVersion:"platform.saved-plan/v1",accountId:"123456789012",region:"ap-northeast-2",
   terraformRoot:"environments/prod/03-platform",backendBucket:"platform-state-123456789012",
   backendKey:"prod/03-platform/terraform.tfstate",lockIdentity:"s3-native-lockfile",
   sourceSha:"701139222a836002b3b05b68a70d0ddf359f5f01",terraformVersion:"1.16.0",
   terraformBinarySha256:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
   providerLockSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
   planSha256:("sha256:" + $plan),planJsonSha256:("sha256:" + $planJson),
   approvalIdentity:"platform-approver",createdAt:"2026-09-05T00:00:00Z"}
' >"$tmp_dir/plan/plan-identity.json"

set +e
output=$(bash "$root/scripts/verify-saved-plan.sh" "$tmp_dir/plan" environments/prod/03-platform \
  123456789012 us-east-1 platform-state-123456789012 prod/03-platform/terraform.tfstate \
  s3-native-lockfile 701139222a836002b3b05b68a70d0ddf359f5f01 2>&1)
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *SAVED_PLAN_REGION_MISMATCH* ]]

bash "$root/scripts/verify-saved-plan.sh" "$tmp_dir/plan" environments/prod/03-platform \
  123456789012 ap-northeast-2 platform-state-123456789012 prod/03-platform/terraform.tfstate \
  s3-native-lockfile 701139222a836002b3b05b68a70d0ddf359f5f01
