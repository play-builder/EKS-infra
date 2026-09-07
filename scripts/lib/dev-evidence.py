#!/usr/bin/env python3
"""Read-only Dev evidence collector. CLI fixtures are rejected, never graded runtime.

The public shell entrypoint owns schema validation and atomic output. This module
owns AWS SDK/SigV4 observations and pure validators. No cloud mutations are used.
SNS CLOUD_RUNTIME means signed notifications matched SNS delivery status logs; it
is not proof that a human read an alert. Execution host, IAM and log writers remain
trust boundaries. Never accept operator booleans as notification delivery evidence.
"""
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

MAX_AGE = 7200
FRESH = 120
SELECTOR = 'reporter="destination",destination_canonical_service="mini-commerce",destination_workload_namespace="app-dev",environment="dev"'
RULE_NAMESPACE = "mini-commerce-release-slo"
LABELS = {"service": "mini-commerce", "environment": "dev"}
SHA = r"[0-9a-f]{40}"
DIGEST = r"sha256:[0-9a-f]{64}"


class EvidenceError(ValueError):
    """Only these fixed, non-sensitive rejection messages may reach operator logs."""


def require(ok, message):
    if not ok:
        raise EvidenceError(message)


def timestamp(value):
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "timezone required")
    return parsed.timestamp()


def stamp(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fresh(value, now, age=FRESH):
    require(math.isfinite(float(value)) and 0 <= now - float(value) <= age, "stale or future observation")


def one(values, message):
    require(len(values) == 1, message)
    return values[0]


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    # stderr can contain credentials or remote payloads. Never echo it.
    require(result.returncode == 0, "read-only command failed: " + args[0])
    return result.stdout


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise EvidenceError("HTTP redirects are forbidden")


def fetch(request):
    with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
        require(response.status == 200, "HTTP read failed")
        data = response.read(8 * 1024 * 1024 + 1)
        require(len(data) <= 8 * 1024 * 1024, "HTTP response too large")
        return data


class Runtime:
    def __init__(self, region):
        try:
            import boto3
            from botocore.config import Config
        except ImportError as error:
            raise EvidenceError("Install scripts/requirements-amp-slo.txt in a Python 3.10+ venv and activate it") from error
        require(not any(os.environ.get(k) for k in ("PLATFORM_CHECK_BIN_DIR", "PLATFORM_CHECK_NOW")),
                "runtime collection rejects fake commands and clock overrides; use offline tests")
        require(not any(k.startswith("AWS_ENDPOINT_URL") and v for k, v in os.environ.items()),
                "custom AWS endpoints cannot produce runtime evidence")
        self.region = region
        self.session = boto3.Session(profile_name=os.environ["AWS_PROFILE"], region_name=region)
        self.config = Config(connect_timeout=10, read_timeout=30, retries={"max_attempts": 2},
                             ignore_configured_endpoint_urls=True)
        self.clients = {}

    def client(self, service):
        if service not in self.clients:
            # Pin the public AWS TLS endpoint even if the profile contains custom endpoints.
            hostname = {"amp": "aps", "ecr": "api.ecr"}.get(service, service)
            url = f"https://{hostname}.{self.region}.amazonaws.com"
            self.clients[service] = self.session.client(service, endpoint_url=url, config=self.config)
        return self.clients[service]

    def kube(self, context, *args):
        return json.loads(command(["kubectl", "--context", context, "--request-timeout=30s", *args, "-o", "json"]))

    def query(self, workspace, path, query=None):
        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest
        require(path in ("/api/v1/query", "/api/v1/rules", "/alertmanager/api/v2/alerts"), "unsupported AMP path")
        url = f"https://aps-workspaces.{self.region}.amazonaws.com/workspaces/{workspace}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = AWSRequest(method="GET", url=url)
        credentials = self.session.get_credentials()
        require(credentials is not None, "AWS credentials unavailable")
        SigV4Auth(credentials.get_frozen_credentials(), "aps", self.region).add_auth(request)
        return json.loads(fetch(urllib.request.Request(url, headers=dict(request.headers.items()))))


def identity(inputs):
    d = inputs
    region = d["region"]
    require(region in ("ap-northeast-2", "us-east-1"), "unsupported Region")
    cluster = re.fullmatch(r"arn:aws:eks:" + region + r":([0-9]{12}):cluster/([A-Za-z0-9][A-Za-z0-9_-]{0,99})", d["clusterArn"])
    require(cluster, "invalid cluster ARN")
    account = cluster[1]
    repo = re.fullmatch(r"[0-9]{12}\.dkr\.ecr\." + region + r"\.amazonaws\.com/([a-z0-9]+(?:[._/-][a-z0-9]+)*)", d["image"]["repository"])
    require(repo and 2 <= len(repo[1]) <= 256, "invalid ECR repository identity")
    require(re.fullmatch(SHA, d["source"]["sha"]) and re.fullmatch(SHA, d["gitopsRevision"]), "exact source and GitOps commits required")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", d["source"]["repository"]), "GitHub owner/repository required")
    require(re.fullmatch(DIGEST, d["image"]["indexDigest"]), "invalid image digest")
    return account, cluster[2], repo[1]


def validate_context(config, cluster, arn):
    require(cluster["arn"] == arn and cluster["status"] == "ACTIVE", "EKS identity/status mismatch")
    ctx = one(config["contexts"], "one minified context required")["context"]
    item = one(config["clusters"], "one minified cluster required")
    require(ctx["cluster"] == item["name"], "context cluster mismatch")
    current = item["cluster"]
    require(current["server"] == cluster["endpoint"] and current["server"].startswith("https://"), "kubectl endpoint differs from EKS")
    require(not current.get("insecure-skip-tls-verify") and not current.get("proxy-url") and not current.get("tls-server-name"), "untrusted kube TLS configuration")
    require(base64.b64decode(current["certificate-authority-data"], validate=True) ==
            base64.b64decode(cluster["certificateAuthority"]["data"], validate=True), "EKS CA mismatch")


def validate_application(app, application, namespace, revision, endpoint, now, repository):
    require(namespace == "app-dev", "Dev evidence requires app-dev")
    meta, spec, status = app["metadata"], app["spec"], app["status"]
    require(meta["name"] == application and meta["namespace"] == "argocd" and meta["uid"] and meta["generation"] > 0, "Argo identity mismatch")
    require(not meta.get("deletionTimestamp") and not app.get("operation"), "Argo operation in progress")
    require(not any(c.get("type", "").endswith("Error") for c in status.get("conditions", [])), "Argo error condition")
    require(status["sync"]["status"] == "Synced" and status["health"]["status"] == "Healthy", "Argo not Synced/Healthy")
    fresh(timestamp(status["reconciledAt"]), now, 300)
    destination = spec["destination"]
    require(destination.get("namespace") == namespace and destination.get("server") in (endpoint, "https://kubernetes.default.svc") and not destination.get("name"), "Argo destination mismatch")
    compared = status["sync"]["comparedTo"]
    require(compared["destination"] == destination, "Argo compared destination is stale")
    sources = spec.get("sources") or [spec["source"]]
    require(compared.get("sources", [compared.get("source")]) == sources, "Argo has not reconciled current sources")
    revisions = status["sync"].get("revisions") if spec.get("sources") else [status["sync"].get("revision")]
    require(revisions == [revision] * len(sources), "all GitOps sources must resolve to requested commit")
    require(all(s.get("repoURL", "").removesuffix(".git") == repository.removesuffix(".git") for s in sources), "unexpected GitOps repository")
    require(any(s.get("path") == "charts/mini-commerce" for s in sources), "mini-commerce chart source required")
    resource = one([r for r in status["resources"] if r.get("kind") == "Deployment" and r.get("name") == "mini-commerce"], "one tracked mini-commerce Deployment required")
    require(resource.get("group") == "apps" and resource["namespace"] == namespace and resource["status"] == "Synced", "Argo tracked workload mismatch")


def ready_deployment(deployment):
    meta, spec, status = deployment["metadata"], deployment["spec"], deployment["status"]
    count = spec.get("replicas", 1)
    require(count > 0 and not meta.get("deletionTimestamp"), "Deployment is inactive")
    require(status.get("observedGeneration") == meta["generation"], "stale Deployment generation")
    require(all(status.get(k) == count for k in ("replicas", "updatedReplicas", "readyReplicas", "availableReplicas")) and status.get("unavailableReplicas", 0) == 0, "Deployment rollout incomplete")
    return count


def image_of(template):
    return one([c for c in template["spec"]["containers"] if c["name"] == "mini-commerce"], "one mini-commerce container required")["image"]


def owner(meta, kind, uid):
    refs = [r for r in meta.get("ownerReferences", []) if r.get("controller")]
    return len(refs) == 1 and refs[0]["kind"] == kind and refs[0]["uid"] == uid


def validate_workload(deployment, replica_sets, pods, nodes, app, namespace, image, children, now):
    count = ready_deployment(deployment)
    meta = deployment["metadata"]
    require(meta["name"] == "mini-commerce" and meta["namespace"] == namespace, "Deployment identity mismatch")
    tracking = meta.get("annotations", {}).get("argocd.argoproj.io/tracking-id")
    require(tracking == f"{app}:apps/Deployment:{namespace}/mini-commerce" or
            (tracking is None and meta.get("labels", {}).get("argocd.argoproj.io/instance") == app), "Deployment is not tracked by expected Argo Application")
    require(image_of(deployment["spec"]["template"]) == image, "Deployment image differs from requested digest")
    owned = {r["metadata"]["uid"]: r for r in replica_sets["items"] if owner(r["metadata"], "Deployment", meta["uid"])}
    require(len(pods["items"]) == count, "pod count differs from ready Deployment")
    latest_start = 0
    for pod in pods["items"]:
        pm, ps = pod["metadata"], pod["status"]
        require(pm["namespace"] == namespace and not pm.get("deletionTimestamp") and ps["phase"] == "Running", "pod inactive or wrong namespace")
        rs = one([r for uid, r in owned.items() if owner(pm, "ReplicaSet", uid)], "pod is not owned by Deployment ReplicaSet")
        require(rs["status"].get("observedGeneration") == rs["metadata"]["generation"] and image_of(rs["spec"]["template"]) == image, "stale or wrong ReplicaSet")
        require(image_of(pod) == image, "pod image differs from Deployment")
        require(any(c["type"] == "Ready" and c["status"] == "True" for c in ps["conditions"]), "pod not Ready")
        statuses = ps["containerStatuses"]
        require(len(statuses) == len(pod["spec"]["containers"]) and all(s["ready"] and "running" in s["state"] for s in statuses), "container not Ready/running")
        container = one([s for s in statuses if s["name"] == "mini-commerce"], "app container status missing")
        node = nodes[pod["spec"]["nodeName"]]
        platform = (node["status"]["nodeInfo"]["operatingSystem"], node["status"]["nodeInfo"]["architecture"])
        require(platform in children, "node platform absent from OCI index")
        actual = container["imageID"].removeprefix("docker-pullable://").removeprefix("containerd://")
        require(actual in (image, image.split("@")[0] + "@" + children[platform], children[platform]), "running imageID is not index/platform child")
        started = timestamp(container["state"]["running"]["startedAt"])
        require(started <= now, "future container start")
        latest_start = max(latest_start, started)
    return latest_start


def index_children(response, digest):
    require(not response.get("failures"), "ECR image lookup failed")
    item = one(response["images"], "one OCI index required")
    raw = item["imageManifest"]
    require(item["imageId"]["imageDigest"] == digest and "sha256:" + hashlib.sha256(raw.encode()).hexdigest() == digest, "ECR index hash mismatch")
    data = json.loads(raw)
    require(data["schemaVersion"] == 2 and data["mediaType"] in ("application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json"), "image must be an OCI index")
    children = {}
    for manifest in data["manifests"]:
        platform = manifest["platform"]
        if platform["os"] == "unknown" and platform["architecture"] == "unknown":
            continue  # BuildKit attestation descriptor, never a runnable image.
        key = platform["os"], platform["architecture"]
        require(key not in children and key in (("linux", "amd64"), ("linux", "arm64")), "ambiguous/unsupported image platform")
        require(re.fullmatch(DIGEST, manifest["digest"]), "invalid platform manifest digest")
        children[key] = manifest["digest"]
    require(children, "OCI index has no runtime manifests")
    return children


def collect_deployment(runtime, data, context, namespace, application, now):
    account, cluster_name, repository_name = identity(data)
    require(runtime.client("sts").get_caller_identity()["Account"] == account, "AWS caller account mismatch")
    cluster = runtime.client("eks").describe_cluster(name=cluster_name)["cluster"]
    config = runtime.kube(context, "config", "view", "--minify", "--raw", "--flatten")
    validate_context(config, cluster, data["clusterArn"])
    app = runtime.kube(context, "-n", "argocd", "get", "application", application)
    validate_application(app, application, namespace, data["gitopsRevision"], cluster["endpoint"], now,
                         os.environ.get("DEV_GITOPS_REPOSITORY", "https://github.com/play-builder/argocd-gitops.git"))
    ns = runtime.kube(context, "get", "namespace", namespace)
    require(ns["metadata"]["name"] == namespace and ns["metadata"]["labels"]["environment"] == "dev", "namespace environment mismatch")
    deployment = runtime.kube(context, "-n", namespace, "get", "deployment", "mini-commerce")
    selector = deployment["spec"]["selector"]
    require(not selector.get("matchExpressions") and selector.get("matchLabels"), "simple Deployment selector required")
    labels = ",".join(k + "=" + v for k, v in sorted(selector["matchLabels"].items()))
    replicas = runtime.kube(context, "-n", namespace, "get", "replicasets", "-l", labels)
    pods = runtime.kube(context, "-n", namespace, "get", "pods", "-l", labels)
    nodes = {name: runtime.kube(context, "get", "node", name) for name in sorted({p["spec"]["nodeName"] for p in pods["items"]})}
    image = data["image"]["repository"] + "@" + data["image"]["indexDigest"]
    manifest = runtime.client("ecr").batch_get_image(registryId=data["image"]["repository"].split(".")[0], repositoryName=repository_name,
                                                    imageIds=[{"imageDigest": data["image"]["indexDigest"]}])
    children = index_children(manifest, data["image"]["indexDigest"])
    started = validate_workload(deployment, replicas, pods, nodes, application, namespace, image, children, now)
    command(["gh", "attestation", "verify", "oci://" + image, "--repo", data["source"]["repository"],
             "--bundle-from-oci", "--signer-workflow", data["source"]["repository"] + "/.github/workflows/ci.yml",
             "--source-digest", data["source"]["sha"], "--predicate-type", "https://slsa.dev/provenance/v1"])
    snapshot = {
        "application": (app["metadata"]["uid"], app["metadata"]["resourceVersion"]),
        "deployment": (deployment["metadata"]["uid"], deployment["metadata"]["resourceVersion"]),
        "pods": sorted((p["metadata"]["uid"], p["metadata"]["resourceVersion"]) for p in pods["items"]),
    }
    binding = {"startedAt": started, "istioRevision": ns["metadata"]["labels"].get("istio.io/rev"),
               "snapshot": snapshot, "selector": labels, "application": application}
    check_snapshot(runtime, context, binding)
    return binding


def check_snapshot(runtime, context, binding):
    # Collection is a bounded observation, not an atomic distributed transaction.
    # Re-read after expensive provenance/AMP checks and fail on concurrent changes.
    for kind, name, namespace in (("application", binding["application"], "argocd"), ("deployment", "mini-commerce", "app-dev")):
        after = runtime.kube(context, "-n", namespace, "get", kind, name)["metadata"]
        require((after["uid"], after["resourceVersion"]) == binding["snapshot"][kind], "workload changed during collection; retry")
    pods = runtime.kube(context, "-n", "app-dev", "get", "pods", "-l", binding["selector"])
    require(sorted((p["metadata"]["uid"], p["metadata"]["resourceVersion"]) for p in pods["items"]) == binding["snapshot"]["pods"], "pods changed during collection; retry")


def compact(expression):
    return re.sub(r'"(?:\\.|[^"\\])*"|\s+', lambda m: m[0] if m[0].startswith('"') else "", expression)


def canonical_promql(expression):
    # Prometheus reorders label matchers when rendering parsed rules. Compare the
    # same bounded selectors independent of ordering, without erasing operators.
    def selector(match):
        body = match[1]
        parts = re.findall(r'([A-Za-z_][A-Za-z0-9_]*)(=~|!~|!=|=)("(?:\\.|[^"\\])*")', body)
        require(",".join("".join(p) for p in parts) == body and len({p[0] for p in parts}) == len(parts), "unsupported/duplicate PromQL matchers")
        return "{" + ",".join("".join(p) for p in sorted(parts)) + "}"
    return re.sub(r"\{([^{}]*)\}", selector, compact(expression))


def rule_policy(namespace):
    import yaml
    require(namespace["name"] == RULE_NAMESPACE and namespace["status"]["statusCode"] == "ACTIVE", "AMP rule namespace is not ACTIVE")
    # boto3 returns decoded bytes for blob fields, nested below ruleGroupsNamespace.
    require(isinstance(namespace["data"], bytes), "AMP SDK rule data must be bytes")
    groups = yaml.safe_load(namespace["data"])["groups"]
    rules = one([g for g in groups if g["name"] == RULE_NAMESPACE], "missing canonical rule group")["rules"]
    policy = {"records": {}, "windows": {}, "traffic": {}}
    for window in ("short", "long"):
        name = "mini_commerce:success_burn:" + window
        rule = one([r for r in rules if r.get("record") == name], "missing/ambiguous burn recording rule")
        require(rule["labels"] == LABELS, "burn rule labels mismatch")
        expr = compact(rule["expr"])
        # Deliberately accept the repository's Terraform grammar, not arbitrary PromQL.
        prefix = '(sum(rate(istio_requests_total{' + SELECTOR + ',response_code=~"5.."}['
        require(expr.startswith(prefix), "burn selector differs from canonical Dev target")
        parsed = re.fullmatch(re.escape(prefix) + r'([1-9][0-9]*[mh])\]\)\)/sum\(rate\(istio_requests_total\{' + re.escape(SELECTOR) + r'\}\[\1\]\)\)\)/\(1-([0-9.]+)\)', expr)
        require(parsed, "unsupported burn formula; review collector alongside Terraform rules")
        duration, target = parsed.groups()
        seconds = int(duration[:-1]) * (60 if duration[-1] == "m" else 3600)
        require(0 < float(target) < 1 and seconds <= MAX_AGE, "invalid SLO target/window")
        policy["records"][name] = rule
        policy["windows"][window] = seconds
        policy["traffic"][window] = "sum(rate(istio_requests_total{" + SELECTOR + "}[" + duration + "]))"
    require(policy["windows"]["short"] < policy["windows"]["long"], "invalid SLO window ordering")
    alert = one([r for r in rules if r.get("alert") == "MiniCommerceSuccessBurn"], "missing burn alert")
    require(all(alert["labels"].get(k) == v for k, v in LABELS.items()) and alert["for"] == "1m", "burn alert identity/hold mismatch")
    alert_expr = compact(alert["expr"])
    number = r"([0-9]+(?:\.[0-9]+)?)"
    expected = (r"\(" + re.escape(compact(policy["records"]["mini_commerce:success_burn:short"]["expr"])) + ">" + number + r"\)and\(" +
                re.escape(compact(policy["records"]["mini_commerce:success_burn:long"]["expr"])) + ">" + number + r"\)and\(" +
                re.escape(policy["traffic"]["short"]) + ">=" + number + r"\)and\(" + re.escape(policy["traffic"]["long"]) + ">=" + number + r"\)")
    match = re.fullmatch(expected, alert_expr)
    require(match and all(float(v) > 0 for v in match.groups()), "alert must bind both windows and positive traffic floors")
    require(match[3] == match[4], "traffic floor differs between windows")
    policy.update(alert=alert, floor=float(match[3]))
    return policy


def vector(response, now, expected_labels, age=FRESH):
    require(response["status"] == "success" and not response.get("error") and not response.get("warnings"), "AMP query failed or partial")
    data = response["data"]
    require(data["resultType"] == "vector", "instant vector required")
    sample = one(data["result"], "one unambiguous target sample required")
    require(sample["metric"] == expected_labels, "metric target labels mismatch")
    at, value = sample["value"]
    require(isinstance(at, (int, float)) and not isinstance(at, bool) and isinstance(value, str), "invalid Prometheus sample types")
    fresh(at, now, age)
    value = float(value)
    require(math.isfinite(value), "nonfinite metric sample")
    return value


def evaluated_rules(response, policy, now):
    require(response["status"] == "success" and not response.get("warnings"), "AMP evaluated rules unavailable")
    rules = [r for g in response["data"]["groups"] for r in g["rules"]]
    for name, definition in [*policy["records"].items(), ("MiniCommerceSuccessBurn", policy["alert"])]:
        rule = one([r for r in rules if r["name"] == name and r.get("labels", {}).get("environment") == "dev"], "missing/ambiguous evaluated Dev rule")
        require(rule["health"] == "ok" and not rule.get("lastError") and rule["labels"] == definition["labels"], "unhealthy/wrong evaluated rule")
        require(canonical_promql(rule["query"]) == canonical_promql(definition["expr"]), "evaluated rule differs from configured rule")
        fresh(timestamp(rule["lastEvaluation"]), now)
        if name == "MiniCommerceSuccessBurn":
            require(rule["type"] == "alerting" and rule["state"] == "inactive" and not rule.get("alerts"), "burn alert still active/pending")
        else:
            require(rule["type"] == "recording", "wrong rule type")


def alert_routing(definition, topic, region):
    import yaml
    require(definition["status"]["statusCode"] == "ACTIVE" and isinstance(definition["data"], bytes), "AMP Alertmanager definition not ACTIVE")
    outer = yaml.safe_load(definition["data"])
    config = yaml.safe_load(outer["alertmanager_config"])
    route = config["route"]
    require(not route.get("routes") and not any(route.get(k) for k in ("match", "match_re", "matchers", "mute_time_intervals", "active_time_intervals")), "conditional/nested Alertmanager routes require review")
    receiver = one([r for r in config["receivers"] if r["name"] == route["receiver"]], "default receiver absent")
    sns = one(receiver["sns_configs"], "one SNS route required")
    require(sns["topic_arn"] == topic and sns["sigv4"]["region"] == region and sns["send_resolved"] is True, "SNS topic/SigV4/resolved route mismatch")


def topic_policy(attributes, topic, workspace, account):
    require(attributes["TopicArn"] == topic, "SNS topic mismatch")
    statements = json.loads(attributes["Policy"])["Statement"]
    statement = one(statements, "SNS topic must have only the exact AMP publish grant")
    require(statement["Effect"] == "Allow" and statement["Principal"] == {"Service": "aps.amazonaws.com"} and
            statement["Action"] == "sns:Publish" and statement["Resource"] == topic and
            statement["Condition"] == {"ArnEquals": {"AWS:SourceArn": workspace}, "StringEquals": {"AWS:SourceAccount": account}}, "SNS publish policy is not exact workspace/account-scoped")


def validate_receipts(record, deployment, workspace, topic, now):
    require(record["source"] == "captured" and record["evidenceGrade"] == "LIVE_NOT_VERIFIED", "fixtures and asserted runtime receipts cannot be promoted")
    spec = importlib.util.spec_from_file_location("amp_drill", pathlib.Path(__file__).with_name("amp-slo-drill.py"))
    drill = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(drill)
    from types import SimpleNamespace
    drill.validate(record, SimpleNamespace(max_age_minutes=120, traffic_floor_rps=0.1, resolve_timeout_minutes=15))
    b = record["binding"]
    require(b["environment"] == "dev" and b["workspaceArn"] == workspace and b["topicArn"] == topic and
            b["clusterArn"] == deployment["clusterArn"] and b["region"] == deployment["region"] and
            b["imageIndexDigest"] == deployment["image"]["indexDigest"] and b["gitopsRevision"] == deployment["gitopsRevision"], "receipt deployment/workspace binding mismatch")
    fresh(timestamp(record["fault"]["startedAt"]), now, MAX_AGE)
    require(timestamp(record["fault"]["startedAt"]) >= timestamp(deployment["observedAt"]), "alert drill predates deployment evidence")
    return record["observations"]["deliveryReceipt"]


def verify_notification(envelope, region):
    # TLS retrieves the signing certificate ONLY from the fixed regional SNS host.
    require(envelope["Type"] == "Notification" and envelope["SignatureVersion"] in ("1", "2"), "unsupported SNS envelope")
    url = envelope["SigningCertURL"]
    require(re.fullmatch(r"https://sns\." + re.escape(region) + r"\.amazonaws\.com/SimpleNotificationService-[A-Za-z0-9_-]+\.pem", url), "untrusted SNS signing certificate URL")
    cert = fetch(urllib.request.Request(url))
    names = ["Message", "MessageId"] + (["Subject"] if "Subject" in envelope else []) + ["Timestamp", "TopicArn", "Type"]
    signed = "".join(k + "\n" + envelope[k] + "\n" for k in names).encode()
    with tempfile.TemporaryDirectory(prefix="dev-sns-verify-") as folder:
        base = pathlib.Path(folder)
        (base / "cert.pem").write_bytes(cert)
        (base / "message").write_bytes(signed)
        (base / "signature").write_bytes(base64.b64decode(envelope["Signature"], validate=True))
        command(["openssl", "x509", "-in", str(base / "cert.pem"), "-checkend", "0", "-noout"])
        key = command(["openssl", "x509", "-in", str(base / "cert.pem"), "-pubkey", "-noout"])
        (base / "key.pem").write_text(key)
        command(["openssl", "dgst", "-sha256" if envelope["SignatureVersion"] == "2" else "-sha1", "-verify", str(base / "key.pem"),
                 "-signature", str(base / "signature"), str(base / "message")])


def delivery_logs(runtime, receipts, topic, account, now):
    sns = runtime.client("sns")
    subscriptions = {}
    for page in sns.get_paginator("list_subscriptions_by_topic").paginate(TopicArn=topic):
        subscriptions.update({s["SubscriptionArn"]: s for s in page["Subscriptions"]})
    confirmed = []
    for receipt in receipts.values():
        arn = receipt["headers"]["x-amz-sns-subscription-arn"]
        require(arn in subscriptions, "receipt subscriber is not currently confirmed")
        sub = subscriptions[arn]
        require(sub["TopicArn"] == topic and sub["Owner"] == account and sub["Protocol"] == "https" and sub["Endpoint"].startswith("https://"), "authenticated HTTPS subscriber required; email cannot prove delivery")
        confirmed.append(arn)
        env = receipt["envelope"]
        verify_notification(env, runtime.region)
        # SNS service-generated success stream; no operator-selected arbitrary log group.
        group = f"sns/{runtime.region}/{account}/{topic.split(':')[-1]}"
        matches = []
        for page in runtime.client("logs").get_paginator("filter_log_events").paginate(
                logGroupName=group, startTime=int((now - MAX_AGE) * 1000), endTime=int(now * 1000),
                filterPattern='{ $.notification.messageId = "' + env["MessageId"] + '" }'):
            for event in page["events"]:
                entry = json.loads(event["message"])
                if entry.get("notification", {}).get("messageId") == env["MessageId"]:
                    matches.append((event, entry))
        require(matches, "SNS delivery SUCCESS log missing (logging/sampling/retention may need setup)")
        valid = False
        for event, entry in matches:
            if entry.get("status") != "SUCCESS" or entry.get("notification", {}).get("topicArn") != topic:
                continue
            delivery = entry["delivery"]
            require(entry["notification"]["messageMD5Sum"] == hashlib.md5(env["Message"].encode(), usedforsecurity=False).hexdigest(), "SNS delivery payload hash mismatch")
            event_at = event["timestamp"] / 1000
            fresh(event_at, now, MAX_AGE)
            require(timestamp(env["Timestamp"]) <= event_at and delivery["destination"] == sub["Endpoint"] and
                    200 <= int(delivery["statusCode"]) < 300, "SNS delivery log identity/time/status mismatch")
            valid = True
        require(valid, "no successful delivery to receipt subscriber")
    require(len(set(confirmed)) == 1, "firing/resolved must reach the same subscriber")


def k6_readiness(runtime, context, namespace, name, started, now):
    operator = runtime.kube(context, "-n", namespace, "get", "deployment", "k6-operator-controller-manager")
    ready_deployment(operator)
    crd = runtime.kube(context, "get", "crd", "testruns.k6.io")
    require(any(c["type"] == "Established" and c["status"] == "True" for c in crd["status"]["conditions"]), "k6 CRD not Established")
    run = runtime.kube(context, "-n", namespace, "get", "testrun", name)
    meta = run["metadata"]
    require(meta["name"] == name and meta["namespace"] == namespace and run["status"]["stage"] == "finished", "k6 run not finished")
    fresh(timestamp(meta["creationTimestamp"]), now, MAX_AGE)
    require(timestamp(meta["creationTimestamp"]) >= started, "k6 run predates current workload")
    annotations = meta["annotations"]
    duration = annotations["playbuilder.platform/max-duration"]
    rate = annotations["playbuilder.platform/max-rate"]
    require(re.fullmatch(r"[1-9][0-9]*[sm]", duration) and re.fullmatch(r"[1-9][0-9]*", rate) and
            int(rate) <= 1000 and int(duration[:-1]) * (60 if duration[-1] == "m" else 1) <= 900 and
            annotations["playbuilder.platform/cost-boundary"] == "existing-eks-compute", "k6 budget metadata absent/out of bounds")
    jobs = runtime.kube(context, "-n", namespace, "get", "jobs", "-l", "k6_cr=" + name)["items"]
    require(jobs, "k6 execution jobs missing")
    for job in jobs:
        require(owner(job["metadata"], "TestRun", meta["uid"]), "k6 Job owner mismatch")
        status = job["status"]
        require(not status.get("failed") and status.get("succeeded") == job["spec"].get("completions", 1), "k6 Job failed/incomplete")
        fresh(timestamp(status["completionTime"]), now, MAX_AGE)
        require(timestamp(status["startTime"]) >= timestamp(meta["creationTimestamp"]) and
                timestamp(status["completionTime"]) - timestamp(status["startTime"]) <= 900, "k6 execution outside bounded interval")


def collect_slo(runtime, deployment, context, namespace, testrun, workspace_id, topic, receipt_record, now):
    account, _, _ = identity(deployment)
    require(deployment["evidenceGrade"] == "CLOUD_RUNTIME", "runtime deployment evidence required")
    fresh(timestamp(deployment["observedAt"]), now, MAX_AGE)
    require(re.fullmatch(r"ws-[A-Za-z0-9_-]+", workspace_id), "invalid AMP workspace ID")
    require(re.fullmatch(f"arn:aws:sns:{runtime.region}:{account}:" + r"[A-Za-z0-9_-]+", topic), "SNS topic account/Region mismatch")
    workspace_arn = f"arn:aws:aps:{runtime.region}:{account}:workspace/{workspace_id}"
    receipts = validate_receipts(receipt_record, deployment, workspace_arn, topic, now)
    binding = collect_deployment(runtime, deployment, context, "app-dev", os.environ.get("DEV_ARGO_APPLICATION", "mini-commerce-dev"), now)
    require(binding["istioRevision"] == receipt_record["binding"]["istioRevision"], "Istio revision differs from drill")
    k6_readiness(runtime, context, namespace, testrun, binding["startedAt"], now)
    amp = runtime.client("amp")
    workspace = amp.describe_workspace(workspaceId=workspace_id)["workspace"]
    endpoint = f"https://aps-workspaces.{runtime.region}.amazonaws.com/workspaces/{workspace_id}/"
    require(workspace["arn"] == workspace_arn and workspace["workspaceId"] == workspace_id and workspace["status"]["statusCode"] == "ACTIVE" and workspace["prometheusEndpoint"] == endpoint, "AMP workspace identity/status mismatch")
    namespace_response = amp.describe_rule_groups_namespace(workspaceId=workspace_id, name=RULE_NAMESPACE)["ruleGroupsNamespace"]
    require(namespace_response["arn"] == f"arn:aws:aps:{runtime.region}:{account}:rulegroupsnamespace/{workspace_id}/{RULE_NAMESPACE}", "AMP namespace ARN mismatch")
    policy = rule_policy(namespace_response)
    require(now - binding["startedAt"] >= policy["windows"]["long"], "current pods have not covered the long SLO window")
    for key in ("query", "longQuery"):
        require(vector(receipt_record["observations"][key], timestamp(receipt_record["capturedAt"]), {}, MAX_AGE) >= policy["floor"], "drill traffic below configured floor or stale")
    alert_labels = {"alertname": "MiniCommerceSuccessBurn", **policy["alert"]["labels"]}
    require(one([a for a in receipt_record["observations"]["firing"] if a["labels"].get("alertname") == "MiniCommerceSuccessBurn" and a["labels"].get("environment") == "dev"], "one drill burn alert required")["labels"] == alert_labels, "drill alert differs from configured target")
    alert_routing(amp.describe_alert_manager_definition(workspaceId=workspace_id)["alertManagerDefinition"], topic, runtime.region)
    attrs = runtime.client("sns").get_topic_attributes(TopicArn=topic)["Attributes"]
    topic_policy(attrs, topic, workspace_arn, account)
    delivery_logs(runtime, receipts, topic, account, now)
    current_rules = runtime.query(workspace_id, "/api/v1/rules")
    evaluated_rules(current_rules, policy, dt.datetime.now(dt.timezone.utc).timestamp())
    for window in ("short", "long"):
        traffic = runtime.query(workspace_id, "/api/v1/query", {"query": policy["traffic"][window], "time": str(now)})
        require(vector(traffic, now, {}) >= policy["floor"], "insufficient target traffic")
        name = "mini_commerce:success_burn:" + window
        sample = runtime.query(workspace_id, "/api/v1/query", {"query": name + '{service="mini-commerce",environment="dev"}', "time": str(now)})
        require(0 <= vector(sample, now, {"__name__": name, **LABELS}) <= 1, "target exceeds success error budget")
    scrape = runtime.query(workspace_id, "/api/v1/query", {"query": "min(timestamp(istio_requests_total{" + SELECTOR + "}))", "time": str(now)})
    fresh(vector(scrape, now, {}), now)
    alerts = runtime.query(workspace_id, "/alertmanager/api/v2/alerts")
    require(not any(a["labels"].get("alertname") == "MiniCommerceSuccessBurn" and
                    all(a["labels"].get(k) == v for k, v in LABELS.items()) for a in alerts), "target Alertmanager alert remains active/suppressed")
    check_snapshot(runtime, context, binding)
    require(dt.datetime.now(dt.timezone.utc).timestamp() - now <= FRESH, "collection exceeded freshness budget; retry")
    material = json.dumps({"deployment": deployment, "workspace": workspace_arn, "receipts": receipts, "observedAt": stamp(now)}, sort_keys=True)
    return {**{k: deployment[k] for k in ("source", "image", "gitopsRevision", "clusterArn", "region")},
            "schemaVersion": "playbuilder.dev-slo/v1", "evidenceGrade": "CLOUD_RUNTIME", "status": "PASS",
            "observedAt": stamp(now), "expiresAt": stamp(now + 3600),
            "evidenceId": "sha256:" + hashlib.sha256(material.encode()).hexdigest()}


def main(argv):
    mode, *args = argv
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    if mode == "deployment":
        context, namespace, application, repo, sha, image, digest, revision, cluster, region = args
        data = {"schemaVersion": "playbuilder.dev-deployment/v1", "evidenceGrade": "CLOUD_RUNTIME",
                "status": {"sync": "Synced", "health": "Healthy"}, "source": {"repository": repo, "sha": sha},
                "image": {"repository": image, "indexDigest": digest}, "gitopsRevision": revision,
                "clusterArn": cluster, "region": region, "observedAt": stamp(now)}
        identity(data)
        collect_deployment(Runtime(region), data, context, namespace, application, now)
        require(dt.datetime.now(dt.timezone.utc).timestamp() - now <= FRESH, "collection exceeded freshness budget; retry")
        print(json.dumps(data))
    elif mode == "slo":
        deployment, context, namespace, testrun, workspace, topic, region = args
        data = json.loads(pathlib.Path(deployment).read_text())
        require(data["region"] == region, "deployment/SLO Region mismatch")
        receipts = json.loads(pathlib.Path(os.environ["ALERT_DELIVERY_EVIDENCE"]).read_text())
        print(json.dumps(collect_slo(Runtime(region), data, context, namespace, testrun, workspace, topic, receipts, now)))
    else:
        raise EvidenceError("unsupported capture mode")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as error:
        print("DEV_EVIDENCE_REJECTED: " + (str(error) if isinstance(error, EvidenceError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
