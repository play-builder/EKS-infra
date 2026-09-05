import pathlib
import subprocess
import unittest
import datetime as dt
import importlib.util
import json
import tempfile
from unittest.mock import patch

support_spec = importlib.util.spec_from_file_location('rds_support', pathlib.Path(__file__).with_name('rds-test-support.py'))
support = importlib.util.module_from_spec(support_spec)
support_spec.loader.exec_module(support)
rds = support.load('rds-recovery')

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Recovery(unittest.TestCase):
    def test_capture_runs_account_rds_and_read_only_tls_sql_boundaries(self):
        source,_=support.pair(rds)
        c=source['contract']
        calls=[]
        def external(args,**kwargs):
            calls.append(args)
            if args[0]=='psql':
                self.assertIn('default_transaction_read_only=on',kwargs['env']['PGOPTIONS'])
                self.assertEqual(kwargs['env']['PGSSLMODE'],'verify-full')
                self.assertIn('public.order_items',kwargs['input'])
                self.assertIn('public.inventory',kwargs['input'])
                self.assertNotIn('CREATE ',kwargs['input'])
                sql=source['sql'].copy(); sql['serverAt']=rds.now()
                result=sql
            elif 'get-caller-identity' in args: result={'Account':c['accountId'],'Arn':'arn:aws:sts::123456789012:assumed-role/a/b'}
            elif 'describe-db-instances' in args: result={'DBInstances':[support.instance(c)]}
            elif 'get-secret-value' in args: result={'SecretString':json.dumps({'username':'platform_admin','password':'SQL_SECRET_SENTINEL'})}
            else: self.fail('unexpected command')
            return subprocess.CompletedProcess(args,0,json.dumps(result),'')
        with tempfile.TemporaryDirectory() as directory:
            ca=pathlib.Path(directory)/'ca'; ca.write_text('LOCAL_FAKE_CA')
            with patch.object(rds.db.subprocess,'run',side_effect=external):
                observation=rds.capture(c,ca)
        self.assertEqual(len(calls),4)
        self.assertEqual(observation['sql']['orders'],2)
        self.assertNotIn('SQL_SECRET_SENTINEL',json.dumps(observation)+json.dumps(calls))

    def check(self, source, target):
        return rds.evaluate(source, target, '2026-09-05T00:15:00Z', current=dt.datetime(2026,9,5,1,tzinfo=dt.timezone.utc))

    def test_conservative_commit_interval_derives_rpo_and_rto(self):
        result = self.check(*support.pair(rds))
        self.assertEqual(result['achieved'], {'rpoMinutes':15,'rtoMinutes':15})
        self.assertEqual(result['evidenceGrade'], 'LOCAL_VERIFIED')

    def test_rejects_raw_grade_inflation(self):
        source,target = support.pair(rds)
        target['evidenceGrade'] = 'CLOUD_RUNTIME'
        with self.assertRaises(rds.db.Denied): self.check(source,target)

    def test_requires_actual_restore_api_event_identity(self):
        source,target=support.pair(rds)
        target.pop('restoreEvent',None)
        with self.assertRaises((rds.db.Denied,KeyError)): self.check(source,target)

    def test_rejects_identity_time_integrity_and_convergence_changes(self):
        changes = [
            lambda s,t: t['contract'].update(identifier='commerce-source'),
            lambda s,t: t.update(completedAt='2026-09-05T02:00:00Z'),
            lambda s,t: t.update(startedAt='2026-09-05T00:14:00Z'),
            lambda s,t: t['sql'].update(items=4),
            lambda s,t: t['sql'].update(negativeStock=1),
            lambda s,t: t['sql'].update(orphanItems=1),
            lambda s,t: t['sql'].update(invalidTotals=1),
            lambda s,t: t['sql'].update(duplicateIdempotency=1),
            lambda s,t: t['sql'].update(markers=[]),
            lambda s,t: t['sql']['markers'][0].update(seq=2),
            lambda s,t: t['instance'].update(PendingModifiedValues={'BackupRetentionPeriod':35}),
            lambda s,t: t['instance'].update(CACertificateIdentifier='old-ca'),
            lambda s,t: t['contract']['objectives'].update(rpoMinutes=10),
            lambda s,t: t['contract']['objectives'].update(rtoMinutes=10),
            lambda s,t: s.update(markerTranscript=s['markerTranscript'].replace('COMMIT','ROLLBACK')),
        ]
        for index, change in enumerate(changes):
            with self.subTest(case=index):
                source,target = support.pair(rds)
                change(source,target)
                with self.assertRaises(rds.db.Denied): self.check(source,target)

    def test_missing_capture_is_explicitly_pending(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/rds-recovery-check.sh')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('PENDING', result.stdout)
        self.assertNotIn('CLOUD_RUNTIME', result.stdout)


if __name__ == '__main__':
    unittest.main()
