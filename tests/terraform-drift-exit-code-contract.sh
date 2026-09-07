#!/usr/bin/env bash
set -Eeuo pipefail

source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
repo="$tmp_dir/repo"
mkdir -p "$repo/scripts/lib" "$repo/environments/prod/01-network" "$repo/environments/prod/config" "$repo/bin"
cp "$source_root/scripts/terraform-drift-check.sh" "$repo/scripts/terraform-drift-check.sh"
cp "$source_root/scripts/lib/terraform-plan-contract.sh" "$repo/scripts/lib/terraform-plan-contract.sh"
cp "$source_root/scripts/lib/evidence-common.sh" "$repo/scripts/lib/evidence-common.sh"
printf 'terraform {}\n' >"$repo/environments/prod/01-network/main.tf"
printf 'provider-lock\n' >"$repo/environments/prod/01-network/.terraform.lock.hcl"
cat >"$repo/environments/prod/config/network.tfbackend" <<'EOF'
key          = "prod/01-network/terraform.tfstate"
encrypt      = true
use_lockfile = true
EOF
cat >"$repo/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == *' plan '* ]]; then
  for arg in "$@"; do
    [[ "$arg" == -out=* ]] && printf 'drift-plan\n' >"${arg#-out=}"
  done
  exit "${FAKE_TERRAFORM_PLAN_STATUS:?}"
fi
exit 0
EOF
chmod +x "$repo/bin/terraform"
git -C "$repo" init -q
git -C "$repo" config user.email contract@example.invalid
git -C "$repo" config user.name contract
git -C "$repo" add .
git -C "$repo" commit -qm baseline

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Each iteration starts from the same previously published artifact (a sentinel only), so exit code 1
# must leave that artifact untouched while 0 and 2 must replace it atomically with fresh evidence.
# Assertions are written as `[[ ... ]] || fail` on purpose: bash 3.2 (macOS /bin/bash) does not honour
# set -e for a failing compound `[[ a && b ]]`, which let a wrong assertion pass locally while it failed on Linux.
for code in 0 1 2; do
  artifact="$repo/evidence/terraform-drift/prod-network"
  rm -rf -- "$artifact"
  mkdir -p "$artifact"
  printf 'previous\n' >"$artifact/sentinel"
  set +e
  PATH="$repo/bin:$PATH" FAKE_TERRAFORM_PLAN_STATUS=$code BACKEND_BUCKET=platform-state-123456789012 \
    AWS_REGION=ap-northeast-2 bash "$repo/scripts/terraform-drift-check.sh" \
      "$repo/environments/prod/01-network" "$repo/environments/prod/config/network.tfbackend" \
      "$artifact" >"$tmp_dir/drift-$code.log" 2>&1
  actual=$?
  set -e
  [[ "$actual" -eq "$code" ]] || fail "terraform plan exit code $code was reported as $actual: $(cat "$tmp_dir/drift-$code.log")"
  if [[ "$code" -eq 1 ]]; then
    [[ -f "$artifact/sentinel" ]] || fail "exit code 1 must preserve the previously published artifact"
    [[ "$(cat "$artifact/sentinel")" == previous ]] || fail "exit code 1 must not rewrite the previously published artifact"
    [[ ! -e "$artifact/drift.json" && ! -e "$artifact/drift.tfplan" ]] || fail "exit code 1 must not publish drift evidence"
  else
    [[ ! -e "$artifact/sentinel" ]] || fail "exit code $code must replace the previously published artifact"
    expected=NO_DRIFT
    [[ "$code" -eq 0 ]] || expected=DRIFT_DETECTED
    jq -e --arg expected "$expected" '.decision == $expected and .evidenceGrade == "CLOUD_RUNTIME"' \
      "$artifact/drift.json" >/dev/null || fail "exit code $code must publish drift.json with decision $expected"
    [[ -s "$artifact/drift.tfplan" ]] || fail "exit code $code must publish the saved drift plan"
  fi
  [[ -z $(find "$(dirname "$artifact")" -maxdepth 1 -name '.prod-network.staging.*' -print -quit) ]] || \
    fail "exit code $code left a staging directory behind"
  [[ -z $(find "$(dirname "$artifact")" -maxdepth 1 -name '.prod-network.previous.*' -print -quit) ]] || \
    fail "exit code $code left a previous-artifact backup behind"
done

echo 'PASS: drift capture atomically preserves Terraform detailed exit codes 0, 1, and 2.'
