import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lifecycle', ROOT / 'scripts/lib/eks-lifecycle.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def fixture():
    stamp = lambda seconds: (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=seconds)).isoformat()
    cluster = {'name': 'fixture', 'arn': 'arn:aws:eks:ap-northeast-2:123456789012:cluster/fixture', 'version': '1.35', 'status': 'ACTIVE', 'platformVersion': 'eks.1', 'endpoint': 'https://cluster.invalid'}
    insight = {'id': 'i', 'category': 'UPGRADE_READINESS', 'kubernetesVersion': '1.36', 'lastRefreshTime': stamp(-10), 'insightStatus': {'status': 'PASSING'}}
    addons, compatible = {}, {}
    for name in m.ADDONS:
        version = 'v1.2.3-eksbuild.1'
        addons[name] = {'addonName': name, 'clusterName': 'fixture', 'addonArn': 'arn:aws:eks:ap-northeast-2:123456789012:addon/fixture/' + name + '/uuid', 'status': 'ACTIVE', 'addonVersion': version, 'health': {'issues': []}}
        compatible[name] = {'addons': [{'addonName': name, 'addonVersions': [{'addonVersion': version, 'architecture': ['amd64', 'arm64'], 'compatibilities': [{'clusterVersion': '1.36', 'platformVersions': ['*']}]}]}]}
    controllers = []
    for namespace, name in [('kube-system', 'cluster-autoscaler'), ('argocd', 'argocd-server'), ('argo-rollouts', 'argo-rollouts'), ('external-secrets', 'external-secrets'), ('opentelemetry-operator-system', 'adot-collector-prometheus-collector'), ('istio-system', 'istiod-stable')]:
        controllers.append({'kind': 'Deployment', 'metadata': {'name': name, 'namespace': namespace, 'uid': name + '-uid', 'generation': 2}, 'spec': {'replicas': 2}, 'status': {'observedGeneration': 2, 'replicas': 2, 'readyReplicas': 2, 'availableReplicas': 2, 'updatedReplicas': 2}})
    return {'schemaVersion': 'platform.eks-upgrade-preflight/v2', 'cluster': 'fixture', 'region': 'ap-northeast-2', 'accountId': '123456789012', 'clusterArn': cluster['arn'], 'clusterObservation': cluster, 'fromVersion': '1.35', 'toVersion': '1.36', 'observedAt': stamp(0), 'refresh': {'status': 'COMPLETED', 'startedAt': stamp(-30), 'endedAt': stamp(-5)}, 'insights': [copy.deepcopy(insight)], 'details': [{'insight': dict(insight, resources=[])}], 'installedAddonNames': list(addons), 'addons': addons, 'addonCompatibility': compatible, 'nodes': {'items': [{'metadata': {'name': 'node', 'labels': {'kubernetes.io/arch': 'amd64', 'eks.amazonaws.com/nodegroup': 'workers'}}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}], 'nodeInfo': {'kubeletVersion': 'v1.35.3-eks-build'}}}]}, 'pdbs': {'items': [{'metadata': {'generation': 2}, 'status': {'observedGeneration': 2, 'disruptionsAllowed': 1}}]}, 'controllers': {'items': controllers}, 'nodegroup': {'nodegroupName': 'workers', 'clusterName': 'fixture', 'status': 'ACTIVE', 'version': '1.35', 'releaseVersion': '1.35.3-20260901', 'health': {'issues': []}}, 'nodegroupName': 'workers', 'expectedRelease': '1.35.3-20260901'}


class Lifecycle(unittest.TestCase):
    def test_real_api_shaped_compatibility_and_optional_snapshot(self):
        m.validate(fixture())

    def test_rejects_health_and_unsupported_target(self):
        for mutate in (
            lambda x: x['refresh'].update(status='FAILED'),
            lambda x: x['details'][0]['insight'].update(id='different-insight'),
            lambda x: x['details'][0]['insight'].update(lastRefreshTime='2020-01-01T00:00:00Z'),
            lambda x: x['details'][0]['insight'].update(resources=[{'insightStatus': {'status': 'ERROR'}}]),
            lambda x: x['addons']['coredns'].update(status='DEGRADED'),
            lambda x: x['addons']['coredns']['health'].update(issues=[{'code': 'InsufficientNumberOfReplicas'}]),
            lambda x: x['addons']['coredns'].update(addonVersion='unknown-version'),
            lambda x: x['addonCompatibility']['coredns']['addons'][0]['addonVersions'][0].update(architecture=['arm64']),
            lambda x: x['addonCompatibility']['coredns']['addons'][0]['addonVersions'][0]['compatibilities'][0].update(clusterVersion='1.35'),
            lambda x: x['addonCompatibility']['coredns']['addons'][0]['addonVersions'][0]['compatibilities'][0].update(platformVersions=['eks.unknown']),
            lambda x: x['addonCompatibility']['coredns'].update(nextToken='truncated'),
            lambda x: x['installedAddonNames'].append('unobserved-addon'),
            lambda x: x['controllers']['items'][0]['status'].update(readyReplicas=0),
            lambda x: x['controllers']['items'][0]['status'].update(observedGeneration=1),
            lambda x: x['controllers']['items'][0]['metadata'].update(namespace='other-namespace'),
            lambda x: x['controllers']['items'][0]['metadata'].update(name='not-cluster-autoscaler'),
            lambda x: x['pdbs']['items'][0]['status'].update(observedGeneration=1),
            lambda x: x['pdbs']['items'][0]['status'].update(disruptionsAllowed=0),
            lambda x: x['nodes']['items'][0]['status']['nodeInfo'].update(kubeletVersion='v1.34.1'),
            lambda x: x['nodegroup'].update(version='1.34'),
            lambda x: x['nodegroup'].update(releaseVersion='wrong'),
            lambda x: x.update(toVersion='1.38'),
            lambda x: x.update(observedAt='2020-01-01T00:00:00Z'),
        ):
            x = fixture()
            mutate(x)
            with self.subTest(mutation=mutate):
                with self.assertRaises(ValueError):
                    m.validate(x)

    def test_local_validate_never_emits_cloud_grade(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'observations.json'
            path.write_text(json.dumps(dict(fixture(), evidenceGrade='CLOUD_RUNTIME')))
            r = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/lib/eks-lifecycle.py'), 'validate', str(path)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('[STATIC]', r.stdout)
            self.assertNotIn('CLOUD_RUNTIME', r.stdout)

    def test_collector_queries_real_compatibility_api(self):
        x = fixture()
        calls = []
        def fake(*args):
            calls.append(args)
            if args[:3] == ('aws', 'sts', 'get-caller-identity'):
                return {'Account': x['accountId']}
            if args[0] == 'kubectl':
                if 'config' in args:
                    return {'clusters': [{'cluster': {'server': x['clusterObservation']['endpoint']}}]}
                return {'nodes': x['nodes'], 'pdb': x['pdbs'], 'deploy,statefulset,daemonset': x['controllers']}[args[2]]
            action = args[2]
            if action == 'describe-cluster': return {'cluster': x['clusterObservation']}
            if action == 'start-insights-refresh': return {}
            if action == 'describe-insights-refresh': return x['refresh']
            if action == 'list-insights': return {'insights': x['insights']}
            if action == 'describe-insight': return x['details'][0]
            if action == 'list-addons': return {'addons': x['installedAddonNames']}
            if action == 'describe-nodegroup': return {'nodegroup': x['nodegroup']}
            name = args[args.index('--addon-name') + 1]
            if action == 'describe-addon': return {'addon': x['addons'][name]}
            if action == 'describe-addon-versions':
                self.assertIn('--kubernetes-version', args)
                self.assertEqual(args[args.index('--kubernetes-version') + 1], '1.36')
                return x['addonCompatibility'][name]
            raise AssertionError(args)
        with tempfile.TemporaryDirectory() as directory, patch.object(m, 'run', side_effect=fake), patch.dict(os.environ, {'PLATFORM_CHECK_BIN_DIR': directory}):
            path = Path(directory) / 'output.json'
            m.collect('fixture', 'ap-northeast-2', '1.35', '1.36', 'workers', x['expectedRelease'], path)
            value = json.loads(path.read_text())
            self.assertEqual(value['evidenceGrade'], 'STATIC')
            self.assertEqual(len([c for c in calls if 'describe-addon-versions' in c]), len(m.ADDONS))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                m.collect('fixture', 'ap-northeast-2', '1.35', '1.36', 'workers', x['expectedRelease'], path)

    def test_stateful_and_daemonset_status(self):
        stateful = {'kind': 'StatefulSet', 'metadata': {'uid': 's', 'generation': 1}, 'spec': {'replicas': 1}, 'status': {'observedGeneration': 1, 'replicas': 1, 'readyReplicas': 1, 'updatedReplicas': 1, 'currentReplicas': 1, 'currentRevision': 'r', 'updateRevision': 'r'}}
        m.controller_ready(stateful)
        stateful['status'].pop('currentRevision')
        with self.assertRaises(ValueError): m.controller_ready(stateful)
        ds = {'kind': 'DaemonSet', 'metadata': {'uid': 'd', 'generation': 1}, 'spec': {}, 'status': {'observedGeneration': 1, 'desiredNumberScheduled': 2, 'currentNumberScheduled': 2, 'updatedNumberScheduled': 2, 'numberReady': 2, 'numberAvailable': 2}}
        m.controller_ready(ds)
        ds['status']['numberReady'] = 1
        with self.assertRaises(ValueError): m.controller_ready(ds)


if __name__ == '__main__':
    unittest.main(verbosity=2)
