#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

if [[ -n "${PLATFORM_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$PLATFORM_CHECK_BIN_DIR" ]] || pb_fail 'PLATFORM_CHECK_BIN_DIR is not a directory' 64
  PATH="$PLATFORM_CHECK_BIN_DIR:$PATH"
fi

dev_context=''
prod_context=''
dev_cluster_name=''
prod_cluster_name=''
output_override=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev-context) dev_context=${2:-}; shift 2 ;;
    --prod-context) prod_context=${2:-}; shift 2 ;;
    --dev-cluster-name) dev_cluster_name=${2:-}; shift 2 ;;
    --prod-cluster-name) prod_cluster_name=${2:-}; shift 2 ;;
    --output) output_override=${2:-}; shift 2 ;;
    *) pb_fail "unknown argument: $1" 64 ;;
  esac
done

for name in dev_context prod_context dev_cluster_name prod_cluster_name; do
  [[ -n "${!name}" ]] || pb_fail "--${name//_/-} is required" 64
done
for name in OWNER_ID AWS_ACCOUNT_ID AWS_REGION AWS_PROFILE; do
  [[ -n "${!name:-}" ]] || pb_fail "$name is required" 64
done
pb_validate_region "$AWS_REGION"
pb_validate_account "$AWS_ACCOUNT_ID"
jq -en --arg owner "$OWNER_ID" --arg dev "$dev_context" --arg prod "$prod_context" '
  def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
  ($owner | nonblank) and ($dev | nonblank) and ($prod | nonblank) and $dev != $prod
' >/dev/null || pb_fail 'owner and Kubernetes context identities must be nonblank and distinct' 64
for cluster_name in "$dev_cluster_name" "$prod_cluster_name"; do
  [[ "$cluster_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] || \
    pb_fail 'invalid canonical EKS cluster name' 64
done
[[ "$dev_cluster_name" != "$prod_cluster_name" ]] || pb_fail 'EKS cluster names must be distinct' 64

ttl=${CLEANUP_IN_FLIGHT_TTL_SECONDS:-900}
[[ "$ttl" =~ ^[1-9][0-9]*$ ]] || pb_fail 'CLEANUP_IN_FLIGHT_TTL_SECONDS must be positive' 64
grade=$(pb_runtime_grade)
canonical_output="$REPO_ROOT/evidence/cleanup/in-flight-zero.json"
if [[ "$grade" == STATIC ]]; then
  [[ -n "$output_override" ]] || pb_fail '--output is required with PLATFORM_CHECK_BIN_DIR' 64
  output=$output_override
  cleanup_require_canonical_runtime_output "$output" "$REPO_ROOT" in-flight-zero.json
else
  [[ -z "$output_override" ]] || pb_fail 'runtime in-flight output is fixed to the canonical path' 64
  output=$canonical_output
  cleanup_require_canonical_runtime_output "$output" "$REPO_ROOT" in-flight-zero.json
  mkdir -p "$REPO_ROOT/evidence/cleanup"
fi

for command_name in aws kubectl jq mktemp; do
  command -v "$command_name" >/dev/null || pb_fail "required command not found: $command_name" 69
done

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

empty_list() {
  printf '%s\n' '{"apiVersion":"v1","kind":"List","items":[]}'
}

capture_cluster() {
  local environment=$1 context=$2 cluster_name=$3
  local cluster_json cluster_arn endpoint kubeconfig server api_resources resource

  cluster_json=$(aws eks describe-cluster --name "$cluster_name" --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" --output json) || pb_fail "unable to describe $environment EKS cluster"
  jq -e --arg name "$cluster_name" --arg environment "$environment" --arg region "$AWS_REGION" \
    --arg account "$AWS_ACCOUNT_ID" --arg owner "$OWNER_ID" '
    .cluster.name == $name and .cluster.status == "ACTIVE" and
    .cluster.arn == ("arn:aws:eks:"+$region+":"+$account+":cluster/"+$name) and
    (.cluster.endpoint | type == "string" and startswith("https://")) and
    (.cluster.tags.OwnerId // .cluster.tags.PlatformInstanceId) == $owner and
    (.cluster.tags.PlatformInstanceId == null or .cluster.tags.PlatformInstanceId == $owner) and
    .cluster.tags.Environment == $environment
  ' <<<"$cluster_json" >/dev/null || pb_fail "$environment EKS cluster scope or ownership mismatch"
  cluster_arn=$(jq -r '.cluster.arn' <<<"$cluster_json")
  pb_assert_eks_cluster_arn "$cluster_arn" "$AWS_REGION" "$AWS_ACCOUNT_ID"
  endpoint=$(jq -r '.cluster.endpoint' <<<"$cluster_json")

  kubeconfig=$(kubectl --context "$context" config view --minify -o json) || \
    pb_fail "unable to inspect $environment Kubernetes context"
  server=$(jq -er '.clusters | if length == 1 then .[0].cluster.server else empty end' \
    <<<"$kubeconfig") || pb_fail "$environment context must contain exactly one cluster server"
  [[ "$server" == "$endpoint" ]] || pb_fail "$environment Kubernetes context does not match EKS cluster"

  jq -n --arg environment "$environment" --arg context "$context" --arg arn "$cluster_arn" \
    '{environment:$environment,context:$context,clusterArn:$arn}' >"$tmp_dir/$environment-cluster.json"

  api_resources=$(kubectl --context "$context" api-resources -o name) || \
    pb_fail "unable to discover writer APIs in $environment"
  kubectl --context "$context" get jobs.batch -A -o json >"$tmp_dir/$environment-jobs.json" || \
    pb_fail "unable to query Jobs in $environment"
  kubectl --context "$context" get statefulsets.apps -A -o json >"$tmp_dir/$environment-statefulsets.json" || \
    pb_fail "unable to query StatefulSets in $environment"

  if grep -Fxq 'testruns.k6.io' <<<"$api_resources"; then
    kubectl --context "$context" get testruns.k6.io -A -o json >"$tmp_dir/$environment-load.json" || \
      pb_fail "unable to query k6 TestRuns in $environment"
  else
    empty_list >"$tmp_dir/$environment-load.json"
  fi
  for resource in podchaos.chaos-mesh.org networkchaos.chaos-mesh.org; do
    if grep -Fxq "$resource" <<<"$api_resources"; then
      kubectl --context "$context" get "$resource" -A -o json >"$tmp_dir/$environment-$resource.json" || \
        pb_fail "unable to query $resource in $environment"
    else
      empty_list >"$tmp_dir/$environment-$resource.json"
    fi
  done

  for resource in jobs statefulsets load podchaos.chaos-mesh.org networkchaos.chaos-mesh.org; do
    jq -e '.items | type == "array"' "$tmp_dir/$environment-$resource.json" >/dev/null || \
      pb_fail "$environment writer query returned a non-list response"
  done
}

capture_cluster dev "$dev_context" "$dev_cluster_name"
capture_cluster prod "$prod_context" "$prod_cluster_name"

clusters=$(jq -s '.' "$tmp_dir/dev-cluster.json" "$tmp_dir/prod-cluster.json")
jq -e '
  [.[].environment] == ["dev","prod"] and
  (.[0].context != .[1].context) and (.[0].clusterArn != .[1].clusterArn)
' <<<"$clusters" >/dev/null || pb_fail 'Dev and Prod cluster identities must be ordered and distinct'

writers=$(jq -n \
  --slurpfile devJobs "$tmp_dir/dev-jobs.json" --slurpfile prodJobs "$tmp_dir/prod-jobs.json" \
  --slurpfile devStateful "$tmp_dir/dev-statefulsets.json" --slurpfile prodStateful "$tmp_dir/prod-statefulsets.json" \
  --slurpfile devLoad "$tmp_dir/dev-load.json" --slurpfile prodLoad "$tmp_dir/prod-load.json" \
  --slurpfile devPodChaos "$tmp_dir/dev-podchaos.chaos-mesh.org.json" \
  --slurpfile prodPodChaos "$tmp_dir/prod-podchaos.chaos-mesh.org.json" \
  --slurpfile devNetworkChaos "$tmp_dir/dev-networkchaos.chaos-mesh.org.json" \
  --slurpfile prodNetworkChaos "$tmp_dir/prod-networkchaos.chaos-mesh.org.json" '
  def items($left;$right): $left[0].items + $right[0].items;
  def active_job($labels):
    ((.status.active // 0) | type == "number" and . > 0) and
    ((.metadata.labels["playbuilder.io/writer"] // "") == $labels[0] or
     (.metadata.labels["app.kubernetes.io/component"] // "") == $labels[1]);
  items($devJobs;$prodJobs) as $jobs |
  items($devStateful;$prodStateful) as $stateful |
  {
    loadGenerators:
      (([items($devLoad;$prodLoad)[] | select((.status.stage // "") != "finished")] | length) +
       ([$jobs[] | select(active_job(["load-generator","load-generator"]))] | length)),
    chaosResources:
      ((items($devPodChaos;$prodPodChaos) | length) +
       (items($devNetworkChaos;$prodNetworkChaos) | length)),
    recoveryJobs:
      (([$jobs[] | select(active_job(["recovery","recovery"]))] | length) +
       ([$stateful[] | select(
         ((.spec.replicas // 0) | type == "number" and . > 0) and
         ((.metadata.labels["playbuilder.io/writer"] // "") == "recovery" or
          (.metadata.labels["app.kubernetes.io/component"] // "") == "recovery" or
          (.metadata.labels["playbuilder.io/cleanup-scope"] // "") == "recovery"))] | length)),
    migrationJobs:([$jobs[] | select(active_job(["migration","migration"]))] | length)
  }
') || pb_fail 'unable to summarize active writers'
jq -e '
  (keys == ["chaosResources","loadGenerators","migrationJobs","recoveryJobs"]) and
  ([.[]] | all(type == "number" and floor == . and . == 0))
' <<<"$writers" >/dev/null || pb_fail 'active load, Chaos, recovery, or migration writers remain'

observed=$(pb_now)
expires=$(pb_expires_after "$ttl")
payload=$(jq -n --arg grade "$grade" --arg owner "$OWNER_ID" --arg account "$AWS_ACCOUNT_ID" \
  --arg region "$AWS_REGION" --arg observed "$observed" --arg expires "$expires" \
  --argjson clusters "$clusters" --argjson writers "$writers" '
  {schemaVersion:"playbuilder.in-flight-zero/v1",evidenceGrade:$grade,status:"PASS",
   ownerId:$owner,accountId:$account,region:$region,clusters:$clusters,
   remainingWriters:$writers,observedAt:$observed,expiresAt:$expires}
')

if [[ -e "$output" || -L "$output" ]]; then
  [[ -f "$output" && ! -L "$output" ]] || pb_fail 'existing in-flight evidence is not a regular file'
  pb_assert_json "$output" '
    keys == ["accountId","clusters","evidenceGrade","expiresAt","observedAt","ownerId","region","remainingWriters","schemaVersion","status"] and
    .schemaVersion == "playbuilder.in-flight-zero/v1" and .status == "PASS" and
    (.evidenceGrade == "STATIC" or .evidenceGrade == "CLOUD_RUNTIME") and
    (.observedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      ((fromdateiso8601 | todateiso8601) == .)) and
    (.expiresAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      ((fromdateiso8601 | todateiso8601) == .))
  ' 'existing in-flight evidence is invalid'
  jq -en --argjson existing "$(jq -c . "$output")" --argjson incoming "$payload" '
    $existing.ownerId == $incoming.ownerId and
    $existing.accountId == $incoming.accountId and
    $existing.region == $incoming.region and
    $existing.clusters == $incoming.clusters
  ' >/dev/null || pb_fail 'IN_FLIGHT_EXISTING_IDENTITY_MISMATCH'
fi

pb_write_json "$output" "$payload"
if [[ "$grade" == STATIC ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT in-flight writer evidence is zero.'
else
  echo 'PASS: [CLOUD_RUNTIME] in-flight writer evidence is zero.'
fi
