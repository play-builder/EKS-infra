#!/usr/bin/env bash
# Loaded by dev-ready-check.sh after evidence-common.sh.

check_core_runtime() {
  local context=${1:-mini-commerce-dev} namespace=${2:-app-dev}
  pb_require_command kubectl
  pb_require_command jq

  local nodes application external_secret deployment
  nodes=$(kubectl --context "$context" get nodes -o json)
  jq -e '(.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' \
    <<<"$nodes" >/dev/null || pb_fail "Ready 상태가 아닌 Dev node가 있습니다."

  application=$(kubectl --context "$context" -n argocd get application mini-commerce-dev -o json)
  jq -e '.status.sync.status == "Synced" and .status.health.status == "Healthy"' \
    <<<"$application" >/dev/null || pb_fail "mini-commerce-dev Application이 Synced/Healthy가 아닙니다."

  external_secret=$(kubectl --context "$context" -n "$namespace" get externalsecret mini-commerce-runtime -o json)
  jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' \
    <<<"$external_secret" >/dev/null || pb_fail "mini-commerce-runtime ExternalSecret이 Ready가 아닙니다."

  deployment=$(kubectl --context "$context" -n "$namespace" get deployment mini-commerce -o json)
  jq -e '.status.availableReplicas > 0 and .status.availableReplicas == .status.replicas' \
    <<<"$deployment" >/dev/null || pb_fail "mini-commerce Deployment replica가 모두 Available이 아닙니다."

  pb_detail "Core runtime Dev 핵심 runtime 상태가 Ready/Synced/Healthy입니다."
}

check_stateful() {
  local context=${1:-} namespace=${2:-} base_url=${3:-}
  [[ -n "$context" && -n "$namespace" && -n "$base_url" ]] || \
    pb_fail "사용법: bash scripts/dev-ready-check.sh stateful <kubectl-context> <namespace> <base-url>" 64
  base_url=${base_url%/}
  for command in kubectl jq curl; do
    pb_require_command "$command"
  done

  local storage_class stateful_set claims migration_job application_pods products inventory order
  storage_class=$(kubectl --context "$context" get storageclass/mini-commerce-gp3 -o json)
  jq -e '
    .provisioner == "ebs.csi.aws.com" and
    .reclaimPolicy == "Delete" and
    .volumeBindingMode == "WaitForFirstConsumer" and
    .allowVolumeExpansion == true and
    .parameters.type == "gp3" and
    .parameters.encrypted == "true"
  ' <<<"$storage_class" >/dev/null || pb_fail "mini-commerce-gp3 StorageClass 계약이 일치하지 않습니다."

  stateful_set=$(kubectl --context "$context" -n "$namespace" get statefulset mini-commerce-postgresql -o json)
  jq -e '.spec.replicas == 1 and .status.readyReplicas == 1 and .status.currentRevision == .status.updateRevision' \
    <<<"$stateful_set" >/dev/null || pb_fail "PostgreSQL StatefulSet이 Ready가 아닙니다."

  claims=$(kubectl --context "$context" -n "$namespace" get pvc \
    -l app.kubernetes.io/component=database -o json)
  jq -e '
    (.items | length) == 1 and
    all(.items[]; .status.phase == "Bound" and .spec.storageClassName == "mini-commerce-gp3")
  ' <<<"$claims" >/dev/null || pb_fail "PostgreSQL PVC가 mini-commerce-gp3에 Bound되지 않았습니다."

  migration_job=$(kubectl --context "$context" -n "$namespace" get job mini-commerce-migration -o json)
  jq -e '.status.succeeded >= 1 and (.status.failed // 0) == 0' \
    <<<"$migration_job" >/dev/null || pb_fail "schema migration Job이 성공하지 않았습니다."

  application_pods=$(kubectl --context "$context" -n "$namespace" get pods \
    -l app.kubernetes.io/name=mini-commerce -o json)
  jq -e '
    (.items | length) > 0 and
    all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  ' <<<"$application_pods" >/dev/null || pb_fail "Mini Commerce application Pod가 모두 Ready가 아닙니다."

  products=$(curl --fail --silent --show-error --max-time 5 "$base_url/products")
  jq -e '.products | type == "array" and length >= 4' <<<"$products" >/dev/null || \
    pb_fail "상품 목록 API가 mock 상품을 반환하지 않습니다."
  inventory=$(curl --fail --silent --show-error --max-time 5 "$base_url/products/1/inventory")
  jq -e '.productId == 1 and (.availableQuantity | type == "number")' <<<"$inventory" >/dev/null || \
    pb_fail "재고 API 응답이 유효하지 않습니다."
  order=$(curl --fail --silent --show-error --max-time 5 \
    --request POST "$base_url/orders" \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: platform-check-$namespace" \
    --data '{"items":[{"productId":4,"quantity":1}]}')
  jq -e '.order.status == "CONFIRMED" and .order.totalCents == 32900 and (.order.id | type == "number")' \
    <<<"$order" >/dev/null || pb_fail "멱등 주문 생성 API 응답이 유효하지 않습니다."

  jq '{productCount: (.products | length), firstSku: .products[0].sku}' <<<"$products"
  jq '{productId, availableQuantity}' <<<"$inventory"
  jq '{orderId: .order.id, status: .order.status, totalCents: .order.totalCents}' <<<"$order"
  pb_detail "Stateful Mini Commerce storage, migration, Pod, 상품·재고·주문 API가 유효합니다."
}

check_secret_freshness() {
  local context=${1:-} namespace=${2:-} external_secret=${3:-} rollout=${4:-}
  local runtime_secret=${5:-} expected_version=${6:-} previous_pod_uid=${7:-}
  [[ $# -eq 7 ]] || pb_fail "사용법: secret-freshness <context> <namespace> <externalsecret> <rollout> <runtime-secret-id> <version-id> <previous-pod-uid>" 64
  [[ "$runtime_secret" == */mini-commerce-runtime ]] || pb_fail "Secret freshness reload target은 mini-commerce-runtime secret이어야 합니다." 64
  for command in aws kubectl jq; do pb_require_command "$command"; done
  for name in AWS_PROFILE AWS_REGION; do pb_require_environment "$name"; done
  pb_validate_region "$AWS_REGION"

  local secret external rollout_json pods current_hash
  secret=$(aws secretsmanager describe-secret --secret-id "$runtime_secret" --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json)
  jq -e --arg version "$expected_version" '.VersionIdsToStages[$version] | index("AWSCURRENT") != null' \
    <<<"$secret" >/dev/null || pb_fail "expected runtime secret VersionId가 AWSCURRENT가 아닙니다."
  external=$(kubectl --context "$context" -n "$namespace" get externalsecret "$external_secret" -o json)
  jq -e --arg version "$expected_version" '
    .metadata.generation as $generation |
    any(.status.conditions[]?; .type == "Ready" and .status == "True" and ((.observedGeneration // $generation) == $generation)) and
    (.status.syncedResourceVersion == $version)
  ' <<<"$external" >/dev/null || pb_fail "ExternalSecret이 current generation/VersionId를 Ready로 동기화하지 않았습니다."
  rollout_json=$(kubectl --context "$context" -n "$namespace" get rollout "$rollout" -o json)
  current_hash=$(jq -r '.status.currentPodHash // empty' <<<"$rollout_json")
  [[ -n "$current_hash" ]] || pb_fail "Rollout currentPodHash가 없습니다."
  pods=$(kubectl --context "$context" -n "$namespace" get pods -l "rollouts-pod-template-hash=$current_hash" -o json)
  jq -e --arg previous "$previous_pod_uid" '
    (.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True")) and
    any(.items[]; .metadata.uid != $previous)
  ' <<<"$pods" >/dev/null || pb_fail "runtime secret 변경 후 새 Ready Pod UID를 확인하지 못했습니다."
  printf 'SECRET_RELOAD: version=%s currentPodHash=%s\n' "$expected_version" "$current_hash"
}
