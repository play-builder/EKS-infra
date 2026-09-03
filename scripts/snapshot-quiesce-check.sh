#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

[[ $# -eq 1 ]] || course_fail 'usage: snapshot-quiesce-check.sh <snapshot-quiesce.json>' 64
evidence=$1
course_require_file "$evidence"
course_assert_eks_cluster_arn \
  "$(jq -r '.clusterArn // empty' "$evidence")" \
  "$(jq -r '.region // empty' "$evidence")"

course_assert_json "$evidence" '
  (keys | sort) == ["checksum","clusterArn","database","environment","evidenceGrade","expiresAt","gitopsRevision","observedAt","region","schemaVersion","source","storage","writers"] and
  .schemaVersion == "course.snapshot-quiesce/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
  (.environment == "dev" or .environment == "prod") and
  (.region == "ap-northeast-2" or .region == "us-east-1") and
  (.gitopsRevision | test("^[0-9a-f]{40}$")) and
  (.source | (keys | sort) == ["namespace","pvcName","pvcUid","statefulSet","volumeName"]) and
  ([.source.namespace,.source.statefulSet,.source.pvcName,.source.pvcUid,.source.volumeName] | all(type == "string" and length > 0)) and
  (.writers | (keys | sort) == ["applicationReplicas","migrationActive","migrationPending"] and all(.[]; type == "number" and floor == . and . == 0)) and
  (.database | (keys | sort) == ["cleanShutdownEvidenceId","cleanShutdownObserved","desiredReplicas","readyReplicas","shutdownSignal","stoppedAt"] and
    .desiredReplicas == 0 and .readyReplicas == 0 and .shutdownSignal == "SIGTERM" and
    .cleanShutdownObserved == true and (.cleanShutdownEvidenceId | test("^sha256:[0-9a-f]{64}$")) and (.stoppedAt | fromdateiso8601)) and
  (.storage | (keys | sort) == ["mountedPodUids","volumeAttachmentNames"] and .mountedPodUids == [] and .volumeAttachmentNames == []) and
  (.checksum | (keys | sort) == ["algorithm","capturedAt","value"] and .algorithm == "sha256" and (.value | test("^sha256:[0-9a-f]{64}$")) and (.capturedAt | fromdateiso8601)) and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601) and
  (.checksum.capturedAt | fromdateiso8601) < (.database.stoppedAt | fromdateiso8601) and
  (.database.stoppedAt | fromdateiso8601) <= (.observedAt | fromdateiso8601)
' 'invalid, stale, or unsafe snapshot quiesce evidence'

if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]]; then
  echo 'DETAIL: snapshot quiesce ordering and detach evidence is valid.'
elif [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT snapshot quiesce ordering is valid.'
else
  echo 'PASS: [CLOUD_RUNTIME] snapshot quiesce evidence is valid; live recheck required before snapshot creation.'
fi
