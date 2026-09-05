#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
ruby -ryaml - "$root" <<'RUBY'
root=ARGV.fetch(0)
w=YAML.load_file("#{root}/.github/workflows/terraform-drift.yml")
trigger=w.fetch('on',w[true])
raise 'scheduled drift missing' unless trigger.fetch('schedule').size==1
job=w.fetch('jobs').fetch('drift')
raise 'unexpected write permission' unless job.fetch('permissions')=={'contents'=>'read','id-token'=>'write'}
steps=job.fetch('steps')
auth=steps.find{|s|s.fetch('uses','').start_with?('aws-actions/configure-aws-credentials@')}
raise 'dedicated drift identity' unless auth.fetch('with').fetch('role-to-assume')=='${{ secrets.TERRAFORM_DRIFT_ROLE_ARN }}'
commands=steps.map{|s|s['run']}.compact.join("\n")
raise 'mutation in drift' if commands.match?(/terraform\s+.*\b(?:apply|destroy)\b|git\s+push/)
raise 'script must preserve drift exit code' unless commands.include?('bash scripts/terraform-drift-check.sh')
raise 'fail closed input' unless commands.include?('DRIFT_INPUTS_REQUIRED') && commands.include?('DRIFT_ACCOUNT_MISMATCH')
raise 'binary plan leaked' if steps.any?{|s|s.fetch('with',{}).fetch('path','').include?('tfplan')}
roots=job.fetch('strategy').fetch('matrix').fetch('include').map{|x|x.fetch('root')}
raise 'operator-only root in workload cron' if roots.any?{|r|r.include?('00-finops')||r.include?('platform-backup')}
raise 'database drift missing' unless roots.include?('environments/prod/03-database')&&roots.include?('environments/recovery/03-database')
puts 'PASS: scheduled drift uses a dedicated read-only role, fail-closed inputs and redacted artifacts'
RUBY
