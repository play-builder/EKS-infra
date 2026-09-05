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

for code in 0 1 2; do
  artifact="$repo/evidence/terraform-drift/prod-network"
  mkdir -p "$artifact"
  printf 'previous\n' >"$artifact/sentinel"
  set +e
  PATH="$repo/bin:$PATH" FAKE_TERRAFORM_PLAN_STATUS=$code BACKEND_BUCKET=platform-state-123456789012 \
    AWS_REGION=ap-northeast-2 bash "$repo/scripts/terraform-drift-check.sh" \
      "$repo/environments/prod/01-network" "$repo/environments/prod/config/network.tfbackend" \
      "$artifact" >/dev/null 2>&1
  actual=$?
  set -e
  [[ "$actual" -eq "$code" ]]
  if [[ "$code" -eq 1 ]]; then
    [[ -f "$artifact/sentinel" && ! -f "$artifact/drift.json" ]]
  else
    [[ ! -f "$artifact/sentinel" ]]
    expected=NO_DRIFT
    [[ "$code" -eq 0 ]] || expected=DRIFT_DETECTED
    jq -e --arg expected "$expected" '.decision == $expected and .evidenceGrade == "CLOUD_RUNTIME"' \
      "$artifact/drift.json" >/dev/null
  fi
  [[ -z $(find "$(dirname "$artifact")" -maxdepth 1 -name '.prod-network.staging.*' -print -quit) ]]
done

echo 'PASS: drift capture atomically preserves Terraform detailed exit codes 0, 1, and 2.'
