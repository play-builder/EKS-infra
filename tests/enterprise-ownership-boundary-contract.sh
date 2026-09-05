#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
ruby - "$root" <<'RUBY'
require 'json'
root = ARGV.fetch(0)
def validate_ownership(files)
  files.each do |path, source|
    text = source.gsub(/^[ \t]*(?:#|\/\/).*$/, '').gsub(%r{/\*.*?\*/}m, '')
    raise "EKS cannot own Istio/app policy: #{path}" if text.match?(/\bkind\s*(?:=|:)\s*"?(?:VirtualService|DestinationRule|PeerAuthentication|Telemetry|ClusterImagePolicy|AppProject)"?\b/)
    raise "EKS cannot install GitOps-owned chart: #{path}" if text.match?(/\bchart\s*=\s*"(?:istiod|cni|mini-commerce)"/)
    raise "Mini Commerce workload belongs to GitOps: #{path}" if text.match?(/\bkind\s*(?:=|:)\s*"?(?:Rollout|Deployment|NetworkPolicy)"?\b/) && text.match?(/(?:name|namespace)\s*(?:=|:)\s*"?(?:mini-commerce|app-(?:dev|prod|recovery))/)
    raise "Terraform must not own secret payloads: #{path}" if text.match?(/(?:resource|data)\s+"aws_secretsmanager_secret_version"/)
    raise "Retired Rollouts plugin: #{path}" if text.include?('trafficRouterPlugins') || text.include?('gateway_plugin_') || text.include?('ignoreDifferences.gateway.networking.k8s.io_HTTPRoute')
  end
end
files = Dir.glob("#{root}/{environments,modules}/**/*.tf").to_h { |p| [p, File.read(p)] }
validate_ownership(files)
%w[VirtualService DestinationRule PeerAuthentication Telemetry ClusterImagePolicy AppProject].each do |kind|
  begin
    validate_ownership({'negative.tf' => %(resource "kubectl_manifest" "bad" { yaml_body = yamlencode({ kind = "#{kind}" }) })})
    raise "accepted prohibited #{kind}"
  rescue RuntimeError => e
    raise if e.message.start_with?('accepted')
  end
end
%w[Rollout Deployment NetworkPolicy].each do |kind|
  begin
    validate_ownership({'negative.tf' => %(resource "kubectl_manifest" "bad" { yaml_body = yamlencode({kind = "#{kind}", metadata = {name = "mini-commerce"}}) })})
    raise "accepted prohibited app #{kind}"
  rescue RuntimeError => e
    raise if e.message.start_with?('accepted')
  end
end
required = {
  'modules/finops/main.tf' => /resource\s+"aws_budgets_budget"/,
  'modules/addons/sigstore-policy-controller/main.tf' => /resource\s+"helm_release"\s+"policy_controller"/,
  'environments/prod/03-database/outputs.tf' => /output\s+"database_contract"/,
  'environments/recovery/03-database/outputs.tf' => /output\s+"database_contract"/,
  'environments/prod/01-network/logging.tf' => /output\s+"logging_contract"/,
  'environments/prod/03-platform/outputs.tf' => /output\s+"sigstore_controller"/,
  'environments/prod/04-workloads/argocd/outputs.tf' => /output\s+"argocd"/,
  'terraform/platform-backup/outputs.tf' => /output\s+"backup"/
}
required.each { |p, pattern| raise "missing producer #{p}" unless File.read("#{root}/#{p}").match?(pattern) }
puts 'PASS: semantic EKS ownership boundary + 9 forbidden-resource mutations (STATIC_VERIFIED)'
RUBY
