#!/usr/bin/env bash

raw_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

provider_secret_projection_sha256() {
  local inventory=$1
  jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
    "$inventory" | shasum -a 256 | awk '{print $1}'
}

prepare_saved_plan_manifest() {
  local output_dir=$1 manifest=$2 layer plan_path plan_sha
  local -a layers=(
    environments/prod/04-workloads/argocd
    environments/dev/04-workloads/argocd
    environments/prod/03-platform
    environments/dev/03-platform
    environments/prod/02-eks
    environments/dev/02-eks
    environments/prod/01-network
    environments/dev/01-network
  )
  mkdir -p "$output_dir"
  jq -n '{schemaVersion:"course.saved-destroy-plans/v1",status:"REVIEWED",reviewedAt:"2026-09-03T00:10:00Z",plans:[]}' >"$manifest"
  for layer in "${layers[@]}"; do
    plan_path="$output_dir/${layer//\//__}.tfplan"
    printf 'saved destroy plan for %s\n' "$layer" >"$plan_path"
    plan_sha=$(raw_sha256 "$plan_path")
    jq --arg layer "$layer" --arg path "$plan_path" --arg sha "$plan_sha" \
      '.plans += [{layer:$layer,path:$path,sha256:$sha}]' "$manifest" >"$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
  done
}

prepare_cleanup_fixtures() {
  local root=$1 output_dir=$2 region=$3
  local inventory_sha freeze_sha removal_sha decisions_sha pre_destroy_sha provider_sha
  jq --arg region "$region" '
    .region=$region |
    .resources |= map(
      if (.id | startswith("arn:aws:")) then
        .id |= gsub("ap-northeast-2";$region)
      else . end
    )
  ' "$root/tests/fixtures/cleanup-ownership-valid.json" >"$output_dir/inventory.json"
  inventory_sha=$(raw_sha256 "$output_dir/inventory.json")

  jq --arg region "$region" --arg inventory "$inventory_sha" '
    .region=$region | .inventorySha256=$inventory |
    .decisions |= map(if (.id | startswith("arn:aws:")) then .id |= gsub("ap-northeast-2";$region) else . end)
  ' "$root/tests/fixtures/cleanup-retain-decisions-valid.json" >"$output_dir/decisions.json"

  jq --arg region "$region" '
    .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/cleanup-gitops-freeze-valid.json" >"$output_dir/freeze.json"
  freeze_sha=$(raw_sha256 "$output_dir/freeze.json")
  provider_sha=$(provider_secret_projection_sha256 "$output_dir/inventory.json")

  jq --arg region "$region" --arg freeze "$freeze_sha" --arg provider "$provider_sha" '
    .freezeEvidenceSha256=$freeze | .providerSecrets.inventorySha256=$provider |
    .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/cleanup-gitops-removal-valid.json" >"$output_dir/removal.json"
  removal_sha=$(raw_sha256 "$output_dir/removal.json")

  jq --arg region "$region" --arg removal "$removal_sha" '
    .region=$region | .gitopsRemovalSha256=$removal |
    .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/kubernetes-pre-destroy-valid.json" >"$output_dir/pre-destroy.json"

  decisions_sha=$(raw_sha256 "$output_dir/decisions.json")
  pre_destroy_sha=$(raw_sha256 "$output_dir/pre-destroy.json")
  jq --arg inventory "$inventory_sha" --arg decisions "$decisions_sha" \
    --arg pre "$pre_destroy_sha" --arg removal "$removal_sha" '
    .inventorySha256=$inventory | .retainDecisionsSha256=$decisions |
    .kubernetesPreDestroySha256=$pre | .gitopsRemovalSha256=$removal
  ' "$root/tests/fixtures/cleanup-residual-zero-$region.json" >"$output_dir/residual.json"
}
