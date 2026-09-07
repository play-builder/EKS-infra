"""Exercise the actual runtime CLI with fail-closed fake transports, never cloud APIs."""
import copy
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OLD, NEW = '1' * 32, '2' * 32
SOURCE = 'dev-mini-commerce/mini-commerce/runtime'
ARN = 'arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:' + SOURCE + '-AbCdEf'


def at(seconds):
    return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=seconds)).isoformat()


def metadata(name, namespace='app-dev', generation=2):
    return {'name': name, 'namespace': namespace, 'uid': name + '-uid', 'generation': generation, 'creationTimestamp': at(-3600)}


def own(child, parent):
    child['metadata']['ownerReferences'] = [{'apiVersion': parent.get('apiVersion', 'apps/v1'), 'kind': parent['kind'], 'name': parent['metadata']['name'], 'uid': parent['metadata']['uid'], 'controller': True}]
    return child


def fixture(namespace='app-dev'):
    workload = {'kind': 'Deployment', 'metadata': metadata('mini-commerce', namespace), 'spec': {'replicas': 2, 'template': {'spec': {'containers': [{'name': 'app', 'envFrom': [{'secretRef': {'name': 'mini-commerce-runtime'}}]}]}}}, 'status': {'observedGeneration': 2, 'replicas': 2, 'readyReplicas': 2, 'availableReplicas': 2, 'updatedReplicas': 2}}
    workload['metadata']['annotations'] = {'deployment.kubernetes.io/revision': '2'}
    rollout = copy.deepcopy(workload)
    rollout['kind'] = 'Rollout'
    rollout['status'].update(observedGeneration='2', currentPodHash='hash2', stableRS='hash2', phase='Healthy')
    rs = {'kind': 'ReplicaSet', 'metadata': metadata('mini-commerce-rs', namespace), 'spec': {'replicas': 2}, 'status': {'observedGeneration': 2, 'replicas': 2, 'readyReplicas': 2}}
    rs['metadata'].update(annotations={'deployment.kubernetes.io/revision': '2'}, labels={'rollouts-pod-template-hash': 'hash2'})
    own(rs, workload)
    def pod(name, parent):
        p = {'kind': 'Pod', 'metadata': metadata(name, namespace), 'spec': {'containers': [{'name': 'app'}]}, 'status': {'phase': 'Running', 'conditions': [{'type': 'Ready', 'status': 'True'}], 'containerStatuses': [{'name': 'app', 'ready': True}]}}
        p['metadata']['creationTimestamp'] = at(-10)
        return own(p, parent)
    pods = [pod('app-1', rs), pod('app-2', rs)]
    db = {'kind': 'StatefulSet', 'metadata': metadata('mini-commerce-postgresql', namespace), 'spec': {'replicas': 1, 'volumeClaimTemplates': [{'metadata': {'name': 'data'}}]}, 'status': {'observedGeneration': 2, 'replicas': 1, 'readyReplicas': 1, 'updatedReplicas': 1, 'currentReplicas': 1, 'currentRevision': 'r2', 'updateRevision': 'r2'}}
    dbpod = pod('mini-commerce-postgresql-0', db)
    dbpod['metadata']['labels'] = {'controller-revision-hash': 'r2'}
    dbpod['spec'].update(volumes=[{'name': 'data', 'persistentVolumeClaim': {'claimName': 'data-mini-commerce-postgresql-0'}}])
    dbpod['spec']['containers'][0]['volumeMounts'] = [{'name': 'data', 'mountPath': '/var/lib/postgresql/data'}]
    claim = {'metadata': metadata('data-mini-commerce-postgresql-0', namespace), 'spec': {'storageClassName': 'mini-commerce-gp3', 'volumeName': 'pv-db'}, 'status': {'phase': 'Bound'}}
    volume = {'spec': {'claimRef': {'name': claim['metadata']['name'], 'namespace': namespace, 'uid': claim['metadata']['uid']}, 'csi': {'driver': 'ebs.csi.aws.com'}}, 'status': {'phase': 'Bound'}}
    job = {'kind': 'Job', 'metadata': metadata('mini-commerce-migration', namespace), 'spec': {'completions': 1}, 'status': {'succeeded': 1, 'conditions': [{'type': 'Complete', 'status': 'True'}]}}
    jobpod = pod('migration-pod', job)
    jobpod['status']['phase'] = 'Succeeded'
    es = {'kind': 'ExternalSecret', 'metadata': metadata('mini-commerce-runtime', namespace), 'spec': {'target': {'name': 'mini-commerce-runtime', 'creationPolicy': 'Owner'}, 'secretStoreRef': {'kind': 'SecretStore', 'name': 'mini-commerce-secrets'}, 'data': [{'secretKey': 'API_KEY', 'remoteRef': {'key': ARN, 'property': 'API_KEY', 'version': 'uuid/' + NEW}}]}, 'status': {'syncedResourceVersion': '2-abc123hash', 'refreshTime': at(-30), 'conditions': [{'type': 'Ready', 'status': 'True', 'reason': 'SecretSynced', 'message': 'secret synced'}]}}
    target = own({'metadata': metadata('mini-commerce-runtime', namespace)}, es)
    return {
        'nodes': {'items': [{'metadata': metadata('node'), 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}}]},
        'application': {'metadata': metadata('mini-commerce-dev', 'argocd'), 'spec': {'destination': {'namespace': namespace}}, 'status': {'sync': {'status': 'Synced'}, 'health': {'status': 'Healthy'}}},
        'deployment': workload, 'rollout': rollout, 'replicasets': {'items': [rs]}, 'pods': {'items': pods + [dbpod, jobpod]}, 'statefulset': db, 'pvc': claim, 'pv': volume, 'job': job,
        'storageclass': {'provisioner': 'ebs.csi.aws.com', 'reclaimPolicy': 'Delete', 'volumeBindingMode': 'WaitForFirstConsumer', 'allowVolumeExpansion': True, 'parameters': {'type': 'gp3', 'encrypted': 'true'}},
        'externalsecret': es, 'secretstore': {'spec': {'provider': {'aws': {'region': 'ap-northeast-2', 'service': 'SecretsManager'}}}}, 'secret': target['metadata'],
        'aws-secret': {'ARN': ARN, 'Name': SOURCE, 'VersionIdsToStages': {NEW: ['AWSCURRENT'], OLD: ['AWSPREVIOUS']}},
        'aws-identity': {'Account': '123456789012'}, 'kubeconfig': {'clusters': [{'cluster': {'server': 'https://cluster.example.invalid'}}]}, 'products': {'products': []},
    }


FAKE = '''#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]; tool=pathlib.Path(sys.argv[0]).name
f=json.loads(pathlib.Path(os.environ['RUNTIME_FIXTURE']).read_text())
with open(os.environ['RUNTIME_CALL_LOG'],'a') as stream:stream.write(json.dumps([tool]+args)+'\\n')
if tool=='kubectl':
 assert '--context' in args and args[args.index('--context')+1]==os.environ['EXPECTED_CONTEXT']
 if 'config' in args: value=f['kubeconfig']
 else:
  kind=args[args.index('get')+1]
  assert kind in f, args
  value=f[kind]
  if kind not in ('nodes','application'):
   assert args[args.index('-n')+1]==os.environ['EXPECTED_NAMESPACE']
  if kind=='secret':assert args[-1]=='jsonpath={.metadata}'
elif tool=='aws':
 assert '--profile' in args and '--region' in args
 if args[:2]==['sts','get-caller-identity']:value=f['aws-identity']
 elif args[:2]==['secretsmanager','describe-secret']:value=f['aws-secret']
 else:raise AssertionError('unexpected AWS call')
elif tool=='curl':
 assert args[-1]=='https://example.invalid/products' and '--request' not in args
 value=f['products']
else:raise AssertionError('unexpected tool')
print(json.dumps(value))
'''


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.bin = self.path / 'bin'
        self.bin.mkdir()
        for name in ('aws', 'kubectl', 'curl'):
            file = self.bin / name
            file.write_text(FAKE)
            file.chmod(0o755)
        self.data = fixture()
        self.env = dict(os.environ, PLATFORM_CHECK_BIN_DIR=str(self.bin), AWS_PROFILE='fixture', AWS_REGION='ap-northeast-2', RUNTIME_FIXTURE=str(self.path / 'fixture.json'), RUNTIME_CALL_LOG=str(self.path / 'calls.jsonl'), EXPECTED_CONTEXT='mini-commerce-dev', EXPECTED_NAMESPACE='app-dev')

    def invoke(self, mode, *args, good=True):
        Path(self.env['RUNTIME_FIXTURE']).write_text(json.dumps(self.data))
        result = subprocess.run(['bash', str(ROOT / 'scripts/dev-ready-check.sh'), mode, *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, good, result.stdout + result.stderr)
        self.assertNotIn('[CLOUD_RUNTIME]', result.stdout)
        return result

    def rotation(self):
        own(self.data['replicasets']['items'][0], self.data['rollout'])
        es, ro = self.data['externalsecret'], self.data['rollout']
        baseline = {'schemaVersion': 'platform.secret-rotation-baseline/v1', 'identity': {'context': 'mini-commerce-dev', 'clusterEndpoint': 'https://cluster.example.invalid', 'namespace': 'app-dev', 'externalSecretUid': es['metadata']['uid'], 'rolloutUid': ro['metadata']['uid'], 'sourceArn': ARN}, 'observedAt': at(-120), 'sourceVersionId': OLD, 'rolloutGeneration': 1, 'podUids': ['old-1', 'old-2'], 'evidenceGrade': 'STATIC'}
        self.baseline = self.path / 'baseline.json'
        self.baseline.write_text(json.dumps(baseline))
        return baseline

    def fresh(self, good=True):
        return self.invoke('secret-freshness', 'mini-commerce-dev', 'app-dev', 'mini-commerce-runtime', 'mini-commerce', SOURCE, NEW, str(self.baseline), good=good)


class Core(RuntimeTest):
    def test_default_and_explicit_context(self):
        self.invoke('core')
        self.data = fixture('custom-ns')
        self.env.update(EXPECTED_CONTEXT='custom-context', EXPECTED_NAMESPACE='custom-ns')
        self.invoke('core', 'custom-context', 'custom-ns')

    def test_stale_and_unowned_resources(self):
        for change in (
            lambda f: f['deployment']['status'].update(observedGeneration=1),
            lambda f: f['deployment']['status'].update(updatedReplicas=0),
            lambda f: f['deployment']['spec'].update(replicas=3),
            lambda f: f['deployment']['metadata'].update(deletionTimestamp=at(-1)),
            lambda f: f['pods']['items'][0]['metadata']['ownerReferences'][0].update(uid='unrelated'),
            lambda f: f['replicasets']['items'][0]['metadata']['ownerReferences'][0].update(controller=False),
            lambda f: f['replicasets']['items'][0]['metadata']['annotations'].update({'deployment.kubernetes.io/revision': '1'}),
            lambda f: f['pods']['items'][0]['metadata'].update(deletionTimestamp=at(-1)),
            lambda f: f['pods']['items'][0]['status']['containerStatuses'][0].update(ready=False),
            lambda f: f['externalsecret']['status'].update(syncedResourceVersion='1-oldhash'),
            lambda f: f['externalsecret']['status'].update(refreshTime=at(-9000)),
            lambda f: f['application']['spec']['destination'].update(namespace='wrong'),
        ):
            self.data = fixture()
            change(self.data)
            self.invoke('core', good=False)


class Stateful(RuntimeTest):
    def test_current_owned_storage_and_readonly_api(self):
        self.invoke('stateful', 'mini-commerce-dev', 'app-dev', 'https://example.invalid')
        calls = [json.loads(line) for line in Path(self.env['RUNTIME_CALL_LOG']).read_text().splitlines()]
        self.assertTrue(any('pv' in call for call in calls))
        self.assertEqual(len([call for call in calls if call[0] == 'curl']), 1)

    def test_generation_revision_and_storage_wiring(self):
        for change in (
            lambda f: f['statefulset']['status'].update(observedGeneration=1),
            lambda f: f['statefulset']['status'].update(currentRevision=None, updateRevision=None),
            lambda f: f['pods']['items'][2]['metadata']['labels'].update({'controller-revision-hash': 'r1'}),
            lambda f: f['pods']['items'][2]['metadata']['ownerReferences'][0].update(uid='other-db'),
            lambda f: f['pods']['items'][2]['spec']['volumes'][0]['persistentVolumeClaim'].update(claimName='unrelated'),
            lambda f: f['pv']['spec']['claimRef'].update(uid='other-pvc'),
            lambda f: f['pvc']['spec'].update(storageClassName='other'),
            lambda f: f['job']['status'].update(conditions=[]),
            lambda f: f['pods']['items'][3]['metadata']['ownerReferences'][0].update(uid='other-job'),
            lambda f: f['deployment']['status'].update(observedGeneration=1),
        ):
            self.data = fixture()
            change(self.data)
            self.invoke('stateful', 'mini-commerce-dev', 'app-dev', 'https://example.invalid', good=False)


class Secret(RuntimeTest):
    def test_baseline_capture_complete_set_no_payload(self):
        self.rotation()
        output = self.path / 'captured.json'
        self.invoke('secret-baseline', 'mini-commerce-dev', 'app-dev', 'mini-commerce-runtime', 'mini-commerce', SOURCE, str(output))
        value = json.loads(output.read_text())
        self.assertEqual(value['podUids'], ['app-1-uid', 'app-2-uid'])
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('API_KEY', output.read_text())
        self.invoke('secret-baseline', 'mini-commerce-dev', 'app-dev', 'mini-commerce-runtime', 'mini-commerce', SOURCE, str(output), good=False)

    def test_real_eso_shape_and_pinned_new_version(self):
        self.rotation()
        self.fresh()

    def test_invalid_version_generation_and_pod_set(self):
        for change in (
            lambda f: f['externalsecret']['status'].update(syncedResourceVersion=NEW),
            lambda f: f['externalsecret']['status'].update(syncedResourceVersion='1-oldhash'),
            lambda f: f['externalsecret']['status'].update(refreshTime=at(-200)),
            lambda f: f['externalsecret']['spec']['data'][0]['remoteRef'].pop('version'),
            lambda f: f['externalsecret']['spec']['data'][0]['remoteRef'].update(key='other-secret'),
            lambda f: f['externalsecret']['spec']['data'][0]['remoteRef'].update(property='DB_PASSWORD'),
            lambda f: f['secretstore']['spec']['provider']['aws'].update(region='us-east-1'),
            lambda f: f['secret']['ownerReferences'][0].update(uid='other-es'),
            lambda f: f['rollout']['status'].update(observedGeneration='1'),
            lambda f: f['rollout']['status'].update(stableRS='oldhash'),
            lambda f: f['rollout']['spec']['template']['spec']['containers'][0].update(envFrom=[]),
            lambda f: f['pods']['items'][0]['metadata'].update(uid='old-1'),
            lambda f: f['pods']['items'][0]['metadata'].update(creationTimestamp=at(-200)),
            lambda f: f['pods']['items'][0]['metadata']['ownerReferences'][0].update(uid='unrelated'),
            lambda f: f['aws-secret']['VersionIdsToStages'].update({NEW: ['AWSPREVIOUS'], OLD: ['AWSCURRENT']}),
        ):
            self.data = fixture()
            self.rotation()
            change(self.data)
            self.fresh(good=False)

    def test_baseline_identity_staleness_and_legacy_uid(self):
        for change in (
            lambda b: b['identity'].update(clusterEndpoint='other-cluster'),
            lambda b: b.update(observedAt=at(-9000)),
            lambda b: b.update(podUids=[]),
            lambda b: b.update(sourceVersionId=NEW),
            lambda b: b.update(evidenceGrade='CLOUD_RUNTIME'),
        ):
            baseline = self.rotation()
            change(baseline)
            self.baseline.write_text(json.dumps(baseline))
            self.fresh(good=False)
        self.baseline = Path('old-pod-uid')
        self.fresh(good=False)


if __name__ == '__main__':
    classes = {'core': Core, 'stateful': Stateful, 'secret': Secret}
    selected = [classes[sys.argv[1]]] if len(sys.argv) > 1 else list(classes.values())
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(c) for c in selected)
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
