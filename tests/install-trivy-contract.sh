#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 -B "$root/tests/install_trivy_test.py"
ruby -ryaml - "$root" <<'RUBY'
root=ARGV.fetch(0)
workflow=YAML.load_file(File.join(root,'.github/workflows/terraform-validate.yml'))
steps=workflow.fetch('jobs').fetch('security').fetch('steps')
install=steps.index{|s|s['name']=='Install checksum-verified Trivy'}
scan=steps.index{|s|s['name']=='Scan Terraform with Trivy'}
abort 'Trivy installation must precede scanning' unless install && scan && install<scan
version=steps[install].fetch('env').fetch('TRIVY_VERSION')
lock=YAML.load_file(File.join(root,'versions.lock.yaml')).fetch('tooling')
abort 'installer/action/lock Trivy version mismatch' unless version==lock.fetch('trivy') && steps[scan].fetch('with').fetch('version')=='v'+version
abort 'action would replace checksum-verified binary' unless steps[scan].fetch('with').fetch('skip-setup-trivy').to_s=='true'
abort 'Trivy action pin mismatch' unless steps[scan].fetch('uses')=='aquasecurity/trivy-action@'+lock.fetch('trivyActionSha')
puts 'PASS: checksum-before-execute and installer/action/lock version agreement'
RUBY
