#!/usr/bin/env bash
set -Eeuo pipefail

source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
repo="$tmp_dir/repo"
mkdir -p "$repo/scripts/lib" "$repo/environments/prod/01-network" "$repo/environments/prod/config" "$repo/bin"
cp "$source_root/scripts/create-saved-plan.sh" "$repo/scripts/create-saved-plan.sh"
cp "$source_root/scripts/lib/terraform-plan-contract.sh" "$repo/scripts/lib/terraform-plan-contract.sh"
cp "$source_root/scripts/lib/evidence-common.sh" "$repo/scripts/lib/evidence-common.sh"
printf 'terraform { required_version = "= 1.16.0" }\n' >"$repo/environments/prod/01-network/main.tf"
printf 'provider-lock\n' >"$repo/environments/prod/01-network/.terraform.lock.hcl"
cat >"$repo/environments/prod/config/network.tfbackend" <<'EOF'
key          = "prod/01-network/terraform.tfstate"
encrypt      = true
use_lockfile = true
EOF
cat >"$repo/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == 'version -json' ]]; then
  printf '{"terraform_version":"1.16.0"}\n'
elif [[ "$*" == *' plan '* ]]; then
  [[ "${FAKE_PLAN_FAIL:-false}" != true ]] || exit 91
  for arg in "$@"; do
    [[ "$arg" == -out=* ]] && printf 'binary-plan\n' >"${arg#-out=}"
  done
elif [[ "$*" == *' show -json '* ]]; then
  printf '{"format_version":"1.2","terraform_version":"1.16.0","resource_changes":[]}\n'
fi
EOF
cat >"$repo/bin/aws" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *'--region ap-northeast-2'* ]] || exit 94
printf '{"Account":"123456789012"}\n'
EOF
chmod +x "$repo/bin/terraform" "$repo/bin/aws"
git -C "$repo" init -q
git -C "$repo" config user.email contract@example.invalid
git -C "$repo" config user.name contract
git -C "$repo" add .
git -C "$repo" commit -qm baseline

common_env=(
  PATH="$repo/bin:$PATH"
  AWS_REGION=ap-northeast-2
  BACKEND_BUCKET=platform-state-123456789012
  PLAN_REQUEST_IDENTITY=release-requester
  PLAN_RUN_ID=987654321
)

env "${common_env[@]}" bash "$repo/scripts/create-saved-plan.sh" \
  "$repo/environments/prod/01-network" "$repo/environments/prod/config/network.tfbackend" \
  "$repo/plan-artifact" apply
jq -e '.operation == "apply" and .approvalIdentity == null and .requestIdentity == "release-requester"' \
  "$repo/plan-artifact/plan-identity.json" >/dev/null
(cd "$repo/plan-artifact" && shasum -a 256 -c tfplan.sha256 && shasum -a 256 -c tfplan.json.sha256) >/dev/null

printf 'preserve-old-artifact\n' >"$repo/plan-artifact/sentinel"
set +e
env "${common_env[@]}" FAKE_PLAN_FAIL=true bash "$repo/scripts/create-saved-plan.sh" \
  "$repo/environments/prod/01-network" "$repo/environments/prod/config/network.tfbackend" \
  "$repo/plan-artifact" apply >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 && -f "$repo/plan-artifact/sentinel" ]]
[[ -z $(find "$repo" -maxdepth 1 -name '.plan-artifact.staging.*' -print -quit) ]]

ln -s "$repo/environments/prod/01-network" "$repo/network-link"
set +e
output=$(env "${common_env[@]}" bash "$repo/scripts/create-saved-plan.sh" \
  "$repo/network-link" "$repo/environments/prod/config/network.tfbackend" "$repo/plan-artifact" apply 2>&1)
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *SAVED_PLAN_PATH_NOT_CANONICAL* ]]

mkdir -p "$repo/not-allowed"
set +e
output=$(env "${common_env[@]}" bash "$repo/scripts/create-saved-plan.sh" \
  "$repo/environments/prod/01-network" "$repo/environments/prod/config/network.tfbackend" \
  "$repo/not-allowed/plan" apply 2>&1)
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *SAVED_PLAN_ARTIFACT_PATH_NOT_ALLOWED* ]]

echo 'PASS: saved Terraform plan creation is allowlisted and atomically published.'
