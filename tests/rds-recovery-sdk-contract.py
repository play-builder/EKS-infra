#!/usr/bin/env python3
"""Offline botocore-shaped regression at the real recovery collector CLI boundary."""
import datetime as dt
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import boto3
from botocore.stub import Stubber

sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('rds_support',pathlib.Path(__file__).with_name('rds-test-support.py'))
support=importlib.util.module_from_spec(spec);spec.loader.exec_module(support)
rds=support.load('rds-recovery')


class Clock(dt.datetime):
    @classmethod
    def now(cls,tz=None): return cls(2026,9,5,0,25,tzinfo=dt.timezone.utc)


class RecoverySDK(unittest.TestCase):
    def test_actual_collector_uses_sdk_valid_dbinstance_and_automated_backup_shapes(self):
        source,target=support.pair(rds)
        c=target['contract'];s=source['contract']
        session=boto3.Session(aws_access_key_id='TESTACCESSKEY',aws_secret_access_key='TESTSECRET',region_name=c['region'])
        clients={name:session.client(name) for name in ('sts','rds','secretsmanager','cloudtrail')}
        stubs={name:Stubber(client) for name,client in clients.items()}
        self.assertNotIn('EarliestRestorableTime',clients['rds'].meta.service_model.shape_for('DBInstance').members)
        stubs['sts'].add_response('get_caller_identity',{'Account':c['accountId'],'Arn':'arn:aws:sts::123456789012:assumed-role/operator/session','UserId':'LOCALTEST'}, {})
        stubs['rds'].add_response('describe_db_instances',{'DBInstances':[target['instance']]},{'DBInstanceIdentifier':c['identifier']})
        stubs['secretsmanager'].add_response('get_secret_value',{'ARN':c['masterSecretArn'],'SecretString':json.dumps({'username':c['masterUsername'],'password':'SDK_SECRET_SENTINEL'})},{'SecretId':c['masterSecretArn']})
        stubs['rds'].add_response('describe_db_instances',{'DBInstances':[source['instance']]},{'DBInstanceIdentifier':s['identifier']})
        stubs['rds'].add_response('describe_db_instance_automated_backups',target['sourceAutomatedBackups'],{'DbiResourceId':s['resourceId']})
        stubs['cloudtrail'].add_response('lookup_events',{'Events':[{'EventId':'event-123','EventName':'RestoreDBInstanceToPointInTime',
            'CloudTrailEvent':json.dumps(target['restoreEvent'])}]},{'LookupAttributes':[{'AttributeKey':'ResourceName','AttributeValue':c['identifier']}],'StartTime':'2026-09-05T00:15:00Z'})
        for stub in stubs.values(): stub.activate()
        calls=[]
        def external(args,**kwargs):
            calls.append(args)
            if args[0]=='psql':
                payload=target['sql'].copy();payload['serverAt']='2026-09-05T00:25:00Z'
            else:
                self.assertEqual(args[:5],['aws','--region','us-east-1','--no-cli-pager',args[4]])
                operation=args[5]
                if operation=='get-caller-identity': payload=clients['sts'].get_caller_identity()
                elif operation=='describe-db-instances': payload=clients['rds'].describe_db_instances(DBInstanceIdentifier=args[args.index('--db-instance-identifier')+1])
                elif operation=='describe-db-instance-automated-backups': payload=clients['rds'].describe_db_instance_automated_backups(DbiResourceId=args[args.index('--dbi-resource-id')+1])
                elif operation=='get-secret-value': payload=clients['secretsmanager'].get_secret_value(SecretId=args[args.index('--secret-id')+1])
                elif operation=='lookup-events':
                    self.assertEqual(args[args.index('--lookup-attributes')+1],'AttributeKey=ResourceName,AttributeValue='+c['identifier'])
                    payload=clients['cloudtrail'].lookup_events(LookupAttributes=[{'AttributeKey':'ResourceName','AttributeValue':c['identifier']}],StartTime=args[args.index('--start-time')+1])
                else: self.fail('unapproved external operation')
            return subprocess.CompletedProcess(args,0,json.dumps(payload,default=lambda v:v.isoformat()),'')
        with tempfile.TemporaryDirectory(prefix='rds-sdk-') as directory:
            directory=pathlib.Path(directory)
            for name,data in [('source.json',source),('contract.json',c)]: (directory/name).write_text(json.dumps(data))
            (directory/'ca.pem').write_text('LOCAL_FAKE_CA')
            argv=['rds-recovery','--capture','--source',str(directory/'source.json'),'--contract',str(directory/'contract.json'),
                  '--ca',str(directory/'ca.pem'),'--incident-at','2026-09-05T00:15:00Z','--target',str(directory/'target.json'),'--output',str(directory/'result.json')]
            output=io.StringIO()
            with patch.object(rds.db.subprocess,'run',side_effect=external),patch.object(rds.dt,'datetime',Clock),patch.object(sys,'argv',argv),redirect_stdout(output):
                self.assertEqual(rds.main(),0)
            result=json.loads((directory/'result.json').read_text())
            self.assertEqual(result['achieved'],{'rpoMinutes':15,'rtoMinutes':10})
            self.assertNotIn('SDK_SECRET_SENTINEL',output.getvalue()+json.dumps(calls))
            observed=json.loads((directory/'target.json').read_text())
            self.assertEqual(observed['sourceAutomatedBackups']['DBInstanceAutomatedBackups'][0]['DbiResourceId'],s['resourceId'])
        for stub in stubs.values(): stub.assert_no_pending_responses()


if __name__=='__main__': unittest.main()
