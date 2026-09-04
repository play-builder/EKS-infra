#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for environment in dev prod; do
  outputs="$root/environments/$environment/03-platform/outputs.tf"
  for output_name in adot_xray_enabled otlp_http_traces_endpoint otlp_traces_protocol otlp_http_port otlp_http_traces_path; do
    rg -q "^output \"$output_name\"" "$outputs" || {
      echo "$environment platform must publish $output_name" >&2
      exit 1
    }
  done
  rg -q 'module\.adot_collector\[0\]\.otlp_http_port' "$outputs" || {
    echo "$environment platform must forward the ADOT OTLP HTTP port" >&2
    exit 1
  }
  rg -q 'module\.adot_collector\[0\]\.otlp_http_traces_path' "$outputs" || {
    echo "$environment platform must forward the ADOT OTLP traces path" >&2
    exit 1
  }
done

for contract_line in \
  'otlpProtocol: "http/protobuf"' \
  'otlpHttpPort: 4318' \
  'otlpTracesPath: "/v1/traces"' \
  'rollouts_pod_template_hash'; do
  rg -q --fixed-strings "$contract_line" "$root/versions.lock.yaml" || {
    echo "versions.lock.yaml is missing telemetry contract: $contract_line" >&2
    exit 1
  }
done

echo 'PASS: platform publishes the bounded OTLP/X-Ray producer contract'
