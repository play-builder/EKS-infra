#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$COURSE_CHECK_BIN_DIR" ]] || course_fail 'COURSE_CHECK_BIN_DIR is not a directory' 64
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

validate_only=false
inventory=''
decisions=''
pre_destroy=''
removal=''
residual=''
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only) validate_only=true; shift ;;
    --inventory) inventory=${2:-}; shift 2 ;;
    --retain-decisions) decisions=${2:-}; shift 2 ;;
    --kubernetes-pre-destroy) pre_destroy=${2:-}; shift 2 ;;
    --gitops-removal) removal=${2:-}; shift 2 ;;
    --residual) residual=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    *) course_fail "unknown argument: $1" 64 ;;
  esac
done
for name in inventory decisions pre_destroy removal; do
  [[ -n "${!name}" ]] || course_fail "--${name//_/-} is required" 64
done

cleanup_validate_removal "$inventory" "$removal"
cleanup_validate_decisions "$inventory" "$decisions"
cleanup_validate_pre_destroy "$inventory" "$removal" "$pre_destroy"

if [[ "$validate_only" == true ]]; then
  [[ -n "$residual" ]] || course_fail '--residual is required with --validate-only' 64
  cleanup_validate_residual "$inventory" "$decisions" "$pre_destroy" "$removal" "$residual"
  echo 'PASS: [STATIC] canonical cleanup residual evidence validated without cloud calls.'
  exit 0
fi

[[ -n "$output" ]] || course_fail '--output is required' 64
: "${AWS_PROFILE:?AWS_PROFILE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID is required}"
: "${COURSE_ID:?COURSE_ID is required}"
course_validate_region "$AWS_REGION"
course_validate_account "$AWS_ACCOUNT_ID"
[[ "$COURSE_ID" == "$(jq -r '.courseId' "$inventory")" ]] || course_fail 'residual CourseId mismatch'
[[ "$AWS_ACCOUNT_ID" == "$(jq -r '.accountId' "$inventory")" ]] || course_fail 'residual account mismatch'
[[ "$AWS_REGION" == "$(jq -r '.region' "$inventory")" ]] || course_fail 'residual Region mismatch'
cleanup_reject_runtime_output_from_fixture "$output" residual.json

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

aws_scan() {
  aws "$@" --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json
}

resource_present() {
  local kind=$1 id=$2
  case "$kind" in
    LoadBalancer) jq -e --arg id "$id" 'any(.LoadBalancers[]?; .LoadBalancerArn == $id)' "$tmp_dir/load-balancers.json" >/dev/null ;;
    NatGateway) jq -e --arg id "$id" 'any(.NatGateways[]?; .NatGatewayId == $id)' "$tmp_dir/nat-gateways.json" >/dev/null ;;
    EksCluster)
      local cluster_name=${id##*/}
      jq -e --arg id "$cluster_name" 'any(.clusters[]?; . == $id)' "$tmp_dir/eks-clusters.json" >/dev/null
      ;;
    EbsVolume) jq -e --arg id "$id" 'any(.Volumes[]?; .VolumeId == $id)' "$tmp_dir/ebs-volumes.json" >/dev/null ;;
    EbsSnapshot) jq -e --arg id "$id" 'any(.Snapshots[]?; .SnapshotId == $id)' "$tmp_dir/ebs-snapshots.json" >/dev/null ;;
    AmpWorkspace) jq -e --arg id "$id" 'any(.workspaces[]?; (.arn // .workspaceId) == $id)' "$tmp_dir/amp-workspaces.json" >/dev/null ;;
    SnsTopic) jq -e --arg id "$id" 'any(.Topics[]?; .TopicArn == $id)' "$tmp_dir/sns-topics.json" >/dev/null ;;
    EcrRepository) jq -e --arg id "$id" 'any(.repositories[]?; (.repositoryArn // .repositoryUri // .repositoryName) == $id)' "$tmp_dir/ecr-repositories.json" >/dev/null ;;
    SecretsManagerSecret)
      aws_scan secretsmanager describe-secret --secret-id "$id" >/dev/null 2>&1
      ;;
    *) return 2 ;;
  esac
}

scan_once() {
  aws_scan elbv2 describe-load-balancers >"$tmp_dir/load-balancers.json"
  aws_scan ec2 describe-nat-gateways --filter Name=state,Values=pending,available,deleting >"$tmp_dir/nat-gateways.json"
  aws_scan eks list-clusters >"$tmp_dir/eks-clusters.json"
  aws_scan ec2 describe-volumes >"$tmp_dir/ebs-volumes.json"
  aws_scan ec2 describe-snapshots --owner-ids self >"$tmp_dir/ebs-snapshots.json"
  aws_scan amp list-workspaces >"$tmp_dir/amp-workspaces.json"
  aws_scan sns list-topics >"$tmp_dir/sns-topics.json"
  aws_scan ecr describe-repositories >"$tmp_dir/ecr-repositories.json"
  for file in "$tmp_dir/load-balancers.json" "$tmp_dir/nat-gateways.json" "$tmp_dir/eks-clusters.json" \
    "$tmp_dir/ebs-volumes.json" "$tmp_dir/ebs-snapshots.json" "$tmp_dir/amp-workspaces.json" \
    "$tmp_dir/sns-topics.json" "$tmp_dir/ecr-repositories.json"; do
    jq -e . "$file" >/dev/null || course_fail "invalid AWS residual response: $file"
  done

  load_balancers=0
  nat_gateways=0
  eks_clusters=0
  ebs_volumes=0
  ebs_snapshots=0
  amp_workspaces=0
  sns_topics=0
  ecr_repositories=0
  missing_protected=0

  while IFS= read -r resource; do
    kind=$(jq -r '.kind' <<<"$resource")
    id=$(jq -r '.id' <<<"$resource")
    decision=$(jq -r '.decision' <<<"$resource")
    present=false
    status=0
    if resource_present "$kind" "$id"; then
      present=true
    else
      status=$?
      [[ "$status" -ne 2 ]] || course_fail "UNSUPPORTED_CLEANUP_RESOURCE_KIND: $kind"
    fi
    if [[ "$decision" == DELETE && "$present" == true ]]; then
      case "$kind" in
        LoadBalancer) ((load_balancers+=1)) ;;
        NatGateway) ((nat_gateways+=1)) ;;
        EksCluster) ((eks_clusters+=1)) ;;
        EbsVolume) ((ebs_volumes+=1)) ;;
        EbsSnapshot) ((ebs_snapshots+=1)) ;;
        AmpWorkspace) ((amp_workspaces+=1)) ;;
        SnsTopic) ((sns_topics+=1)) ;;
        EcrRepository) ((ecr_repositories+=1)) ;;
        *) course_fail "UNSUPPORTED_DELETE_KIND: $kind" ;;
      esac
    elif [[ "$decision" != DELETE && "$present" != true ]]; then
      ((missing_protected+=1))
    fi
  done < <(jq -c '.resources[]' "$inventory")

  total=$((load_balancers + nat_gateways + eks_clusters + ebs_volumes + ebs_snapshots + amp_workspaces + sns_topics + ecr_repositories))
}

attempts=${RESIDUAL_SCAN_ATTEMPTS:-12}
delay=${RESIDUAL_SCAN_DELAY_SECONDS:-10}
if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  attempts=${RESIDUAL_SCAN_ATTEMPTS:-1}
  delay=${RESIDUAL_SCAN_DELAY_SECONDS:-0}
fi
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || course_fail 'RESIDUAL_SCAN_ATTEMPTS must be a positive integer' 64
[[ "$delay" =~ ^[0-9]+$ ]] || course_fail 'RESIDUAL_SCAN_DELAY_SECONDS must be a non-negative integer' 64

for ((attempt=1; attempt<=attempts; attempt++)); do
  scan_once
  if [[ "$total" -eq 0 && "$missing_protected" -eq 0 ]]; then break; fi
  if [[ "$attempt" -eq "$attempts" ]]; then
    course_fail "RESIDUAL_SCAN_TIMEOUT: unapproved=$total missingProtected=$missing_protected"
  fi
  sleep "$delay"
done

grade=$(course_runtime_grade)
observed=$(course_now)
external=$(jq '[.resources[] | select(.decision == "EXTERNAL_SHARED") |
  {kind,id,owner,deletePlanned:false,presentAfterCleanup:true}] | sort_by(.kind,.id)' "$inventory")
retained=$(jq -n --argjson inventory "$(jq -c . "$inventory")" --argjson decisions "$(jq -c . "$decisions")" '
  [$decisions.decisions[] | select(.decision == "RETAIN") as $d |
    ($inventory.resources[] | select(.kind == $d.kind and .id == $d.id)) as $i |
    {kind:$d.kind,id:$d.id,owner:$i.owner,reason:$d.reason,followUpAction:$d.followUpAction,presentAfterCleanup:true}]
  | sort_by(.kind,.id)
')
payload=$(jq -n --arg grade "$grade" --arg course "$COURSE_ID" --arg account "$AWS_ACCOUNT_ID" \
  --arg region "$AWS_REGION" --arg inventory_sha "$(course_raw_sha256_file "$inventory")" \
  --arg decisions_sha "$(course_raw_sha256_file "$decisions")" \
  --arg pre_sha "$(course_raw_sha256_file "$pre_destroy")" --arg removal_sha "$(course_raw_sha256_file "$removal")" \
  --arg observed "$observed" --argjson external "$external" --argjson retained "$retained" \
  --argjson load_balancers "$load_balancers" --argjson nat_gateways "$nat_gateways" \
  --argjson eks_clusters "$eks_clusters" --argjson ebs_volumes "$ebs_volumes" \
  --argjson ebs_snapshots "$ebs_snapshots" --argjson amp_workspaces "$amp_workspaces" \
  --argjson sns_topics "$sns_topics" --argjson ecr_repositories "$ecr_repositories" '
  {
    schemaVersion:"course.cleanup-residual/v1",evidenceGrade:$grade,status:"PASS",
    courseId:$course,accountId:$account,region:$region,
    inventorySha256:$inventory_sha,retainDecisionsSha256:$decisions_sha,
    kubernetesPreDestroySha256:$pre_sha,gitopsRemovalSha256:$removal_sha,
    unapprovedCourseOwned:{loadBalancers:$load_balancers,natGateways:$nat_gateways,
      eksClusters:$eks_clusters,ebsVolumes:$ebs_volumes,ebsSnapshots:$ebs_snapshots,
      ampWorkspaces:$amp_workspaces,snsTopics:$sns_topics,ecrRepositories:$ecr_repositories,
      total:($load_balancers+$nat_gateways+$eks_clusters+$ebs_volumes+$ebs_snapshots+$amp_workspaces+$sns_topics+$ecr_repositories)},
    externalShared:$external,retained:$retained,observedAt:$observed
  }
')
course_write_json "$output" "$payload"
cleanup_validate_residual "$inventory" "$decisions" "$pre_destroy" "$removal" "$output"
if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" != true ]]; then
  if [[ "$grade" == STATIC ]]; then
    echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT cleanup residual scan passed.'
  else
    echo 'PASS: [CLOUD_RUNTIME] cleanup residual scan passed.'
  fi
fi
