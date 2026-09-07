#!/usr/bin/env bash

setup_ch16_fake_environment() {
  local target=$1
  mkdir -p "$target/bin"

  cat >"$target/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ -z "${PLATFORM_FAKE_CLOUD_LOG:-}" ]] || printf 'kubectl %s\n' "$*" >>"$PLATFORM_FAKE_CLOUD_LOG"
case "$*" in
  *"get deployment k6-operator-controller-manager"*)
    echo '{"status":{"replicas":1,"availableReplicas":1}}'
    ;;
  *"get crd testruns.k6.io"*)
    echo '{"status":{"conditions":[{"type":"Established","status":"True"}]}}'
    ;;
  *"get testrun platform-baseline"*)
    if [[ "${FAKE_K6_BAD:-false}" == "true" ]]; then
      echo '{"metadata":{"annotations":{"playbuilder.platform/max-duration":"10m","playbuilder.platform/max-rate":"20"}},"status":{"stage":"finished"}}'
    else
      echo '{"metadata":{"annotations":{"playbuilder.platform/max-duration":"10m","playbuilder.platform/max-rate":"20","playbuilder.platform/cost-boundary":"existing-eks-compute"}},"status":{"stage":"finished"}}'
    fi
    ;;
  *) printf 'unexpected kubectl invocation: %s\n' "$*" >&2; exit 97 ;;
esac
EOF

  cat >"$target/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ -z "${PLATFORM_FAKE_CLOUD_LOG:-}" ]] || printf 'aws %s\n' "$*" >>"$PLATFORM_FAKE_CLOUD_LOG"
case "$1 $2" in
  "amp describe-workspace")
    echo '{"workspace":{"arn":"arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-test","workspaceId":"ws-test","status":{"statusCode":"ACTIVE"},"prometheusEndpoint":"https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/ws-test/"}}'
    ;;
  "amp get-rule-groups-namespace")
    echo '{"data":"Z3JvdXBzOgotIG5hbWU6IG1pbmktY29tbWVyY2UtcmVsZWFzZS1zbG8KICBydWxlczoKICAtIHJlY29yZDogcGxhdGZvcm06aHR0cF9zdWNjZXNzX3JhdGlvOjVtCiAgLSBhbGVydDogUGxhdGZvcm1EZWFkbWFuCg=="}'
    ;;
  "amp get-alert-manager-definition")
    echo '{"status":{"statusCode":"ACTIVE"},"data":"cm91dGU6CiAgcmVjZWl2ZXI6IG1pbmktY29tbWVyY2Utc25zCnJlY2VpdmVyczoKLSBuYW1lOiBtaW5pLWNvbW1lcmNlLXNucwogIHNuc19jb25maWdzOgogIC0gdG9waWNfYXJuOiBhcm46YXdzOnNuczphcC1ub3J0aGVhc3QtMjoxMjM0NTY3ODkwMTI6bWluaS1jb21tZXJjZS1hbGVydHMKICAgIHNpZ3Y0OgogICAgICByZWdpb246IGFwLW5vcnRoZWFzdC0yCiAgICBzZW5kX3Jlc29sdmVkOiB0cnVlCg=="}'
    ;;
  "sns get-topic-attributes")
    if [[ "${FAKE_SNS_WRONG_SOURCE:-false}" == "true" ]]; then
      source_arn='arn:aws:aps:ap-northeast-2:999999999999:workspace/ws-other'
    else
      source_arn='arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-test'
    fi
    printf '{"Attributes":{"TopicArn":"arn:aws:sns:ap-northeast-2:123456789012:mini-commerce-alerts","Policy":"{\\"Version\\":\\"2012-10-17\\",\\"Statement\\":[{\\"Principal\\":{\\"Service\\":\\"aps.amazonaws.com\\"},\\"Action\\":\\"sns:Publish\\",\\"Resource\\":\\"arn:aws:sns:ap-northeast-2:123456789012:mini-commerce-alerts\\",\\"Condition\\":{\\"ArnEquals\\":{\\"AWS:SourceArn\\":\\"%s\\"},\\"StringEquals\\":{\\"AWS:SourceAccount\\":\\"123456789012\\"}}}]}"}}\n' "$source_arn"
    ;;
  "amp query-metrics")
    echo '{"data":{"resultType":"vector","result":[{"value":[1788412200,"0.999"]}]}}'
    ;;
  "sns list-subscriptions-by-topic")
    if [[ "${FAKE_SNS_PENDING:-false}" == "true" ]]; then
      echo '{"Subscriptions":[{"SubscriptionArn":"PendingConfirmation"}]}'
    else
      echo '{"Subscriptions":[{"SubscriptionArn":"arn:aws:sns:ap-northeast-2:123456789012:mini-commerce-alerts:subscription"}]}'
    fi
    ;;
  *) printf 'unexpected aws invocation: %s\n' "$*" >&2; exit 97 ;;
esac
EOF
  chmod +x "$target/bin/kubectl" "$target/bin/aws"

  cat >"$target/alert-delivery.json" <<'EOF'
{"schemaVersion":"playbuilder.alert-delivery/v1","evidenceGrade":"CLOUD_RUNTIME","topicArn":"arn:aws:sns:ap-northeast-2:123456789012:mini-commerce-alerts","firing":{"delivered":true},"resolved":{"delivered":true},"observedAt":"2026-09-03T10:20:00Z"}
EOF
}

run_ch16_fixture() {
  local root=$1 target=$2 output=$3
  AWS_PROFILE=mini-commerce PLATFORM_CHECK_BIN_DIR="$target/bin" PLATFORM_CHECK_NOW="2026-09-03T10:30:00Z" \
    ALERT_DELIVERY_EVIDENCE="$target/alert-delivery.json" \
    bash "$root/scripts/platform-check.sh" ch16 \
    "$root/tests/fixtures/dev-deployment-static.json" mini-commerce-dev k6-operator-system platform-baseline \
    ws-test arn:aws:sns:ap-northeast-2:123456789012:mini-commerce-alerts ap-northeast-2 --output "$output"
}
