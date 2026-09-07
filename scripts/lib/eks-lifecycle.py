#!/usr/bin/env python3
"""Collect EKS readiness and AWS addon compatibility, without upgrading resources.

Collection requests an EKS insights refresh. `validate` only checks a local snapshot
and never upgrades its provenance to CLOUD_RUNTIME.
"""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ADDONS = ('coredns', 'kube-proxy', 'vpc-cni', 'aws-ebs-csi-driver')
CONTROLLERS = {
    'cluster-autoscaler': ('kube-system', r'cluster-autoscaler'),
    'argocd': ('argocd', r'argocd-(server|repo-server|application-controller|applicationset-controller)'),
    'rollouts': ('argo-rollouts', r'argo-rollouts'),
    'external-secrets': ('external-secrets', r'external-secrets(?:-webhook|-cert-controller)?'),
    'adot': ('opentelemetry-operator-system', r'adot-collector-prometheus-collector'),
    'istiod': ('istio-system', r'istiod(?:-[a-z0-9-]+)?'),
}


def require(value, code):
    if not value:
        raise ValueError(code)


def timestamp(value):
    # AWS CLI serializes service timestamps as ISO strings.
    result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(result.tzinfo is not None, 'TIMESTAMP_TIMEZONE_REQUIRED')
    return result


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    require(result.returncode == 0, 'LIFECYCLE_COMMAND_FAILED')
    return json.loads(result.stdout)


def controller_ready(obj):
    meta, status, spec = obj['metadata'], obj['status'], obj['spec']
    require(meta.get('uid') and not meta.get('deletionTimestamp'), 'CONTROLLER_DELETING')
    require(type(meta['generation']) is int and status.get('observedGeneration') == meta['generation'], 'CONTROLLER_STATUS_STALE')
    if obj['kind'] == 'DaemonSet':
        desired = status.get('desiredNumberScheduled', 0)
        require(desired > 0 and all(status.get(k) == desired for k in ('currentNumberScheduled', 'updatedNumberScheduled', 'numberReady', 'numberAvailable')) and status.get('numberMisscheduled', 0) == 0, 'CONTROLLER_NOT_READY')
    else:
        desired = spec.get('replicas', 1)
        require(desired > 0 and all(status.get(k) == desired for k in ('replicas', 'readyReplicas', 'updatedReplicas')), 'CONTROLLER_NOT_READY')
        if obj['kind'] == 'Deployment':
            require(status.get('availableReplicas') == desired, 'CONTROLLER_NOT_AVAILABLE')
        elif obj['kind'] == 'StatefulSet':
            require(status.get('currentRevision') and status['currentRevision'] == status.get('updateRevision') and status.get('currentReplicas') == desired, 'CONTROLLER_REVISION_STALE')
        else:
            raise ValueError('UNSUPPORTED_CONTROLLER_KIND')


def validate(x):
    current = dt.datetime.now(dt.timezone.utc)
    require(x['schemaVersion'] == 'platform.eks-upgrade-preflight/v2', 'SNAPSHOT_SCHEMA_UNSUPPORTED')
    observed = timestamp(x['observedAt'])
    require(0 <= (current - observed).total_seconds() <= 900, 'UPGRADE_OBSERVATIONS_STALE')
    source, target = x['fromVersion'], x['toVersion']
    require(re.fullmatch(r'1\.\d+', source) and re.fullmatch(r'1\.\d+', target), 'KUBERNETES_VERSION_INVALID')
    require(int(target.split('.')[1]) - int(source.split('.')[1]) in (0, 1), 'ONE_MINOR_UPGRADE_REQUIRED')
    cluster = x['clusterObservation']
    require(cluster['status'] == 'ACTIVE' and cluster['name'] == x['cluster'] and cluster['version'] == source and cluster['arn'] == x['clusterArn'], 'CLUSTER_IDENTITY_OR_VERSION_MISMATCH')
    require(x['clusterArn'] == 'arn:aws:eks:' + x['region'] + ':' + x['accountId'] + ':cluster/' + x['cluster'], 'CLUSTER_ACCOUNT_MISMATCH')
    refresh = x['refresh']
    require(refresh['status'] == 'COMPLETED', 'INSIGHTS_REFRESH_INCOMPLETE')
    start, end = timestamp(refresh['startedAt']), timestamp(refresh['endedAt'])
    require(start <= end <= observed and 0 <= (current - end).total_seconds() <= 900, 'INSIGHTS_REFRESH_STALE')
    summaries = {i['id']: i for i in x['insights']}
    details = {i['insight']['id']: i['insight'] for i in x['details']}
    require(summaries and len(summaries) == len(x['insights']) and len(details) == len(x['details']) and summaries.keys() == details.keys(), 'INSIGHTS_MISSING_OR_MISMATCHED')
    for key, insight in summaries.items():
        for item in (insight, details[key]):
            require(item['kubernetesVersion'] == target and item['category'] == 'UPGRADE_READINESS' and item['insightStatus']['status'] == 'PASSING', 'INSIGHT_NOT_PASS')
            require(start <= timestamp(item['lastRefreshTime']) <= observed, 'INSIGHT_DETAIL_STALE')
        require(all(r.get('insightStatus', {}).get('status') == 'PASSING' for r in details[key].get('resources', [])), 'UNSUPPORTED_API')
    nodes = x['nodes']['items']
    require(nodes, 'NO_NODES')
    for node in nodes:
        require(not node['metadata'].get('deletionTimestamp') and any(c.get('type') == 'Ready' and c.get('status') == 'True' for c in node['status'].get('conditions', [])), 'NODE_NOT_READY')
    architectures = {n['metadata']['labels']['kubernetes.io/arch'] for n in nodes}
    require(architectures and architectures <= {'amd64', 'arm64'}, 'NODE_ARCHITECTURE_UNKNOWN')
    for pdb in x['pdbs']['items']:
        require(not pdb['metadata'].get('deletionTimestamp') and pdb['status'].get('observedGeneration') == pdb['metadata']['generation'], 'PDB_STATUS_STALE')
        require(pdb['status'].get('disruptionsAllowed', 0) > 0, 'PDB_BLOCKS_DISRUPTION')
    installed = x['installedAddonNames']
    require(set(ADDONS) <= set(installed) and set(x['addons']) == set(installed) and set(x['addonCompatibility']) == set(installed), 'ADDON_INVENTORY_INCOMPLETE')
    for name in installed:
        addon = x['addons'][name]
        require(addon['addonName'] == name and addon['clusterName'] == x['cluster'] and addon['status'] == 'ACTIVE' and addon['health']['issues'] == [], 'ADDON_NOT_ACTIVE')
        require(addon['addonArn'].startswith('arn:aws:eks:' + x['region'] + ':' + x['accountId'] + ':addon/' + x['cluster'] + '/' + name + '/'), 'ADDON_IDENTITY_MISMATCH')
        response = x['addonCompatibility'][name]
        require(not response.get('nextToken'), 'ADDON_COMPATIBILITY_INCOMPLETE')
        matches = [v for a in response['addons'] if a['addonName'] == name for v in a['addonVersions'] if v['addonVersion'] == addon['addonVersion']]
        require(len(matches) == 1 and architectures <= set(matches[0]['architecture']), 'ADDON_VERSION_OR_ARCHITECTURE_UNSUPPORTED')
        platform = cluster['platformVersion'] if source == target else None
        require(any(c['clusterVersion'] == target and ('*' in c['platformVersions'] or (platform and platform in c['platformVersions'])) for c in matches[0]['compatibilities']), 'ADDON_TARGET_COMPATIBILITY_UNPROVEN')
    controllers = x['controllers']['items']
    for namespace, pattern in CONTROLLERS.values():
        matches = [c for c in controllers if c['metadata'].get('namespace') == namespace and re.fullmatch(pattern, c['metadata']['name'])]
        require(matches, 'CONTROLLER_INVENTORY_INCOMPLETE')
        for controller in matches:
            controller_ready(controller)
    ng = x['nodegroup']
    require(ng['clusterName'] == x['cluster'] and ng['nodegroupName'] == x['nodegroupName'] and ng['status'] == 'ACTIVE' and ng['health']['issues'] == [], 'NODEGROUP_UNHEALTHY')
    require(ng['releaseVersion'] == x['expectedRelease'] and ng['version'] == source, 'NODE_RELEASE_OR_VERSION_MISMATCH')
    group_nodes = [n for n in nodes if n['metadata']['labels'].get('eks.amazonaws.com/nodegroup') == ng['nodegroupName']]
    require(group_nodes, 'NODEGROUP_NODES_MISSING')
    for node in group_nodes:
        require(re.match(r'^v' + re.escape(source) + r'\.', node['status']['nodeInfo']['kubeletVersion']), 'NODEGROUP_KUBELET_VERSION_MISMATCH')


def collect(cluster, region, old, new, nodegroup, release, output):
    path = Path(output)
    require(not path.exists() and not path.is_symlink() and path.parent.is_dir(), 'OUTPUT_ALREADY_EXISTS_OR_PARENT_MISSING')
    aws = lambda *args: run('aws', 'eks', *args, '--region', region, '--output', 'json')
    identity = run('aws', 'sts', 'get-caller-identity', '--region', region, '--output', 'json')
    cluster_data = aws('describe-cluster', '--name', cluster)['cluster']
    require(cluster_data['version'] == old, 'SOURCE_CLUSTER_VERSION_MISMATCH')
    context = run('kubectl', 'config', 'view', '--minify', '-o', 'json')
    require(context['clusters'][0]['cluster']['server'] == cluster_data['endpoint'], 'KUBECONFIG_CLUSTER_MISMATCH')
    aws('start-insights-refresh', '--cluster-name', cluster)
    deadline = time.monotonic() + 300
    while True:
        refresh = aws('describe-insights-refresh', '--cluster-name', cluster)
        if refresh['status'] == 'COMPLETED':
            break
        require(refresh['status'] != 'FAILED' and time.monotonic() < deadline, 'INSIGHTS_REFRESH_TIMEOUT')
        time.sleep(10)
    insights = aws('list-insights', '--cluster-name', cluster, '--filter', json.dumps({'categories': ['UPGRADE_READINESS'], 'kubernetesVersions': [new]}))['insights']
    details = [aws('describe-insight', '--cluster-name', cluster, '--id', i['id']) for i in insights]
    installed = aws('list-addons', '--cluster-name', cluster)['addons']
    addons = {n: aws('describe-addon', '--cluster-name', cluster, '--addon-name', n)['addon'] for n in installed}
    compatibility = {n: aws('describe-addon-versions', '--addon-name', n, '--kubernetes-version', new) for n in installed}
    x = {'schemaVersion': 'platform.eks-upgrade-preflight/v2', 'cluster': cluster, 'region': region, 'accountId': identity['Account'], 'clusterArn': cluster_data['arn'], 'clusterObservation': cluster_data, 'fromVersion': old, 'toVersion': new, 'refresh': refresh, 'insights': insights, 'details': details, 'installedAddonNames': installed, 'addons': addons, 'addonCompatibility': compatibility, 'nodes': run('kubectl', 'get', 'nodes', '-o', 'json'), 'pdbs': run('kubectl', 'get', 'pdb', '-A', '-o', 'json'), 'controllers': run('kubectl', 'get', 'deploy,statefulset,daemonset', '-A', '-o', 'json'), 'nodegroup': aws('describe-nodegroup', '--cluster-name', cluster, '--nodegroup-name', nodegroup)['nodegroup'], 'nodegroupName': nodegroup, 'expectedRelease': release, 'observedAt': dt.datetime.now(dt.timezone.utc).isoformat()}
    validate(x)
    x.update(evidenceGrade='STATIC' if os.environ.get('PLATFORM_CHECK_BIN_DIR') else 'CLOUD_RUNTIME', decision='PASS', verificationScope='current-runtime-and-aws-addon-target-compatibility; third-party-controller-target-support-not-proven', observationsSha256=hashlib.sha256(json.dumps(x, sort_keys=True).encode()).hexdigest())
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(x, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'validate':
            validate(json.loads(Path(sys.argv[2]).read_text()))
            print('PASS: [STATIC] local snapshot semantics only; no live compatibility or rollout completion claim')
        elif sys.argv[1] == 'collect':
            collect(*sys.argv[2:])
        else:
            raise ValueError('USAGE_VALIDATE_FILE_OR_COLLECT_CLUSTER_REGION_FROM_TO_NODEGROUP_RELEASE_OUTPUT')
    except (ValueError, KeyError, TypeError, IndexError, OSError, subprocess.SubprocessError):
        error = sys.exc_info()[1]
        reason = str(error) if type(error) is ValueError and re.fullmatch(r'[A-Z_]+', str(error)) else 'LIFECYCLE_INPUT_OR_COMMAND_INVALID'
        print('ERROR: ' + reason, file=sys.stderr)
        sys.exit(1)
