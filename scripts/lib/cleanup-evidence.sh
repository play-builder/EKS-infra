#!/usr/bin/env bash

cleanup_grade_is_valid() {
  local file=$1
  jq -e '.evidenceGrade == "CLOUD_RUNTIME" or (.evidenceGrade == "STATIC" and ($ENV.COURSE_CHECK_BIN_DIR // "") != "")' \
    "$file" >/dev/null
}

cleanup_assert_canonical_utc_seconds() {
  course_assert_canonical_utc_seconds "$@"
}

cleanup_expected_destroy_layers_json() {
  jq -cn '[
    "environments/prod/04-workloads/argocd",
    "environments/dev/04-workloads/argocd",
    "environments/prod/03-platform",
    "environments/dev/03-platform",
    "environments/prod/02-eks",
    "environments/dev/02-eks",
    "environments/prod/01-network",
    "environments/dev/01-network"
  ]'
}

cleanup_validate_saved_plan_manifest() {
  local manifest=$1 repo_root=$2 layer
  course_require_file "$manifest"
  cleanup_assert_canonical_utc_seconds "$manifest" 'saved destroy plans reviewedAt' '["reviewedAt"]'
  course_assert_json "$manifest" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    keys == ["plans","reviewedAt","schemaVersion","status"] and
    .schemaVersion == "course.saved-destroy-plans/v1" and .status == "REVIEWED" and
    (.reviewedAt | fromdateiso8601) <= now and
    (.plans | type == "array" and length == 8) and
    ([.plans[].layer] == [
      "environments/prod/04-workloads/argocd",
      "environments/dev/04-workloads/argocd",
      "environments/prod/03-platform",
      "environments/dev/03-platform",
      "environments/prod/02-eks",
      "environments/dev/02-eks",
      "environments/prod/01-network",
      "environments/dev/01-network"
    ]) and
    all(.plans[];
      keys == ["layer","path","sha256"] and
      (.layer | nonblank) and (.path | startswith("/")) and
      (.sha256 | test("^[0-9a-f]{64}$")))
  ' 'invalid reviewed saved destroy plan manifest'

  while IFS= read -r layer; do
    [[ -d "$repo_root/$layer" ]] || course_fail "cleanup layer not found: $layer"
  done < <(jq -r '.plans[].layer' "$manifest")
}

cleanup_validate_saved_plan_file() {
  local saved_plan=$1 expected_sha=$2 layer=$3
  [[ -f "$saved_plan" && ! -L "$saved_plan" ]] || course_fail "SAVED_DESTROY_PLAN_INVALID: $saved_plan"
  chmod 600 "$saved_plan"
  [[ $(course_raw_sha256_file "$saved_plan") == "$expected_sha" ]] || \
    course_fail "SAVED_DESTROY_PLAN_DIGEST_MISMATCH: $layer"
}

cleanup_validate_saved_destroy_plan() {
  local layer=$1 saved_plan=$2 inventory=$3 repo_root=$4
  local course=$5 account=$6 region=$7 project=$8 plan_json environment semantic_layer
  environment=${layer#environments/}
  environment=${environment%%/*}
  case "$layer" in
    */01-network) semantic_layer=network ;;
    */02-eks) semantic_layer=eks ;;
    */03-platform) semantic_layer=platform ;;
    */04-workloads/argocd) semantic_layer=workloads ;;
    *) course_fail "SAVED_DESTROY_PLAN_LAYER_UNSUPPORTED: $layer" ;;
  esac

  plan_json=$(terraform -chdir="$repo_root/$layer" show -json "$saved_plan") || \
    course_fail "SAVED_DESTROY_PLAN_SHOW_FAILED: $layer"
  jq -e '
    (.format_version | type == "string") and
    (.resource_changes | type == "array" and length > 0) and
    all(.resource_changes[]; .mode == "managed" and .change.actions == ["delete"] and (.change.before | type == "object"))
  ' <<<"$plan_json" >/dev/null || course_fail "SAVED_DESTROY_PLAN_NOT_DELETE_ONLY: $layer"

  jq -e --arg environment "$environment" --arg semanticLayer "$semantic_layer" \
    --arg course "$course" --arg account "$account" --arg region "$region" \
    --arg project "$project" --slurpfile inventory "$inventory" '
    def address_allowed:
      if $semanticLayer == "network" then
        .address | test("^module\\.vpc(\\[[^]]+\\])?\\.")
      elif $semanticLayer == "eks" then
        .address | test("^module\\.(eks_cluster|node_group_public|node_group_private|bastion)(\\[[^]]+\\])?\\.")
      elif $semanticLayer == "platform" then
        (.address | test("^(terraform_data\\.external_secrets_ownership_gate|kubernetes_storage_class_v1\\.course_gp3|kubectl_manifest\\.(gateway_api|aws_lbc_gateway|volume_snapshot_class)(\\[[^]]+\\])?|aws_secretsmanager_secret\\.(sample_app_runtime|sample_app_db)|aws_eks_addon\\.snapshot_controller(\\[[^]]+\\])?|aws_iam_(role|policy|role_policy_attachment)\\.recovery_db_secret_reader(\\[[^]]+\\])?)$")) or
        (.address | test("^module\\.(external_secrets_reader_irsa|rollouts_amp_irsa|external_secrets|reloader|k6_operator|chaos_mesh|ebs_csi_driver|aws_load_balancer_controller|external_dns|acm|metrics_server|cluster_autoscaler|container_insights|amp|adot_collector|amp_alerting|amg)(\\[[^]]+\\])?\\."))
      else
        .address | test("^(terraform_data\\.course_ownership|helm_release\\.(argocd|argo_rollouts)|kubectl_manifest\\.(gateway_plugin_cluster_role|gateway_plugin_cluster_role_binding|bootstrap))(\\[[^]]+\\])?$")
      end;
    def untaggable:
      .type == "terraform_data" or .type == "helm_release" or .type == "kubectl_manifest" or
      (.type | startswith("kubernetes_")) or
      .type == "aws_acm_certificate_validation" or .type == "aws_eks_access_policy_association" or
      .type == "aws_iam_role_policy" or .type == "aws_iam_role_policy_attachment" or
      .type == "aws_prometheus_alert_manager_definition" or .type == "aws_prometheus_rule_group_namespace" or
      .type == "aws_route" or .type == "aws_route53_record" or .type == "aws_route_table_association" or
      .type == "aws_security_group_rule" or .type == "aws_sns_topic_policy" or .type == "aws_sns_topic_subscription";
    def matching_inventory:
      (.change.before.id // "") as $id |
      [$inventory[0].resources[] | select(.id == $id)];
    def inventory_allows_delete:
      matching_inventory as $matches |
      ($matches | length) <= 1 and
      (if ($matches | length) == 1 then
         $matches[0].decision == "DELETE" and $matches[0].owner == "course" and
         $matches[0].managedBy == "terraform" and $matches[0].environment == $environment
       else true end);
    def tags_allow_delete:
      (.change.before.tags_all // .change.before.tags // null) as $tags |
      if ($tags | type) == "object" and ($tags | length) > 0 then
        $tags.CourseId == $course and $tags.Project == $project and
        $tags.Environment == $environment and $tags.Layer == $semanticLayer and
        $tags.ManagedBy == "Terraform"
      elif .type == "terraform_data" and .address == "terraform_data.course_ownership" then
        .change.before.input.CourseId == $course and .change.before.input.AccountId == $account and
        .change.before.input.Region == $region and .change.before.input.Project == $project and
        .change.before.input.Environment == $environment and
        .change.before.input.Layer == $semanticLayer and .change.before.input.ManagedBy == "Terraform"
      else untaggable end;
    all(.resource_changes[]; address_allowed and inventory_allows_delete and tags_allow_delete)
  ' <<<"$plan_json" >/dev/null || course_fail "SAVED_DESTROY_PLAN_OWNERSHIP_MISMATCH: $layer"
}

cleanup_validate_apply_progress() {
  local progress=$1 manifest=$2
  course_require_file "$progress"
  cleanup_assert_canonical_utc_seconds "$progress" 'saved plan progress updatedAt' '["updatedAt"]'
  course_assert_json "$progress" '
    keys == ["completed","inFlight","manifestSha256","schemaVersion","status","updatedAt"] and
    .schemaVersion == "course.saved-destroy-progress/v1" and
    (.manifestSha256 | test("^[0-9a-f]{64}$")) and
    (.status == "IN_PROGRESS" or .status == "COMPLETE") and
    (.completed | type == "array" and length <= 8) and
    all(.completed[]; keys == ["appliedAt","layer","sha256"] and
      (.sha256 | test("^[0-9a-f]{64}$")) and
      (.appliedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
        ((try (fromdateiso8601 | todateiso8601) catch "") == .))) and
    (.inFlight == null or (.inFlight | keys == ["layer","sha256","startedAt"] and
      (.sha256 | test("^[0-9a-f]{64}$")) and
      (.startedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
        ((try (fromdateiso8601 | todateiso8601) catch "") == .)))) and
    (if .status == "COMPLETE" then (.completed | length) == 8 and .inFlight == null
     else (.completed | length) < 8 end)
  ' 'invalid saved destroy plan progress'
  while IFS=$'\t' read -r index layer sha; do
    [[ $(jq -r --argjson index "$index" '.plans[$index].layer' "$manifest") == "$layer" ]] || \
      course_fail 'SAVED_DESTROY_PROGRESS_LAYER_MISMATCH'
    [[ $(jq -r --argjson index "$index" '.plans[$index].sha256' "$manifest") == "$sha" ]] || \
      course_fail 'SAVED_DESTROY_PROGRESS_DIGEST_MISMATCH'
  done < <(jq -r '.completed | to_entries[] | [.key,.value.layer,.value.sha256] | @tsv' "$progress")
}

cleanup_remove_completed_plan_files() {
  local manifest=$1 progress=$2 completed_count saved_plan expected_sha layer
  completed_count=$(jq -r '.completed | length' "$progress")
  while IFS=$'\t' read -r layer saved_plan expected_sha; do
    if [[ -e "$saved_plan" ]]; then
      cleanup_validate_saved_plan_file "$saved_plan" "$expected_sha" "$layer"
      rm -f -- "$saved_plan"
    fi
  done < <(jq -r --argjson count "$completed_count" '.plans[:$count][] | [.layer,.path,.sha256] | @tsv' "$manifest")
}

cleanup_apply_saved_plans() {
  local manifest=$1 repo_root=$2 inventory=$3 progress=$4 project=$5
  local manifest_sha progress_manifest_sha completed_count layer saved_plan expected_sha actual_manifest_sha now payload
  local course account region
  cleanup_validate_saved_plan_manifest "$manifest" "$repo_root"
  cleanup_validate_inventory "$inventory"
  course=$(jq -r '.courseId' "$inventory")
  account=$(jq -r '.accountId' "$inventory")
  region=$(jq -r '.region' "$inventory")
  manifest_sha=$(course_raw_sha256_file "$manifest")

  if [[ -e "$progress" ]]; then
    [[ ! -L "$progress" ]] || course_fail "SAVED_DESTROY_PROGRESS_SYMLINK_BLOCKED: $progress"
    cleanup_validate_apply_progress "$progress" "$manifest"
    course_assert_file_mode "$progress" 600
    progress_manifest_sha=$(jq -r '.manifestSha256' "$progress")
    if [[ "$progress_manifest_sha" != "$manifest_sha" && $(jq -r '.inFlight == null' "$progress") == true ]]; then
      course_fail 'SAVED_DESTROY_PROGRESS_MANIFEST_MISMATCH'
    fi
    cleanup_remove_completed_plan_files "$manifest" "$progress"
    if [[ $(jq -r '.status' "$progress") == COMPLETE ]]; then
      return 0
    fi
    if [[ $(jq -r '.inFlight != null' "$progress") == true ]]; then
      completed_count=$(jq -r '.completed | length' "$progress")
      layer=$(jq -r '.inFlight.layer' "$progress")
      expected_sha=$(jq -r --argjson index "$completed_count" '.plans[$index].sha256' "$manifest")
      [[ "$layer" == "$(jq -r --argjson index "$completed_count" '.plans[$index].layer' "$manifest")" ]] || \
        course_fail 'SAVED_DESTROY_PROGRESS_LAYER_MISMATCH'
      [[ "$expected_sha" != "$(jq -r '.inFlight.sha256' "$progress")" ]] || \
        course_fail "SAVED_DESTROY_PLAN_REVIEW_REQUIRED_AFTER_FAILURE: $layer"
    fi
    payload=$(jq --arg manifest "$manifest_sha" '
      .manifestSha256=$manifest | .inFlight=null | .status="IN_PROGRESS"
    ' "$progress")
    course_write_json "$progress" "$payload"
  else
    now=$(course_now)
    payload=$(jq -n --arg manifest "$manifest_sha" --arg now "$now" '{
      schemaVersion:"course.saved-destroy-progress/v1",status:"IN_PROGRESS",
      manifestSha256:$manifest,completed:[],inFlight:null,updatedAt:$now
    }')
    course_write_json "$progress" "$payload"
  fi

  completed_count=$(jq -r '.completed | length' "$progress")
  while IFS=$'\t' read -r layer saved_plan expected_sha; do
    cleanup_validate_saved_plan_file "$saved_plan" "$expected_sha" "$layer"
    cleanup_validate_saved_destroy_plan "$layer" "$saved_plan" "$inventory" "$repo_root" \
      "$course" "$account" "$region" "$project"
  done < <(jq -r --argjson start "$completed_count" '.plans[$start:][] | [.layer,.path,.sha256] | @tsv' "$manifest")

  while IFS=$'\t' read -r layer saved_plan expected_sha; do
    actual_manifest_sha=$(course_raw_sha256_file "$manifest")
    [[ "$actual_manifest_sha" == "$manifest_sha" ]] || course_fail 'SAVED_DESTROY_PLAN_MANIFEST_CHANGED'
    cleanup_validate_saved_plan_file "$saved_plan" "$expected_sha" "$layer"
    now=$(course_now)
    payload=$(jq --arg layer "$layer" --arg sha "$expected_sha" --arg now "$now" '
      .inFlight={layer:$layer,sha256:$sha,startedAt:$now} | .updatedAt=$now
    ' "$progress")
    course_write_json "$progress" "$payload"
    if ! terraform -chdir="$repo_root/$layer" apply "$saved_plan"; then
      course_fail "TERRAFORM_SAVED_PLAN_APPLY_FAILED: $layer"
    fi
    now=$(course_now)
    payload=$(jq --arg layer "$layer" --arg sha "$expected_sha" --arg now "$now" '
      .completed += [{layer:$layer,sha256:$sha,appliedAt:$now}] |
      .inFlight=null | .updatedAt=$now
    ' "$progress")
    course_write_json "$progress" "$payload"
    rm -f -- "$saved_plan"
  done < <(jq -r --argjson start "$completed_count" '.plans[$start:][] | [.layer,.path,.sha256] | @tsv' "$manifest")

  now=$(course_now)
  payload=$(jq --arg now "$now" '.status="COMPLETE" | .inFlight=null | .updatedAt=$now' "$progress")
  course_write_json "$progress" "$payload"
}

cleanup_normalize_absolute_path() {
  local input=$1 segment normalized='' depth=0 index
  local -a parts=() stack=()
  [[ "$input" == /* ]] || input="$PWD/$input"
  IFS='/' read -r -a parts <<<"$input"
  for segment in "${parts[@]}"; do
    case "$segment" in
      ''|.) ;;
      ..)
        if ((depth > 0)); then
          depth=$((depth - 1))
          unset "stack[$depth]"
        fi
        ;;
      *)
        stack[$depth]=$segment
        depth=$((depth + 1))
        ;;
    esac
  done
  for ((index=0; index<depth; index++)); do normalized+="/${stack[$index]}"; done
  printf '%s\n' "${normalized:-/}"
}

cleanup_resolve_parent_identity() {
  local directory=$1 probe suffix='' component physical
  directory=$(cleanup_normalize_absolute_path "$directory")
  probe=$directory
  while [[ ! -d "$probe" ]]; do
    [[ "$probe" != / ]] || break
    component=${probe##*/}
    suffix="/$component$suffix"
    probe=${probe%/*}
    [[ -n "$probe" ]] || probe=/
  done
  physical=$(cd -- "$probe" && pwd -P)
  printf '%s%s\n' "${physical%/}" "$suffix"
}

cleanup_output_identity() {
  local output=$1 normalized parent name parent_identity
  normalized=$(cleanup_normalize_absolute_path "$output")
  parent=${normalized%/*}
  [[ -n "$parent" ]] || parent=/
  name=${normalized##*/}
  parent_identity=$(cleanup_resolve_parent_identity "$parent")
  printf '%s/%s\n' "${parent_identity%/}" "$name"
}

cleanup_reject_runtime_output_from_fixture() {
  local output=$1 repo_root=$2 canonical_name=$3
  local output_path canonical_path output_identity canonical_identity
  [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]] || return 0
  output_path=$(cleanup_normalize_absolute_path "$output")
  canonical_path=$(cleanup_normalize_absolute_path "$repo_root/evidence/cleanup/$canonical_name")
  output_identity=$(cleanup_output_identity "$output_path")
  canonical_identity=$(cleanup_output_identity "$canonical_path")
  if [[ -L "$output_path" || "$output_path" == "$canonical_path" || "$output_identity" == "$canonical_identity" ]]; then
    course_fail "FIXTURE_RUNTIME_OUTPUT_BLOCKED: $output"
  fi
}

cleanup_require_canonical_runtime_output() {
  local output=$1 repo_root=$2 canonical_name=$3
  local output_path canonical_path output_identity
  if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
    cleanup_reject_runtime_output_from_fixture "$output" "$repo_root" "$canonical_name"
    return 0
  fi
  output_path=$(cleanup_normalize_absolute_path "$output")
  canonical_path=$(cleanup_normalize_absolute_path "$repo_root/evidence/cleanup/$canonical_name")
  [[ "$output_path" == "$canonical_path" ]] || \
    course_fail "NONCANONICAL_RUNTIME_OUTPUT: expected $canonical_path"
  output_identity=$(cleanup_output_identity "$output_path")
  [[ ! -L "$output_path" && "$output_identity" == "$canonical_path" ]] || \
    course_fail "RUNTIME_OUTPUT_SYMLINK_ESCAPE_BLOCKED: $output"
}

cleanup_provider_secret_sha() {
  local inventory=$1
  jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
    "$inventory" | shasum -a 256 | awk '{print $1}'
}

cleanup_validate_inventory() {
  local inventory=$1
  course_require_file "$inventory"
  cleanup_assert_canonical_utc_seconds "$inventory" 'ownership observedAt' '["observedAt"]'
  cleanup_grade_is_valid "$inventory" || course_fail 'invalid ownership evidence grade'
  course_assert_json "$inventory" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    keys == ["accountId","courseId","evidenceGrade","observedAt","region","resources","schemaVersion"] and
    .schemaVersion == "course.cleanup-ownership/v1" and
    (.courseId | nonblank) and (.accountId | test("^[0-9]{12}$")) and
    (.region == "ap-northeast-2" or .region == "us-east-1") and
    (.resources | type == "array" and length > 0) and
    ([.resources[] | [.kind,.id]] == ([.resources[] | [.kind,.id]] | sort)) and
    ([.resources[] | [.kind,.id]] | unique | length) == (.resources | length) and
    all(.resources[];
      keys == ["billable","classification","decision","environment","followUpAction","id","kind","managedBy","owner","reason"] and
      (.kind | nonblank) and (.id | nonblank) and
      (.environment == "dev" or .environment == "prod" or .environment == "shared") and
      (.classification | nonblank) and
      (.owner | nonblank) and .managedBy == "terraform" and
      (.billable | type == "boolean") and
      (.reason | type == "string") and (.followUpAction | type == "string") and
      (.decision == "DELETE" or .decision == "RETAIN" or .decision == "EXTERNAL_SHARED") and
      (if .decision == "DELETE" then .owner == "course"
       else (.reason | nonblank) and (.followUpAction | nonblank) end)) and
    (.observedAt | fromdateiso8601) <= now
  ' 'invalid course.cleanup-ownership/v1 evidence'
  [[ -z "${COURSE_ID:-}" || $(jq -r '.courseId' "$inventory") == "$COURSE_ID" ]] || course_fail 'inventory CourseId mismatch'
  [[ -z "${AWS_ACCOUNT_ID:-}" || $(jq -r '.accountId' "$inventory") == "$AWS_ACCOUNT_ID" ]] || course_fail 'inventory account mismatch'
  [[ -z "${AWS_REGION:-}" || $(jq -r '.region' "$inventory") == "$AWS_REGION" ]] || course_fail 'inventory Region mismatch'
}

cleanup_validate_decisions() {
  local inventory=$1 decisions=$2
  cleanup_validate_inventory "$inventory"
  course_require_file "$decisions"
  cleanup_assert_canonical_utc_seconds "$decisions" 'retain decisions approvedAt' '["approvedAt"]'
  course_assert_json "$decisions" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    keys == ["accountId","approvedAt","courseId","decisions","evidenceGrade","inventorySha256","region","schemaVersion","status"] and
    .schemaVersion == "course.cleanup-retain-decisions/v1" and .evidenceGrade == "LOCAL_RUNTIME" and .status == "APPROVED" and
    (.courseId | nonblank) and (.accountId | test("^[0-9]{12}$")) and
    (.region == "ap-northeast-2" or .region == "us-east-1") and
    (.inventorySha256 | test("^[0-9a-f]{64}$")) and
    ([.decisions[] | [.kind,.id]] == ([.decisions[] | [.kind,.id]] | sort)) and
    ([.decisions[] | [.kind,.id]] | unique | length) == (.decisions | length) and
    all(.decisions[];
      keys == ["decision","followUpAction","id","kind","reason"] and
      (.kind | nonblank) and (.id | nonblank) and
      (.decision == "RETAIN" or .decision == "EXTERNAL_SHARED") and
      (.reason | nonblank) and (.followUpAction | nonblank)) and
    (.approvedAt | fromdateiso8601) <= now
  ' 'invalid course.cleanup-retain-decisions/v1 evidence'
  [[ $(jq -r '.inventorySha256' "$decisions") == "$(course_raw_sha256_file "$inventory")" ]] || course_fail 'INVENTORY_DIGEST_MISMATCH'
  jq -en --argjson inventory "$(jq -c . "$inventory")" --argjson decisions "$(jq -c . "$decisions")" '
    $inventory.courseId == $decisions.courseId and $inventory.accountId == $decisions.accountId and $inventory.region == $decisions.region and
    ([ $inventory.resources[] | select(.decision != "DELETE") ] | length) == ($decisions.decisions | length) and
    all($decisions.decisions[]; . as $d | any($inventory.resources[];
      .kind == $d.kind and .id == $d.id and .decision == $d.decision and
      .reason == $d.reason and .followUpAction == $d.followUpAction))
  ' >/dev/null || course_fail 'RETAIN_DECISION_NOT_IN_INVENTORY'
}

cleanup_validate_removal() {
  local inventory=$1 removal=$2
  cleanup_validate_inventory "$inventory"
  course_require_file "$removal"
  cleanup_assert_canonical_utc_seconds "$removal" 'GitOps removal observedAt' '["observedAt"]'
  course_assert_json "$removal" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    keys == ["clusters","evidenceGrade","freezeEvidenceSha256","gitopsRevision","observedAt","providerSecrets","remaining","retained","schemaVersion","status"] and
    .schemaVersion == "course.gitops-removal/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "REMOVED" and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and (.freezeEvidenceSha256 | test("^[0-9a-f]{64}$")) and
    [.clusters[].environment] == ["dev","prod"] and all(.clusters[]; keys == ["clusterArn","environment"]) and
    (.remaining | keys == ["chaosResources","deployments","externalSecrets","jobs","rollouts","statefulSets"]) and
    ([.remaining[]] | all(type == "number" and floor == . and . == 0)) and
    (.retained | type == "array") and all(.retained[];
      keys == ["classification","environment","kind","name","namespace","requiresExplicitDeletion","uid"] and
      .requiresExplicitDeletion == true and
      (.kind | IN("PersistentVolumeClaim","VolumeSnapshot","VolumeSnapshotContent","Namespace")) and
      (.environment | IN("dev","prod")) and
      (.classification | nonblank) and
      (.name | nonblank) and
      (.namespace | type == "string") and
      (if .kind == "PersistentVolumeClaim" or .kind == "VolumeSnapshot" then
        (.namespace | nonblank)
       else .namespace == "" end) and
      (.uid | nonblank)) and
    ([.retained[] | [.environment,.kind,.namespace,.name,.uid]] | unique | length) == (.retained | length) and
    (.providerSecrets | keys == ["inventorySha256","retained"]) and .providerSecrets.retained == true and
    (.providerSecrets.inventorySha256 | test("^[0-9a-f]{64}$")) and
    (.observedAt | fromdateiso8601) <= now
  ' 'invalid course.gitops-removal/v1 evidence'
  [[ $(jq -r '.providerSecrets.inventorySha256' "$removal") == "$(cleanup_provider_secret_sha "$inventory")" ]] || \
    course_fail 'PROVIDER_SECRET_PROJECTION_DIGEST_MISMATCH'
  jq -en --argjson inventory "$(jq -c . "$inventory")" --argjson removal "$(jq -c . "$removal")" '
    def canonical_cluster_arn($arn):
      $arn | test("^arn:aws:eks:" + $inventory.region + ":" + $inventory.accountId + ":cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$");
    def retained_inventory_id($r):
      if $r.kind == "PersistentVolumeClaim" or $r.kind == "VolumeSnapshot" then
        ($r.namespace + "/" + $r.name)
      else $r.name
      end;
    def supported_kind($kind):
      $kind == "PersistentVolumeClaim" or $kind == "VolumeSnapshot" or
      $kind == "VolumeSnapshotContent" or $kind == "Namespace";
    all($removal.clusters[]; canonical_cluster_arn(.clusterArn)) and
    all($inventory.resources[] | select(.kind == "SecretsManagerSecret");
      .decision == "RETAIN" or .decision == "EXTERNAL_SHARED") and
    ([ $removal.retained[] | select(supported_kind(.kind)) |
      {environment,kind,classification,id:retained_inventory_id(.)} ] | sort_by(.environment,.kind,.id,.classification)) ==
    ([ $inventory.resources[] | select(.decision == "RETAIN" and supported_kind(.kind)) |
      {environment,kind,classification,id:.id} ] | sort_by(.environment,.kind,.id,.classification))
  ' >/dev/null || course_fail 'GITOPS_REMOVAL_IDENTITY_MISMATCH'
}

cleanup_validate_freeze_removal() {
  local inventory=$1 freeze=$2 removal=$3
  cleanup_validate_inventory "$inventory"
  course_require_file "$freeze"
  cleanup_assert_canonical_utc_seconds "$freeze" 'GitOps freeze observedAt' '["observedAt"]'
  cleanup_validate_removal "$inventory" "$removal"
  course_assert_json "$freeze" '
    keys == ["clusters","evidenceGrade","gitopsRevision","observedAt","schemaVersion","status","writers"] and
    .schemaVersion == "course.gitops-freeze/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "FROZEN" and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    [.clusters[].environment] == ["dev","prod"] and
    all(.clusters[];
      keys == ["application","clusterArn","environment"] and
      (.application | keys == ["automated","health","name","sync"]) and
      .application.name == ("sample-app-" + .environment) and
      .application.automated == false and .application.sync == "Synced" and .application.health == "Healthy") and
    (.writers | keys == ["chaosResources","loadGenerators","migrationJobs","recoveryJobs"]) and
    ([.writers[]] | all(type == "number" and floor == . and . == 0)) and
    (.observedAt | fromdateiso8601) <= now
  ' 'invalid course.gitops-freeze/v1 evidence'
  [[ $(jq -r '.freezeEvidenceSha256' "$removal") == "$(course_raw_sha256_file "$freeze")" ]] || course_fail 'FREEZE_DIGEST_MISMATCH'
  jq -en --argjson inventory "$(jq -c . "$inventory")" --argjson freeze "$(jq -c . "$freeze")" --argjson removal "$(jq -c . "$removal")" '
    def canonical_cluster_arn($arn):
      $arn | test("^arn:aws:eks:" + $inventory.region + ":" + $inventory.accountId + ":cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$");
    [ $freeze.clusters[] | {environment,clusterArn} ] == $removal.clusters and
    ($freeze.observedAt | fromdateiso8601) < ($removal.observedAt | fromdateiso8601) and
    all($removal.clusters[]; canonical_cluster_arn(.clusterArn))
  ' >/dev/null || course_fail 'GITOPS_CLEANUP_IDENTITY_MISMATCH'
}

cleanup_validate_pre_destroy() {
  local inventory=$1 removal=$2 pre=$3
  course_require_file "$pre"
  cleanup_assert_canonical_utc_seconds "$pre" 'Kubernetes pre-destroy observedAt' '["observedAt"]'
  cleanup_grade_is_valid "$pre" || course_fail 'invalid pre-destroy evidence grade'
  course_assert_json "$pre" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    keys == ["accountId","clusters","courseId","evidenceGrade","gitopsRemovalSha256","observedAt","region","remainingWorkloads","remainingWriters","retainedStorage","schemaVersion","status"] and
    .schemaVersion == "course.kubernetes-pre-destroy/v1" and .status == "PASS" and
    (.gitopsRemovalSha256 | test("^[0-9a-f]{64}$")) and
    [.clusters[].environment] == ["dev","prod"] and all(.clusters[]; keys == ["clusterArn","environment"]) and
    (.remainingWriters | keys == ["chaosResources","loadGenerators","migrationJobs","recoveryJobs"]) and
    ([.remainingWriters[]] | all(type == "number" and floor == . and . == 0)) and
    (.remainingWorkloads | keys == ["applications","chaosResources","deployments","externalSecrets","jobs","rollouts","statefulSets","volumeAttachments"]) and
    ([.remainingWorkloads[]] | all(type == "number" and floor == . and . == 0)) and
    all(.retainedStorage[];
      keys == ["classification","environment","kind","name","namespace","uid"] and
      (.environment | IN("dev","prod")) and
      (.kind | IN("PersistentVolumeClaim","VolumeSnapshot","VolumeSnapshotContent","Namespace")) and
      (.classification | nonblank) and (.name | nonblank) and (.uid | nonblank) and
      (.namespace | type == "string") and
      (if .kind == "PersistentVolumeClaim" or .kind == "VolumeSnapshot" then
        (.namespace | nonblank)
       else .namespace == "" end)) and
    (.observedAt | fromdateiso8601) <= now
  ' 'invalid course.kubernetes-pre-destroy/v1 evidence'
  [[ $(jq -r '.gitopsRemovalSha256' "$pre") == "$(course_raw_sha256_file "$removal")" ]] || course_fail 'GITOPS_REMOVAL_DIGEST_MISMATCH'
  jq -en --argjson inventory "$(jq -c . "$inventory")" --argjson removal "$(jq -c . "$removal")" --argjson pre "$(jq -c . "$pre")" '
    $inventory.courseId == $pre.courseId and $inventory.accountId == $pre.accountId and $inventory.region == $pre.region and
    $removal.clusters == $pre.clusters and
    ([$removal.retained[] | del(.requiresExplicitDeletion)] == $pre.retainedStorage)
  ' >/dev/null || course_fail 'PRE_DESTROY_IDENTITY_OR_STORAGE_MISMATCH'
}

cleanup_validate_residual() {
  local inventory=$1 decisions=$2 pre=$3 removal=$4 residual=$5
  cleanup_validate_decisions "$inventory" "$decisions"
  cleanup_validate_pre_destroy "$inventory" "$removal" "$pre"
  course_require_file "$residual"
  cleanup_assert_canonical_utc_seconds "$residual" 'cleanup residual observedAt' '["observedAt"]'
  cleanup_grade_is_valid "$residual" || course_fail 'invalid residual evidence grade'
  course_assert_json "$residual" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    keys == ["accountId","courseId","evidenceGrade","externalShared","gitopsRemovalSha256","inventorySha256","kubernetesPreDestroySha256","observedAt","region","retainDecisionsSha256","retained","schemaVersion","status","unapprovedCourseOwned"] and
    .schemaVersion == "course.cleanup-residual/v1" and .status == "PASS" and
    (.unapprovedCourseOwned | keys == ["ampWorkspaces","ebsSnapshots","ebsVolumes","ecrRepositories","eksClusters","loadBalancers","natGateways","snsTopics","total"]) and
    ([.unapprovedCourseOwned[]] | all(type == "number" and floor == . and . == 0)) and
    (.courseId | nonblank) and
    (.externalShared | type == "array") and
    ([.externalShared[] | [.kind,.id]] == ([.externalShared[] | [.kind,.id]] | sort)) and
    all(.externalShared[];
      keys == ["deletePlanned","id","kind","owner","presentAfterCleanup"] and
      ([.kind,.id,.owner] | all(nonblank)) and
      .deletePlanned == false and .presentAfterCleanup == true) and
    (.retained | type == "array") and
    ([.retained[] | [.kind,.id]] == ([.retained[] | [.kind,.id]] | sort)) and
    all(.retained[];
      keys == ["followUpAction","id","kind","owner","presentAfterCleanup","reason"] and
      ([.kind,.id,.owner,.reason,.followUpAction] | all(nonblank)) and
      .presentAfterCleanup == true) and
    (.observedAt | fromdateiso8601) <= now
  ' 'invalid course.cleanup-residual/v1 evidence'
  [[ $(jq -r '.inventorySha256' "$residual") == "$(course_raw_sha256_file "$inventory")" ]] || course_fail 'RESIDUAL_INVENTORY_DIGEST_MISMATCH'
  [[ $(jq -r '.retainDecisionsSha256' "$residual") == "$(course_raw_sha256_file "$decisions")" ]] || course_fail 'RESIDUAL_DECISIONS_DIGEST_MISMATCH'
  [[ $(jq -r '.kubernetesPreDestroySha256' "$residual") == "$(course_raw_sha256_file "$pre")" ]] || course_fail 'RESIDUAL_PRE_DESTROY_DIGEST_MISMATCH'
  [[ $(jq -r '.gitopsRemovalSha256' "$residual") == "$(course_raw_sha256_file "$removal")" ]] || course_fail 'RESIDUAL_GITOPS_DIGEST_MISMATCH'
  jq -en --argjson inventory "$(jq -c . "$inventory")" --argjson decisions "$(jq -c . "$decisions")" --argjson residual "$(jq -c . "$residual")" '
    $inventory.courseId == $residual.courseId and $inventory.accountId == $residual.accountId and $inventory.region == $residual.region and
    ([ $inventory.resources[] | select(.decision == "EXTERNAL_SHARED") | {kind,id,owner,deletePlanned:false,presentAfterCleanup:true} ] | sort_by(.kind,.id)) == $residual.externalShared and
    ([ $decisions.decisions[] | select(.decision == "RETAIN") as $d |
      ($inventory.resources[] | select(.kind == $d.kind and .id == $d.id)) as $i |
      {kind:$d.kind,id:$d.id,owner:$i.owner,reason:$d.reason,followUpAction:$d.followUpAction,presentAfterCleanup:true} ] | sort_by(.kind,.id)) == $residual.retained
  ' >/dev/null || course_fail 'RESIDUAL_RETAINED_OR_EXTERNAL_MISMATCH'
}
