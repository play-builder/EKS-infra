#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

terraform_root=environments/prod/03-platform
backend_bucket=platform-state-123456789012
backend_key=prod/03-platform/terraform.tfstate
account_id=123456789012
region=ap-northeast-2
source_sha=$(git -C "$root" rev-parse HEAD)
request_identity=release-requester
approval_identity=platform-approver
run_id=987654321

make_artifact() {
  local artifact=$1 operation=${2:-apply}
  mkdir -p "$artifact"
  printf 'binary-plan\n' >"$artifact/tfplan"
  jq -n --arg version "$(terraform version -json | jq -r '.terraform_version')" \
    '{format_version:"1.2",terraform_version:$version,resource_changes:[]}' >"$artifact/tfplan.json"
  printf '%s  tfplan\n' "$(shasum -a 256 "$artifact/tfplan" | awk '{print $1}')" >"$artifact/tfplan.sha256"
  printf '%s  tfplan.json\n' "$(shasum -a 256 "$artifact/tfplan.json" | awk '{print $1}')" >"$artifact/tfplan.json.sha256"

  jq -n --arg request "$request_identity" --arg run "$run_id" --arg approver "$approval_identity" '
    {schemaVersion:"platform.saved-plan-approval/v1",source:"github-actions-review-history",
     environment:"production",state:"approved",runId:$run,requestIdentity:$request,
     approvalIdentity:$approver}' >"$artifact/approval-evidence.json"

  local plan_sha plan_json_sha binary_sha lock_sha approval_sha version
  plan_sha=$(shasum -a 256 "$artifact/tfplan" | awk '{print $1}')
  plan_json_sha=$(shasum -a 256 "$artifact/tfplan.json" | awk '{print $1}')
  binary_sha=$(shasum -a 256 "$(command -v terraform)" | awk '{print $1}')
  lock_sha=$(shasum -a 256 "$root/$terraform_root/.terraform.lock.hcl" | awk '{print $1}')
  approval_sha=$(shasum -a 256 "$artifact/approval-evidence.json" | awk '{print $1}')
  version=$(terraform version -json | jq -r '.terraform_version')
  jq -n --arg account "$account_id" --arg region "$region" --arg tfroot "$terraform_root" \
    --arg bucket "$backend_bucket" --arg key "$backend_key" --arg source "$source_sha" \
    --arg version "$version" --arg binary "$binary_sha" --arg lock "$lock_sha" \
    --arg plan "$plan_sha" --arg plan_json "$plan_json_sha" --arg request "$request_identity" \
    --arg approver "$approval_identity" --arg run "$run_id" --arg approval "$approval_sha" \
    --arg operation "$operation" '
    {schemaVersion:"platform.saved-plan/v1",accountId:$account,region:$region,terraformRoot:$tfroot,
     backendBucket:$bucket,backendKey:$key,lockIdentity:"s3-native-lockfile",sourceSha:$source,
     terraformVersion:$version,terraformBinarySha256:("sha256:"+$binary),
     providerLockSha256:("sha256:"+$lock),planSha256:("sha256:"+$plan),
     planJsonSha256:("sha256:"+$plan_json),operation:$operation,requestIdentity:$request,
     approvalIdentity:$approver,approvalRunId:$run,approvalEvidenceSha256:("sha256:"+$approval),
     createdAt:(now|todateiso8601)}' >"$artifact/plan-identity.json"
}

verify() {
  bash "$root/scripts/verify-saved-plan.sh" "$1" "$terraform_root" "$account_id" "$region" \
    "$backend_bucket" "$backend_key" s3-native-lockfile "$source_sha" \
    "$request_identity" "$run_id" "${2:-apply}"
}

expect_failure() {
  local expected=$1 artifact=$2 operation=${3:-apply}
  set +e
  local output status
  output=$(verify "$artifact" "$operation" 2>&1)
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"$expected"* ]] || {
    echo "expected $expected, got status=$status output=$output" >&2
    exit 1
  }
}

make_artifact "$tmp_dir/valid"
verify "$tmp_dir/valid" >/dev/null

cp -R "$tmp_dir/valid" "$tmp_dir/pending"
jq '.approvalIdentity="pending"' "$tmp_dir/pending/plan-identity.json" >"$tmp_dir/pending/new"
mv "$tmp_dir/pending/new" "$tmp_dir/pending/plan-identity.json"
expect_failure SAVED_PLAN_APPROVAL_INVALID "$tmp_dir/pending"

cp -R "$tmp_dir/valid" "$tmp_dir/self"
jq --arg requester "$request_identity" '.approvalIdentity=$requester' \
  "$tmp_dir/self/plan-identity.json" >"$tmp_dir/self/new"
mv "$tmp_dir/self/new" "$tmp_dir/self/plan-identity.json"
expect_failure SAVED_PLAN_SELF_APPROVAL "$tmp_dir/self"

for case_name in terraform-version binary lock plan-json source account root backend; do
  cp -R "$tmp_dir/valid" "$tmp_dir/$case_name"
  case "$case_name" in
    terraform-version) filter='.terraformVersion="0.0.0"'; expected=SAVED_PLAN_TERRAFORM_VERSION_MISMATCH ;;
    binary) filter='.terraformBinarySha256="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'; expected=SAVED_PLAN_TERRAFORM_BINARY_MISMATCH ;;
    lock) filter='.providerLockSha256="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'; expected=SAVED_PLAN_PROVIDER_LOCK_MISMATCH ;;
    plan-json) filter='.planJsonSha256="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"'; expected=SAVED_PLAN_PLAN_JSON_DIGEST_MISMATCH ;;
    source) filter='.sourceSha="0000000000000000000000000000000000000000"'; expected=SAVED_PLAN_SOURCE_SHA_MISMATCH ;;
    account) filter='.accountId="000000000000"'; expected=SAVED_PLAN_ACCOUNT_MISMATCH ;;
    root) filter='.terraformRoot="environments/prod/01-network"'; expected=SAVED_PLAN_ROOT_MISMATCH ;;
    backend) filter='.backendKey="prod/01-network/terraform.tfstate"'; expected=SAVED_PLAN_BACKEND_KEY_MISMATCH ;;
  esac
  jq "$filter" "$tmp_dir/$case_name/plan-identity.json" >"$tmp_dir/$case_name/new"
  mv "$tmp_dir/$case_name/new" "$tmp_dir/$case_name/plan-identity.json"
  expect_failure "$expected" "$tmp_dir/$case_name"
done

cp -R "$tmp_dir/valid" "$tmp_dir/sidecar"
printf '0  tfplan\n' >"$tmp_dir/sidecar/tfplan.sha256"
expect_failure SAVED_PLAN_PLAN_CHECKSUM_INVALID "$tmp_dir/sidecar"

make_artifact "$tmp_dir/destroy" destroy
expect_failure SAVED_PLAN_OPERATION_MISMATCH "$tmp_dir/destroy" apply
verify "$tmp_dir/destroy" destroy >/dev/null

cat >"$tmp_dir/history-approved.json" <<'JSON'
[{"state":"approved","environments":[{"name":"production"}],"user":{"login":"platform-approver"}}]
JSON
make_artifact "$tmp_dir/bind"
jq '.approvalIdentity=null | .approvalRunId=null | .approvalEvidenceSha256=null' \
  "$tmp_dir/bind/plan-identity.json" >"$tmp_dir/bind/new"
mv "$tmp_dir/bind/new" "$tmp_dir/bind/plan-identity.json"
rm "$tmp_dir/bind/approval-evidence.json"
bash "$root/scripts/bind-saved-plan-approval.sh" "$tmp_dir/bind" "$tmp_dir/history-approved.json" \
  production "$request_identity" "$run_id"
verify "$tmp_dir/bind" >/dev/null

# A different rerun actor must not rewrite the original requester or make the
# complete verifier accept that substituted identity.
cp -R "$tmp_dir/bind" "$tmp_dir/bind-mismatch"
set +e
output=$(bash "$root/scripts/bind-saved-plan-approval.sh" "$tmp_dir/bind-mismatch" \
  "$tmp_dir/history-approved.json" production different-requester "$run_id" 2>&1)
bind_status=$?
verify_output=$(request_identity=different-requester verify "$tmp_dir/bind-mismatch" 2>&1)
verify_status=$?
set -e
[[ "$bind_status" -ne 0 && "$output" == *SAVED_PLAN_REQUEST_IDENTITY_MISMATCH* &&
   "$verify_status" -ne 0 && "$verify_output" == *SAVED_PLAN_REQUEST_IDENTITY_MISMATCH* ]] || {
  echo "requester substitution accepted: bind=$bind_status verify=$verify_status" >&2
  exit 1
}
diff -r "$tmp_dir/bind" "$tmp_dir/bind-mismatch"
verify "$tmp_dir/bind-mismatch" >/dev/null

for invalid in pending blank self; do
  case "$invalid" in
    pending) history='[{"state":"pending","environments":[{"name":"production"}],"user":{"login":"platform-approver"}}]' ;;
    blank) history='[{"state":"approved","environments":[{"name":"production"}],"user":{"login":""}}]' ;;
    self) history='[{"state":"approved","environments":[{"name":"production"}],"user":{"login":"release-requester"}}]' ;;
  esac
  printf '%s\n' "$history" >"$tmp_dir/history-$invalid.json"
  cp -R "$tmp_dir/bind" "$tmp_dir/bind-$invalid"
  set +e
  output=$(bash "$root/scripts/bind-saved-plan-approval.sh" "$tmp_dir/bind-$invalid" \
    "$tmp_dir/history-$invalid.json" production "$request_identity" "$run_id" 2>&1)
  status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *SAVED_PLAN_APPROVAL_HISTORY_INVALID* ]]
done

echo 'PASS: saved Terraform plans bind runtime, source, backend, plan, and trusted approval identities.'
