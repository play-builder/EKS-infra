import copy
import re
import base64
import datetime as dt
import hashlib
import json
import uuid
import argparse
import os
import pathlib
import subprocess
import sys


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


def store_export(contract, source, documents, s3):
    if source['argocdVersion'] != '3.5.2' or not re.fullmatch('[0-9a-f]{40}',source['gitopsRevision']):
        raise Denied('EXPORT_SOURCE_VERSION_INVALID')
    body = encode_objects(sanitize(documents))
    digest = hashlib.sha256(body).digest()
    checksum = base64.b64encode(digest).decode()
    key = 'argocd/'+uuid.uuid4().hex+'.yaml'
    response=s3.put_object(Bucket=contract['bucket'],Key=key,Body=body,ExpectedBucketOwner=contract['accountId'],IfNoneMatch='*',ServerSideEncryption='aws:kms',SSEKMSKeyId=contract['kmsKeyArn'],ChecksumSHA256=checksum,ContentType='application/yaml',Metadata={'source-sha256':source_hash(source)})
    version=response.get('VersionId')
    if not version or version == 'null':
        raise Denied('UPLOAD_VERSION_REQUIRED')
    payload={'bucket':contract['bucket'],'key':key,'versionId':version,'kmsKeyArn':contract['kmsKeyArn'],'sha256':'sha256:'+digest.hex(),'sizeBytes':len(body),'s3ChecksumSha256':checksum}
    head=s3.head_object(Bucket=contract['bucket'],Key=key,VersionId=version,ExpectedBucketOwner=contract['accountId'],ChecksumMode='ENABLED')
    validate_object(payload,body,head)
    if head.get('Metadata',{}).get('source-sha256') != source_hash(source):
        raise Denied('ARCHIVE_SOURCE_BINDING_MISMATCH')
    return {'schemaVersion':'platform.argocd-dr/v1','evidenceGrade':'LOCAL_VERIFIED','capturedAt':utcnow().isoformat(timespec='seconds').replace('+00:00','Z'),'source':source,'payload':payload,'restored':None}


def source_hash(source):
    return hashlib.sha256(json.dumps(source,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def encode_objects(documents):
    return ('\n---\n'.join(json.dumps(x,sort_keys=True) for x in documents)+'\n').encode()


def cluster_identity(eks, run, context, cluster_arn, namespace):
    if not re.fullmatch(r'arn:aws:eks:(us-east-1|ap-northeast-2):[0-9]{12}:cluster/[A-Za-z0-9_-]+',cluster_arn) or namespace != 'argocd' or not context:
        raise Denied('CLUSTER_IDENTITY_INPUT_INVALID')
    cluster=eks.describe_cluster(name=cluster_arn.split('/')[-1])['cluster']
    config=json.loads(run(['kubectl','--context',context,'config','view','--minify','-o','json']))
    if cluster['arn'] != cluster_arn or cluster['status'] != 'ACTIVE' or len(config.get('clusters',[])) != 1 or config['clusters'][0]['cluster']['server'] != cluster['endpoint']:
        raise Denied('KUBECONTEXT_CLUSTER_ENDPOINT_MISMATCH')
    version=run(['argocd','version','--client','--short']).decode().strip()
    if not re.fullmatch(r'argocd: v3\.5\.2(?:\+[^\s]+)?',version):
        raise Denied('ARGO_CLIENT_VERSION_MISMATCH')
    deployment=json.loads(run(['kubectl','--context',context,'-n',namespace,'get','deployment','argocd-server','-o','json']))
    images=[c['image'] for c in deployment['spec']['template']['spec']['containers'] if c['name']=='argocd-server']
    status=deployment.get('status',{})
    if (len(images) != 1 or not re.fullmatch(r'quay.io/argoproj/argocd:v3\.5\.2(?:@sha256:[0-9a-f]{64})?',images[0]) or
        status.get('readyReplicas',0) < deployment['spec'].get('replicas',1) or status.get('readyReplicas',0) < 1 or
        status.get('observedGeneration') != deployment['metadata']['generation']):
        raise Denied('ARGO_SERVER_VERSION_OR_READINESS_MISMATCH')
    return '3.5.2'


def validate_storage(contract, observed):
    try:
        encryption = observed['encryption']['ServerSideEncryptionConfiguration']['Rules']
        retention = observed['lock']['ObjectLockConfiguration']['Rule']['DefaultRetention']
        if (contract['schemaVersion'] != 'platform.backup-storage/v1' or contract['prefix'] != 'argocd/' or
            contract['objectLockMode'] != 'GOVERNANCE' or contract['retentionDays'] < 90 or
            observed['accountId'] != contract['accountId'] or observed['region'] != contract['region'] or
            not re.fullmatch(r'arn:aws:kms:'+re.escape(contract['region'])+':'+re.escape(contract['accountId'])+r':key/[0-9a-f-]{36}',contract['kmsKeyArn']) or
            observed['versioning']['Status'] != 'Enabled' or
            observed['lock']['ObjectLockConfiguration']['ObjectLockEnabled'] != 'Enabled' or
            retention.get('Mode') != 'GOVERNANCE' or retention.get('Days',0) < contract['retentionDays'] or
            len(encryption) != 1 or encryption[0]['ApplyServerSideEncryptionByDefault'] != {'SSEAlgorithm':'aws:kms','KMSMasterKeyID':contract['kmsKeyArn']} or encryption[0].get('BucketKeyEnabled',False) or
            any(observed['public']['PublicAccessBlockConfiguration'].get(key) is not True for key in ['BlockPublicAcls','BlockPublicPolicy','IgnorePublicAcls','RestrictPublicBuckets']) or
            observed['policy']['PolicyStatus'].get('IsPublic') is not False or
            observed['ownership']['OwnershipControls']['Rules'] != [{'ObjectOwnership':'BucketOwnerEnforced'}]):
            raise Denied('ARCHIVE_STORAGE_NOT_PROTECTED')
    except (KeyError,TypeError,ValueError) as error:
        raise Denied('ARCHIVE_STORAGE_OBSERVATION_INCOMPLETE') from error
    return contract


def validate_object(payload, body, response):
    digest = hashlib.sha256(body).digest()
    checksum = base64.b64encode(digest).decode()
    retained = response.get('ObjectLockRetainUntilDate')
    if (not payload.get('versionId') or payload['versionId'] == 'null' or
        response.get('VersionId') != payload['versionId'] or response.get('ServerSideEncryption') != 'aws:kms' or
        response.get('SSEKMSKeyId') != payload['kmsKeyArn'] or response.get('ChecksumSHA256') != checksum or
        payload.get('s3ChecksumSha256') != checksum or payload.get('sha256') != 'sha256:'+digest.hex() or
        payload.get('sizeBytes') != len(body) or response.get('ContentLength') != len(body) or
        response.get('ObjectLockMode') != 'GOVERNANCE' or not isinstance(retained,dt.datetime) or retained <= utcnow()):
        raise Denied('ARCHIVE_VERSION_INTEGRITY_OR_RETENTION_MISMATCH')
    return body


def verify_restore(metadata, target_arn, namespace, version, applications, current=None, *, expected_applications, imported_at):
    current = current or utcnow()
    source = metadata['source']
    if (metadata.get('schemaVersion') != 'platform.argocd-dr/v1' or target_arn == source['clusterArn'] or
        not re.fullmatch(r'arn:aws:eks:(us-east-1|ap-northeast-2):[0-9]{12}:cluster/[A-Za-z0-9_-]+',target_arn) or
        version != '3.5.2' or source['argocdVersion'] != version or namespace != source['namespace'] or
        not applications or not re.fullmatch('[0-9a-f]{40}',source['gitopsRevision'])):
        raise Denied('RESTORE_IDENTITY_MISMATCH')
    captured = dt.datetime.fromisoformat(metadata['capturedAt'].replace('Z','+00:00'))
    if not captured <= current <= captured+dt.timedelta(days=90):
        raise Denied('RESTORE_ARCHIVE_STALE')
    revisions = {}
    expected={obj['metadata']['name']:obj for obj in expected_applications if obj.get('kind')=='Application'}
    if not expected or not isinstance(imported_at,dt.datetime) or not captured <= imported_at <= current:
        raise Denied('RESTORE_IMPORT_BINDING_REQUIRED')
    for app in applications:
        state=app.get('status',{})
        original=expected.get(app.get('metadata',{}).get('name'))
        if not original or app['metadata'].get('namespace') != namespace or app.get('operation') or app['metadata'].get('deletionTimestamp'):
            raise Denied('RESTORE_APPLICATION_SPEC_MISMATCH')
        spec=app.get('spec',{})
        expected_spec=original['spec']
        if (any(spec.get(key) != expected_spec.get(key) for key in ('source','sources','destination','project')) or
            spec.get('destination',{}).get('server') != 'https://kubernetes.default.svc' or
            spec.get('syncPolicy',{}).get('automated') is not None):
            raise Denied('RESTORE_APPLICATION_SPEC_MISMATCH')
        compared=state.get('sync',{}).get('comparedTo',{})
        if any(compared.get(key) != expected_spec.get(key) for key in ('source','sources','destination')):
            raise Denied('RESTORE_APPLICATION_COMPARISON_STALE')
        try:
            reconciled=dt.datetime.fromisoformat(state['reconciledAt'].replace('Z','+00:00'))
            if not imported_at <= reconciled <= current:
                raise Denied('RESTORE_APPLICATION_RECONCILIATION_STALE')
        except (KeyError,TypeError,ValueError) as error:
            raise Denied('RESTORE_APPLICATION_RECONCILIATION_STALE') from error
        if state.get('sync',{}).get('status') != 'Synced' or state['sync'].get('revision') != source['gitopsRevision'] or state.get('health',{}).get('status') != 'Healthy':
            raise Denied('RESTORE_APPLICATION_NOT_HEALTHY_AT_REVISION')
        revisions[app['metadata']['name']]=state['sync']['revision']
    result = copy.deepcopy(metadata)
    result['evidenceGrade']='LOCAL_VERIFIED'
    result['restored']={'clusterArn':target_arn,'namespace':namespace,'argocdVersion':version,'applicationRevisions':revisions,'observedAt':current.isoformat(timespec='seconds').replace('+00:00','Z')}
    return result


class Denied(Exception):
    pass


def sanitize(documents):
    result = []
    allowed = {'ConfigMap':'v1', 'AppProject':'argoproj.io/v1alpha1', 'Application':'argoproj.io/v1alpha1', 'ApplicationSet':'argoproj.io/v1alpha1'}
    for original in documents:
        if not isinstance(original, dict):
            raise Denied('EXPORT_OBJECT_INVALID')
        if original.get('kind') == 'Secret':
            continue
        kind = original.get('kind')
        if kind not in allowed or original.get('apiVersion') != allowed[kind]:
            raise Denied('EXPORT_KIND_INVALID')
        obj = copy.deepcopy(original)
        obj.pop('status', None)
        obj.pop('operation', None)
        meta = obj.get('metadata', {})
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*', meta.get('name', '')):
            raise Denied('EXPORT_NAME_INVALID')
        obj['metadata'] = {key:value for key,value in meta.items() if key in ('name','namespace','labels','finalizers')}
        reject_credentials(obj)
        result.append(obj)
    if not any(x['kind'] == 'Application' for x in result) or not any(x['kind'] == 'AppProject' for x in result):
        raise Denied('EXPORT_APPLICATION_PROJECT_REQUIRED')
    return result


def reject_credentials(value, key=''):
    sensitive = re.compile(r'(password|clientsecret|privatekey|apitoken|accesskey|secretkey|authorization)', re.I)
    if isinstance(value, dict):
        if sensitive.search(str(value.get('name',''))) and 'value' in value and not str(value['value']).startswith('$'):
            raise Denied('INLINE_CREDENTIAL_REJECTED')
        for name, item in value.items():
            reject_credentials(item, name)
    elif isinstance(value, list):
        for item in value:
            reject_credentials(item, key)
    elif isinstance(value, str):
        if sensitive.search(key) and value and not value.startswith('$'):
            raise Denied('INLINE_CREDENTIAL_REJECTED')
        if 'PRIVATE KEY-----' in value or re.search(r'https?://[^/\s]+:[^/\s]+@', value):
            raise Denied('INLINE_CREDENTIAL_REJECTED')
        if value.strip().startswith(('{','[')):
            try:
                nested=json.loads(value)
            except json.JSONDecodeError:
                nested=None
            if isinstance(nested,(dict,list)):
                reject_credentials(nested)
        for line in value.splitlines():
            match = re.match(r'\s*[\"\']?([A-Za-z_-]+)[\"\']?\s*:\s*[\"\']?([^\s\"\']+)', line)
            if match and sensitive.search(match[1]) and not match[2].startswith('$'):
                raise Denied('INLINE_CREDENTIAL_REJECTED')


def restore_objects(documents, namespace):
    result = []
    for obj in sanitize(documents):
        if obj['kind'] not in ('AppProject','Application'):
            continue
        if obj['kind'] == 'AppProject' and obj['metadata']['name'] == 'default':
            continue
        meta = obj['metadata']
        if meta.get('namespace', namespace) != namespace:
            raise Denied('EXPORT_NAMESPACE_MISMATCH')
        meta['namespace'] = namespace
        meta.pop('finalizers', None)
        if obj['kind'] == 'Application':
            destinations = [obj['spec'].get('destination', {})]
            obj['spec'].setdefault('syncPolicy', {}).pop('automated', None)
        else:
            destinations = obj['spec'].get('destinations', [])
        if any(d.get('server') != 'https://kubernetes.default.svc' or 'name' in d for d in destinations):
            raise Denied('RESTORE_EXTERNAL_DESTINATION_REJECTED')
        result.append(obj)
    return result


def invoke(args, *, input=None):
    result=subprocess.run(args,input=input,capture_output=True,timeout=180,check=False)
    if result.returncode != 0:
        raise Denied('EXTERNAL_COMMAND_FAILED_'+pathlib.Path(args[0]).name.upper())
    if len(result.stdout) > 16*1024*1024:
        raise Denied('EXPORT_SIZE_LIMIT_EXCEEDED')
    return result.stdout


def read_json(path):
    file=pathlib.Path(path)
    if file.is_symlink() or not file.is_file() or file.stat().st_size > 1024*1024:
        raise Denied('METADATA_FILE_INVALID')
    return json.loads(file.read_text())


def write_json(path, record):
    descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'w') as stream:
        json.dump(record,stream,indent=2)
        stream.write('\n')


def storage_observations(contract, s3, sts):
    args={'Bucket':contract['bucket'],'ExpectedBucketOwner':contract['accountId']}
    return {
        'accountId':sts.get_caller_identity()['Account'],
        'region':s3.get_bucket_location(**args).get('LocationConstraint') or 'us-east-1',
        'versioning':s3.get_bucket_versioning(**args),
        'lock':s3.get_object_lock_configuration(**args),
        'encryption':s3.get_bucket_encryption(**args),
        'public':s3.get_public_access_block(**args),
        'policy':s3.get_bucket_policy_status(**args),
        'ownership':s3.get_bucket_ownership_controls(**args),
    }


def download_archive(metadata,contract,s3):
    payload=metadata['payload']
    if payload['bucket'] != contract['bucket'] or payload['kmsKeyArn'] != contract['kmsKeyArn'] or not re.fullmatch(r'argocd/[0-9a-f]{32}\.yaml',payload['key']):
        raise Denied('ARCHIVE_STORAGE_BINDING_MISMATCH')
    response=s3.get_object(Bucket=payload['bucket'],Key=payload['key'],VersionId=payload['versionId'],ExpectedBucketOwner=contract['accountId'],ChecksumMode='ENABLED')
    try:
        body=response['Body'].read(16*1024*1024+1)
    finally:
        response['Body'].close()
    if len(body)>16*1024*1024 or response.get('Metadata',{}).get('source-sha256') != source_hash(metadata['source']):
        raise Denied('ARCHIVE_SOURCE_BINDING_MISMATCH')
    validate_object(payload,body,response)
    documents=[json.loads(part) for part in body.decode().split('\n---\n')]
    if encode_objects(sanitize(documents)) != body:
        raise Denied('ARCHIVE_SANITIZATION_MISMATCH')
    return documents


def application(run,context,namespace,name):
    if not re.fullmatch('[a-z0-9][a-z0-9.-]*',name):
        raise Denied('APPLICATION_NAME_INVALID')
    return json.loads(run(['kubectl','--context',context,'-n',namespace,'get','application',name,'-o','json']))


def rehydrated_secrets(run,context,namespace):
    names={'argocd-oidc','argocd-notifications-secret','argocd-repository-credentials'}
    items=json.loads(run(['kubectl','--context',context,'-n',namespace,'get','externalsecrets','-o','json']))['items']
    ready=set()
    for obj in items:
        target=obj.get('spec',{}).get('target',{}).get('name',obj['metadata']['name'])
        status=obj.get('status',{})
        metadata=obj.get('metadata',{})
        # ESO records generation plus a metadata hash, not observedGeneration.
        version=re.fullmatch(r'([1-9][0-9]*)-([a-zA-Z0-9]+)',status.get('syncedResourceVersion',''))
        if metadata.get('deletionTimestamp') or not version or int(version.group(1)) != metadata.get('generation'):
            continue
        try:
            refreshed=dt.datetime.fromisoformat(status['refreshTime'].replace('Z','+00:00'))
            created=dt.datetime.fromisoformat(metadata['creationTimestamp'].replace('Z','+00:00'))
            if not created <= refreshed <= utcnow():
                continue
        except (KeyError,TypeError,ValueError):
            continue
        for condition in status.get('conditions',[]):
            if (condition.get('type')=='Ready' and condition.get('status')=='True' and
                condition.get('reason')=='SecretSynced' and condition.get('message')=='secret synced'):
                ready.add(target)
    if not names.issubset(ready):
        raise Denied('EXTERNALSECRET_REHYDRATION_PENDING')


def subset(expected,observed):
    if isinstance(expected,dict):
        return isinstance(observed,dict) and all(key in observed and subset(value,observed[key]) for key,value in expected.items())
    return expected == observed


def import_archive(documents,context,namespace,run):
    prepared=restore_objects(documents,namespace)
    existing=json.loads(run(['kubectl','--context',context,'-n',namespace,'get','applications','-o','json']))['items']
    allowed={x['metadata']['name'] for x in prepared if x['kind']=='Application'}
    if not allowed or any(x['metadata']['name'] not in allowed or x.get('operation') for x in existing):
        raise Denied('RESTORE_TARGET_HAS_UNRELATED_OR_ACTIVE_APPLICATIONS')
    result=run(['argocd','admin','import','-','--context',context,'-n',namespace],input=encode_objects(prepared))
    for expected in prepared:
        actual=json.loads(run(['kubectl','--context',context,'-n',namespace,'get',expected['kind'],expected['metadata']['name'],'-o','json']))
        if not subset(expected['spec'],actual.get('spec',{})) or actual.get('spec',{}).get('syncPolicy',{}).get('automated') is not None:
            raise Denied('IMPORTED_OBJECT_NOT_OBSERVED')
    return {'importOutputSha256':'sha256:'+hashlib.sha256(result).hexdigest(),'applicationNames':sorted(allowed)}


def main():
    parser=argparse.ArgumentParser(description='Protected Argo CD export, isolated import and read-only recovery verification')
    parser.add_argument('action',choices=['export','restore','verify'])
    parser.add_argument('--storage',required=True,help='terraform output -json backup metadata file')
    parser.add_argument('--context',required=True)
    parser.add_argument('--cluster-arn',required=True)
    parser.add_argument('--namespace',default='argocd')
    parser.add_argument('--application',default='mini-commerce-prod')
    parser.add_argument('--gitops-revision')
    parser.add_argument('--metadata')
    parser.add_argument('--restore-receipt')
    parser.add_argument('--output',required=True)
    parser.add_argument('--confirm-isolated-target')
    parser.add_argument('--execute',action='store_true')
    args=parser.parse_args()
    if args.action in ('export','restore') and not args.execute:
        parser.error('--execute is required for upload/import; review the technical runbook first')
    contract=read_json(args.storage)
    if not re.fullmatch(r'arn:aws:eks:(us-east-1|ap-northeast-2):[0-9]{12}:cluster/[A-Za-z0-9_-]+',args.cluster_arn):
        raise Denied('CLUSTER_ARN_INVALID')
    import boto3
    session=boto3.Session()
    s3=session.client('s3',region_name=contract['region'])
    sts=session.client('sts',region_name=contract['region'])
    validate_storage(contract,storage_observations(contract,s3,sts))
    if args.cluster_arn.split(':')[4] != contract['accountId']:
        raise Denied('CLUSTER_ACCOUNT_MISMATCH')
    eks=session.client('eks',region_name=args.cluster_arn.split(':')[3])
    version=cluster_identity(eks,invoke,args.context,args.cluster_arn,args.namespace)
    if args.action=='export':
        import yaml
        app=application(invoke,args.context,args.namespace,args.application)
        source={'clusterArn':args.cluster_arn,'argocdVersion':version,'namespace':args.namespace,'gitopsRevision':args.gitops_revision}
        if not args.gitops_revision or app.get('status',{}).get('sync',{}).get('revision') != args.gitops_revision or app['status']['sync'].get('status') != 'Synced':
            raise Denied('EXPORT_APPLICATION_REVISION_MISMATCH')
        raw=invoke(['argocd','admin','export','--context',args.context,'-n',args.namespace])
        documents=[obj for obj in yaml.safe_load_all(raw) if obj is not None]
        exported=[obj for obj in documents if obj.get('kind')=='Application' and obj.get('metadata',{}).get('name')==args.application]
        if len(exported)!=1 or exported[0].get('status',{}).get('sync',{}).get('revision') != args.gitops_revision:
            raise Denied('EXPORT_REVISION_CHANGED_OR_MISSING')
        record=store_export(contract,source,documents,s3)
        record['evidenceGrade']='CAPTURED'
    else:
        if not args.metadata: parser.error('--metadata is required')
        metadata=read_json(args.metadata)
        if args.cluster_arn==metadata['source']['clusterArn'] or args.namespace!=metadata['source']['namespace'] or version!=metadata['source']['argocdVersion']:
            raise Denied('RESTORE_TARGET_NOT_ISOLATED_OR_VERSION_MISMATCH')
        documents=download_archive(metadata,contract,s3)
        rehydrated_secrets(invoke,args.context,args.namespace)
        if args.action=='restore':
            if args.confirm_isolated_target != args.cluster_arn: parser.error('--confirm-isolated-target must equal the reviewed recovery cluster ARN')
            observed=import_archive(documents,args.context,args.namespace,invoke)
            record={'schemaVersion':'platform.argocd-import/v1','evidenceGrade':'CAPTURED','clusterArn':args.cluster_arn,'namespace':args.namespace,'archiveSha256':metadata['payload']['sha256'],'sourceHash':source_hash(metadata['source']),'observedAt':utcnow().isoformat(timespec='seconds').replace('+00:00','Z'),**observed}
        else:
            if not args.restore_receipt: parser.error('--restore-receipt is required')
            receipt=read_json(args.restore_receipt)
            now=utcnow()
            receipt_time=dt.datetime.fromisoformat(receipt['observedAt'].replace('Z','+00:00'))
            if (receipt.get('schemaVersion')!='platform.argocd-import/v1' or receipt.get('evidenceGrade')!='CAPTURED' or receipt.get('clusterArn')!=args.cluster_arn or receipt.get('namespace')!=args.namespace or receipt.get('archiveSha256')!=metadata['payload']['sha256'] or receipt.get('sourceHash')!=source_hash(metadata['source']) or args.application not in receipt.get('applicationNames',[]) or not now-dt.timedelta(days=1)<=receipt_time<=now):
                raise Denied('IMPORT_RECEIPT_BINDING_OR_FRESHNESS_MISMATCH')
            expected=[obj for obj in restore_objects(documents,args.namespace) if obj['kind']=='Application']
            record=verify_restore(metadata,args.cluster_arn,args.namespace,version,[application(invoke,args.context,args.namespace,args.application)],now,expected_applications=expected,imported_at=receipt_time)
            record['evidenceGrade']='CLOUD_RUNTIME'
    write_json(args.output,record)
    print('PASS: '+record['schemaVersion']+' '+record['evidenceGrade']+'; metadata written, no secret values printed')


if __name__=='__main__':
    try:
        main()
    except Denied as error:
        print('STOP: '+str(error),file=sys.stderr)
        sys.exit(1)
    except ImportError:
        print('STOP: install scripts/requirements-argocd-backup.txt in an isolated Python venv',file=sys.stderr)
        sys.exit(2)
    except Exception:
        print('STOP: backup operation failed; inspect identity, permissions and input shape without logging secret output',file=sys.stderr)
        sys.exit(1)
