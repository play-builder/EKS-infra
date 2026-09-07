#!/usr/bin/env python3
"""Offline Dev runtime verification through real SDK models and SigV4 signing.

Run in requirements-amp-slo.txt venv. --terraform additionally validates freshly
rendered provider rule/Alertmanager blobs (Terraform mock_provider, no cloud).
Every fixture is test-only; the public CLI has no fixture-to-runtime switch.
"""
import base64
import copy
import datetime as dt
import hashlib
import importlib.util
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import boto3
import yaml
from botocore.stub import Stubber

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dev = load("dev", ROOT / "scripts/lib/dev-evidence.py")
drill_fixture = load("drill_fixture", ROOT / "tests/amp-slo-drill-contract.py")
NOW = int(dt.datetime.now(dt.timezone.utc).timestamp())
ACCOUNT, REGION = "123456789012", "ap-northeast-2"
WORKSPACE_ID = "ws-test"
WORKSPACE = f"arn:aws:aps:{REGION}:{ACCOUNT}:workspace/{WORKSPACE_ID}"
TOPIC = f"arn:aws:sns:{REGION}:{ACCOUNT}:test-alerts"
SUBSCRIPTION = TOPIC + ":00000000-0000-0000-0000-000000000001"
ENDPOINT = "https://alerts.example.com/sns"
CHILD = "sha256:" + "c" * 64
CERT = None
PRIVATE_KEY = None
TERRAFORM = "--terraform" in sys.argv
if TERRAFORM:
    sys.argv.remove("--terraform")


def stamp(offset=0):
    return dev.stamp(NOW + offset)


def vector(value="1", metric=None, offset=-1):
    return {"status": "success", "data": {"resultType": "vector", "result": [{"metric": metric or {}, "value": [NOW + offset, str(value)]}]}}


def namespace_fixture():
    rules = []
    expressions, traffic = {}, {}
    for key, window in (("short", "5m"), ("long", "1h")):
        traffic[key] = 'sum(rate(istio_requests_total{' + dev.SELECTOR + '}[' + window + ']))'
        expressions[key] = '(sum(rate(istio_requests_total{' + dev.SELECTOR + ',response_code=~"5.."}[' + window + '])) / ' + traffic[key] + ') / (1 - 0.999)'
        rules.append({"record": "mini_commerce:success_burn:" + key, "expr": expressions[key], "labels": dev.LABELS})
    rules.append({"alert": "MiniCommerceSuccessBurn", "expr": '(' + expressions['short'] + ' > 14.4) and (' + expressions['long'] + ' > 14.4) and (' + traffic['short'] + ' >= 0.1) and (' + traffic['long'] + ' >= 0.1)',
                  "for": "1m", "labels": {**dev.LABELS, "severity": "critical", "runbook": "https://example.com/runbook"}})
    return {"name": dev.RULE_NAMESPACE, "arn": f"arn:aws:aps:{REGION}:{ACCOUNT}:rulegroupsnamespace/{WORKSPACE_ID}/{dev.RULE_NAMESPACE}",
            "status": {"statusCode": "ACTIVE"}, "data": yaml.safe_dump({"groups": [{"name": dev.RULE_NAMESPACE, "rules": rules}]}).encode(),
            "createdAt": NOW - 10000, "modifiedAt": NOW - 10000}


def alertmanager_fixture():
    config = {"route": {"receiver": "platform-sns"}, "receivers": [{"name": "platform-sns", "sns_configs": [{"topic_arn": TOPIC, "sigv4": {"region": REGION}, "send_resolved": True}]}]}
    return {"status": {"statusCode": "ACTIVE"}, "data": yaml.safe_dump({"alertmanager_config": yaml.safe_dump(config)}).encode(), "createdAt": NOW - 10000, "modifiedAt": NOW - 10000}


def sign(envelope):
    fields = ["Message", "MessageId"] + (["Subject"] if "Subject" in envelope else []) + ["Timestamp", "TopicArn", "Type"]
    message = "".join(k + "\n" + envelope[k] + "\n" for k in fields).encode()
    result = subprocess.run(["openssl", "dgst", "-sha256" if envelope["SignatureVersion"] == "2" else "-sha1", "-sign", PRIVATE_KEY], input=message, capture_output=True, check=True)
    envelope["Signature"] = base64.b64encode(result.stdout).decode()


class Fixture:
    def __init__(self):
        self.data = json.loads((ROOT / "tests/fixtures/dev-deployment-valid.json").read_text())
        manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [{"digest": CHILD, "mediaType": "application/vnd.oci.image.manifest.v1+json", "size": 123, "platform": {"os": "linux", "architecture": "arm64"}}]})
        digest = "sha256:" + hashlib.sha256(manifest.encode()).hexdigest()
        self.data["image"]["indexDigest"] = digest
        self.data["observedAt"] = stamp(-7000)
        self.index = {"images": [{"imageId": {"imageDigest": digest}, "imageManifest": manifest}]}
        self.image = self.data["image"]["repository"] + "@" + digest
        self.cluster = {"arn": self.data["clusterArn"], "status": "ACTIVE", "endpoint": "https://TEST.gr7.ap-northeast-2.eks.amazonaws.com", "certificateAuthority": {"data": base64.b64encode(b"cluster-ca").decode()}}
        self.config = {"contexts": [{"name": "dev", "context": {"cluster": "dev"}}], "clusters": [{"name": "dev", "cluster": {"server": self.cluster["endpoint"], "certificate-authority-data": self.cluster["certificateAuthority"]["data"]}}]}
        source = {"repoURL": "https://github.com/play-builder/argocd-gitops.git", "path": "charts/mini-commerce", "targetRevision": "main"}
        destination = {"namespace": "app-dev", "server": "https://kubernetes.default.svc"}
        self.app = {"metadata": {"name": "mini-commerce-dev", "namespace": "argocd", "uid": "app-uid", "generation": 7, "resourceVersion": "10"},
                    "spec": {"source": source, "destination": destination}, "status": {"sync": {"status": "Synced", "revision": self.data["gitopsRevision"], "comparedTo": {"source": copy.deepcopy(source), "destination": copy.deepcopy(destination)}},
                    "health": {"status": "Healthy"}, "reconciledAt": stamp(-3), "resources": [{"kind": "Deployment", "group": "apps", "namespace": "app-dev", "name": "mini-commerce", "status": "Synced"}]}}
        self.namespace = {"metadata": {"name": "app-dev", "labels": {"environment": "dev", "istio.io/rev": "1-30-4"}}}
        self.deployment = {"metadata": {"name": "mini-commerce", "namespace": "app-dev", "uid": "deployment-uid", "generation": 4, "resourceVersion": "12", "annotations": {"argocd.argoproj.io/tracking-id": "mini-commerce-dev:apps/Deployment:app-dev/mini-commerce"}},
                           "spec": {"replicas": 1, "selector": {"matchLabels": {"app": "mini-commerce"}}, "template": {"spec": {"containers": [{"name": "mini-commerce", "image": self.image}]}}},
                           "status": {"observedGeneration": 4, "replicas": 1, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1}}
        self.rs = {"items": [{"metadata": {"uid": "rs-uid", "generation": 1, "ownerReferences": [{"controller": True, "kind": "Deployment", "uid": "deployment-uid"}]}, "spec": {"template": copy.deepcopy(self.deployment["spec"]["template"])}, "status": {"observedGeneration": 1}}]}
        self.pods = {"items": [{"metadata": {"uid": "pod-uid", "resourceVersion": "14", "namespace": "app-dev", "ownerReferences": [{"controller": True, "kind": "ReplicaSet", "uid": "rs-uid"}]},
                               "spec": {"nodeName": "node-1", "containers": [{"name": "mini-commerce", "image": self.image}]},
                               "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}], "containerStatuses": [{"name": "mini-commerce", "ready": True, "state": {"running": {"startedAt": stamp(-7100)}}, "imageID": self.data["image"]["repository"] + "@" + CHILD}]}}]}
        self.nodes = {"node-1": {"status": {"nodeInfo": {"operatingSystem": "linux", "architecture": "arm64"}}}}
        self.rules = namespace_fixture()
        self.policy = dev.rule_policy(self.rules)
        self.evaluated = {"status": "success", "data": {"groups": [{"rules": [{"name": name, "labels": definition["labels"], "health": "ok", "lastEvaluation": stamp(-1), "query": definition["expr"],
                         "type": "alerting" if name == "MiniCommerceSuccessBurn" else "recording", "state": "inactive", "alerts": []} for name, definition in [*self.policy["records"].items(), ("MiniCommerceSuccessBurn", self.policy["alert"])]]}]}}
        self.definition = alertmanager_fixture()
        self.topic_attrs = {"TopicArn": TOPIC, "Policy": json.dumps({"Statement": [{"Effect": "Allow", "Principal": {"Service": "aps.amazonaws.com"}, "Action": "sns:Publish", "Resource": TOPIC, "Condition": {"ArnEquals": {"AWS:SourceArn": WORKSPACE}, "StringEquals": {"AWS:SourceAccount": ACCOUNT}}}]})}
        self.record = drill_fixture.fixture()
        self.record.update(source="captured", evidenceGrade="LIVE_NOT_VERIFIED")
        b = self.record["binding"]
        b.update(environment="dev", imageIndexDigest=digest, gitopsRevision=self.data["gitopsRevision"], clusterArn=self.data["clusterArn"])
        o = self.record["observations"]
        o["cluster"]["cluster"]["arn"] = b["clusterArn"]
        o["query"] = vector(offset=-500)
        o["longQuery"] = vector(offset=-500)
        labels = {"alertname": "MiniCommerceSuccessBurn", **self.policy["alert"]["labels"]}
        o["rules"]["data"]["groups"][0]["rules"][0]["labels"] = self.policy["alert"]["labels"]
        o["firing"][0]["labels"] = labels
        for receipt in o["deliveryReceipt"].values():
            message = json.loads(receipt["envelope"]["Message"])
            message["alerts"][0]["labels"] = labels
            receipt["envelope"]["Message"] = json.dumps(message)
            if PRIVATE_KEY:
                sign(receipt["envelope"])
        self.subscriptions = {"Subscriptions": [{"SubscriptionArn": SUBSCRIPTION, "Owner": ACCOUNT, "TopicArn": TOPIC, "Protocol": "https", "Endpoint": ENDPOINT}]}
        self.operator = copy.deepcopy(self.deployment)
        self.run = {"metadata": {"name": "baseline", "namespace": "k6-operator-system", "uid": "run-uid", "creationTimestamp": stamp(-900), "annotations": {"playbuilder.platform/max-duration": "10m", "playbuilder.platform/max-rate": "20", "playbuilder.platform/cost-boundary": "existing-eks-compute"}}, "status": {"stage": "finished"}}
        self.jobs = {"items": [{"metadata": {"ownerReferences": [{"controller": True, "kind": "TestRun", "uid": "run-uid"}]}, "spec": {"completions": 1}, "status": {"succeeded": 1, "startTime": stamp(-850), "completionTime": stamp(-800)}}]}
        self.requests, self.commands = [], []

    def kube(self, context, *args):
        self.requests.append(args)
        mapping = {
            ("config", "view", "--minify", "--raw", "--flatten"): self.config,
            ("-n", "argocd", "get", "application", "mini-commerce-dev"): self.app,
            ("get", "namespace", "app-dev"): self.namespace,
            ("-n", "app-dev", "get", "deployment", "mini-commerce"): self.deployment,
            ("-n", "app-dev", "get", "replicasets", "-l", "app=mini-commerce"): self.rs,
            ("-n", "app-dev", "get", "pods", "-l", "app=mini-commerce"): self.pods,
            ("get", "node", "node-1"): self.nodes["node-1"],
            ("-n", "k6-operator-system", "get", "deployment", "k6-operator-controller-manager"): self.operator,
            ("get", "crd", "testruns.k6.io"): {"status": {"conditions": [{"type": "Established", "status": "True"}]}},
            ("-n", "k6-operator-system", "get", "testrun", "baseline"): self.run,
            ("-n", "k6-operator-system", "get", "jobs", "-l", "k6_cr=baseline"): self.jobs,
        }
        return copy.deepcopy(mapping[args])

    def command(self, args):
        if args[0] == "openssl":
            return REAL_COMMAND(args)
        assert args == ["gh", "attestation", "verify", "oci://" + self.image, "--repo", self.data["source"]["repository"], "--bundle-from-oci", "--signer-workflow", self.data["source"]["repository"] + "/.github/workflows/ci.yml", "--source-digest", self.data["source"]["sha"], "--predicate-type", "https://slsa.dev/provenance/v1"]
        self.commands.append(args)
        return "Verified"

    def fetch(self, request):
        if request.full_url.startswith("https://sns."):
            return CERT
        from urllib.parse import urlparse, parse_qs
        url = urlparse(request.full_url)
        assert url.hostname == f"aps-workspaces.{REGION}.amazonaws.com"
        assert request.get_method() == "GET"
        assert f"/{REGION}/aps/aws4_request" in request.headers["Authorization"]
        self.requests.append(request.full_url)
        if url.path.endswith("/api/v1/rules"):
            return json.dumps(self.evaluated).encode()
        if url.path.endswith("/alertmanager/api/v2/alerts"):
            return b"[]"
        assert url.path.endswith("/api/v1/query")
        query = parse_qs(url.query)
        assert query["time"] == [str(NOW)]
        q = query["query"][0]
        if q in self.policy["traffic"].values():
            result = vector("1")
        elif q.startswith("mini_commerce:success_burn:"):
            metric = q.split("{")[0]
            assert q == metric + '{service="mini-commerce",environment="dev"}'
            result = vector("0.1", {"__name__": metric, **dev.LABELS})
        else:
            assert q == "min(timestamp(istio_requests_total{" + dev.SELECTOR + "}))"
            result = vector(NOW - 10)
        return json.dumps(result).encode()

    def stub_runtime(self, include_slo=False):
        session = boto3.Session(aws_access_key_id="TESTACCESSKEY", aws_secret_access_key="TESTSECRET", region_name=REGION)
        runtime = dev.Runtime.__new__(dev.Runtime)
        runtime.region, runtime.session = REGION, session
        runtime.clients = {name: session.client(name) for name in ("sts", "eks", "ecr", "amp", "sns", "logs")}
        runtime.kube = self.kube
        self.stubs = {name: Stubber(client) for name, client in runtime.clients.items()}
        def add(service, method, response, params):
            self.stubs[service].add_response(method, response, params)
        add("sts", "get_caller_identity", {"Account": ACCOUNT, "Arn": f"arn:aws:iam::{ACCOUNT}:role/reader", "UserId": "reader"}, {})
        add("eks", "describe_cluster", {"cluster": self.cluster}, {"name": "dev-mini-commerce"})
        add("ecr", "batch_get_image", self.index, {"registryId": self.data["image"]["repository"].split(".")[0], "repositoryName": "mini-commerce", "imageIds": [{"imageDigest": self.data["image"]["indexDigest"]}]})
        if include_slo:
            add("amp", "describe_workspace", {"workspace": {"arn": WORKSPACE, "workspaceId": WORKSPACE_ID, "status": {"statusCode": "ACTIVE"}, "createdAt": NOW - 10000, "prometheusEndpoint": f"https://aps-workspaces.{REGION}.amazonaws.com/workspaces/{WORKSPACE_ID}/"}}, {"workspaceId": WORKSPACE_ID})
            add("amp", "describe_rule_groups_namespace", {"ruleGroupsNamespace": self.rules}, {"workspaceId": WORKSPACE_ID, "name": dev.RULE_NAMESPACE})
            add("amp", "describe_alert_manager_definition", {"alertManagerDefinition": self.definition}, {"workspaceId": WORKSPACE_ID})
            add("sns", "get_topic_attributes", {"Attributes": self.topic_attrs}, {"TopicArn": TOPIC})
            add("sns", "list_subscriptions_by_topic", self.subscriptions, {"TopicArn": TOPIC})
            for receipt in self.record["observations"]["deliveryReceipt"].values():
                envelope = receipt["envelope"]
                message = {"status": "SUCCESS", "notification": {"topicArn": TOPIC, "messageId": envelope["MessageId"], "messageMD5Sum": hashlib.md5(envelope["Message"].encode()).hexdigest()}, "delivery": {"destination": ENDPOINT, "statusCode": 200}}
                response = {"events": [{"timestamp": int(dev.timestamp(receipt["receivedAt"]) * 1000), "message": json.dumps(message)}]}
                if hasattr(self, "change_log"):
                    self.change_log(response)
                add("logs", "filter_log_events", response, {"logGroupName": f"sns/{REGION}/{ACCOUNT}/test-alerts", "startTime": (NOW - dev.MAX_AGE) * 1000, "endTime": NOW * 1000, "filterPattern": '{ $.notification.messageId = "' + envelope["MessageId"] + '" }'})
        for stub in self.stubs.values():
            stub.activate()
        return runtime

    def assert_consumed(self):
        for stub in self.stubs.values():
            stub.assert_no_pending_responses()


REAL_COMMAND = dev.command


class RuntimeContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global CERT, PRIVATE_KEY
        cls.temp = tempfile.TemporaryDirectory(prefix="dev-evidence-tests-")
        PRIVATE_KEY = str(pathlib.Path(cls.temp.name) / "private.pem")
        certificate = str(pathlib.Path(cls.temp.name) / "cert.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", PRIVATE_KEY, "-out", certificate, "-days", "1", "-subj", "/CN=SNS-test-only"], check=True, capture_output=True)
        CERT = pathlib.Path(certificate).read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        # Every un-stubbed network call is a hard test failure.
        self.network = patch.object(socket.socket, "connect", side_effect=AssertionError("offline test attempted network"))
        self.network.start()
        self.addCleanup(self.network.stop)

    def test_real_sdk_and_signing_end_to_end(self):
        fixture = Fixture()
        runtime = fixture.stub_runtime(include_slo=True)
        with patch.object(dev, "fetch", side_effect=fixture.fetch), patch.object(dev, "command", side_effect=fixture.command):
            result = dev.collect_slo(runtime, fixture.data, "dev", "k6-operator-system", "baseline", WORKSPACE_ID, TOPIC, fixture.record, NOW)
        self.assertEqual(set(result), {"source", "image", "gitopsRevision", "clusterArn", "region", "schemaVersion", "evidenceGrade", "status", "observedAt", "expiresAt", "evidenceId"})
        self.assertEqual(result["image"], fixture.data["image"])
        self.assertEqual(result["evidenceGrade"], "CLOUD_RUNTIME")  # Test object only: no CLI grade bypass.
        self.assertEqual(len(fixture.commands), 1)
        self.assertEqual(len([x for x in fixture.requests if isinstance(x, str)]), 7)
        fixture.assert_consumed()
        with tempfile.TemporaryDirectory() as directory:
            deployment, slo = pathlib.Path(directory) / "deployment.json", pathlib.Path(directory) / "slo.json"
            deployment.write_text(json.dumps(fixture.data))
            slo.write_text(json.dumps(result))
            output = subprocess.run(["bash", str(ROOT / "scripts/capture-dev-evidence.sh"), "slo", "--validate-evidence", str(deployment), str(slo), stamp()], capture_output=True, text=True, check=True)
            self.assertIn("[STATIC]", output.stdout)

    def test_network_registry_is_independent_from_workload_account(self):
        f = Fixture()
        f.data["image"]["repository"] = f.data["image"]["repository"].replace(ACCOUNT, "999999999999")
        f.image = f.data["image"]["repository"] + "@" + f.data["image"]["indexDigest"]
        for obj in [f.deployment, f.rs["items"][0]]:
            obj["spec"]["template"]["spec"]["containers"][0]["image"] = f.image
        f.pods["items"][0]["spec"]["containers"][0]["image"] = f.image
        for status in f.pods["items"][0]["status"]["containerStatuses"]:
            status["imageID"] = status["imageID"].replace(ACCOUNT, "999999999999")
        runtime = f.stub_runtime(include_slo=True)
        with patch.object(dev, "fetch", side_effect=f.fetch), patch.object(dev, "command", side_effect=f.command):
            result = dev.collect_slo(runtime, f.data, "dev", "k6-operator-system", "baseline", WORKSPACE_ID, TOPIC, f.record, NOW)
        self.assertTrue(result["image"]["repository"].startswith("999999999999."))
        self.assertIn(ACCOUNT, result["clusterArn"])
        f.assert_consumed()

    def test_deployment_invalid_permutations(self):
        mutations = [
            lambda f: f.config["clusters"][0]["cluster"].update(server="https://other-cluster"),
            lambda f: f.config["clusters"][0]["cluster"].update(**{"insecure-skip-tls-verify": True}),
            lambda f: f.cluster.update(arn=f.cluster["arn"].replace(ACCOUNT, "999999999999")),
            lambda f: f.app["spec"]["destination"].update(namespace="app-prod"),
            lambda f: f.app["spec"]["source"].update(targetRevision="other"),
            lambda f: f.app["status"]["sync"].update(revision="f" * 40),
            lambda f: f.app["status"].update(reconciledAt=stamp(-600)),
            lambda f: f.app["metadata"].update(name="other"),
            lambda f: f.app["status"]["sync"]["comparedTo"]["source"].update(repoURL="https://github.com/other/argocd-gitops"),
            lambda f: f.namespace["metadata"]["labels"].update(environment="prod"),
            lambda f: f.deployment["spec"]["template"]["spec"]["containers"][0].update(image=f.image.replace("sha256:", "sha256:b")),
            lambda f: f.deployment["status"].update(observedGeneration=3),
            lambda f: f.deployment["metadata"]["annotations"].update({"argocd.argoproj.io/tracking-id": "other:apps/Deployment:app-dev/mini-commerce"}),
            lambda f: f.pods["items"][0]["status"]["containerStatuses"][0].update(imageID="sha256:" + "d" * 64),
            lambda f: f.pods["items"][0]["status"]["containerStatuses"][0].update(ready=False),
            lambda f: f.pods["items"][0]["metadata"]["ownerReferences"][0].update(uid="other-rs"),
            lambda f: f.pods["items"][0]["metadata"].update(namespace="app-prod"),
            lambda f: f.rs["items"][0]["status"].update(observedGeneration=0),
            lambda f: f.nodes["node-1"]["status"]["nodeInfo"].update(architecture="amd64"),
            lambda f: f.index["images"][0].update(imageManifest="{}"),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutations.index(mutation)):
                f = Fixture()
                mutation(f)
                runtime = f.stub_runtime()
                with patch.object(dev, "command", side_effect=f.command), self.assertRaises((ValueError, KeyError)):
                    dev.collect_deployment(runtime, f.data, "dev", "app-dev", "mini-commerce-dev", NOW)

    def test_multi_source_and_source_digest_binding(self):
        f = Fixture()
        sources = [f.app["spec"].pop("source"), {"repoURL": "https://github.com/play-builder/argocd-gitops.git", "targetRevision": "main", "ref": "values"}]
        f.app["spec"]["sources"] = sources
        compared = f.app["status"]["sync"]["comparedTo"]
        compared.pop("source")
        compared["sources"] = copy.deepcopy(sources)
        f.app["status"]["sync"].pop("revision")
        f.app["status"]["sync"]["revisions"] = [f.data["gitopsRevision"]] * 2
        dev.validate_application(f.app, "mini-commerce-dev", "app-dev", f.data["gitopsRevision"], f.cluster["endpoint"], NOW, sources[0]["repoURL"])
        f.app["status"]["sync"]["revisions"][1] = "f" * 40
        with self.assertRaises(ValueError):
            dev.validate_application(f.app, "mini-commerce-dev", "app-dev", f.data["gitopsRevision"], f.cluster["endpoint"], NOW, sources[0]["repoURL"])
        f = Fixture()
        runtime = f.stub_runtime()
        def attest(args):
            self.assertIn(f.data["source"]["sha"], args)
            raise ValueError("attestation source digest does not match")
        with patch.object(dev, "command", side_effect=attest), self.assertRaises(ValueError):
            dev.collect_deployment(runtime, f.data, "dev", "app-dev", "mini-commerce-dev", NOW)

    def test_observation_race_is_rejected(self):
        f = Fixture()
        runtime = f.stub_runtime()
        def attest(args):
            f.command(args)
            f.app["metadata"]["resourceVersion"] = "new"
            return "Verified"
        with patch.object(dev, "command", side_effect=attest), self.assertRaisesRegex(ValueError, "changed"):
            dev.collect_deployment(runtime, f.data, "dev", "app-dev", "mini-commerce-dev", NOW)

    def test_metric_permutations(self):
        invalid = [vector("NaN"), vector("+Inf"), vector(offset=-1000), vector(offset=1000), vector(metric={"service": "other"})]
        for response in invalid:
            with self.subTest(response=response), self.assertRaises(ValueError):
                dev.vector(response, NOW, {})
        for count in (0, 2):
            response = vector()
            response["data"]["result"] *= count
            with self.assertRaises(ValueError):
                dev.vector(response, NOW, {})
        response = vector("0.5", {"service": "mini-commerce"})
        response["data"]["result"].append(vector("0.999", {"service": "other"})["data"]["result"][0])
        with self.assertRaises(ValueError):
            dev.vector(response, NOW, {"service": "mini-commerce"})

    def test_slo_negative_observations(self):
        def low_traffic(q, r):
            if q.startswith("sum(rate("):
                r["data"]["result"][0]["value"][1] = "0.01"
        def excessive_burn(q, r):
            if q.startswith("mini_commerce:success_burn:"):
                r["data"]["result"][0]["value"][1] = "14.4"
        def old_scrape(q, r):
            if q.startswith("min(timestamp"):
                r["data"]["result"][0]["value"][1] = "1"
        def wrong_target(q, r):
            if q.startswith("mini_commerce:success_burn:"):
                r["data"]["result"][0]["metric"]["service"] = "other"
        def extra_series(q, r):
            r["data"]["result"] *= 2
        def stale_sample(q, r):
            r["data"]["result"][0]["value"][0] = NOW - 999
        for mutation in (low_traffic, excessive_burn, old_scrape, wrong_target, extra_series, stale_sample):
            f = Fixture()
            runtime = f.stub_runtime(include_slo=True)
            def fetch(request):
                result = f.fetch(request)
                if "/api/v1/query?" in request.full_url:
                    from urllib.parse import parse_qs, urlparse
                    payload = json.loads(result)
                    mutation(parse_qs(urlparse(request.full_url).query)["query"][0], payload)
                    return json.dumps(payload).encode()
                return result
            with self.subTest(mutation=mutation.__name__), patch.object(dev, "fetch", side_effect=fetch), patch.object(dev, "command", side_effect=f.command), self.assertRaises(ValueError):
                dev.collect_slo(runtime, f.data, "dev", "k6-operator-system", "baseline", WORKSPACE_ID, TOPIC, f.record, NOW)

    def test_delivery_logs_policy_and_subscription_fail_closed(self):
        mutations = [
            lambda f: f.subscriptions["Subscriptions"][0].update(SubscriptionArn="PendingConfirmation"),
            lambda f: f.subscriptions["Subscriptions"][0].update(Protocol="email"),
            lambda f: f.topic_attrs.update(Policy=f.topic_attrs["Policy"].replace(WORKSPACE, WORKSPACE + "other")),
            lambda f: setattr(f, "change_log", lambda r: r.update(events=[])),
            lambda f: setattr(f, "change_log", lambda r: r["events"][0].update(message=r["events"][0]["message"].replace("SUCCESS", "FAILURE"))),
            lambda f: setattr(f, "change_log", lambda r: r["events"][0].update(message=r["events"][0]["message"].replace(ENDPOINT, "https://other.example.com"))),
            lambda f: setattr(f, "change_log", lambda r: r["events"][0].update(timestamp=1)),
            lambda f: setattr(f, "change_log", lambda r: r["events"][0].update(message=r["events"][0]["message"].replace(TOPIC, TOPIC + "other"))),
        ]
        for mutation in mutations:
            f = Fixture()
            mutation(f)
            runtime = f.stub_runtime(include_slo=True)
            with self.subTest(mutation=mutations.index(mutation)), patch.object(dev, "fetch", side_effect=f.fetch), patch.object(dev, "command", side_effect=f.command), self.assertRaises(ValueError):
                dev.collect_slo(runtime, f.data, "dev", "k6-operator-system", "baseline", WORKSPACE_ID, TOPIC, f.record, NOW)

    def test_k6_actual_job_and_budget_contract(self):
        from types import SimpleNamespace
        mutations = [
            lambda f: f.run["metadata"]["annotations"].pop("playbuilder.platform/cost-boundary"),
            lambda f: f.run["metadata"]["annotations"].update({"playbuilder.platform/max-rate": "1000000"}),
            lambda f: f.run["metadata"].update(creationTimestamp="2000-01-01T00:00:00Z"),
            lambda f: f.jobs["items"][0]["status"].update(failed=1),
            lambda f: f.jobs["items"][0]["metadata"]["ownerReferences"][0].update(uid="other"),
            lambda f: f.operator["status"].update(observedGeneration=0),
        ]
        for mutation in mutations:
            f = Fixture()
            mutation(f)
            with self.subTest(mutation=mutations.index(mutation)), self.assertRaises((ValueError, KeyError)):
                dev.k6_readiness(SimpleNamespace(kube=f.kube), "dev", "k6-operator-system", "baseline", NOW - 7100, NOW)

    def test_api_models_have_real_nested_blob_shapes(self):
        session = boto3.Session(aws_access_key_id="TEST", aws_secret_access_key="TEST", region_name=REGION)
        amp = session.client("amp")
        for operation, key in (("DescribeRuleGroupsNamespace", "ruleGroupsNamespace"), ("DescribeAlertManagerDefinition", "alertManagerDefinition")):
            shape = amp.meta.service_model.operation_model(operation).output_shape
            self.assertEqual(shape.members[key].members["data"].type_name, "blob")
        for nonexistent in ("get_rule_groups_namespace", "get_alert_manager_definition", "query_metrics"):
            self.assertFalse(hasattr(amp, nonexistent))

    def test_rules_and_nested_configuration(self):
        f = Fixture()
        self.assertEqual(f.policy["windows"], {"short": 300, "long": 3600})
        for old, new in (("mini_commerce:success_burn:short", "platform:http_success_ratio:5m"), ("MiniCommerceSuccessBurn", "PlatformDeadman"), ("app-dev", "app-prod"), ('environment="dev"', 'environment="prod"')):
            changed = copy.deepcopy(f.rules)
            changed["data"] = changed["data"].replace(old.encode(), new.encode())
            with self.subTest(new=new), self.assertRaises(ValueError):
                dev.rule_policy(changed)
        dev.evaluated_rules(f.evaluated, f.policy, NOW)
        for change in ({"state": "firing"}, {"state": "pending"}, {"health": "err"}, {"lastEvaluation": stamp(-300)}, {"query": "vector(0)"}):
            obj = copy.deepcopy(f.evaluated)
            obj["data"]["groups"][0]["rules"][-1].update(change)
            with self.assertRaises(ValueError):
                dev.evaluated_rules(obj, f.policy, NOW)
        wrong = copy.deepcopy(f.definition)
        wrong["data"] = yaml.safe_dump({"route": {"receiver": "old"}}).encode()
        with self.assertRaises(KeyError):
            dev.alert_routing(wrong, TOPIC, REGION)

    def test_receipt_mutations_never_uplift(self):
        changes = [lambda r: r.update(evidenceGrade="CLOUD_RUNTIME"), lambda r: r.update(source="fixture", evidenceGrade="LOCAL_VERIFIED"),
                   lambda r: r.update(capturedAt="2000-01-01T00:00:00Z"), lambda r: r["binding"].update(environment="prod"),
                   lambda r: r["observations"]["deliveryReceipt"]["resolved"]["envelope"].update(TopicArn=TOPIC + "other"),
                   lambda r: r["observations"]["deliveryReceipt"]["resolved"].update(receivedAt="2000-01-01T00:00:00Z"),
                   lambda r: r["observations"]["deliveryReceipt"].update(resolved={"delivered": True}),
                   lambda r: r["observations"].update(resolved=r["observations"]["firing"])]
        for change in changes:
            f = Fixture()
            change(f.record)
            with self.subTest(change=changes.index(change)), self.assertRaises((ValueError, KeyError)):
                dev.validate_receipts(f.record, f.data, WORKSPACE, TOPIC, NOW)

    def test_real_signature_and_tampering(self):
        f = Fixture()
        env = f.record["observations"]["deliveryReceipt"]["firing"]["envelope"]
        with patch.object(dev, "fetch", return_value=CERT):
            dev.verify_notification(env, REGION)
            for version in ("1", "2"):
                env["SignatureVersion"] = version
                env["Subject"] = "test notification"
                sign(env)
                dev.verify_notification(env, REGION)
            env["Message"] += " "
            with self.assertRaises(ValueError):
                dev.verify_notification(env, REGION)
            env["SigningCertURL"] = "https://sns.ap-northeast-2.amazonaws.com.evil.example/cert.pem"
            with self.assertRaises(ValueError):
                dev.verify_notification(env, REGION)

    def test_no_fake_runtime_configuration(self):
        for env in ({"PLATFORM_CHECK_BIN_DIR": "/tmp"}, {"PLATFORM_CHECK_NOW": stamp()}, {"AWS_ENDPOINT_URL_AMP": "http://localhost:9000"}):
            with patch.dict(os.environ, env, clear=True), self.assertRaises(ValueError):
                dev.Runtime(REGION)

    @unittest.skipUnless(TERRAFORM, "run --terraform in tool-backed CI for actual Terraform mock-generated YAML")
    def test_actual_terraform_rule_and_alertmanager_blobs(self):
        result = subprocess.run(["terraform", "-chdir=" + os.environ.get("DEV_EVIDENCE_TERRAFORM_ROOT", str(ROOT / "modules/addons/amp-alerting")), "test", "-filter=tests/enterprise-slo.tftest.hcl", "-json", "-verbose"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout[-6000:] + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        state = next(e["test_state"] for e in events if e.get("type") == "test_state")
        resources = state["root_module"]["resources"]
        rules = next(r["values"]["data"] for r in resources if r["type"] == "aws_prometheus_rule_group_namespace")
        alertmanager_yaml = next(r["values"]["definition"] for r in resources if r["type"] == "aws_prometheus_alert_manager_definition")
        f = Fixture()
        f.rules["data"] = rules.encode()
        policy = dev.rule_policy(f.rules)
        self.assertEqual(policy["windows"], {"short": 300, "long": 3600})
        # Use the real Prometheus parser: it sorts label matchers in /api/v1/rules.
        # Comparing literal source strings would reject the actual runtime rule.
        evaluated = []
        for name, definition in [*policy["records"].items(), ("MiniCommerceSuccessBurn", policy["alert"])]:
            formatted = subprocess.run(["promtool", "--experimental", "promql", "format", definition["expr"]], check=True, capture_output=True, text=True).stdout
            evaluated.append({"name": name, "query": formatted, "labels": definition["labels"], "health": "ok", "lastEvaluation": stamp(),
                              "type": "alerting" if name == "MiniCommerceSuccessBurn" else "recording", "state": "inactive", "alerts": []})
        dev.evaluated_rules({"status": "success", "data": {"groups": [{"rules": evaluated}]}}, policy, NOW)
        f.definition["data"] = alertmanager_yaml.encode()
        dev.alert_routing(f.definition, f"arn:aws:sns:{REGION}:{ACCOUNT}:test-amp-alerts", REGION)


if __name__ == "__main__":
    unittest.main()
