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
  local manifest=$1 repo_root=$2 inventory=${3:-} layer
  course_require_file "$manifest"
  cleanup_assert_canonical_utc_seconds "$manifest" 'saved destroy plans reviewedAt' '["reviewedAt"]'
  course_assert_json "$manifest" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    . as $manifest |
    keys == ["plans","reviewedAt","schemaVersion","status"] and
    .schemaVersion == "course.saved-destroy-plans/v1" and .status == "REVIEWED" and
    (.reviewedAt | fromdateiso8601) <= now and
    (.plans | type == "array" and length >= 8 and length <= 10) and
    ([.plans[].layer] == [
      "environments/prod/04-workloads/argocd",
      "environments/dev/04-workloads/argocd",
      (if any($manifest.plans[]; .layer == "environments/recovery/03-database") then "environments/recovery/03-database" else empty end),
      (if any($manifest.plans[]; .layer == "environments/prod/03-database") then "environments/prod/03-database" else empty end),
      "environments/prod/03-platform",
      "environments/dev/03-platform",
      "environments/prod/02-eks",
      "environments/dev/02-eks",
      "environments/prod/01-network",
      "environments/dev/01-network"
    ]) and
    ([.plans[].path] | unique | length) == (.plans | length) and
    all(.plans[];
      keys == ["layer","path","sha256"] and
      (.layer | nonblank) and (.path | startswith("/")) and
      (.sha256 | test("^[0-9a-f]{64}$")))
  ' 'invalid reviewed saved destroy plan manifest'
  if [[ -n "$inventory" ]]; then
    local expected_layers
    expected_layers=$(python3 "$repo_root/scripts/lib/enterprise-cleanup.py" layers "$inventory") || course_fail ENTERPRISE_CLEANUP_ORDER_BLOCKED
    [[ "$(jq -r '.plans[].layer' "$manifest")" == "$expected_layers" ]] || course_fail ENTERPRISE_DATABASE_PLAN_ORDER_MISMATCH
  fi

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

cleanup_inspect_saved_destroy_plan() {
  local layer=$1 saved_plan=$2 inventory=$3 repo_root=$4
  local course=$5 account=$6 region=$7 project=$8 plan_json environment semantic_layer
  environment=${layer#environments/}
  environment=${environment%%/*}
  case "$layer" in
    environments/dev/01-network|environments/prod/01-network) semantic_layer=network ;;
    environments/dev/02-eks|environments/prod/02-eks) semantic_layer=eks ;;
    environments/dev/03-platform|environments/prod/03-platform) semantic_layer=platform ;;
    environments/prod/03-database) semantic_layer=database ;;
    environments/recovery/03-database) semantic_layer=recovery-database ;;
    environments/dev/04-workloads/argocd|environments/prod/04-workloads/argocd) semantic_layer=workloads ;;
    *) course_fail "SAVED_DESTROY_PLAN_LAYER_UNSUPPORTED: $layer" ;;
  esac

  plan_json=$(terraform -chdir="$repo_root/$layer" show -json "$saved_plan") || \
    course_fail "SAVED_DESTROY_PLAN_SHOW_FAILED: $layer"
  jq -e '.format_version | type == "string"' <<<"$plan_json" >/dev/null || \
    course_fail "SAVED_DESTROY_PLAN_FORMAT_INVALID: $layer"
  if jq -e '
    (.resource_changes // []) as $changes |
    ($changes | type == "array") and
    all($changes[]; .mode == "data" and
      (.change.actions == ["read"] or .change.actions == ["no-op"]))
  ' <<<"$plan_json" >/dev/null; then
    jq -e '
      def modules:
        . as $module | $module, (($module.child_modules // [])[] | modules);
      (.terraform_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+")) and
      (.planned_values | type == "object") and
      (.configuration | type == "object") and
      (has("values") | not) and
      ([.planned_values.root_module // {} | modules |
        (.resources // [])[] | select(.mode == "managed")] | length == 0)
    ' <<<"$plan_json" >/dev/null || course_fail "SAVED_DESTROY_PLAN_ARTIFACT_INVALID: $layer"
    printf '%s\n' NO_CHANGES
    return 0
  fi
  jq -e '
    (.format_version | type == "string") and
    (.resource_changes | type == "array" and length > 0) and
    all(.resource_changes[]; .mode == "managed" and .change.actions == ["delete"] and (.change.before | type == "object"))
  ' <<<"$plan_json" >/dev/null || course_fail "SAVED_DESTROY_PLAN_NOT_DELETE_ONLY: $layer"
  printf '%s' "$plan_json" | python3 "$repo_root/scripts/lib/enterprise-cleanup.py" guard-stdin "$inventory" || course_fail "ENTERPRISE_CLEANUP_GUARD_FAILED: $layer"

  jq -e --arg environment "$environment" --arg semanticLayer "$semantic_layer" \
    --arg course "$course" --arg account "$account" --arg region "$region" \
    --arg project "$project" --slurpfile inventory "$inventory" '
    def address_allowed:
      if $semanticLayer == "network" then
        .address | test("^module\\.(vpc|log_key)(\\[[^]]+\\])?\\.")
      elif $semanticLayer == "eks" then
        (.address | test("^module\\.(eks_cluster|node_group_public|node_group_private|bastion)(\\[[^]]+\\])?\\.")) or
        (.type == "terraform_data" and .address == "terraform_data.logging_identity") or
        (.type == "aws_eks_addon" and (.address | test("^module\\.managed_addons\\.aws_eks_addon\\.(coredns|kube_proxy)$"))) or
        ((.type == "aws_eks_access_entry" or .type == "aws_eks_access_policy_association") and
          (.type as $type | .address | startswith("module.access_entries." + $type + ".")) and
          (.address | test("^module\\.access_entries\\.aws_eks_access_(entry|policy_association)\\.this\\[\"[^\"]+\"\\]$"))) or
        ($environment == "prod" and
          (.type as $type | .address | startswith("module.operator_access." + $type + ".")) and
          (.address | test("^module\\.operator_access\\.(aws_security_group\\.operator|aws_vpc_security_group_ingress_rule\\.operator_eks_api|aws_iam_role\\.(instance|operator)|aws_iam_role_policy\\.(instance_assume_operator|operator_eks)|aws_iam_role_policy_attachment\\.instance_ssm|aws_iam_instance_profile\\.instance|aws_instance\\.operator)$")))
      elif $semanticLayer == "platform" then
        (.address | test("^(terraform_data\\.(external_secrets_ownership_gate|logging_identity)|kubernetes_storage_class_v1\\.course_gp3|kubectl_manifest\\.(gateway_api|aws_lbc_gateway|volume_snapshot_class)(\\[[^]]+\\])?|aws_secretsmanager_secret\\.(sample_app_runtime|sample_app_db)|aws_eks_addon\\.snapshot_controller(\\[[^]]+\\])?|aws_iam_(role|policy|role_policy_attachment)\\.recovery_db_secret_reader(\\[[^]]+\\])?)$")) or
        (.address | test("^module\\.(external_secrets_reader_irsa|rollouts_amp_irsa|external_secrets|reloader|k6_operator|chaos_mesh|ebs_csi_driver|aws_load_balancer_controller|external_dns|acm|metrics_server|cluster_autoscaler|container_insights|amp|adot_collector|amp_alerting|amg|sigstore_policy_controller|mini_commerce_secrets|waf)(\\[[^]]+\\])?\\."))
      elif $semanticLayer == "database" or $semanticLayer == "recovery-database" then
        (.address == "terraform_data.identity") or (.address | test("^module\\.(database|recovery_secrets)\\."))
      else
        (.address | test("^module\\.argocd\\.")) or
        (.address | test("^(terraform_data\\.course_ownership|helm_release\\.(argocd|argo_rollouts)|kubectl_manifest\\.(gateway_plugin_cluster_role|gateway_plugin_cluster_role_binding|bootstrap))(\\[[^]]+\\])?$"))
      end;
    def untaggable:
      .type == "terraform_data" or .type == "helm_release" or .type == "kubectl_manifest" or
      (.type | startswith("kubernetes_")) or
      .type == "aws_acm_certificate_validation" or .type == "aws_eks_access_policy_association" or
      .type == "aws_iam_role_policy" or .type == "aws_iam_role_policy_attachment" or
      .type == "aws_prometheus_alert_manager_definition" or .type == "aws_prometheus_rule_group_namespace" or
      .type == "aws_kms_alias" or .type == "aws_wafv2_web_acl_association" or .type == "aws_wafv2_web_acl_logging_configuration" or
      .type == "aws_route" or .type == "aws_route53_record" or .type == "aws_route_table_association" or
      .type == "aws_security_group_rule" or .type == "aws_sns_topic_policy" or .type == "aws_sns_topic_subscription";
    def matching_inventory:
      (.change.before.arn // .change.before.id // "") as $id |
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
        $tags.Environment == (if $environment == "recovery" then "prod" else $environment end) and $tags.Layer == $semanticLayer and
        $tags.ManagedBy == "Terraform"
      elif .type == "terraform_data" and .address == "terraform_data.course_ownership" then
        .change.before.input.CourseId == $course and .change.before.input.AccountId == $account and
        .change.before.input.Region == $region and .change.before.input.Project == $project and
        .change.before.input.Environment == $environment and
        .change.before.input.Layer == $semanticLayer and .change.before.input.ManagedBy == "Terraform"
      else untaggable end;
    all(.resource_changes[]; address_allowed and inventory_allows_delete and tags_allow_delete)
  ' <<<"$plan_json" >/dev/null || course_fail "SAVED_DESTROY_PLAN_OWNERSHIP_MISMATCH: $layer"
  printf '%s\n' DELETE
}

cleanup_validate_saved_destroy_plan() {
  local kind
  kind=$(cleanup_inspect_saved_destroy_plan "$@")
  [[ "$kind" == DELETE ]] || course_fail "SAVED_DESTROY_PLAN_NOT_DELETE_ONLY: $1"
}

cleanup_validate_apply_progress() {
  local progress=$1 manifest=$2
  course_require_file "$progress"
  cleanup_assert_canonical_utc_seconds "$progress" 'saved plan progress updatedAt' '["updatedAt"]'
  local plan_count
  plan_count=$(jq '.plans | length' "$manifest")
  jq -e --argjson planCount "$plan_count" '
    . as $progress |
    keys == ["completed","inFlight","manifestSha256","registeredPlans","schemaVersion","status","updatedAt"] and
    .schemaVersion == "course.saved-destroy-progress/v2" and
    (.manifestSha256 | test("^[0-9a-f]{64}$")) and
    (.status == "IN_PROGRESS" or .status == "COMPLETE") and
    (.completed | type == "array" and length <= $planCount) and
    all(.completed[]; keys == ["appliedAt","layer","outcome","path","sha256"] and
      (.layer | type == "string" and test("[^[:space:]\uFEFF]")) and
      (.path | type == "string" and startswith("/")) and
      (.sha256 | test("^[0-9a-f]{64}$")) and
      (.outcome == "APPLIED" or .outcome == "RECOVERED_NO_CHANGES") and
      (.appliedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
        ((try (fromdateiso8601 | todateiso8601) catch "") == .))) and
    (.inFlight == null or (.inFlight | keys == ["layer","path","sha256","startedAt"] and
      (.layer | type == "string" and test("[^[:space:]\uFEFF]")) and
      (.path | type == "string" and startswith("/")) and
      (.sha256 | test("^[0-9a-f]{64}$")) and
      (.startedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
        ((try (fromdateiso8601 | todateiso8601) catch "") == .)))) and
    (.registeredPlans | type == "array" and length >= $planCount and length <= ($planCount * 4)) and
    all(.registeredPlans[];
      keys == ["layer","path","sha256"] and
      (.layer | type == "string" and test("[^[:space:]\uFEFF]")) and
      (.path | type == "string" and startswith("/")) and
      (.sha256 | test("^[0-9a-f]{64}$"))) and
    ([.registeredPlans[] | [.path,.sha256]] | unique | length) == (.registeredPlans | length) and
    all((.registeredPlans | group_by(.layer)[]); length <= 4) and
    all(.registeredPlans[]; . as $registered |
      all($progress.registeredPlans[]; .path != $registered.path or .layer == $registered.layer)) and
    all(.completed[]; . as $done | any($progress.registeredPlans[];
      .layer == $done.layer and .path == $done.path and .sha256 == $done.sha256)) and
    (.inFlight == null or (.inFlight as $active | any(.registeredPlans[];
      .layer == $active.layer and .path == $active.path and .sha256 == $active.sha256))) and
    (if .status == "COMPLETE" then (.completed | length) == $planCount and .inFlight == null
     else (.completed | length) <= $planCount and
       (if (.completed | length) == $planCount then .inFlight == null else true end) end)
  ' "$progress" >/dev/null || course_fail 'invalid saved destroy plan progress'
  while IFS=$'\t' read -r index layer path sha; do
    [[ $(jq -r --argjson index "$index" '.plans[$index].layer' "$manifest") == "$layer" ]] || \
      course_fail 'SAVED_DESTROY_PROGRESS_LAYER_MISMATCH'
    [[ $(jq -r --argjson index "$index" '.plans[$index].path' "$manifest") == "$path" ]] || \
      course_fail 'SAVED_DESTROY_PROGRESS_PATH_MISMATCH'
    [[ $(jq -r --argjson index "$index" '.plans[$index].sha256' "$manifest") == "$sha" ]] || \
      course_fail 'SAVED_DESTROY_PROGRESS_DIGEST_MISMATCH'
  done < <(jq -r '.completed | to_entries[] | [.key,.value.layer,.value.path,.value.sha256] | @tsv' "$progress")
}

cleanup_remove_registered_plan_files() {
  local progress=$1 scope=${2:-ALL} saved_plan actual_sha
  while IFS= read -r saved_plan; do
    if [[ -e "$saved_plan" ]]; then
      [[ -f "$saved_plan" && ! -L "$saved_plan" ]] || course_fail "SAVED_DESTROY_PLAN_INVALID: $saved_plan"
      chmod 600 "$saved_plan"
      actual_sha=$(course_raw_sha256_file "$saved_plan")
      jq -e --arg path "$saved_plan" --arg sha "$actual_sha" '
        any(.registeredPlans[]; .path == $path and .sha256 == $sha)
      ' "$progress" >/dev/null || course_fail "SAVED_DESTROY_REGISTERED_PLAN_DIGEST_MISMATCH: $saved_plan"
      rm -f -- "$saved_plan"
    fi
  done < <(jq -r --arg scope "$scope" '
    if $scope == "ALL" then
      [.registeredPlans[].path] | unique[]
    else
      [.completed[].layer] as $completedLayers |
      [.registeredPlans[] | select(.layer as $layer | $completedLayers | index($layer)) | .path] | unique[]
    end
  ' "$progress")
}

cleanup_validate_plan_registry_extension() {
  local progress=$1 manifest=$2
  jq -en --argjson existing "$(jq -c '.registeredPlans' "$progress")" \
    --argjson plans "$(jq -c '[.plans[] | {layer,path,sha256}]' "$manifest")" '
    ($existing + $plans | unique_by([.path,.sha256])) as $all |
    ($all | length) <= 40 and
    all(($all | group_by(.layer)[]); length <= 4) and
    all($all[]; . as $registered |
      all($all[]; .path != $registered.path or .layer == $registered.layer))
  ' >/dev/null || course_fail 'SAVED_DESTROY_PLAN_REGISTRY_LIMIT_OR_PATH_CONFLICT'
}

cleanup_register_replacement_candidate() {
  local progress=$1 manifest=$2 manifest_sha=$3 layer=$4 saved_plan=$5 expected_sha=$6
  local now payload
  [[ $(course_raw_sha256_file "$manifest") == "$manifest_sha" ]] || \
    course_fail 'SAVED_DESTROY_PLAN_MANIFEST_CHANGED'
  jq -en --argjson existing "$(jq -c '.registeredPlans' "$progress")" \
    --arg layer "$layer" --arg path "$saved_plan" --arg sha "$expected_sha" '
    ($existing + [{layer:$layer,path:$path,sha256:$sha}] | unique_by([.path,.sha256])) as $all |
    ($all | length) <= 40 and
    all(($all | group_by(.layer)[]); length <= 4) and
    all($all[]; . as $registered |
      all($all[]; .path != $registered.path or .layer == $registered.layer))
  ' >/dev/null || course_fail 'SAVED_DESTROY_PLAN_REGISTRY_LIMIT_OR_PATH_CONFLICT'
  now=$(course_now)
  payload=$(jq --arg layer "$layer" --arg path "$saved_plan" --arg sha "$expected_sha" --arg now "$now" '
    .registeredPlans=([.registeredPlans[], {layer:$layer,path:$path,sha256:$sha}] |
      unique_by([.path,.sha256]) | sort_by(.layer,.path,.sha256)) |
    .updatedAt=$now
  ' "$progress")
  course_write_json "$progress" "$payload"
}

cleanup_apply_saved_plans() {
  local manifest=$1 repo_root=$2 inventory=$3 progress=$4 project=$5
  local manifest_sha progress_manifest_sha completed_count layer saved_plan expected_sha actual_manifest_sha now payload
  local course account region recovery=false recovery_kind='' index plan_kind plan_count
  plan_count=$(jq '.plans | length' "$manifest")
  cleanup_validate_saved_plan_manifest "$manifest" "$repo_root" "$inventory"
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
    completed_count=$(jq -r '.completed | length' "$progress")
    if [[ "$completed_count" -eq "$plan_count" ]]; then
      [[ "$progress_manifest_sha" == "$manifest_sha" ]] || course_fail 'SAVED_DESTROY_PROGRESS_MANIFEST_MISMATCH'
      if [[ $(jq -r '.status' "$progress") != COMPLETE ]]; then
        now=$(course_now)
        payload=$(jq --arg now "$now" '.status="COMPLETE" | .updatedAt=$now' "$progress")
        course_write_json "$progress" "$payload"
      fi
      cleanup_remove_registered_plan_files "$progress" ALL
      return 0
    fi
    if [[ "$progress_manifest_sha" == "$manifest_sha" ]]; then
      [[ $(jq -r '.inFlight == null' "$progress") == true ]] || {
        layer=$(jq -r '.inFlight.layer' "$progress")
        course_fail "SAVED_DESTROY_PLAN_REVIEW_REQUIRED_AFTER_FAILURE: $layer"
      }
    else
      [[ $(jq -r '.inFlight != null' "$progress") == true ]] || \
        course_fail 'SAVED_DESTROY_PROGRESS_MANIFEST_MISMATCH'
      layer=$(jq -r '.inFlight.layer' "$progress")
      expected_sha=$(jq -r --argjson index "$completed_count" '.plans[$index].sha256' "$manifest")
      [[ "$layer" == "$(jq -r --argjson index "$completed_count" '.plans[$index].layer' "$manifest")" ]] || \
        course_fail 'SAVED_DESTROY_PROGRESS_LAYER_MISMATCH'
      [[ "$expected_sha" != "$(jq -r '.inFlight.sha256' "$progress")" ]] || \
        course_fail "SAVED_DESTROY_PLAN_REVIEW_REQUIRED_AFTER_FAILURE: $layer"
      recovery=true
    fi
  else
    completed_count=0
  fi

  index=$completed_count
  if [[ "$recovery" == true ]]; then
    IFS=$'\t' read -r layer saved_plan expected_sha < <(
      jq -r --argjson index "$completed_count" '.plans[$index] | [.layer,.path,.sha256] | @tsv' "$manifest"
    )
    cleanup_validate_saved_plan_file "$saved_plan" "$expected_sha" "$layer"
    plan_kind=$(cleanup_inspect_saved_destroy_plan "$layer" "$saved_plan" "$inventory" "$repo_root" \
      "$course" "$account" "$region" "$project")
    case "$plan_kind" in
      NO_CHANGES) recovery_kind=NO_CHANGES ;;
      DELETE) recovery_kind=DELETE ;;
      *) course_fail "SAVED_DESTROY_PLAN_NOT_DELETE_ONLY: $layer" ;;
    esac
    cleanup_register_replacement_candidate "$progress" "$manifest" "$manifest_sha" \
      "$layer" "$saved_plan" "$expected_sha"
    index=$((index + 1))
  fi

  while IFS=$'\t' read -r layer saved_plan expected_sha; do
    cleanup_validate_saved_plan_file "$saved_plan" "$expected_sha" "$layer"
    plan_kind=$(cleanup_inspect_saved_destroy_plan "$layer" "$saved_plan" "$inventory" "$repo_root" \
      "$course" "$account" "$region" "$project")
    [[ "$plan_kind" == DELETE ]] || course_fail "SAVED_DESTROY_PLAN_NOT_DELETE_ONLY: $layer"
    index=$((index + 1))
  done < <(jq -r --argjson start "$index" '.plans[$start:][] | [.layer,.path,.sha256] | @tsv' "$manifest")
  actual_manifest_sha=$(course_raw_sha256_file "$manifest")
  [[ "$actual_manifest_sha" == "$manifest_sha" ]] || course_fail 'SAVED_DESTROY_PLAN_MANIFEST_CHANGED'

  if [[ ! -e "$progress" ]]; then
    now=$(course_now)
    payload=$(jq -n --arg manifest "$manifest_sha" --arg now "$now" \
      --argjson plans "$(jq -c '[.plans[] | {layer,path,sha256}]' "$manifest")" '{
      schemaVersion:"course.saved-destroy-progress/v2",status:"IN_PROGRESS",
      manifestSha256:$manifest,completed:[],inFlight:null,registeredPlans:$plans,updatedAt:$now
    }')
    course_write_json "$progress" "$payload"
  elif [[ "$recovery" == true ]]; then
    cleanup_validate_plan_registry_extension "$progress" "$manifest"
    now=$(course_now)
    payload=$(jq --arg manifest "$manifest_sha" --arg now "$now" \
      --argjson plans "$(jq -c '[.plans[] | {layer,path,sha256}]' "$manifest")" '
      .manifestSha256=$manifest | .inFlight=null | .status="IN_PROGRESS" | .updatedAt=$now |
      .registeredPlans=([.registeredPlans[], $plans[]] | unique_by([.path,.sha256]) | sort_by(.layer,.path,.sha256))
    ' "$progress")
    if [[ "$recovery_kind" == NO_CHANGES ]]; then
      layer=$(jq -r --argjson index "$completed_count" '.plans[$index].layer' "$manifest")
      saved_plan=$(jq -r --argjson index "$completed_count" '.plans[$index].path' "$manifest")
      expected_sha=$(jq -r --argjson index "$completed_count" '.plans[$index].sha256' "$manifest")
      payload=$(jq --arg layer "$layer" --arg path "$saved_plan" --arg sha "$expected_sha" --arg now "$now" '
        .completed += [{layer:$layer,path:$path,sha256:$sha,outcome:"RECOVERED_NO_CHANGES",appliedAt:$now}]
      ' <<<"$payload")
      completed_count=$((completed_count + 1))
    fi
    course_write_json "$progress" "$payload"
  fi

  cleanup_remove_registered_plan_files "$progress" COMPLETED
  if [[ "$completed_count" -eq "$plan_count" ]]; then
    now=$(course_now)
    payload=$(jq --arg now "$now" '.status="COMPLETE" | .updatedAt=$now' "$progress")
    course_write_json "$progress" "$payload"
    cleanup_remove_registered_plan_files "$progress" ALL
    return 0
  fi

  while IFS=$'\t' read -r layer saved_plan expected_sha; do
    actual_manifest_sha=$(course_raw_sha256_file "$manifest")
    [[ "$actual_manifest_sha" == "$manifest_sha" ]] || course_fail 'SAVED_DESTROY_PLAN_MANIFEST_CHANGED'
    cleanup_validate_saved_plan_file "$saved_plan" "$expected_sha" "$layer"
    terraform -chdir="$repo_root/$layer" show -json "$saved_plan" | python3 "$repo_root/scripts/lib/enterprise-cleanup.py" log-key-ready-stdin "$inventory" || course_fail "LOG_KEY_DELETE_READINESS_FAILED: $layer"
    now=$(course_now)
    payload=$(jq --arg layer "$layer" --arg path "$saved_plan" --arg sha "$expected_sha" --arg now "$now" '
      .inFlight={layer:$layer,path:$path,sha256:$sha,startedAt:$now} | .updatedAt=$now
    ' "$progress")
    course_write_json "$progress" "$payload"
    if ! terraform -chdir="$repo_root/$layer" apply "$saved_plan"; then
      course_fail "TERRAFORM_SAVED_PLAN_APPLY_FAILED: $layer"
    fi
    now=$(course_now)
    payload=$(jq --arg layer "$layer" --arg path "$saved_plan" --arg sha "$expected_sha" --arg now "$now" '
      .completed += [{layer:$layer,path:$path,sha256:$sha,outcome:"APPLIED",appliedAt:$now}] |
      .inFlight=null | .updatedAt=$now
    ' "$progress")
    course_write_json "$progress" "$payload"
    cleanup_remove_registered_plan_files "$progress" COMPLETED
  done < <(jq -r --argjson start "$completed_count" '.plans[$start:][] | [.layer,.path,.sha256] | @tsv' "$manifest")

  now=$(course_now)
  payload=$(jq --arg now "$now" '.status="COMPLETE" | .inFlight=null | .updatedAt=$now' "$progress")
  course_write_json "$progress" "$payload"
  cleanup_remove_registered_plan_files "$progress" ALL
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
      (keys - ["purpose","logGroupArns","kmsKeyArn","retentionReleaseApproval","deletionWindowInDays"]) == ["billable","classification","decision","environment","followUpAction","id","kind","managedBy","owner","reason"] and
      (.kind | nonblank) and (.id | nonblank) and
      (.environment == "dev" or .environment == "prod" or .environment == "recovery" or .environment == "shared") and
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
    (keys - ["scheduledKeyDeletions"]) == ["accountId","courseId","evidenceGrade","externalShared","gitopsRemovalSha256","inventorySha256","kubernetesPreDestroySha256","observedAt","region","retainDecisionsSha256","retained","schemaVersion","status","unapprovedCourseOwned"] and
    ((.scheduledKeyDeletions // []) | type == "array") and
    all((.scheduledKeyDeletions // [])[];
      keys == ["deletionDate","keyArn","keyState"] and
      (.keyArn | nonblank) and .keyState == "PendingDeletion" and
      (.deletionDate | fromdateiso8601) > now) and
    .schemaVersion == "course.cleanup-residual/v1" and .status == "PASS" and
    (.unapprovedCourseOwned | (keys - ["enterpriseResources"]) == ["ampWorkspaces","ebsSnapshots","ebsVolumes","ecrRepositories","eksClusters","loadBalancers","natGateways","snsTopics","total"]) and
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
    ([$inventory.resources[] | select(.kind == "KmsLogKey" and .decision == "DELETE") | .id] | sort) == ([$residual.scheduledKeyDeletions[]? | .keyArn] | sort) and
    ([ $inventory.resources[] | select(.decision == "EXTERNAL_SHARED") | {kind,id,owner,deletePlanned:false,presentAfterCleanup:true} ] | sort_by(.kind,.id)) == $residual.externalShared and
    ([ $decisions.decisions[] | select(.decision == "RETAIN") as $d |
      ($inventory.resources[] | select(.kind == $d.kind and .id == $d.id)) as $i |
      {kind:$d.kind,id:$d.id,owner:$i.owner,reason:$d.reason,followUpAction:$d.followUpAction,presentAfterCleanup:true} ] | sort_by(.kind,.id)) == $residual.retained
  ' >/dev/null || course_fail 'RESIDUAL_RETAINED_OR_EXTERNAL_MISMATCH'
}
