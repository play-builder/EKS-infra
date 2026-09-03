#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

valid="$fixtures/external-secrets-handoff-valid.json"
dual="$fixtures/external-secrets-handoff-dual-owner.json"
adoption="$tmp_dir/adoption.json"
handoff_sha=$(shasum -a 256 "$valid" | awk '{print $1}')
jq --arg digest "sha256:$handoff_sha" '.handoffSha256=$digest' \
  "$fixtures/external-secrets-adoption-valid.json" >"$adoption"

bash "$root/scripts/external-secrets-owner-handoff.sh" validate-handoff \
  "$valid" "2026-09-03T12:00:00Z" >/dev/null

expect_handoff_rejected() {
  local label=$1 expression=$2 candidate
  candidate="$tmp_dir/$label.json"
  jq "$expression" "$valid" >"$candidate"
  if bash "$root/scripts/external-secrets-owner-handoff.sh" validate-handoff \
    "$candidate" "2026-09-03T12:00:00Z" >/dev/null 2>&1; then
    echo "invalid handoff was accepted: $label" >&2
    exit 1
  fi
}

expect_cluster_name_accepted() {
  local label=$1 cluster_name=$2 candidate
  candidate="$tmp_dir/$label.json"
  jq --arg name "$cluster_name" \
    '.clusterArn = "arn:aws:eks:ap-northeast-2:123456789012:cluster/" + $name' \
    "$valid" >"$candidate"
  bash "$root/scripts/external-secrets-owner-handoff.sh" validate-handoff \
    "$candidate" "2026-09-03T12:00:00Z" >/dev/null || {
      echo "valid handoff cluster-name boundary was rejected: $label" >&2
      exit 1
    }
}

expect_handoff_rejected trailing-cluster-path '.clusterArn += "/junk"'
expect_handoff_rejected region-mismatch '.region = "us-east-1"'
expect_handoff_rejected application-identity-mismatch '.application.name = "external-secrets-prod"'
expect_handoff_rejected observed-in-future '.observedAt = "2026-09-03T12:01:00Z"'
expect_handoff_rejected expired '.expiresAt = "2026-09-03T11:59:00Z"'
if bash "$root/scripts/external-secrets-owner-handoff.sh" validate-handoff \
  "$valid" "2026-02-30T12:00:00Z" >/dev/null 2>&1; then
  echo 'noncanonical handoff evaluation time must be rejected' >&2
  exit 1
fi

for timestamp_case in \
  'observed-invalid-calendar|observedAt|2026-02-30T00:00:00Z' \
  'observed-fractional|observedAt|2026-09-03T00:00:00.123Z' \
  'observed-offset|observedAt|2026-09-03T09:00:00+09:00' \
  'expires-invalid-calendar|expiresAt|2026-09-31T00:00:00Z' \
  'expires-fractional|expiresAt|2026-09-04T00:00:00.123Z' \
  'expires-offset|expiresAt|2026-09-04T09:00:00+09:00'; do
  IFS='|' read -r label field value <<<"$timestamp_case"
  expect_handoff_rejected "$label" ".${field} = \"${value}\""
done

one_character_name=a
hundred_character_name=$(printf '%0100d' 0)
hundred_one_character_name=$(printf '%0101d' 0)
expect_cluster_name_accepted one-character-cluster-name "$one_character_name"
expect_cluster_name_accepted hundred-character-cluster-name "$hundred_character_name"
expect_handoff_rejected hundred-one-character-cluster-name \
  ".clusterArn = \"arn:aws:eks:ap-northeast-2:123456789012:cluster/$hundred_one_character_name\""

if bash "$root/scripts/external-secrets-owner-handoff.sh" validate-handoff \
  "$dual" "2026-09-03T12:00:00Z" >"$tmp_dir/dual.out" 2>&1; then
  echo "dual active reconcilers must be rejected" >&2
  exit 1
fi
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED' "$tmp_dir/dual.out"

bash "$root/scripts/external-secrets-owner-handoff.sh" validate-adoption \
  "$valid" "$adoption" "2026-09-03T12:00:00Z" >/dev/null

jq '.release = .release.before' "$adoption" >"$tmp_dir/legacy-flat-release.json"
if bash "$root/scripts/external-secrets-owner-handoff.sh" validate-adoption \
  "$valid" "$tmp_dir/legacy-flat-release.json" "2026-09-03T12:00:00Z" >/dev/null 2>&1; then
  echo "legacy flat adoption release must be rejected" >&2
  exit 1
fi

jq '.release.after.helmStorageObjectUid = "replacement-uid"' \
  "$adoption" >"$tmp_dir/changed-after.json"
if bash "$root/scripts/external-secrets-owner-handoff.sh" validate-adoption \
  "$valid" "$tmp_dir/changed-after.json" "2026-09-03T12:00:00Z" >/dev/null 2>&1; then
  echo "adoption with a changed post-import UID must be rejected" >&2
  exit 1
fi

jq '.terraform.planActions=["create"]' "$adoption" >"$tmp_dir/create.json"
if bash "$root/scripts/external-secrets-owner-handoff.sh" validate-adoption \
  "$valid" "$tmp_dir/create.json" "2026-09-03T12:00:00Z" >/dev/null 2>&1; then
  echo "non-no-op adoption must be rejected" >&2
  exit 1
fi

mkdir -p "$tmp_dir/bin" "$tmp_dir/terraform-root" "$tmp_dir/output"
runtime_handoff="$tmp_dir/runtime-handoff.json"
runtime_adoption="$tmp_dir/output/runtime-adoption.json"
live_values_sha=$(printf '{}\n' | jq -S -c . | shasum -a 256 | awk '{print "sha256:"$1}')
runtime_observed=$(jq -nr 'now - 60 | strftime("%Y-%m-%dT%H:%M:%SZ")')
runtime_expires=$(jq -nr 'now + 3600 | strftime("%Y-%m-%dT%H:%M:%SZ")')
jq --arg digest "$live_values_sha" --arg observed "$runtime_observed" --arg expires "$runtime_expires" '
  .release.valuesSha256=$digest | .observedAt=$observed | .expiresAt=$expires
' "$valid" >"$runtime_handoff"

cat >"$tmp_dir/bin/helm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$OWNER_FAKE_COMMAND_LOG"
case "$*" in
  "--kube-context course-dev -n external-secrets status external-secrets -o json")
    jq -n '{name:"external-secrets",namespace:"external-secrets",version:1,
      info:{status:"deployed"},chart:{metadata:{name:"external-secrets",version:"2.10.0"}}}'
    ;;
  "--kube-context course-dev -n external-secrets get values external-secrets -a -o json")
    jq -n '{}'
    ;;
  *)
    echo "unexpected helm command: $*" >&2
    exit 97
    ;;
esac
EOF

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$OWNER_FAKE_COMMAND_LOG"
case "$*" in
  "--context course-dev -n argocd get application external-secrets-dev -o json")
    jq -n '{metadata:{uid:"app-uid-1",finalizers:[]},spec:{syncPolicy:{}},status:{}}'
    ;;
  "--context course-dev -n external-secrets get secret -l owner=helm,name=external-secrets,status=deployed,version=1 -o json")
    uid=helm-storage-uid-1
    if [[ -f "$OWNER_FAKE_IMPORTED_MARKER" && "${OWNER_FAKE_CHANGE_AFTER:-}" == storage ]]; then
      uid=replacement-storage-uid
    fi
    jq -n --arg uid "$uid" '{items:[{metadata:{uid:$uid}}]}'
    ;;
  "--context course-dev -n external-secrets get Deployment external-secrets -o json")
    uid=deployment-uid-1
    if [[ -f "$OWNER_FAKE_IMPORTED_MARKER" && "${OWNER_FAKE_CHANGE_AFTER:-}" == workload ]]; then
      uid=replacement-workload-uid
    fi
    jq -n --arg uid "$uid" '{metadata:{uid:$uid}}'
    ;;
  "--context course-dev get crd externalsecrets.external-secrets.io -o json")
    uid=crd-uid-1
    if [[ -f "$OWNER_FAKE_IMPORTED_MARKER" && "${OWNER_FAKE_CHANGE_AFTER:-}" == crd ]]; then
      uid=replacement-crd-uid
    fi
    jq -n --arg uid "$uid" '{metadata:{uid:$uid}}'
    ;;
  *)
    echo "unexpected kubectl command: $*" >&2
    exit 97
    ;;
esac
EOF

cat >"$tmp_dir/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$OWNER_FAKE_COMMAND_LOG"
operation=${2:-}
case "$operation" in
  import)
    : >"$OWNER_FAKE_IMPORTED_MARKER"
    ;;
  plan)
    ;;
  show)
    actions='["no-op"]'
    [[ "${OWNER_FAKE_PLAN_CHANGE:-}" != create ]] || actions='["create"]'
    jq -n --argjson actions "$actions" '{resource_changes:[{
      address:"module.external_secrets[0].helm_release.this",mode:"managed",
      type:"helm_release",name:"this",change:{actions:$actions}}]}'
    ;;
  state)
    [[ "${3:-}" == pull ]] || exit 97
    version=${OWNER_FAKE_STATE_VERSION:-2.10.0}
    jq -n --arg version "$version" '{
      lineage:"22222222-2222-4222-8222-222222222222",serial:5,
      resources:[{module:"module.external_secrets[0]",mode:"managed",type:"helm_release",name:"this",
        provider:"provider[\"registry.terraform.io/hashicorp/helm\"]",
        instances:[{attributes:{name:"external-secrets",namespace:"external-secrets",
          chart:"external-secrets",version:$version,status:"deployed"}}]}]
    }'
    ;;
  *)
    echo "unexpected terraform command: $*" >&2
    exit 97
    ;;
esac
EOF
chmod +x "$tmp_dir/bin/helm" "$tmp_dir/bin/kubectl" "$tmp_dir/bin/terraform"

run_runtime_adoption() {
  local output=$1
  shift
  rm -f -- "$tmp_dir/imported"
  PATH="$tmp_dir/bin:$PATH" OWNER_FAKE_COMMAND_LOG="$tmp_dir/commands.log" \
    OWNER_FAKE_IMPORTED_MARKER="$tmp_dir/imported" "$@" \
    bash "$root/scripts/external-secrets-owner-handoff.sh" adopt \
      "$tmp_dir/terraform-root" "$runtime_handoff" "$output" course-dev
}

invalid_runtime_handoff="$tmp_dir/runtime-handoff-invalid-time.json"
jq '.observedAt="2020-02-30T00:00:00Z"' "$runtime_handoff" >"$invalid_runtime_handoff"
: >"$tmp_dir/commands.log"
rm -f -- "$tmp_dir/imported"
set +e
PATH="$tmp_dir/bin:$PATH" OWNER_FAKE_COMMAND_LOG="$tmp_dir/commands.log" \
  OWNER_FAKE_IMPORTED_MARKER="$tmp_dir/imported" \
  bash "$root/scripts/external-secrets-owner-handoff.sh" adopt \
    "$tmp_dir/terraform-root" "$invalid_runtime_handoff" \
    "$tmp_dir/output/rejected-invalid-time.json" course-dev >/dev/null 2>&1
invalid_time_status=$?
set -e
if [[ "$invalid_time_status" -eq 0 || -s "$tmp_dir/commands.log" || \
  -e "$tmp_dir/output/rejected-invalid-time.json" ]]; then
  echo 'invalid handoff timestamp must fail before Kubernetes, Helm, or Terraform calls' >&2
  exit 1
fi

: >"$tmp_dir/commands.log"
run_runtime_adoption "$runtime_adoption" env >/dev/null
runtime_handoff_sha=$(shasum -a 256 "$runtime_handoff" | awk '{print "sha256:"$1}')
jq -e --arg handoffSha "$runtime_handoff_sha" --slurpfile handoff "$runtime_handoff" '
  keys == ["clusterArn","environment","evidenceGrade","expiresAt","handoffSha256","observedAt","region","release","schemaVersion","terraform"] and
  .handoffSha256 == $handoffSha and
  (.release | keys) == ["after","before"] and
  .release.before == $handoff[0].release and
  .release.after == .release.before and
  .terraform == {address:"module.external_secrets[0].helm_release.this",imported:true,
    planActions:[],stateLineage:"22222222-2222-4222-8222-222222222222",stateSerial:5}
' "$runtime_adoption" >/dev/null
[[ $(stat -f '%Lp' "$runtime_adoption") == 600 ]]
[[ $(grep -Fc -- '--kube-context course-dev -n external-secrets status external-secrets -o json' \
  "$tmp_dir/commands.log") -eq 2 ]]
grep -Fq -- '-chdir=' "$tmp_dir/commands.log"

expect_runtime_adoption_rejected() {
  local label=$1
  shift
  local output="$tmp_dir/output/rejected-$label.json"
  set +e
  run_runtime_adoption "$output" env "$@" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 || -e "$output" ]]; then
    echo "runtime adoption accepted invalid post-import state: $label" >&2
    exit 1
  fi
}

expect_runtime_adoption_rejected changed-workload OWNER_FAKE_CHANGE_AFTER=workload
expect_runtime_adoption_rejected changed-storage OWNER_FAKE_CHANGE_AFTER=storage
expect_runtime_adoption_rejected changed-crd OWNER_FAKE_CHANGE_AFTER=crd
expect_runtime_adoption_rejected non-noop-plan OWNER_FAKE_PLAN_CHANGE=create
expect_runtime_adoption_rejected wrong-terraform-state OWNER_FAKE_STATE_VERSION=2.11.0

sentinel_output="$tmp_dir/output/preserved-on-failure.json"
printf '%s\n' '{"sentinel":true}' >"$sentinel_output"
sentinel_before=$(shasum -a 256 "$sentinel_output")
set +e
run_runtime_adoption "$sentinel_output" env OWNER_FAKE_CHANGE_AFTER=workload >/dev/null 2>&1
sentinel_status=$?
set -e
sentinel_after=$(shasum -a 256 "$sentinel_output")
if [[ "$sentinel_status" -eq 0 || "$sentinel_before" != "$sentinel_after" ]]; then
  echo "failed adoption replaced an existing evidence file" >&2
  exit 1
fi

if [[ -n "${ARGO_GITOPS_REPO_ROOT:-}" ]]; then
  bash "$ARGO_GITOPS_REPO_ROOT/scripts/verify-platform-owner-phase-b.sh" \
    --environment dev --handoff "$runtime_handoff" --adoption "$runtime_adoption" \
    --expected-gitops-revision 0123456789abcdef0123456789abcdef01234567 >/dev/null
fi

echo 'PASS: External Secrets single-writer handoff contract'
