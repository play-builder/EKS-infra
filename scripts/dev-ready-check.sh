#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

[[ $# -eq 3 ]] || course_fail 'usage: dev-ready-check.sh <dev-deployment.json> <dev-slo.json> <dev-ready.json>' 64
deployment=$1
slo=$2
ready=$3
for file in "$deployment" "$slo" "$ready"; do course_require_file "$file"; done
: "${AWS_REGION:?AWS_REGION is required}"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID is required}"
course_validate_region "$AWS_REGION"
course_validate_account "$AWS_ACCOUNT_ID"

course_assert_json "$deployment" '
  keys == ["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","schemaVersion","source","status"] and
  .schemaVersion == "course.dev-deployment/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
  (.status | keys == ["health","sync"]) and .status.sync == "Synced" and .status.health == "Healthy" and
  (.source | keys == ["repository","sha"]) and (.source.repository | type == "string" and length > 0) and
  (.source.sha | test("^[0-9a-f]{40}$")) and
  (.image | keys == ["indexDigest","repository"]) and (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.gitopsRevision | test("^[0-9a-f]{40}$")) and .region == $ENV.AWS_REGION and
  (.observedAt | fromdateiso8601) <= now
' 'invalid course.dev-deployment/v1 evidence'

course_assert_json "$slo" '
  keys == ["clusterArn","evidenceGrade","evidenceId","expiresAt","gitopsRevision","image","observedAt","region","schemaVersion","source","status"] and
  .schemaVersion == "course.dev-slo/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "PASS" and
  (.source | keys == ["repository","sha"]) and (.source.repository | type == "string" and length > 0) and
  (.source.sha | test("^[0-9a-f]{40}$")) and
  (.image | keys == ["indexDigest","repository"]) and (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.gitopsRevision | test("^[0-9a-f]{40}$")) and .region == $ENV.AWS_REGION and
  (.evidenceId | type == "string" and length > 0) and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid or expired course.dev-slo/v1 evidence'

course_assert_json "$ready" '
  keys == ["attestation","cluster","environment","expiresAt","gitops","image","issuedAt","region","schemaVersion","slo","sourceSha","workflow"] and
  .schemaVersion == "course.dev-ready/v1" and .environment == "dev" and .region == $ENV.AWS_REGION and
  (.sourceSha | test("^[0-9a-f]{40}$")) and
  (.workflow | keys == ["event","name","runAttempt","runId","runUrl"]) and
  .workflow.name == "ci" and .workflow.event == "push" and
  (.workflow.runId | type == "string" and test("^[0-9]+$")) and
  (.workflow.runAttempt | type == "number" and floor == . and . > 0) and
  (
    (.workflow.runUrl |
      capture("^https://github\\.com/(?<repository>[^/]+/cicd-course-sample-app)/actions/runs/(?<url_run_id>[0-9]+)$")) as $run_url |
    ($run_url.url_run_id == .workflow.runId) and
    (.image | keys == ["indexDigest","platforms","repository"]) and
    (.image.repository | test("^" + $ENV.AWS_ACCOUNT_ID + "\\.dkr\\.ecr\\." + $ENV.AWS_REGION + "\\.amazonaws\\.com/")) and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    .image.platforms == ["linux/amd64","linux/arm64"] and
    (.attestation | keys == ["githubId","githubUrl","ociProvenanceDigest","ociSbomDigest"]) and
    (.attestation.githubId | type == "string" and length > 0) and
    .attestation.githubUrl == ("https://github.com/" + $run_url.repository + "/attestations/" + .attestation.githubId) and
    (.attestation.ociSbomDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.attestation.ociProvenanceDigest | test("^sha256:[0-9a-f]{64}$"))
  ) and
  (.gitops | keys == ["devRevision"]) and (.gitops.devRevision | test("^[0-9a-f]{40}$")) and
  (.cluster | keys == ["arn"]) and
  (.cluster.arn | test("^arn:aws:eks:" + $ENV.AWS_REGION + ":" + $ENV.AWS_ACCOUNT_ID + ":cluster/[A-Za-z0-9][A-Za-z0-9_-]+$")) and
  (.slo | keys == ["evidenceId"]) and (.slo.evidenceId | type == "string" and length > 0) and
  (.issuedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid, stale, or aliased course.dev-ready/v1 evidence'

jq -en --slurpfile deployment "$deployment" --slurpfile slo "$slo" --slurpfile ready "$ready" '
  ($deployment[0]) as $d | ($slo[0]) as $s | ($ready[0]) as $r |
  ($r.workflow.runUrl |
    capture("^https://github\\.com/(?<repository>[^/]+/cicd-course-sample-app)/actions/runs/[0-9]+$").repository) as $workflow_repository |
  $d.source == $s.source and $d.image == $s.image and
  $d.source.repository == $workflow_repository and $s.source.repository == $workflow_repository and
  $d.gitopsRevision == $s.gitopsRevision and $d.clusterArn == $s.clusterArn and $d.region == $s.region and
  $r.sourceSha == $d.source.sha and $r.image.repository == $d.image.repository and
  $r.image.indexDigest == $d.image.indexDigest and $r.gitops.devRevision == $d.gitopsRevision and
  $r.cluster.arn == $d.clusterArn and $r.region == $d.region and
  $r.slo.evidenceId == $s.evidenceId and $r.issuedAt == $s.observedAt and $r.expiresAt == $s.expiresAt
' >/dev/null || course_fail 'DEV_READY_IDENTITY_MISMATCH'

if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]]; then
  echo 'DETAIL: DEV_READY and Dev runtime evidence are current and identity-bound.'
else
  echo 'PASS: [STATIC] DEV_READY exact schema and reviewed runtime handoff are valid.'
fi
