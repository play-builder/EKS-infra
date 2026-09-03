#!/usr/bin/env bash

cleanup_grade_is_valid() {
  local file=$1
  jq -e '.evidenceGrade == "CLOUD_RUNTIME" or (.evidenceGrade == "STATIC" and ($ENV.COURSE_CHECK_BIN_DIR // "") != "")' \
    "$file" >/dev/null
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
  cleanup_grade_is_valid "$inventory" || course_fail 'invalid ownership evidence grade'
  course_assert_json "$inventory" '
    def nonblank: type == "string" and test("\\S");
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
  course_assert_json "$decisions" '
    def nonblank: type == "string" and test("\\S");
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
  course_assert_json "$removal" '
    def nonblank: type == "string" and test("\\S");
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
  cleanup_grade_is_valid "$pre" || course_fail 'invalid pre-destroy evidence grade'
  course_assert_json "$pre" '
    def nonblank: type == "string" and test("\\S");
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
  cleanup_grade_is_valid "$residual" || course_fail 'invalid residual evidence grade'
  course_assert_json "$residual" '
    def nonblank: type == "string" and test("\\S");
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
