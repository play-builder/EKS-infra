#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

[[ $# -eq 1 || $# -eq 2 ]] || course_fail 'usage: snapshot-recovery-check.sh <snapshot-recovery.json> [snapshot-quiesce.json]' 64
recovery=$1
course_require_file "$recovery"
course_assert_eks_cluster_arn \
  "$(jq -r '.clusterArn // empty' "$recovery")" \
  "$(jq -r '.region // empty' "$recovery")"

course_assert_json "$recovery" '
  def canonical_utc_seconds:
    type == "string" and
    test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    ((try (fromdateiso8601 | todateiso8601) catch "") == .);
  (keys | sort) == ["clusterArn","environment","evidenceGrade","expiresAt","gitopsRevision","integrity","observedAt","recovery","region","schemaVersion","snapshot","source"] and
  .schemaVersion == "course.snapshot-recovery/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .environment == "dev" and
  (.region == "ap-northeast-2" or .region == "us-east-1") and (.gitopsRevision | test("^[0-9a-f]{40}$")) and
  (.source | (keys | sort) == ["namespace","pvcName","pvcUid","volumeName"]) and
  (.recovery | (keys | sort) == ["cleanupLabel","namespace","pvcName","roleArn","serviceAccount"]) and
  .source.namespace != .recovery.namespace and .source.pvcName != .recovery.pvcName and
  (.recovery.cleanupLabel | type == "string" and length > 0) and
  (.recovery.serviceAccount == "sample-app-recovery-secret-reader") and
  (.recovery.roleArn | test("^arn:aws:iam::[0-9]{12}:role/")) and
  (.snapshot | (keys | sort) == ["driver","name","readyToUse","uid","volumeSnapshotClassName"] and .readyToUse == true and .driver == "ebs.csi.aws.com") and
  (.integrity | (keys | sort) == ["algorithm","value"] and .algorithm == "sha256" and (.value | test("^sha256:[0-9a-f]{64}$"))) and
  (.observedAt | canonical_utc_seconds) and (.expiresAt | canonical_utc_seconds) and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid snapshot recovery evidence or source/recovery collision'

if [[ $# -eq 2 ]]; then
  COURSE_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/snapshot-quiesce-check.sh" "$2" >/dev/null
  jq -e --slurpfile quiesce "$2" '
    .clusterArn == ($quiesce[0].clusterArn // .clusterArn) and
    .region == $quiesce[0].region and .gitopsRevision == $quiesce[0].gitopsRevision and
    .source.namespace == $quiesce[0].source.namespace and .source.pvcName == $quiesce[0].source.pvcName and
    .source.pvcUid == $quiesce[0].source.pvcUid and .source.volumeName == $quiesce[0].source.volumeName and
    (.observedAt | fromdateiso8601) >= ($quiesce[0].observedAt | fromdateiso8601)
  ' "$recovery" >/dev/null || course_fail 'SNAPSHOT_RECOVERY_IDENTITY_MISMATCH'
fi

if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]]; then
  echo 'DETAIL: snapshot recovery source isolation and readiness evidence is valid.'
elif [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT snapshot recovery evidence is valid.'
else
  echo 'PASS: [CLOUD_RUNTIME] snapshot recovery evidence is valid.'
fi
