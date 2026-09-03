#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$COURSE_CHECK_BIN_DIR" ]] || course_fail 'COURSE_CHECK_BIN_DIR is not a directory' 64
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

inventory=''
removal=''
dev_context=''
prod_context=''
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory) inventory=${2:-}; shift 2 ;;
    --gitops-removal) removal=${2:-}; shift 2 ;;
    --dev-context) dev_context=${2:-}; shift 2 ;;
    --prod-context) prod_context=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    *) course_fail "unknown argument: $1" 64 ;;
  esac
done
for name in inventory removal dev_context prod_context output; do
  [[ -n "${!name}" ]] || course_fail "--${name//_/-} is required" 64
done

cleanup_validate_removal "$inventory" "$removal"
course_id=$(jq -r '.courseId' "$inventory")
account_id=$(jq -r '.accountId' "$inventory")
region=$(jq -r '.region' "$inventory")
[[ -z "${COURSE_ID:-}" || "$COURSE_ID" == "$course_id" ]] || course_fail 'pre-destroy CourseId mismatch'
[[ -z "${AWS_ACCOUNT_ID:-}" || "$AWS_ACCOUNT_ID" == "$account_id" ]] || course_fail 'pre-destroy account mismatch'
[[ -z "${AWS_REGION:-}" || "$AWS_REGION" == "$region" ]] || course_fail 'pre-destroy Region mismatch'
cleanup_reject_runtime_output_from_fixture "$output" kubernetes-pre-destroy.json

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

scan_context() {
  local environment=$1 context=$2 prefix
  prefix="$tmp_dir/$environment"
  kubectl --context "$context" get applications.argoproj.io,rollouts.argoproj.io,deployments.apps,statefulsets.apps,jobs.batch,externalsecrets.external-secrets.io,chaosengines.chaos-mesh.org \
    -A -l "course.id=$course_id" -o json >"$prefix-workloads.json"
  kubectl --context "$context" get jobs.batch -A -l "course.id=$course_id,course.writer=load-generator" -o json >"$prefix-load.json"
  kubectl --context "$context" get jobs.batch -A -l "course.id=$course_id,course.writer=recovery" -o json >"$prefix-recovery.json"
  kubectl --context "$context" get jobs.batch -A -l "course.id=$course_id,course.writer=migration" -o json >"$prefix-migration.json"
  kubectl --context "$context" get chaosengines.chaos-mesh.org -A -l "course.id=$course_id" -o json >"$prefix-chaos.json"
  kubectl --context "$context" get persistentvolumeclaims -A -l "course.id=$course_id" -o json >"$prefix-pvcs.json"
  kubectl --context "$context" get persistentvolumes -o json >"$prefix-pvs.json"
  kubectl --context "$context" get volumeattachments.storage.k8s.io -o json >"$prefix-attachments.json"
  for file in "$prefix-workloads.json" "$prefix-load.json" "$prefix-recovery.json" "$prefix-migration.json" \
    "$prefix-chaos.json" "$prefix-pvcs.json" "$prefix-pvs.json" "$prefix-attachments.json"; do
    jq -e '.items | type == "array"' "$file" >/dev/null || course_fail "invalid kubectl response: $file"
  done
}

scan_context dev "$dev_context"
scan_context prod "$prod_context"

summary=$(jq -n \
  --slurpfile devWorkloads "$tmp_dir/dev-workloads.json" --slurpfile prodWorkloads "$tmp_dir/prod-workloads.json" \
  --slurpfile devLoad "$tmp_dir/dev-load.json" --slurpfile prodLoad "$tmp_dir/prod-load.json" \
  --slurpfile devRecovery "$tmp_dir/dev-recovery.json" --slurpfile prodRecovery "$tmp_dir/prod-recovery.json" \
  --slurpfile devMigration "$tmp_dir/dev-migration.json" --slurpfile prodMigration "$tmp_dir/prod-migration.json" \
  --slurpfile devChaos "$tmp_dir/dev-chaos.json" --slurpfile prodChaos "$tmp_dir/prod-chaos.json" \
  --slurpfile devAttachments "$tmp_dir/dev-attachments.json" --slurpfile prodAttachments "$tmp_dir/prod-attachments.json" '
  def allitems($a;$b): ($a[0].items + $b[0].items);
  (allitems($devWorkloads;$prodWorkloads)) as $workloads |
  {
    remainingWriters:{
      loadGenerators:(allitems($devLoad;$prodLoad) | length),
      chaosResources:(allitems($devChaos;$prodChaos) | length),
      recoveryJobs:(allitems($devRecovery;$prodRecovery) | length),
      migrationJobs:(allitems($devMigration;$prodMigration) | length)
    },
    remainingWorkloads:{
      applications:([$workloads[] | select(.kind == "Application")] | length),
      rollouts:([$workloads[] | select(.kind == "Rollout")] | length),
      deployments:([$workloads[] | select(.kind == "Deployment")] | length),
      statefulSets:([$workloads[] | select(.kind == "StatefulSet")] | length),
      jobs:([$workloads[] | select(.kind == "Job")] | length),
      externalSecrets:([$workloads[] | select(.kind == "ExternalSecret")] | length),
      chaosResources:([$workloads[] | select(.kind | startswith("Chaos") or . == "ChaosEngine")] | length),
      volumeAttachments:(allitems($devAttachments;$prodAttachments) | length)
    }
  }
')

jq -e '([.remainingWriters[],.remainingWorkloads[]] | all(. == 0))' <<<"$summary" >/dev/null || \
  course_fail 'KUBERNETES_PRE_DESTROY_NOT_EMPTY'

retained_storage=$(jq '[.retained[] | del(.requiresExplicitDeletion)] | sort_by(.environment,.namespace,.kind,.name,.uid)' "$removal")
for environment in dev prod; do
  jq -en --arg environment "$environment" \
    --argjson expected "$retained_storage" \
    --argjson actual "$(jq -c . "$tmp_dir/$environment-pvcs.json")" '
    [$expected[] | select(.environment == $environment)] as $wanted |
    ($wanted | length) == ([ $actual.items[] as $p | select(
      $p.kind == "PersistentVolumeClaim" and
      any($wanted[]; .namespace == $p.metadata.namespace and .name == $p.metadata.name and .uid == $p.metadata.uid)
    ) ] | length)
  ' >/dev/null || course_fail "RETAINED_STORAGE_NOT_OBSERVED: $environment"
done

grade=$(course_runtime_grade)
observed=$(course_now)
payload=$(jq -n --arg grade "$grade" --arg course "$course_id" --arg account "$account_id" \
  --arg region "$region" --arg removal_sha "$(course_raw_sha256_file "$removal")" --arg observed "$observed" \
  --argjson clusters "$(jq -c '.clusters' "$removal")" --argjson summary "$summary" \
  --argjson retained "$retained_storage" '
  {
    schemaVersion:"course.kubernetes-pre-destroy/v1",evidenceGrade:$grade,status:"PASS",
    courseId:$course,accountId:$account,region:$region,gitopsRemovalSha256:$removal_sha,
    clusters:$clusters,remainingWriters:$summary.remainingWriters,
    remainingWorkloads:$summary.remainingWorkloads,retainedStorage:$retained,observedAt:$observed
  }
')
course_write_json "$output" "$payload"
if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" != true ]]; then
  if [[ "$grade" == STATIC ]]; then
    echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT Kubernetes pre-destroy scan passed.'
  else
    echo 'PASS: [CLOUD_RUNTIME] Kubernetes pre-destroy scan passed.'
  fi
fi
