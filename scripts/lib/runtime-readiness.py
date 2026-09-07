#!/usr/bin/env python3
"""Read-only readiness and explicit version-pinned rotation verification."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def require(value, code):
    if not value:
        raise ValueError(code)


def stamp(value):
    require(isinstance(value, str), 'TIMESTAMP_REQUIRED')
    result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(result.tzinfo is not None, 'TIMESTAMP_TIMEZONE_REQUIRED')
    return result


def now():
    return dt.datetime.now(dt.timezone.utc)


def command(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=90)
    require(result.returncode == 0, 'RUNTIME_COMMAND_FAILED')
    return json.loads(result.stdout)


def live(obj):
    metadata = obj['metadata']
    require(metadata.get('uid') and not metadata.get('deletionTimestamp'), 'OBJECT_DELETING_OR_UID_MISSING')
    return metadata


def owned(obj, parent):
    owners = [r for r in obj['metadata'].get('ownerReferences', []) if r.get('controller') is True]
    return len(owners) == 1 and owners[0].get('uid') == parent['metadata']['uid'] and owners[0].get('kind') == parent['kind'] and owners[0].get('name') == parent['metadata']['name']


def generation(obj):
    metadata = live(obj)
    gen = metadata['generation']
    require(type(gen) is int and gen > 0, 'GENERATION_REQUIRED')
    observed = obj['status'].get('observedGeneration')
    # Argo Rollouts serializes metadata.generation as a decimal string.
    expected = str(gen) if obj['kind'] == 'Rollout' else gen
    require(type(observed) is type(expected) and observed == expected, 'GENERATION_NOT_OBSERVED')


def ready_pod(pod):
    live(pod)
    require(pod['status'].get('phase') == 'Running', 'POD_NOT_RUNNING')
    require(any(c.get('type') == 'Ready' and c.get('status') == 'True' for c in pod['status'].get('conditions', [])), 'POD_NOT_READY')
    containers = pod['status'].get('containerStatuses', [])
    require({c['name'] for c in containers} == {c['name'] for c in pod['spec']['containers']} and all(c.get('ready') is True for c in containers), 'CONTAINERS_NOT_READY')


def ready_workload(obj):
    generation(obj)
    desired = obj['spec'].get('replicas', 1)
    require(type(desired) is int and desired > 0, 'WORKLOAD_SCALED_TO_ZERO')
    status = obj['status']
    for field in ('replicas', 'readyReplicas', 'updatedReplicas'):
        require(status.get(field) == desired, 'WORKLOAD_REPLICAS_INCOMPLETE')
    if obj['kind'] != 'StatefulSet':
        require(status.get('availableReplicas') == desired, 'WORKLOAD_UNAVAILABLE')
    if obj['kind'] == 'Rollout':
        require(status.get('phase') == 'Healthy' and status.get('currentPodHash') and status.get('stableRS') == status['currentPodHash'], 'ROLLOUT_NOT_COMPLETE')
    if obj['kind'] == 'StatefulSet':
        require(status.get('currentRevision') and status['currentRevision'] == status.get('updateRevision') and status.get('currentReplicas') == desired, 'STATEFUL_REVISION_INCOMPLETE')
    return desired


def eso_ready(obj, earliest=None):
    meta = live(obj)
    version = re.fullmatch(r'([1-9][0-9]*)-([a-zA-Z0-9]+)', obj['status'].get('syncedResourceVersion', ''))
    require(version and int(version[1]) == meta['generation'], 'ESO_GENERATION_NOT_SYNCED')
    refreshed = stamp(obj['status']['refreshTime'])
    require(stamp(meta['creationTimestamp']) <= refreshed <= now() and (now() - refreshed).total_seconds() <= 7200, 'ESO_REFRESH_STALE')
    if earliest is not None:
        require(refreshed > earliest, 'ESO_NOT_REFRESHED_AFTER_BASELINE')
    require(any(c.get('type') == 'Ready' and c.get('status') == 'True' and c.get('reason') == 'SecretSynced' and c.get('message') == 'secret synced' for c in obj['status'].get('conditions', [])), 'ESO_NOT_READY')
    # The suffix is an ESO metadata hash, NOT a provider VersionId. No payload/version
    # claim is inferred from the suffix. A version claim below requires uuid/ pinning.
    return refreshed


class Runtime:
    def __init__(self, context, namespace):
        require(context and namespace, 'CONTEXT_NAMESPACE_REQUIRED')
        self.context, self.namespace = context, namespace

    def get(self, kind, name=None, namespace=None):
        args = ['kubectl', '--context', self.context, '-n', namespace or self.namespace, 'get', kind]
        if name:
            args.append(name)
        return command(*args, '-o', 'json')

    def workload(self, kind='deployment', name='mini-commerce'):
        obj = self.get(kind, name)
        desired = ready_workload(obj)
        replicasets = [r for r in self.get('replicasets')['items'] if owned(r, obj)]
        if obj['kind'] == 'Rollout':
            current = [r for r in replicasets if r['metadata'].get('labels', {}).get('rollouts-pod-template-hash') == obj['status']['currentPodHash']]
        else:
            revision = obj['metadata'].get('annotations', {}).get('deployment.kubernetes.io/revision')
            require(revision, 'DEPLOYMENT_REVISION_MISSING')
            current = [r for r in replicasets if r['metadata'].get('annotations', {}).get('deployment.kubernetes.io/revision') == revision]
        require(len(current) == 1, 'CURRENT_REPLICASET_NOT_UNIQUE')
        rs = current[0]
        generation(rs)
        require(rs['spec'].get('replicas') == desired and rs['status'].get('readyReplicas') == desired and rs['status'].get('replicas') == desired, 'REPLICASET_NOT_READY')
        all_owned = [p for p in self.get('pods')['items'] if any(owned(p, r) for r in replicasets)]
        require(len(all_owned) == desired and all(owned(p, rs) for p in all_owned), 'POD_SET_NOT_CURRENT')
        require(len({p['metadata']['uid'] for p in all_owned}) == desired, 'POD_UID_SET_INVALID')
        for pod in all_owned:
            ready_pod(pod)
        return obj, all_owned

    def core(self):
        nodes = command('kubectl', '--context', self.context, 'get', 'nodes', '-o', 'json')['items']
        require(nodes and all(not n['metadata'].get('deletionTimestamp') and any(c.get('type') == 'Ready' and c.get('status') == 'True' for c in n['status'].get('conditions', [])) for n in nodes), 'NODE_NOT_READY')
        application = self.get('application', 'mini-commerce-dev', 'argocd')
        live(application)
        require(application['status']['sync']['status'] == 'Synced' and application['status']['health']['status'] == 'Healthy' and not application.get('operation'), 'APPLICATION_NOT_READY')
        require(application['spec']['destination']['namespace'] == self.namespace, 'APPLICATION_NAMESPACE_MISMATCH')
        eso_ready(self.get('externalsecret', 'mini-commerce-runtime'))
        self.workload()

    def stateful(self, url):
        require(re.fullmatch(r'https?://[^\s]+', url), 'BASE_URL_INVALID')
        sc = self.get('storageclass', 'mini-commerce-gp3')
        require(sc['provisioner'] == 'ebs.csi.aws.com' and sc['reclaimPolicy'] == 'Delete' and sc['volumeBindingMode'] == 'WaitForFirstConsumer' and sc['allowVolumeExpansion'] is True and sc['parameters'].get('type') == 'gp3' and sc['parameters'].get('encrypted') == 'true', 'STORAGE_CLASS_INVALID')
        db = self.get('statefulset', 'mini-commerce-postgresql')
        require(ready_workload(db) == 1, 'DB_REPLICA_COUNT_INVALID')
        dbpods = [p for p in self.get('pods')['items'] if owned(p, db)]
        require(len(dbpods) == 1, 'DATABASE_POD_NOT_UNIQUE')
        pod = dbpods[0]
        ready_pod(pod)
        require(pod['metadata'].get('labels', {}).get('controller-revision-hash') == db['status']['currentRevision'], 'DATABASE_POD_REVISION_MISMATCH')
        require(pod['metadata']['name'] == db['metadata']['name'] + '-' + str(db['spec'].get('ordinals', {}).get('start', 0)), 'DATABASE_POD_ORDINAL_INVALID')
        templates = db['spec'].get('volumeClaimTemplates', [])
        require(templates, 'DATABASE_CLAIM_TEMPLATE_REQUIRED')
        volumes = {v['name']: v.get('persistentVolumeClaim', {}).get('claimName') for v in pod['spec']['volumes']}
        mounts = {v['name'] for c in pod['spec']['containers'] for v in c.get('volumeMounts', [])}
        for template in templates:
            name = template['metadata']['name']
            expected = name + '-' + pod['metadata']['name']
            require(name in mounts and volumes.get(name) == expected, 'DATABASE_PVC_WIRING_MISMATCH')
            claim = self.get('pvc', expected)
            live(claim)
            require(claim['metadata']['namespace'] == self.namespace and claim['status']['phase'] == 'Bound' and claim['spec']['storageClassName'] == 'mini-commerce-gp3' and claim['spec'].get('volumeName'), 'PVC_NOT_BOUND')
            volume = self.get('pv', claim['spec']['volumeName'])
            ref = volume['spec']['claimRef']
            require(ref.get('uid') == claim['metadata']['uid'] and ref.get('name') == expected and ref.get('namespace') == self.namespace and volume['status']['phase'] == 'Bound' and volume['spec']['csi']['driver'] == 'ebs.csi.aws.com', 'PV_CLAIM_IDENTITY_MISMATCH')
        job = self.get('job', 'mini-commerce-migration')
        live(job)
        require(job['status'].get('succeeded') == job['spec'].get('completions', 1) and not job['status'].get('active') and not job['status'].get('failed') and any(c.get('type') == 'Complete' and c.get('status') == 'True' for c in job['status'].get('conditions', [])), 'MIGRATION_NOT_COMPLETE')
        jobpods = [p for p in self.get('pods')['items'] if owned(p, job)]
        require(jobpods and all(not p['metadata'].get('deletionTimestamp') and p['status'].get('phase') == 'Succeeded' for p in jobpods), 'MIGRATION_POD_NOT_COMPLETE')
        self.workload()
        # Operational readiness must not create orders or depend on demo SKUs/prices.
        products = command('curl', '--fail', '--silent', '--show-error', '--max-time', '5', url.rstrip('/') + '/products')
        require(isinstance(products.get('products'), list), 'PRODUCTS_API_INVALID')

    def secret_state(self, external_name, rollout_name, source):
        region, profile = os.environ['AWS_REGION'], os.environ['AWS_PROFILE']
        require(region in ('ap-northeast-2', 'us-east-1') and profile, 'AWS_IDENTITY_REQUIRED')
        identity = command('aws', 'sts', 'get-caller-identity', '--profile', profile, '--region', region, '--output', 'json')
        secret = command('aws', 'secretsmanager', 'describe-secret', '--secret-id', source, '--profile', profile, '--region', region, '--output', 'json')
        require(source in (secret['ARN'], secret['Name']) and secret['ARN'].startswith('arn:aws:secretsmanager:' + region + ':' + identity['Account'] + ':secret:') and not secret.get('DeletedDate'), 'SECRET_SOURCE_IDENTITY_MISMATCH')
        current = [v for v, stages in secret['VersionIdsToStages'].items() if 'AWSCURRENT' in stages]
        require(len(current) == 1, 'AWSCURRENT_NOT_UNIQUE')
        es = self.get('externalsecret', external_name)
        refreshed = eso_ready(es)
        require(es['spec']['target']['name'] == 'mini-commerce-runtime' and es['spec']['target']['creationPolicy'] == 'Owner' and not es['spec'].get('dataFrom'), 'RUNTIME_SECRET_TARGET_REQUIRED')
        data = es['spec']['data']
        require(len(data) == 1 and data[0]['secretKey'] == 'API_KEY' and data[0]['remoteRef']['property'] == 'API_KEY' and data[0]['remoteRef']['key'] in (secret['ARN'], secret['Name']), 'EXTERNAL_SECRET_SOURCE_MISMATCH')
        store_ref = es['spec']['secretStoreRef']
        require(store_ref['kind'] == 'SecretStore', 'NAMESPACED_STORE_REQUIRED')
        store = self.get('secretstore', store_ref['name'])
        provider = store['spec']['provider']['aws']
        require(provider['region'] == region and provider['service'] == 'SecretsManager', 'SECRET_STORE_REGION_MISMATCH')
        # Only metadata is returned; Secret.data is never captured or printed.
        metadata = command('kubectl', '--context', self.context, '-n', self.namespace, 'get', 'secret', 'mini-commerce-runtime', '-o', 'jsonpath={.metadata}')
        target = {'metadata': metadata}
        live(target)
        require(owned(target, es), 'TARGET_SECRET_OWNER_MISMATCH')
        rollout, pods = self.workload('rollout', rollout_name)
        for container in rollout['spec']['template']['spec']['containers']:
            if any(e.get('secretRef', {}).get('name') == 'mini-commerce-runtime' for e in container.get('envFrom', [])) or any(e.get('valueFrom', {}).get('secretKeyRef', {}).get('name') == 'mini-commerce-runtime' for e in container.get('env', [])):
                break
        else:
            raise ValueError('ROLLOUT_DOES_NOT_CONSUME_RUNTIME_SECRET')
        kube = command('kubectl', '--context', self.context, 'config', 'view', '--minify', '-o', 'json')
        cluster = kube['clusters'][0]['cluster']['server']
        return secret, current[0], es, refreshed, rollout, pods, cluster

    def rotation(self, mode, external, rollout_name, source, *args):
        baseline_path = args[0] if mode == 'secret-baseline' else args[1]
        path = Path(baseline_path)
        require(not path.is_symlink(), 'BASELINE_SYMLINK_REJECTED')
        if mode == 'secret-baseline':
            require(not path.exists(), 'BASELINE_ALREADY_EXISTS')
        else:
            require(path.is_file(), 'BASELINE_FILE_REQUIRED_SINGLE_UID_UNSUPPORTED')
        secret, version, es, refreshed, rollout, pods, cluster = self.secret_state(external, rollout_name, source)
        identity = {'context': self.context, 'clusterEndpoint': cluster, 'namespace': self.namespace, 'externalSecretUid': es['metadata']['uid'], 'rolloutUid': rollout['metadata']['uid'], 'sourceArn': secret['ARN']}
        if mode == 'secret-baseline':
            value = {'schemaVersion': 'platform.secret-rotation-baseline/v1', 'identity': identity, 'observedAt': now().isoformat(), 'sourceVersionId': version, 'rolloutGeneration': rollout['metadata']['generation'], 'podUids': sorted(p['metadata']['uid'] for p in pods), 'evidenceGrade': 'STATIC' if os.environ.get('PLATFORM_CHECK_BIN_DIR') else 'RUNTIME_OBSERVATION'}
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as stream:
                json.dump(value, stream, indent=2)
                stream.write('\n')
            print('BASELINE_CAPTURED: complete owned Pod UID set; no secret payload')
            return
        expected = args[0]
        baseline = json.loads(path.read_text())
        require(baseline['schemaVersion'] == 'platform.secret-rotation-baseline/v1' and baseline['identity'] == identity, 'BASELINE_IDENTITY_MISMATCH')
        require(baseline['evidenceGrade'] == ('STATIC' if os.environ.get('PLATFORM_CHECK_BIN_DIR') else 'RUNTIME_OBSERVATION'), 'BASELINE_ORIGIN_MISMATCH')
        observed = stamp(baseline['observedAt'])
        require(0 <= (now() - observed).total_seconds() <= 7200, 'BASELINE_STALE')
        require(expected == version and expected != baseline['sourceVersionId'], 'VERSION_NOT_ROTATED_OR_NOT_CURRENT')
        require(es['spec']['data'][0]['remoteRef']['key'] == secret['ARN'], 'VERSION_PROOF_REQUIRES_EXACT_SOURCE_ARN')
        require(es['spec']['data'][0]['remoteRef'].get('version') == 'uuid/' + expected, 'PROVIDER_VERSION_UNPROVEN_REQUIRE_UUID_PIN')
        eso_ready(es, observed)
        before = baseline['podUids']
        require(isinstance(before, list) and before and len(set(before)) == len(before) and all(isinstance(uid, str) and uid for uid in before), 'BASELINE_POD_SET_INVALID')
        require(rollout['metadata']['generation'] > baseline['rolloutGeneration'], 'ROLLOUT_NOT_UPDATED_AFTER_BASELINE')
        require(not set(before).intersection(p['metadata']['uid'] for p in pods), 'OLD_PODS_REMAIN')
        require(all(refreshed < stamp(p['metadata']['creationTimestamp']) <= now() for p in pods), 'PODS_NOT_CREATED_AFTER_SYNC')
        print('SECRET_RELOAD: pinned AWSCURRENT version, fresh ESO spec, and complete owned Pod replacement verified')


def main():
    mode, args = sys.argv[1], sys.argv[2:]
    counts = {'core': 2, 'stateful': 3, 'secret-baseline': 6, 'secret-freshness': 7}
    require(mode in counts and len(args) == counts[mode], 'USAGE_core_CONTEXT_NAMESPACE_stateful_CONTEXT_NAMESPACE_URL_secret-baseline_CONTEXT_NAMESPACE_ES_ROLLOUT_SOURCE_OUTPUT_secret-freshness_CONTEXT_NAMESPACE_ES_ROLLOUT_SOURCE_VERSION_BASELINE')
    runtime = Runtime(*args[:2])
    if mode == 'core':
        runtime.core()
    elif mode == 'stateful':
        runtime.stateful(args[2])
    else:
        runtime.rotation(mode, *args[2:])
    print('DETAIL: observed runtime checks passed; file-only validation is not live evidence')


try:
    main()
except (ValueError, KeyError, TypeError, IndexError, OSError, subprocess.SubprocessError):
    # External stderr or secret-bearing objects must never be logged.
    error = sys.exc_info()[1]
    reason = str(error) if type(error) is ValueError and re.fullmatch(r'[A-Za-z0-9_]+', str(error)) else 'RUNTIME_INPUT_OR_COMMAND_INVALID'
    print('ERROR: ' + reason, file=sys.stderr)
    sys.exit(1)
