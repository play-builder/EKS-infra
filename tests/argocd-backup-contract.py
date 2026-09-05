import copy
import importlib.util
import pathlib
import unittest
import hashlib
import base64
import datetime as dt
import subprocess
import io
from unittest.mock import Mock, patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('argocd_backup', ROOT / 'scripts/lib/argocd-backup.py')
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


def objects():
    return [
        {'apiVersion':'v1','kind':'Secret','metadata':{'name':'argocd-secret'},'data':{'password':'SECRET_SENTINEL'}},
        {'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'argocd-cm'},'data':{'url':'https://argocd.example.com','oidc.config':'clientSecret: $argocd-oidc:clientSecret'}},
        {'apiVersion':'argoproj.io/v1alpha1','kind':'AppProject','metadata':{'name':'platform'},'spec':{'destinations':[{'server':'https://kubernetes.default.svc','namespace':'app-prod'}]}},
        {'apiVersion':'argoproj.io/v1alpha1','kind':'Application','metadata':{'name':'mini-commerce-prod','finalizers':['resources-finalizer.argocd.argoproj.io'],'annotations':{'kubectl.kubernetes.io/last-applied-configuration':'SECRET_SENTINEL'}},'spec':{'source':{'repoURL':'https://github.com/play-builder/argocd-gitops','targetRevision':'main','path':'envs/prod'},'destination':{'server':'https://kubernetes.default.svc','namespace':'app-prod'},'syncPolicy':{'automated':{'prune':True}}},'status':{'sync':{'revision':'a'*40}},'operation':{'sync':{}}},
        {'apiVersion':'argoproj.io/v1alpha1','kind':'ApplicationSet','metadata':{'name':'platform'},'spec':{'generators':[{'list':{'elements':[]}}]}},
    ]


class BackupContract(unittest.TestCase):
    def test_import_is_paused_scoped_and_post_verified(self):
        expected=backup.restore_objects(backup.sanitize(objects()),'argocd')
        calls=[]
        def run(args,**kwargs):
            calls.append(args)
            if args[0]=='argocd':
                self.assertNotIn('--prune',args)
                self.assertNotIn('--override-on-conflict',args)
                self.assertNotIn(b'"automated"',kwargs['input'])
                return b'import completed'
            if 'applications' in args: return b'{"items":[]}'
            obj=next(x for x in expected if x['kind']==args[-4] and x['metadata']['name']==args[-3])
            return __import__('json').dumps(obj).encode()
        receipt=backup.import_archive(objects(),'recovery-context','argocd',run)
        self.assertEqual(receipt['applicationNames'],['mini-commerce-prod'])
        self.assertEqual(len(calls),4)

    def test_rehydration_rejects_empty_and_stale_conditions_without_secret_reads(self):
        names=['argocd-oidc','argocd-notifications-secret','argocd-repository-credentials']
        now=dt.datetime(2026,9,5,1,tzinfo=dt.timezone.utc)
        clock=patch.object(backup,'utcnow',return_value=now)
        clock.start()
        self.addCleanup(clock.stop)
        items=[{'metadata':{'name':n,'generation':2,'creationTimestamp':'2026-09-05T00:00:00Z'},'status':{'syncedResourceVersion':'2-abc123','refreshTime':'2026-09-05T00:59:00Z','conditions':[{'type':'Ready','status':'True','reason':'SecretSynced','message':'secret synced'}]}} for n in names]
        def run(args,**kwargs):
            self.assertIn('externalsecrets',args)
            self.assertNotIn('secrets',args)
            return __import__('json').dumps({'items':items}).encode()
        backup.rehydrated_secrets(run,'recovery','argocd')
        original=copy.deepcopy(items[0])
        for mutate in [lambda x:x['status'].update(syncedResourceVersion='1-abc123'),lambda x:x['status'].update(syncedResourceVersion='20-abc123'),lambda x:x['status'].update(syncedResourceVersion='2-'),lambda x:x['status'].update(refreshTime=''),lambda x:x['status'].update(refreshTime='2026-09-04T00:00:00Z'),lambda x:x['status'].update(refreshTime='2026-09-05T02:00:00Z'),lambda x:x['status']['conditions'][0].update(reason='SecretDeleted'),lambda x:x['status']['conditions'][0].update(message='secret retained due to DeletionPolicy=Retain'),lambda x:x['status']['conditions'][0].update(status='False'),lambda x:x['metadata'].update(deletionTimestamp='2026-09-05T00:59:59Z')]:
            items[0]=copy.deepcopy(original)
            mutate(items[0])
            with self.assertRaises(backup.Denied): backup.rehydrated_secrets(run,'recovery','argocd')
        items.clear()
        with self.assertRaises(backup.Denied): backup.rehydrated_secrets(run,'recovery','argocd')
    def test_cli_requires_explicit_action_before_external_access(self):
        result=subprocess.run(['python3',str(ROOT/'scripts/lib/argocd-backup.py'),'--help'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0)
        self.assertIn('export',result.stdout)
        result=subprocess.run(['python3',str(ROOT/'scripts/lib/argocd-backup.py'),'export'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
    def test_cluster_identity_requires_matching_endpoint_and_ready_pinned_server(self):
        arn='arn:aws:eks:us-east-1:123456789012:cluster/prod'
        eks=Mock();eks.describe_cluster.return_value={'cluster':{'arn':arn,'status':'ACTIVE','endpoint':'https://eks.example.com'}}
        config={'clusters':[{'cluster':{'server':'https://eks.example.com'}}]}
        deploy={'spec':{'replicas':2,'template':{'spec':{'containers':[{'name':'argocd-server','image':'quay.io/argoproj/argocd:v3.5.2'}]}}},'status':{'readyReplicas':2,'observedGeneration':1},'metadata':{'generation':1}}
        def run(args,**kwargs):
            if args[:3]==['argocd','version','--client']: return b'argocd: v3.5.2+abc\n'
            if 'config' in args: return __import__('json').dumps(config).encode()
            return __import__('json').dumps(deploy).encode()
        self.assertEqual(backup.cluster_identity(eks,run,'course-prod',arn,'argocd'),'3.5.2')
        for mutate in [lambda:config['clusters'][0]['cluster'].update(server='https://other.example.com'),lambda:deploy['status'].update(readyReplicas=0)]:
            config['clusters'][0]['cluster']['server']='https://eks.example.com'
            deploy['status']['readyReplicas']=2
            mutate()
            with self.assertRaises(backup.Denied): backup.cluster_identity(eks,run,'course-prod',arn,'argocd')
    def test_export_upload_is_secret_free_nonclobber_and_reads_exact_version(self):
        contract={'bucket':'commerce-backup','accountId':'123456789012','kmsKeyArn':'arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012'}
        source={'clusterArn':'arn:aws:eks:us-east-1:123456789012:cluster/prod','argocdVersion':'3.5.2','namespace':'argocd','gitopsRevision':'a'*40}
        client=Mock()
        def put(**kwargs):
            self.assertEqual(kwargs['IfNoneMatch'],'*')
            self.assertEqual(kwargs['ServerSideEncryption'],'aws:kms')
            self.assertNotIn(b'SECRET_SENTINEL',kwargs['Body'])
            client.head_object.return_value={'VersionId':'v1','SSEKMSKeyId':contract['kmsKeyArn'],'ServerSideEncryption':'aws:kms','ContentLength':len(kwargs['Body']),'ChecksumSHA256':kwargs['ChecksumSHA256'],'ObjectLockMode':'GOVERNANCE','ObjectLockRetainUntilDate':backup.utcnow()+dt.timedelta(days=120),'Metadata':kwargs['Metadata']}
            return {'VersionId':'v1'}
        client.put_object.side_effect=put
        result=backup.store_export(contract,source,objects(),client)
        self.assertEqual(result.get('schemaVersion'),'platform.argocd-dr/v1')
        self.assertEqual(result['payload']['versionId'],'v1')
        self.assertIsNone(result['restored'])
        self.assertNotEqual(result['evidenceGrade'],'CLOUD_RUNTIME')
        self.assertEqual(client.head_object.call_args.kwargs['VersionId'],'v1')
    def test_storage_requires_actual_private_versioned_kms_object_lock(self):
        contract={'schemaVersion':'platform.backup-storage/v1','accountId':'123456789012','region':'us-east-1','bucket':'commerce-backup','prefix':'argocd/','kmsKeyArn':'arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012','retentionDays':120,'objectLockMode':'GOVERNANCE'}
        observations={'accountId':'123456789012','region':'us-east-1','versioning':{'Status':'Enabled'},'lock':{'ObjectLockConfiguration':{'ObjectLockEnabled':'Enabled','Rule':{'DefaultRetention':{'Mode':'GOVERNANCE','Days':120}}}},'encryption':{'ServerSideEncryptionConfiguration':{'Rules':[{'ApplyServerSideEncryptionByDefault':{'SSEAlgorithm':'aws:kms','KMSMasterKeyID':contract['kmsKeyArn']},'BucketKeyEnabled':False}]}},'public':{'PublicAccessBlockConfiguration':dict.fromkeys(['BlockPublicAcls','BlockPublicPolicy','IgnorePublicAcls','RestrictPublicBuckets'],True)},'policy':{'PolicyStatus':{'IsPublic':False}},'ownership':{'OwnershipControls':{'Rules':[{'ObjectOwnership':'BucketOwnerEnforced'}]}}}
        self.assertEqual(backup.validate_storage(contract,observations),contract)
        for mutate in [lambda o:o.update(accountId='999999999999'),lambda o:o.update(region='ap-northeast-2'),lambda o:o['versioning'].update(Status='Suspended'),lambda o:o['lock']['ObjectLockConfiguration']['Rule']['DefaultRetention'].update(Days=1),lambda o:o['public']['PublicAccessBlockConfiguration'].update(BlockPublicPolicy=False),lambda o:o['policy']['PolicyStatus'].update(IsPublic=True),lambda o:o['encryption']['ServerSideEncryptionConfiguration']['Rules'][0].update(BucketKeyEnabled=True)]:
            observed=copy.deepcopy(observations); mutate(observed)
            with self.assertRaises(backup.Denied): backup.validate_storage(contract,observed)
    def test_secrets_and_live_state_never_reach_archive(self):
        result = backup.sanitize(objects())
        self.assertNotIn('SECRET_SENTINEL', str(result))
        self.assertEqual([x['kind'] for x in result], ['ConfigMap','AppProject','Application','ApplicationSet'])
        self.assertNotIn('status', result[2])
        self.assertNotIn('operation', result[2])

    def test_inline_credentials_in_nonsecret_resources_are_rejected(self):
        values = ['clientSecret: plaintext-secret', 'password: plaintext', '{"DB_PASSWORD":"plaintext"}', 'https://user:pass@example.com/repo', '-----BEGIN PRIVATE KEY-----']
        for value in values:
            with self.subTest(value=value):
                docs = objects()
                docs[1]['data']['injected'] = value
                with self.assertRaises(backup.Denied): backup.sanitize(docs)
        docs=objects()
        docs[3]['spec']['source']['helm']={'parameters':[{'name':'DB_PASSWORD','value':'plaintext'}]}
        with self.assertRaises(backup.Denied): backup.sanitize(docs)

    def test_empty_or_foreign_export_is_not_a_backup(self):
        for docs in [[], [objects()[0]], [{'apiVersion':'v1','kind':'Pod','metadata':{'name':'bad'}}]]:
            with self.subTest(docs=docs):
                with self.assertRaises(backup.Denied): backup.sanitize(docs)

    def test_restore_rehydrates_platform_instead_of_overwriting_it(self):
        result = backup.restore_objects(backup.sanitize(objects()), 'argocd')
        self.assertEqual([x['kind'] for x in result], ['AppProject','Application'])
        app = result[1]
        self.assertNotIn('automated', app['spec']['syncPolicy'])
        self.assertNotIn('finalizers', app['metadata'])
        self.assertEqual(app['metadata']['namespace'], 'argocd')

    def test_restore_rejects_cross_cluster_and_namespace(self):
        for mutate in [lambda d:d[3]['spec']['destination'].update(server='https://prod.example.com'),lambda d:d[3]['metadata'].update(namespace='other-argocd'),lambda d:d[2]['spec']['destinations'][0].update(server='*')]:
            docs = objects(); mutate(docs)
            with self.assertRaises(backup.Denied): backup.restore_objects(backup.sanitize(docs),'argocd')

    def test_archive_bytes_bind_version_key_checksum_and_retention(self):
        body=b'archive'
        checksum=base64.b64encode(hashlib.sha256(body).digest()).decode()
        payload={'bucket':'archive','key':'argocd/a.yaml','versionId':'immutable-version','kmsKeyArn':'arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012','sha256':'sha256:'+hashlib.sha256(body).hexdigest(),'sizeBytes':len(body),'s3ChecksumSha256':checksum}
        response={'VersionId':payload['versionId'],'SSEKMSKeyId':payload['kmsKeyArn'],'ServerSideEncryption':'aws:kms','ChecksumSHA256':checksum,'ContentLength':len(body),'ObjectLockMode':'GOVERNANCE','ObjectLockRetainUntilDate':backup.utcnow()+dt.timedelta(days=120)}
        self.assertEqual(backup.validate_object(payload,body,response),body)
        for mutate in [lambda p,r:r.update(VersionId='null'),lambda p,r:r.update(SSEKMSKeyId='other'),lambda p,r:r.update(ChecksumSHA256='wrong'),lambda p,r:r.update(ObjectLockMode=''),lambda p,r:r.update(ObjectLockRetainUntilDate=backup.utcnow()-dt.timedelta(days=1)),lambda p,r:p.update(sizeBytes=1)]:
            p,r=copy.deepcopy(payload),copy.deepcopy(response); mutate(p,r)
            with self.assertRaises(backup.Denied): backup.validate_object(p,body,r)

    def test_restore_requires_different_cluster_and_live_healthy_revision(self):
        metadata={'schemaVersion':'platform.argocd-dr/v1','evidenceGrade':'CAPTURED','capturedAt':'2026-09-05T00:00:00Z','source':{'clusterArn':'arn:aws:eks:us-east-1:123456789012:cluster/prod','argocdVersion':'3.5.2','namespace':'argocd','gitopsRevision':'a'*40},'payload':{},'restored':None}
        expected=next(x for x in backup.restore_objects(backup.sanitize(objects()),'argocd') if x['kind']=='Application')
        app=copy.deepcopy(expected)
        app['status']={'sync':{'status':'Synced','revision':'a'*40,'comparedTo':{'source':expected['spec']['source'],'destination':expected['spec']['destination']}},'health':{'status':'Healthy'},'reconciledAt':'2026-09-05T00:59:00Z'}
        current=dt.datetime(2026,9,5,1,tzinfo=dt.timezone.utc)
        binding={'expected_applications':[expected],'imported_at':current-dt.timedelta(minutes=2)}
        result=backup.verify_restore(metadata,'arn:aws:eks:us-east-1:123456789012:cluster/recovery','argocd','3.5.2',[app],current,**binding)
        self.assertIsNotNone(result['restored'])
        self.assertEqual(result['restored']['applicationRevisions'],{'mini-commerce-prod':'a'*40})
        self.assertNotEqual(result['evidenceGrade'],'CLOUD_RUNTIME')
        for args in [(metadata['source']['clusterArn'],'argocd','3.5.2',[app]),('arn:aws:eks:us-east-1:123456789012:cluster/recovery','argocd','3.5.1',[app]),('arn:aws:eks:us-east-1:123456789012:cluster/recovery','argocd','3.5.2',[])]:
            with self.assertRaises(backup.Denied): backup.verify_restore(metadata,*args,current,**binding)
        bad=copy.deepcopy(app);bad['status']['sync']['revision']='b'*40
        with self.assertRaises(backup.Denied): backup.verify_restore(metadata,'arn:aws:eks:us-east-1:123456789012:cluster/recovery','argocd','3.5.2',[bad],current,**binding)

    def test_live_restore_rechecks_imported_spec_and_post_import_reconciliation(self):
        metadata={'schemaVersion':'platform.argocd-dr/v1','evidenceGrade':'CAPTURED','capturedAt':'2026-09-05T00:00:00Z','source':{'clusterArn':'arn:aws:eks:us-east-1:123456789012:cluster/prod','argocdVersion':'3.5.2','namespace':'argocd','gitopsRevision':'a'*40},'payload':{},'restored':None}
        expected=next(x for x in backup.restore_objects(backup.sanitize(objects()),'argocd') if x['kind']=='Application')
        live=copy.deepcopy(expected)
        live['status']={'sync':{'status':'Synced','revision':'a'*40,'comparedTo':{'source':expected['spec']['source'],'destination':expected['spec']['destination']}},'health':{'status':'Healthy'},'reconciledAt':'2026-09-05T00:59:00Z'}
        current=dt.datetime(2026,9,5,1,tzinfo=dt.timezone.utc)
        imported=dt.datetime(2026,9,5,0,58,tzinfo=dt.timezone.utc)
        def verify(app):
            return backup.verify_restore(metadata,'arn:aws:eks:us-east-1:123456789012:cluster/recovery','argocd','3.5.2',[app],current,expected_applications=[expected],imported_at=imported)
        self.assertIsNotNone(verify(live)['restored'])
        for mutate in [lambda x:x['spec']['destination'].update(server='https://original-prod.example.com'),lambda x:x['spec']['source'].update(repoURL='https://github.com/foreign/repo'),lambda x:x['spec']['source'].update(targetRevision='other'),lambda x:x['status'].update(reconciledAt='2020-01-01T00:00:00Z'),lambda x:x['status'].update(reconciledAt='2026-09-05T02:00:00Z'),lambda x:x['status']['sync']['comparedTo']['source'].update(targetRevision='old'),lambda x:x['metadata'].update(namespace='foreign'),lambda x:x.update(operation={'sync':{}}),lambda x:x['spec'].update(sources=[expected['spec']['source']])]:
            app=copy.deepcopy(live)
            mutate(app)
            with self.assertRaises(backup.Denied): verify(app)


if __name__ == '__main__': unittest.main()
