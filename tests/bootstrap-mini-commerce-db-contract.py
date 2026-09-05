import json
import os
import pathlib
import subprocess
import tempfile
import unittest
import importlib.util
from unittest.mock import patch

support_spec = importlib.util.spec_from_file_location('rds_support', pathlib.Path(__file__).with_name('rds-test-support.py'))
support = importlib.util.module_from_spec(support_spec)
support_spec.loader.exec_module(support)
bootstrap = support.load('rds-bootstrap')

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/bootstrap-mini-commerce-db.sh'


class Bootstrap(unittest.TestCase):
    def test_marker_preparation_requires_an_explicit_output(self):
        result=subprocess.run(['bash',str(SCRIPT),'--execute','--prepare-marker'],capture_output=True,text=True)
        self.assertEqual(result.returncode,2)
        self.assertIn('PENDING',result.stdout)

    def test_real_bootstrap_boundaries_keep_passwords_out_of_argv_and_isolate_roles(self):
        c = support.contract(True)
        invocations, sql, publications = [], [], []

        def external(args, **kwargs):
            invocations.append(args)
            result = {}
            if args[0] == 'psql':
                env = kwargs['env']
                self.assertEqual(env['PGSSLMODE'], 'verify-full')
                self.assertNotIn('PGPASSWORD', env)
                self.assertEqual(pathlib.Path(env['PGPASSFILE']).stat().st_mode & 0o777, 0o600)
                self.assertIn('MASTER_SENTINEL', pathlib.Path(env['PGPASSFILE']).read_text())
                sql.append(kwargs['input'])
                return subprocess.CompletedProcess(args, 0, '', '')
            if 'get-caller-identity' in args:
                result = {'Account':c['accountId'],'Arn':'arn:aws:sts::123456789012:assumed-role/operator/session'}
            elif 'describe-db-instances' in args:
                result = {'DBInstances':[support.instance(c)]}
            elif 'describe-secret' in args:
                arn = args[args.index('--secret-id')+1]
                m = next(m for m in c['applicationCredentials'].values() if m['arn'] == arn)
                result = {'ARN':arn,'Name':m['name'],'VersionIdsToStages':{}}
            elif 'get-secret-value' in args:
                self.assertEqual(args[args.index('--secret-id')+1], c['masterSecretArn'])
                result = {'SecretString':json.dumps({'username':'platform_admin','password':'MASTER_SENTINEL'})}
            elif 'put-secret-value' in args:
                path = pathlib.Path(args[args.index('--secret-string')+1].removeprefix('file://'))
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                publications.append((args[args.index('--secret-id')+1],json.loads(path.read_text())))
            else:
                self.fail('unexpected external command')
            return subprocess.CompletedProcess(args, 0, json.dumps(result), '')

        with tempfile.TemporaryDirectory() as directory:
            ca = pathlib.Path(directory)/'ca.pem'
            ca.write_text('LOCAL_FAKE_CA')
            with patch.object(bootstrap.subprocess, 'run', side_effect=external):
                bootstrap.bootstrap(c,ca)
        self.assertEqual(len(sql),1)
        self.assertIn('NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',sql[0])
        self.assertIn('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM commerce_runtime',sql[0])
        self.assertIn("ARRAY['products','inventory','orders','order_items']",sql[0])
        self.assertNotIn('GRANT SELECT, INSERT, UPDATE, DELETE',sql[0])
        self.assertEqual({p[1]['DB_USER'] for p in publications},{'commerce_runtime','commerce_migration'})
        self.assertTrue(all(p[1]['DB_HOST']==c['endpoint'] for p in publications))
        self.assertNotIn('MASTER_SENTINEL', json.dumps(invocations)+json.dumps(publications))
        for _,publication in publications:
            self.assertNotIn(publication['DB_PASSWORD'],json.dumps(invocations))

    def test_rejects_shell_values_that_alias_the_master_secret(self):
        c = support.contract()
        c['applicationCredentials']['database']['arn'] = c['masterSecretArn']
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)/'contract.json'
            path.write_text(json.dumps(c))
            with self.assertRaises(bootstrap.Denied): bootstrap.contract(path)

    def test_rejects_empty_master_password_before_sql(self):
        c = support.contract()
        calls=[]
        def external(args, **kwargs):
            calls.append(args)
            if 'get-caller-identity' in args: result={'Account':c['accountId'],'Arn':'arn:aws:sts::123456789012:assumed-role/a/b'}
            elif 'describe-db-instances' in args: result={'DBInstances':[support.instance(c)]}
            elif 'get-secret-value' in args: result={'SecretString':json.dumps({'username':'platform_admin','password':''})}
            else: raise AssertionError('must reject before additional commands')
            return subprocess.CompletedProcess(args,0,json.dumps(result),'')
        with patch.object(bootstrap.subprocess,'run',side_effect=external):
            with self.assertRaises(bootstrap.Denied): bootstrap.bootstrap(c,'/nonexistent-ca')

    def test_missing_explicit_execution_is_denied(self):
        result = subprocess.run(['bash', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('PENDING', result.stdout)

    def test_xtrace_never_discloses_input_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'invalid.json'
            path.write_text(json.dumps({'password': 'SENTINEL_NEVER_LOG_12345'}))
            result = subprocess.run(['bash', '-x', str(SCRIPT), '--execute', '--contract', str(path)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('SENTINEL_NEVER_LOG_12345', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
