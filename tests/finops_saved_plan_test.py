"""Real saved-plan scripts; only AWS and Terraform cloud I/O are doubled."""
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('readiness_fixtures', ROOT / 'tests/finops_readiness_test.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class SavedFinOps(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name).resolve()
        shutil.copytree(ROOT / 'scripts', self.repo / 'scripts')
        self.bin = self.repo / 'bin'; self.bin.mkdir()
        self.calls = self.repo / 'calls'
        self.calls.touch()
        for scope in ('dev', 'prod'):
            root = self.repo / f'environments/{scope}/01-network'; root.mkdir(parents=True)
            (root / '.terraform.lock.hcl').write_text('fixture lock\n')
            backend = self.repo / f'environments/{scope}/config'; backend.mkdir()
            (backend / 'network.tfbackend').write_text(f'key = "{scope}/01-network/terraform.tfstate"\nencrypt = true\nuse_lockfile = true\n')
        (self.bin / 'terraform').write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$TEST_CALLS"
if [[ "$*" == 'version -json' ]]; then
  printf '{"terraform_version":"1.16.0"}\\n'
elif [[ "$*" == *' plan '* ]]; then
  for arg in "$@"; do if [[ "$arg" == -out=* ]]; then printf 'saved binary' >"${arg#-out=}"; fi; done
elif [[ "$*" == *' show -json '* ]]; then
  printf '{"format_version":"1.2","terraform_version":"1.16.0","resource_changes":[]}\\n'
elif [[ "$*" != *' init '* ]]; then exit 91; fi
''')
        (self.bin / 'aws').write_text('''#!/usr/bin/env bash
[[ "$*" == 'sts get-caller-identity --region ap-northeast-2 --output json' ]] || exit 92
printf '{"Account":"123456789012"}\\n'
''')
        for file in self.bin.iterdir(): file.chmod(0o755)
        c, o = fixtures.fixture()
        self.contract = self.repo / 'contract.json'; self.contract.write_text(json.dumps(c))
        self.observations = self.repo / 'observations.json'; self.observations.write_text(json.dumps(o))
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'TEST_CALLS': str(self.calls), 'AWS_REGION': 'ap-northeast-2',
                    'BACKEND_BUCKET': 'platform-state-123456789012', 'PLAN_REQUEST_IDENTITY': 'requester',
                    'PLAN_RUN_ID': '123', 'FINOPS_CONTRACT_JSON': str(self.contract),
                    'FINOPS_CONTRACT_SHA256': 'sha256:' + hashlib.sha256(self.contract.read_bytes()).hexdigest(),
                    'PLATFORM_INSTANCE_ID': 'commerce-123', 'FINOPS_GATE_POLICY': 'configuration-only',
                    'COURSE_CHECK_BIN_DIR': str(self.bin), 'FINOPS_FIXTURE_JSON': str(self.observations)}
        for k in ('GITHUB_ACTIONS', 'FINOPS_BILLING_PROFILE', 'FINOPS_BILLING_ROLE_ARN'):
            self.env.pop(k, None)
        self.run_ok(['git','init','-q'])
        self.run_ok(['git','add','.'])
        self.run_ok(['git','-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'])
        self.sha = self.run_ok(['git','rev-parse','HEAD']).stdout.strip()

    def run_ok(self, args, env=None):
        result = subprocess.run(args, cwd=self.repo, env=env or self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def create(self, scope='prod', operation='apply', env=None):
        return subprocess.run(['bash',str(self.repo/'scripts/create-saved-plan.sh'),
            str(self.repo/f'environments/{scope}/01-network'), str(self.repo/f'environments/{scope}/config/network.tfbackend'),
            str(self.repo/'plan-artifact'), operation], cwd=self.repo, env=env or self.env, text=True, capture_output=True)

    def approved(self):
        result=self.create(); self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repo/'plan-artifact/finops-readiness.json').is_file(), 'production artifact omitted FinOps evaluation')
        history=self.repo/'history.json'
        history.write_text('[{"state":"approved","environments":[{"name":"production"}],"user":{"login":"approver"}}]')
        self.run_ok(['bash',str(self.repo/'scripts/bind-saved-plan-approval.sh'),str(self.repo/'plan-artifact'),str(history),'production','requester','123'])
        self.calls.write_text('')

    def verify(self, env=None):
        return subprocess.run(['bash',str(self.repo/'scripts/verify-saved-plan.sh'),str(self.repo/'plan-artifact'),
            'environments/prod/01-network','123456789012','ap-northeast-2','platform-state-123456789012',
            'prod/01-network/terraform.tfstate','s3-native-lockfile',self.sha,'requester','123','apply'],
            cwd=self.repo, env=env or self.env, text=True, capture_output=True)

    def test_prod_missing_contract_denies_before_terraform(self):
        env={k:v for k,v in self.env.items() if not k.startswith('FINOPS_')}
        result=self.create(env=env)
        self.assertNotEqual(result.returncode, 0, 'production plan accepted no FinOps contract')
        self.assertIn('FINOPS', result.stderr)
        self.assertEqual(self.calls.read_text(), '')

    def test_production_artifact_binds_raw_contract_readiness_and_static_grade(self):
        self.approved()
        artifact=self.repo/'plan-artifact'
        manifest=json.loads((artifact/'plan-identity.json').read_text())
        self.assertEqual(manifest['finops']['evidenceGrade'], 'STATIC')
        for key,file in [('contractSha256','finops-contract.json'),('readinessSha256','finops-readiness.json')]:
            self.assertEqual(manifest['finops'][key], 'sha256:'+hashlib.sha256((artifact/file).read_bytes()).hexdigest())
        readiness=json.loads((artifact/'finops-readiness.json').read_text())
        self.assertEqual(readiness['deliveryStatus'],'NOT_VERIFIED')
        self.assertEqual(readiness['dataStatus'],'DATA_PENDING')
        result=self.verify(); self.assertEqual(result.returncode,0,result.stderr)

    def test_missing_altered_stale_or_foreign_evidence_denies_before_terraform(self):
        self.approved()
        artifact=self.repo/'plan-artifact'
        original={p.name:p.read_bytes() for p in artifact.iterdir()}
        for case in ('missing','contract','readiness','account','region','platform','billing','management','principal','stale','ttl','collector','trusted-digest'):
            with self.subTest(case=case):
                for key,value in original.items(): (artifact/key).write_bytes(value)
                self.calls.write_text('')
                path=artifact/'finops-readiness.json'
                manifest=json.loads((artifact/'plan-identity.json').read_text())
                env=self.env.copy()
                if case=='missing': path.unlink()
                elif case=='contract': (artifact/'finops-contract.json').write_bytes(original['finops-contract.json']+b' ')
                elif case=='readiness': path.write_bytes(original[path.name]+b' ')
                elif case=='trusted-digest': env['FINOPS_CONTRACT_SHA256']='sha256:'+'0'*64
                else:
                    r=json.loads(path.read_text())
                    if case in ('account','region','platform','billing'):
                        key={'account':'accountId','region':'region','platform':'platformInstanceId','billing':'billingAccountId'}[case]
                        r[key]='wrong'
                    elif case=='stale': r['observedAt']='2020-01-01T00:00:00Z'
                    elif case=='ttl': r['expiresAt']='2099-01-01T00:00:00Z'
                    elif case=='management': r['monitoringIdentity']['managementAccountId']='999999999999'
                    elif case=='principal': r['monitoringIdentity']['principalArn']='arn:aws:sts::999999999999:assumed-role/Billing/readiness'
                    else: r['bindings']['collectorSha256']='sha256:'+'0'*64
                    path.write_text(json.dumps(r))
                    manifest['finops']['readinessSha256']='sha256:'+hashlib.sha256(path.read_bytes()).hexdigest()
                    (artifact/'plan-identity.json').write_text(json.dumps(manifest))
                result=self.verify(env)
                self.assertNotEqual(result.returncode,0,case)
                self.assertIn('FINOPS',result.stderr)
                self.assertEqual(self.calls.read_text(),'',case)

    def test_live_configuration_is_rechecked_after_plan_and_fail_closed(self):
        self.approved()
        o=json.loads(self.observations.read_text()); o['costTags'][0]['Status']='Inactive'
        self.observations.write_text(json.dumps(o))
        result=self.verify()
        self.assertNotEqual(result.returncode,0,'inactive cost tag accepted after plan')
        self.assertIn('FINOPS',result.stderr)
        self.assertEqual(self.calls.read_text(),'')

    def test_fixture_can_never_be_used_in_github_lane(self):
        env={**self.env,'GITHUB_ACTIONS':'true'}
        result=self.create(env=env)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls.read_text(),'')

    def test_runtime_lane_rejects_fixture_artifact_without_runtime_calls(self):
        self.approved()
        env={k:v for k,v in self.env.items() if k not in ('FINOPS_FIXTURE_JSON','COURSE_CHECK_BIN_DIR')}
        env.update(GITHUB_ACTIONS='true',FINOPS_BILLING_ROLE_ARN='arn:aws:iam::123456789012:role/Billing')
        result=self.verify(env)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('schema/source mismatch',result.stderr)
        self.assertEqual(self.calls.read_text(),'')

    def test_dev_and_destroy_need_no_finops(self):
        env={k:v for k,v in self.env.items() if not k.startswith('FINOPS_')}
        for scope,operation in [('dev','apply'),('prod','destroy')]:
            with self.subTest(scope=scope,operation=operation):
                result=self.create(scope,operation,env)
                self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__': unittest.main()
