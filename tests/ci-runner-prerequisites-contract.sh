#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

ruby -ryaml -rtmpdir -rfileutils -ropen3 - "$root" <<'RUBY'
root = ARGV.fetch(0)
workflow = YAML.load_file(File.join(root, '.github/workflows/terraform-validate.yml'))
contracts = {
  'contract' => {
    test_command: 'tests/run-contract-tests.sh',
    required: %w[bash git jq python3 rg ruby terraform]
  },
  'enterprise-static' => {
    test_command: 'tests/run-enterprise-static-tests.sh',
    required: %w[bash git helm jq python3 rg ruby terraform]
  }
}

def executable(path, body)
  File.write(path, "#!/bin/bash\n#{body}")
  FileUtils.chmod(0755, path)
end

def run_prerequisite(script, required, missing: nil, apt_fail: false, skip_ripgrep: false)
  Dir.mktmpdir('ci-runner-prerequisites-') do |temporary|
    bin = File.join(temporary, 'bin')
    FileUtils.mkdir_p(bin)
    executable(File.join(bin, 'sudo'), "exec \"$@\"\n")
    executable(File.join(bin, 'apt-get'), <<~'SH')
      printf '%s\n' "$*" >> "$APT_LOG"
      [[ "${APT_FAIL:-false}" != true ]] || {
        echo 'APT_FIXTURE_FAILURE: ripgrep' >&2
        exit 42
      }
      if [[ "$1" == install && "${APT_SKIP_RIPGREP:-false}" != true ]]; then
        printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/rg"
        /bin/chmod 0755 "$FAKE_BIN/rg"
      fi
    SH
    (required - ['rg', missing]).each do |tool|
      executable(File.join(bin, tool), "exit 0\n")
    end
    env = {
      'PATH' => bin,
      'FAKE_BIN' => bin,
      'APT_LOG' => File.join(temporary, 'apt.log'),
      'APT_FAIL' => apt_fail.to_s,
      'APT_SKIP_RIPGREP' => skip_ripgrep.to_s
    }
    output, status = Open3.capture2e(env, '/bin/bash', '-e', '-o', 'pipefail', '-c', script)
    [output, status, File.exist?(env['APT_LOG']) ? File.read(env['APT_LOG']) : '']
  end
end

contracts.each do |job_name, contract|
  steps = workflow.fetch('jobs').fetch(job_name).fetch('steps')
  test_index = steps.index { |step| step.fetch('run', '').include?(contract.fetch(:test_command)) }
  abort "#{job_name}: aggregate test step missing" unless test_index
  install_indexes = steps.each_index.select do |index|
    run = steps[index].fetch('run', '')
    run.include?('apt-get') && run.include?('ripgrep')
  end
  abort "#{job_name}: exactly one ripgrep prerequisite step required" unless install_indexes.length == 1
  install_index = install_indexes.fetch(0)
  abort "#{job_name}: prerequisites must precede aggregate tests" unless install_index < test_index
  script = steps.fetch(install_index).fetch('run')

  output, status, apt_log = run_prerequisite(script, contract.fetch(:required))
  abort "#{job_name}: prerequisite setup failed: #{output}" unless status.success?
  abort "#{job_name}: apt update/install behavior missing: #{apt_log}" unless
    apt_log.lines.any? { |line| line.strip == 'update' } &&
    apt_log.lines.any? { |line| line.include?('install') && line.include?('ripgrep') }

  output, status, = run_prerequisite(script, contract.fetch(:required), apt_fail: true)
  abort "#{job_name}: apt failure was silently accepted" if status.success?
  abort "#{job_name}: apt failure lost the failed package diagnostic: #{output}" unless output.include?('ripgrep')

  contract.fetch(:required).each do |tool|
    options = tool == 'rg' ? {skip_ripgrep: true} : {missing: tool}
    output, status, = run_prerequisite(script, contract.fetch(:required), **options)
    abort "#{job_name}: missing #{tool} silently passed" if status.success?
    abort "#{job_name}: missing #{tool} diagnostic was not useful: #{output}" unless output.include?(tool)
  end
end

puts 'PASS: both isolated CI jobs install and diagnose runner prerequisites before aggregate tests'
RUBY
