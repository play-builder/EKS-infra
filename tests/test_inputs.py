"""Verify private root inputs: reject foreign identities, unsafe paths and secret disclosure."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / 'scripts/lib/project-terraform-inputs.py'
ROOTS = [f'environments/{env}/{layer}' for env in ('dev', 'prod')
         for layer in ('01-network', '02-eks', '03-platform', '04-workloads/argocd')]
ROOTS += ['environments/prod/03-database', 'environments/recovery/03-database']



class Projection(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name)
        self.selected = ROOTS[1]
        for root in ROOTS:
            (self.workspace / root).mkdir(parents=True)
        self.env = dict(os.environ, GITHUB_WORKSPACE=str(self.workspace), TF_ROOT=self.selected,
                        AWS_REGION='us-east-1', AWS_ACCOUNT_ID='123456789012',
                        BACKEND_BUCKET='approved-state-bucket', PYTHONDONTWRITEBYTECODE='1')

    def inputs(self, root):
        value = {'aws_region': 'us-east-1', 'private_value': 'SECRET_SENTINEL'}
        if root.endswith('03-database'):
            value.update(state_bucket='approved-state-bucket', state_region='us-east-1',
                         expected_account_id='123456789012')
        elif not root.endswith('01-network'):
            value['state_bucket_name'] = 'approved-state-bucket'
        return value

    def run_helper(self, action='plan', document=None, selected=None):
        if selected is not None:
            self.env['TF_ROOT'] = selected
        if document is None:
            document = {self.env['TF_ROOT']: self.inputs(self.env['TF_ROOT'])}
        self.env['TERRAFORM_PLAN_INPUTS_JSON'] = json.dumps(document)
        self.env['TERRAFORM_DRIFT_INPUTS_JSON'] = json.dumps(document)
        return subprocess.run([sys.executable, '-B', str(HELPER), action], env=self.env,
                              text=True, capture_output=True)

    def assert_denied(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SECRET_SENTINEL', result.stdout + result.stderr)

    def test_all_ten_roots_project_only_selected_inputs_privately_for_both_lanes(self):
        self.assertTrue(HELPER.is_file(), 'root input projection helper missing')
        for action in ('plan', 'drift'):
            for root in ROOTS:
                with self.subTest(action=action, root=root):
                    data = {r: self.inputs(r) for r in ROOTS}
                    result = self.run_helper(action, data, root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    target = self.workspace / root / 'terraform.tfvars.json'
                    self.assertEqual(json.loads(target.read_text()), data[root])
                    self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                    self.assertNotIn('SECRET_SENTINEL', result.stdout + result.stderr)
                    self.assertEqual(self.run_helper('cleanup').returncode, 0)
                    self.assertFalse(target.exists())

    def test_identity_missing_foreign_and_unknown_inputs_fail_before_write(self):
        cases = [{}, {self.selected: {}}, {self.selected: []}, {'../outside': {}},
                 {self.selected: self.inputs(self.selected), '../outside': {}}]
        for field, value in [('aws_region', 'ap-northeast-2'), ('state_bucket_name', 'foreign'),
                             ('expected_account_id', '999999999999')]:
            data = self.inputs(self.selected); data[field] = value
            cases.append({self.selected: data})
        for field in ('aws_region', 'state_bucket_name'):
            data = self.inputs(self.selected); del data[field]
            cases.append({self.selected: data})
        for data in cases:
            with self.subTest(data=data):
                self.assert_denied(self.run_helper(document=data))
                self.assertFalse((self.workspace / self.selected / 'terraform.tfvars.json').exists())
        for root in ('../outside', '/tmp', 'environments/prod/00-finops', 'terraform/platform-backup'):
            self.assert_denied(self.run_helper(selected=root))

    def test_database_requires_exact_all_three_identity_fields(self):
        root = 'environments/recovery/03-database'
        for field in ('state_bucket', 'state_region', 'expected_account_id'):
            for missing in (True, False):
                data = self.inputs(root)
                if missing: del data[field]
                else: data[field] = 'foreign'
                self.assert_denied(self.run_helper(document={root: data}, selected=root))
                self.assertFalse((self.workspace / root / 'terraform.tfvars.json').exists())

    def test_existing_files_symlinks_and_symlinked_root_components_are_untouched(self):
        output = self.workspace / self.selected / 'terraform.tfvars.json'
        sentinel = self.workspace / 'sentinel'; sentinel.write_text('DO_NOT_CHANGE')
        output.write_text('DO_NOT_CHANGE')
        self.assert_denied(self.run_helper())
        self.assertEqual(output.read_text(), 'DO_NOT_CHANGE')
        output.unlink(); output.symlink_to(sentinel)
        self.assert_denied(self.run_helper())
        self.assertEqual(sentinel.read_text(), 'DO_NOT_CHANGE')
        output.unlink()
        directory = self.workspace / 'environments/dev'
        directory.rename(self.workspace / 'relocated')
        directory.symlink_to(self.workspace / 'relocated', target_is_directory=True)
        self.assert_denied(self.run_helper())
        self.assertFalse((self.workspace / 'relocated/02-eks/terraform.tfvars.json').exists())

    def test_invalid_json_duplicate_keys_and_missing_fixed_secret_never_print_inputs(self):
        for raw in ('SECRET_SENTINEL', '{"x":1,"x":2}', 'NaN'):
            self.env['TERRAFORM_PLAN_INPUTS_JSON'] = raw
            result = subprocess.run([sys.executable, '-B', str(HELPER), 'plan'], env=self.env,
                                    text=True, capture_output=True)
            self.assert_denied(result)
        self.env.pop('TERRAFORM_PLAN_INPUTS_JSON', None)
        self.env['TERRAFORM_DRIFT_INPUTS_JSON'] = json.dumps({self.selected: self.inputs(self.selected)})
        result = subprocess.run([sys.executable, '-B', str(HELPER), 'plan'], env=self.env,
                                text=True, capture_output=True)
        self.assert_denied(result)

    def test_expected_identity_and_workspace_cannot_be_omitted_or_redirected(self):
        for key, value in [('AWS_ACCOUNT_ID', ''), ('AWS_ACCOUNT_ID', 'not-an-account'),
                           ('AWS_REGION', 'eu-west-1'), ('BACKEND_BUCKET', '../outside'),
                           ('GITHUB_WORKSPACE', 'relative-workspace')]:
            previous = self.env[key]
            self.env[key] = value
            self.assert_denied(self.run_helper())
            self.env[key] = previous
        self.assertFalse((self.workspace / self.selected / 'terraform.tfvars.json').exists())


if __name__ == "__main__":
    unittest.main()
