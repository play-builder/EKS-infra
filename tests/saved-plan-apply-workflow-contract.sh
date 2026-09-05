#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# Execute the actual workflow run blocks on a fresh local fixture. Only remote
# AWS/GitHub calls and Terraform's cloud engine are replaced at the CLI boundary.
ruby - "$root" <<'RUBY'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'

source = ARGV.fetch(0)
workflow = YAML.load_file(File.join(source, '.github/workflows/terraform-validate.yml'))
steps = workflow.fetch('jobs').fetch('reviewed-plan-apply').fetch('steps')
tfroot = 'environments/prod/01-network'
backend = 'environments/prod/config/network.tfbackend'
bindings = {
  'inputs.terraform_root' => tfroot, 'inputs.backend_config' => backend,
  'vars.AWS_REGION' => 'ap-northeast-2', 'vars.STATE_BUCKET_NAME' => 'platform-state-123456789012',
  'github.token' => 'fixture-token'
}
expand = lambda do |text|
  text.gsub(/\$\{\{\s*([^}]+?)\s*\}\}/) { bindings.fetch(Regexp.last_match(1).strip) }
end
Dir.mktmpdir('saved-plan-workflow-') do |repo|
  repo = File.realpath(repo)
  FileUtils.cp_r(File.join(source, 'scripts'), repo)
  FileUtils.mkdir_p([File.join(repo, tfroot), File.join(repo, File.dirname(backend)), File.join(repo, 'bin')])
  FileUtils.cp(File.join(source, backend), File.join(repo, backend))
  File.write(File.join(repo, tfroot, '.terraform.lock.hcl'), "fixture-provider-lock\n")
  File.write(File.join(repo, tfroot, 'main.tf'), "# fixture\n")
  File.write(File.join(repo, 'bin', 'terraform'), <<~'SH')
    #!/usr/bin/env bash
    set -Eeuo pipefail
    if [[ "$*" == 'version -json' ]]; then
      printf 'version\n' >>"$GITHUB_WORKSPACE/calls"
      printf '{"terraform_version":"1.16.0"}\n'
      exit
    fi
    [[ "$1" == "-chdir=$GITHUB_WORKSPACE/environments/prod/01-network" ]] || exit 82
    shift
    action=$1
    shift
    printf '%s\n' "$action" >>"$GITHUB_WORKSPACE/calls"
    case "$action" in
      init)
        [[ "$*" == *'-input=false'* && "$*" == *'-lockfile=readonly'* &&
           "$*" == *"-backend-config=$GITHUB_WORKSPACE/environments/prod/config/network.tfbackend"* &&
           "$*" == *'-backend-config=bucket=platform-state-123456789012'* &&
           "$*" == *'-backend-config=region=ap-northeast-2'* ]] || exit 83
        [[ "${FAIL_INIT:-false}" != true ]] || exit 84
        touch "$GITHUB_WORKSPACE/environments/prod/01-network/.initialized"
        ;;
      plan)
        for arg in "$@"; do
          if [[ "$arg" == -out=* ]]; then printf 'binary-plan\n' >"${arg#-out=}"; fi
        done
        ;;
      show) printf '{"format_version":"1.2","terraform_version":"1.16.0","resource_changes":[]}\n' ;;
      apply)
        [[ -f "$GITHUB_WORKSPACE/environments/prod/01-network/.initialized" ]] || exit 85
        [[ "$*" == "$GITHUB_WORKSPACE/plan-artifact/tfplan" ]] || exit 86
        ;;
      *) exit 87 ;;
    esac
  SH
  File.write(File.join(repo, 'bin', 'aws'), <<~'SH')
    #!/usr/bin/env bash
    [[ "$*" == 'sts get-caller-identity'* ]] || exit 88
    if [[ "$*" == *'--query Account --output text'* ]]; then
      printf '123456789012\n'
    else
      printf '{"Account":"123456789012"}\n'
    fi
  SH
  File.write(File.join(repo, 'bin', 'gh'), <<~'SH')
    #!/usr/bin/env bash
    [[ "$*" == 'api /repos/fixture/repo/actions/runs/987654321/approvals' ]] || exit 89
    printf '[{"state":"approved","environments":[{"name":"production"}],"user":{"login":"platform-approver"}}]\n'
  SH
  FileUtils.chmod(0755, Dir[File.join(repo, 'bin', '*')])
  run = lambda do |env, *cmd|
    output, status = Open3.capture2e(env, *cmd, chdir: repo)
    raise "#{cmd.inspect}: #{output}" unless status.success?
    output
  end
  run.call({}, 'git', 'init', '-q')
  run.call({}, 'git', 'add', '.')
  run.call({}, 'git', '-c', 'user.name=contract', '-c', 'user.email=contract@example.invalid', 'commit', '-qm', 'fixture')
  env = {
    'PATH' => "#{repo}/bin:#{ENV.fetch('PATH')}", 'GITHUB_WORKSPACE' => repo,
    'RUNNER_TEMP' => repo, 'GITHUB_REPOSITORY' => 'fixture/repo',
    'GITHUB_RUN_ID' => '987654321', 'GITHUB_TRIGGERING_ACTOR' => 'release-requester',
    'GITHUB_SHA' => run.call({}, 'git', 'rev-parse', 'HEAD').strip,
    'AWS_REGION' => 'ap-northeast-2', 'BACKEND_BUCKET' => 'platform-state-123456789012',
    'PLAN_REQUEST_IDENTITY' => 'release-requester', 'PLAN_RUN_ID' => '987654321'
  }
  # Real FinOps collector/evaluator with fixture observations; never cloud credentials.
  run.call(env, 'python3', '-B', '-c', <<~'PY', source, repo)
    import importlib.util,json,pathlib,sys
    s=importlib.util.spec_from_file_location('fixtures',pathlib.Path(sys.argv[1])/'tests/finops_readiness_test.py')
    m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
    c,o=m.fixture(); root=pathlib.Path(sys.argv[2])
    (root/'contract.json').write_text(json.dumps(c));(root/'observations.json').write_text(json.dumps(o))
  PY
  env.merge!('COURSE_CHECK_BIN_DIR'=>File.join(repo,'bin'), 'FINOPS_FIXTURE_JSON'=>File.join(repo,'observations.json'),
             'FINOPS_CONTRACT_JSON'=>File.join(repo,'contract.json'), 'PLATFORM_INSTANCE_ID'=>'commerce-123',
             'FINOPS_GATE_POLICY'=>'configuration-only', 'FINOPS_CONTRACT_SHA256'=>'sha256:'+Digest::SHA256.file(File.join(repo,'contract.json')).hexdigest,
             'GITHUB_ACTIONS'=>'false', 'FINOPS_BILLING_PROFILE'=>nil, 'FINOPS_BILLING_ROLE_ARN'=>nil)
  run.call(env, 'bash', File.join(repo, 'scripts/create-saved-plan.sh'), File.join(repo, tfroot),
           File.join(repo, backend), File.join(repo, 'plan-artifact'), 'apply')
  saved_readiness=File.read(File.join(repo,'plan-artifact/finops-readiness.json'))
  saved_observations=File.read(File.join(repo,'observations.json'))
  %w[success init-failure identity-failure finops-changed finops-missing].each do |scenario|
    File.write(File.join(repo,'plan-artifact/finops-readiness.json'),saved_readiness)
    File.write(File.join(repo,'observations.json'),saved_observations)
    FileUtils.rm_f(File.join(repo, tfroot, '.initialized'))
    File.write(File.join(repo, 'calls'), '')
    scenario_env = env.merge('FAIL_INIT' => (scenario == 'init-failure').to_s)
    if scenario == 'identity-failure'
      scenario_env['GITHUB_TRIGGERING_ACTOR'] = 'different-requester'
    end
    if scenario == 'finops-changed'
      o=JSON.parse(saved_observations);o.fetch('costTags')[0]['Status']='Inactive'
      File.write(File.join(repo,'observations.json'),JSON.generate(o))
    end
    FileUtils.rm_f(File.join(repo,'plan-artifact/finops-readiness.json')) if scenario=='finops-missing'
    failure = nil
    steps.select { |step| step.key?('run') && step['name'] != 'Install pinned FinOps collector dependencies' }.each do |step|
      step_env = scenario_env.merge((step['env'] || {}).transform_values { |v| expand.call(v) })
      output, status = Open3.capture2e(step_env, 'bash', '-e', '-o', 'pipefail', '-c', expand.call(step['run']), chdir: repo)
      unless status.success?
        failure = output
        break
      end
    end
    calls = File.readlines(File.join(repo, 'calls'), chomp: true)
    if scenario == 'success'
      raise "fresh apply failed: #{failure}; calls=#{calls}" if failure
      raise "verification must precede init and saved binary apply: #{calls}" unless calls == %w[version init apply]
    else
      raise "#{scenario} continued to apply: #{calls}" unless failure && !calls.include?('apply')
      if scenario == 'identity-failure'
        raise "mismatch was not rejected by binding: #{failure}" unless failure.include?('SAVED_PLAN_REQUEST_IDENTITY_MISMATCH')
      end
      if scenario.start_with?('finops-')
        raise "FinOps failure reached Terraform: #{calls}; #{failure}" unless calls.empty? && failure.include?('FINOPS')
      end
    end
  end
end
puts 'PASS: fresh apply verifies FinOps and approval before Terraform init/apply, and fails closed.'
RUBY
