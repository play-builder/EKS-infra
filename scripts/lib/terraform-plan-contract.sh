#!/usr/bin/env bash

terraform_plan_fail() {
  printf 'SAVED_PLAN_%s\n' "$1" >&2
  exit "${2:-1}"
}

terraform_plan_binary_path() {
  if command -v terraform-bin >/dev/null 2>&1; then
    command -v terraform-bin
  else
    command -v terraform
  fi
}

terraform_plan_canonical_directory() {
  local path=$1 canonical parent lexical
  [[ -d "$path" ]] || terraform_plan_fail PATH_NOT_FOUND 66
  canonical=$(cd -- "$path" && pwd -P)
  parent=$(cd -- "$(dirname -- "$path")" && pwd -P)
  lexical="$parent/$(basename -- "$path")"
  [[ "$canonical" == "$lexical" ]] || terraform_plan_fail PATH_NOT_CANONICAL
  printf '%s\n' "$canonical"
}

terraform_plan_canonical_file() {
  local path=$1 canonical_parent lexical
  [[ -f "$path" && ! -L "$path" ]] || terraform_plan_fail PATH_NOT_FOUND 66
  canonical_parent=$(cd -- "$(dirname -- "$path")" && pwd -P)
  lexical="$canonical_parent/$(basename -- "$path")"
  [[ -f "$lexical" && ! -L "$lexical" ]] || terraform_plan_fail PATH_NOT_CANONICAL
  printf '%s\n' "$lexical"
}

terraform_plan_relative_to_repo() {
  local repo_root=$1 canonical=$2
  case "$canonical" in
    "$repo_root") printf '.\n' ;;
    "$repo_root"/*) printf '%s\n' "${canonical#"$repo_root"/}" ;;
    *) terraform_plan_fail PATH_OUTSIDE_REPOSITORY ;;
  esac
}

terraform_plan_expected_backend_for_root() {
  case "$1" in
    environments/dev/01-network) printf 'environments/dev/config/network.tfbackend\n' ;;
    environments/dev/02-eks) printf 'environments/dev/config/eks.tfbackend\n' ;;
    environments/dev/03-platform) printf 'environments/dev/config/platform.tfbackend\n' ;;
    environments/dev/04-workloads/argocd) printf 'environments/dev/config/argocd.tfbackend\n' ;;
    environments/prod/01-network) printf 'environments/prod/config/network.tfbackend\n' ;;
    environments/prod/02-eks) printf 'environments/prod/config/eks.tfbackend\n' ;;
    environments/prod/03-platform) printf 'environments/prod/config/platform.tfbackend\n' ;;
    environments/prod/04-workloads/argocd) printf 'environments/prod/config/argocd.tfbackend\n' ;;
    *) terraform_plan_fail ROOT_NOT_ALLOWED ;;
  esac
}

terraform_plan_expected_backend_key_for_root() {
  case "$1" in
    environments/dev/01-network) printf 'dev/01-network/terraform.tfstate\n' ;;
    environments/dev/02-eks) printf 'dev/02-eks/terraform.tfstate\n' ;;
    environments/dev/03-platform) printf 'dev/03-platform/terraform.tfstate\n' ;;
    environments/dev/04-workloads/argocd) printf 'dev/04-workloads/argocd/terraform.tfstate\n' ;;
    environments/prod/01-network) printf 'prod/01-network/terraform.tfstate\n' ;;
    environments/prod/02-eks) printf 'prod/02-eks/terraform.tfstate\n' ;;
    environments/prod/03-platform) printf 'prod/03-platform/terraform.tfstate\n' ;;
    environments/prod/04-workloads/argocd) printf 'prod/04-workloads/argocd/terraform.tfstate\n' ;;
    *) terraform_plan_fail ROOT_NOT_ALLOWED ;;
  esac
}

terraform_plan_assert_root_backend_pair() {
  local repo_root=$1 relative_root=$2 relative_backend=$3 expected_backend expected_key actual_key
  expected_backend=$(terraform_plan_expected_backend_for_root "$relative_root")
  [[ "$relative_backend" == "$expected_backend" ]] || terraform_plan_fail ROOT_BACKEND_NOT_ALLOWED
  git -C "$repo_root" ls-files --error-unmatch "$relative_backend" >/dev/null 2>&1 || \
    terraform_plan_fail BACKEND_CONFIG_NOT_TRACKED
  expected_key=$(terraform_plan_expected_backend_key_for_root "$relative_root")
  actual_key=$(awk -F= '/^[[:space:]]*key[[:space:]]*=/{gsub(/[[:space:]\"]/, "", $2); print $2; exit}' \
    "$repo_root/$relative_backend")
  [[ "$actual_key" == "$expected_key" ]] || terraform_plan_fail BACKEND_KEY_NOT_ALLOWED
  grep -Eq '^[[:space:]]*encrypt[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$repo_root/$relative_backend" || \
    terraform_plan_fail BACKEND_ENCRYPTION_REQUIRED
  grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$repo_root/$relative_backend" || \
    terraform_plan_fail BACKEND_LOCK_REQUIRED
}

terraform_plan_assert_artifact_path() {
  local repo_root=$1 artifact_dir=$2 parent canonical_artifact
  parent=$(cd -- "$(dirname -- "$artifact_dir")" && pwd -P)
  canonical_artifact="$parent/$(basename -- "$artifact_dir")"
  case "$canonical_artifact" in
    "$repo_root/plan-artifact"|"$repo_root/evidence/cleanup/saved-plans/"*|"$repo_root/evidence/terraform-drift/"*) ;;
    *) terraform_plan_fail ARTIFACT_PATH_NOT_ALLOWED ;;
  esac
  printf '%s\n' "$canonical_artifact"
}
