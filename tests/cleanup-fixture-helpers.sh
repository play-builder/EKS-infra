#!/usr/bin/env bash

raw_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

provider_secret_projection_sha256() {
  local inventory=$1
  jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
    "$inventory" | shasum -a 256 | awk '{print $1}'
}

prepare_cleanup_fixtures() {
  local root=$1 output_dir=$2 region=$3
  local inventory_sha freeze_sha removal_sha decisions_sha pre_destroy_sha provider_sha observed freeze_observed removal_observed pre_observed
  observed=$(date -u -v-3S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3 seconds' +%Y-%m-%dT%H:%M:%SZ)
  freeze_observed=$(date -u -v-2S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-2 seconds' +%Y-%m-%dT%H:%M:%SZ)
  removal_observed=$(date -u -v-1S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1 second' +%Y-%m-%dT%H:%M:%SZ)
  pre_observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg region "$region" --arg observed "$freeze_observed" '
    .region=$region | .observedAt=$observed |
    .resources |= map(
      if (.id | startswith("arn:aws:")) then
        .id |= gsub("ap-northeast-2";$region)
      else . end
    )
  ' "$root/tests/fixtures/cleanup-ownership-valid.json" >"$output_dir/inventory.json"
  inventory_sha=$(raw_sha256 "$output_dir/inventory.json")

  jq --arg region "$region" --arg inventory "$inventory_sha" --arg observed "$observed" '
    .region=$region | .inventorySha256=$inventory | .approvedAt=$observed |
    .decisions |= map(if (.id | startswith("arn:aws:")) then .id |= gsub("ap-northeast-2";$region) else . end)
  ' "$root/tests/fixtures/cleanup-retain-decisions-valid.json" >"$output_dir/decisions.json"

  jq --arg region "$region" --arg observed "$observed" '
    .observedAt=$observed | .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/cleanup-gitops-freeze-valid.json" >"$output_dir/freeze.json"
  freeze_sha=$(raw_sha256 "$output_dir/freeze.json")
  provider_sha=$(provider_secret_projection_sha256 "$output_dir/inventory.json")

  jq --arg region "$region" --arg freeze "$freeze_sha" --arg provider "$provider_sha" --arg observed "$removal_observed" '
    .freezeEvidenceSha256=$freeze | .providerSecrets.inventorySha256=$provider | .observedAt=$observed |
    .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/cleanup-gitops-removal-valid.json" >"$output_dir/removal.json"
  removal_sha=$(raw_sha256 "$output_dir/removal.json")

  jq --arg region "$region" --arg removal "$removal_sha" --arg observed "$pre_observed" '
    .region=$region | .gitopsRemovalSha256=$removal | .observedAt=$observed |
    .clusters |= map(.clusterArn |= gsub("ap-northeast-2";$region))
  ' "$root/tests/fixtures/kubernetes-pre-destroy-valid.json" >"$output_dir/pre-destroy.json"

  decisions_sha=$(raw_sha256 "$output_dir/decisions.json")
  pre_destroy_sha=$(raw_sha256 "$output_dir/pre-destroy.json")
  jq --arg inventory "$inventory_sha" --arg decisions "$decisions_sha" \
    --arg pre "$pre_destroy_sha" --arg removal "$removal_sha" --arg observed "$observed" '
    .inventorySha256=$inventory | .retainDecisionsSha256=$decisions |
    .kubernetesPreDestroySha256=$pre | .gitopsRemovalSha256=$removal | .observedAt=$observed
  ' "$root/tests/fixtures/cleanup-residual-zero-$region.json" >"$output_dir/residual.json"
}
