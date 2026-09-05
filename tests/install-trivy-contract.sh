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

# Exercise the other workflow consumer with official, missing, duplicated and
# foreign version prefixes; a lock match must not conceal a different release.
python3 - "$root" <<'PY'
import pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='trivy-version-consumers-') as temporary:
    work = pathlib.Path(temporary)
    (work/'tests').mkdir()
    (work/'.github/workflows').mkdir(parents=True)
    shutil.copy2(root/'versions.lock.yaml', work/'versions.lock.yaml')
    shutil.copy2(root/'tests/workflow-supply-chain-contract.sh', work/'tests/workflow-supply-chain-contract.sh')
    target = work/'.github/workflows/terraform-validate.yml'
    original = (root/'.github/workflows/terraform-validate.yml').read_text()
    for version, accepted in [('v0.74.0', True), ('0.74.0', False), ('vv0.74.0', False), ('v0.73.0', False)]:
        target.write_text(original)
        subprocess.run(['yq', '-i', '(.jobs.security.steps[] | select(.name == "Scan Terraform with Trivy") | .with.version) = "'+version+'"', str(target)], check=True)
        result = subprocess.run(['bash', str(work/'tests/workflow-supply-chain-contract.sh')], capture_output=True, text=True)
        assert (result.returncode == 0) is accepted, version + ': ' + result.stderr
print('PASS: both Trivy version consumers accept only the official locked v-prefixed release')
PY
