#!/usr/bin/env bash

sha256_file() {
  shasum -a 256 "$1" | awk '{print "sha256:" $1}'
}

make_dev_handoff() {
  local ready=$1 deployment=$2 slo=$3
  jq '{
    schemaVersion:"course.dev-deployment/v1",
    evidenceGrade:"CLOUD_RUNTIME",
    status:{sync:"Synced",health:"Healthy"},
    source:{repository:"play-builder/cicd-course-sample-app",sha:.sourceSha},
    image:{repository:.image.repository,indexDigest:.image.indexDigest},
    gitopsRevision:.gitops.devRevision,
    clusterArn:.cluster.arn,
    region:.region,
    observedAt:.issuedAt
  }' "$ready" >"$deployment"
  jq '{
    schemaVersion:"course.dev-slo/v1",
    evidenceGrade:"CLOUD_RUNTIME",
    status:"PASS",
    source:{repository:"play-builder/cicd-course-sample-app",sha:.sourceSha},
    image:{repository:.image.repository,indexDigest:.image.indexDigest},
    gitopsRevision:.gitops.devRevision,
    clusterArn:.cluster.arn,
    region:.region,
    evidenceId:.slo.evidenceId,
    observedAt:.issuedAt,
    expiresAt:.expiresAt
  }' "$ready" >"$slo"
}

render_saved_plan_summary() {
  local template=$1 plan_file=$2 output=$3 region=$4 digest
  digest=$(sha256_file "$plan_file")
  jq --arg path "$plan_file" --arg digest "$digest" --arg region "$region" '
    .savedPlan.path=$path |
    .savedPlan.sha256=$digest |
    .region=$region |
    if .network? then
      .network.availabilityZones=[$region+"a",$region+"b",$region+"c"]
    else . end
  ' "$template" >"$output"
}
