import base64
import datetime as dt
import hashlib
import importlib.util
import pathlib
import types
import unittest
from unittest.mock import patch

import boto3
from botocore.stub import Stubber
import yaml

HERE=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('backup_tests',HERE/'argocd-backup-contract.py')
support=importlib.util.module_from_spec(spec);spec.loader.exec_module(support)
backup=support.backup


class BackupSDK(unittest.TestCase):
    def test_real_botocore_put_and_head_accept_wire_contract(self):
        s3=boto3.client('s3',region_name='us-east-1',aws_access_key_id='LOCAL_TEST_ACCESS',aws_secret_access_key='LOCAL_TEST_SECRET')
        contract={'bucket':'commerce-backup','accountId':'123456789012','kmsKeyArn':'arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012'}
        source={'clusterArn':'arn:aws:eks:us-east-1:123456789012:cluster/prod','argocdVersion':'3.5.2','namespace':'argocd','gitopsRevision':'a'*40}
        body=backup.encode_objects(backup.sanitize(support.objects()))
        checksum=base64.b64encode(hashlib.sha256(body).digest()).decode()
        key='argocd/'+'a'*32+'.yaml'
        upload={'Bucket':contract['bucket'],'Key':key,'Body':body,'ExpectedBucketOwner':contract['accountId'],'IfNoneMatch':'*','ServerSideEncryption':'aws:kms','SSEKMSKeyId':contract['kmsKeyArn'],'ChecksumSHA256':checksum,'ContentType':'application/yaml','Metadata':{'source-sha256':backup.source_hash(source)}}
        head={'VersionId':'v1','SSEKMSKeyId':contract['kmsKeyArn'],'ServerSideEncryption':'aws:kms','ContentLength':len(body),'ChecksumSHA256':checksum,'ObjectLockMode':'GOVERNANCE','ObjectLockRetainUntilDate':backup.utcnow()+dt.timedelta(days=120),'Metadata':upload['Metadata']}
        with Stubber(s3) as stub:
            stub.add_response('put_object',{'VersionId':'v1'},upload)
            stub.add_response('head_object',head,{'Bucket':contract['bucket'],'Key':key,'VersionId':'v1','ExpectedBucketOwner':contract['accountId'],'ChecksumMode':'ENABLED'})
            with patch.object(backup.uuid,'uuid4',return_value=types.SimpleNamespace(hex='a'*32)):
                record=backup.store_export(contract,source,support.objects(),s3)
            stub.assert_no_pending_responses()
        self.assertEqual(record['payload']['key'],key)

    def test_yaml_stream_becomes_secret_free_valid_import_stream(self):
        raw=yaml.safe_dump_all(support.objects())
        result=backup.sanitize(list(yaml.safe_load_all(raw)))
        encoded=backup.encode_objects(result)
        self.assertNotIn(b'SECRET_SENTINEL',encoded)
        self.assertEqual(list(yaml.safe_load_all(encoded)),result)
        with self.assertRaises(yaml.YAMLError): list(yaml.safe_load_all('!!python/object/apply:os.system ["echo unsafe"]'))


if __name__=='__main__': unittest.main()
