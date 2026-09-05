#!/usr/bin/env python3
"""Read-only AMP snapshots and conservative captured-evidence validation.

No fault injection, subscription mutation, notification send, or live-grade attestation.
HTTP subscriber receipts are operator-supplied SNS Notification envelopes, not booleans.
"""
import argparse
import datetime as dt
import json
import math
import os
import pathlib
import re
import sys
import urllib.parse
import urllib.request

SCHEMA = "platform.amp-slo-drill/v1"
LIMIT = "Captured API/subscriber data checked for consistency only; SNS signatures, subscriber audit provenance, image/GitOps/Istio deployment binding require independent operator verification."

def require(condition, message):
    if not condition:
        raise ValueError(message)

def timestamp(value):
    require(isinstance(value, str), "timestamp required")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "timestamp must include timezone")
    return parsed.timestamp()

def read(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

def binding(record):
    b = record["binding"]
    account, region = b["accountId"], b["region"]
    require(re.fullmatch(r"[0-9]{12}", account), "accountId invalid")
    require(region in ("ap-northeast-2", "us-east-1"), "Region unsupported")
    for key, service, prefix in (("workspaceArn","aps","workspace/"),("topicArn","sns",""),("clusterArn","eks","cluster/")):
        require(re.fullmatch(r"arn:aws:" + service + ":" + region + ":" + account + ":" + prefix + r"[A-Za-z0-9_-]+",b[key]), key + " must match account and Region")
    require(b["environment"] in ("dev","prod"), "environment invalid")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}",b["imageIndexDigest"]), "image index digest required")
    require(re.fullmatch(r"[0-9a-f]{40}",b["gitopsRevision"]), "GitOps commit required")
    require(re.fullmatch(r"[0-9]+-[0-9]+-[0-9]+",b["istioRevision"]), "exact Istio revision required")
    return b

def validate(record, args):
    require(record["schemaVersion"] == SCHEMA, "unsupported evidence schema")
    source = record["source"]
    require(source in ("fixture","captured"), "source must be fixture or captured")
    expected_grade = "LOCAL_VERIFIED" if source == "fixture" else "LIVE_NOT_VERIFIED"
    require(record["evidenceGrade"] == expected_grade, "fixture/captured grade uplift rejected")
    b = binding(record)
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    captured = timestamp(record["capturedAt"])
    require(0 <= now-captured <= args.max_age_minutes*60, "stale or future capture")
    start, stop = timestamp(record["fault"]["startedAt"]), timestamp(record["fault"]["stoppedAt"])
    require(start < stop <= captured and now-start <= args.max_age_minutes*60, "fault interval invalid or stale")
    require(bool(record["fault"]["operatorEvidence"].strip()), "bounded operator fault evidence required")
    o = record["observations"]
    require(o["identity"]["Account"] == b["accountId"], "caller identity mismatch")
    require(o["workspace"]["workspace"]["arn"] == b["workspaceArn"] and o["workspace"]["workspace"]["status"]["statusCode"] == "ACTIVE", "workspace not active or mismatched")
    require(o["cluster"]["cluster"]["arn"] == b["clusterArn"] and o["cluster"]["cluster"]["status"] == "ACTIVE", "cluster not active or mismatched")
    for key in ("query", "longQuery"):
        q = o[key]
        require(q["status"] == "success" and not q.get("error"), "AMP query denied or failed")
        require(q["data"]["resultType"] == "vector" and len(q["data"]["result"]) == 1, "nonempty unambiguous traffic sample required")
        at, value = q["data"]["result"][0]["value"]
        require(start <= float(at) <= stop, "traffic sample outside fault interval")
        require(math.isfinite(float(value)) and float(value) >= args.traffic_floor_rps, "below traffic floor")
    rules = o["rules"]
    require(rules["status"] == "success" and not rules.get("error"), "AMP rules denied or failed")
    evaluated = [r for g in rules["data"]["groups"] for r in g["rules"] if r.get("name") == "MiniCommerceSuccessBurn"]
    require(len(evaluated) == 1 and evaluated[0]["health"] == "ok" and evaluated[0]["type"] == "alerting", "healthy actual AMP burn rule required")
    require(evaluated[0]["state"] == "firing" and not evaluated[0].get("lastError") and start <= timestamp(evaluated[0]["lastEvaluation"]) <= stop, "rule did not fire within the fault interval")
    firing = [a for a in o["firing"] if a["labels"].get("alertname") == "MiniCommerceSuccessBurn" and a["labels"].get("environment") == b["environment"]]
    require(len(firing) == 1, "one matching Alertmanager firing observation required")
    alert = firing[0]
    require(evaluated[0]["labels"] == {key:value for key,value in alert["labels"].items() if key != "alertname"}, "rule labels differ from observed alert")
    fp = alert["fingerprint"]
    require(re.fullmatch(r"[0-9a-f]{16}",fp), "Alertmanager fingerprint invalid")
    require(alert["status"]["state"] == "active", "suppressed alert cannot prove firing")
    require(alert["labels"]["service"] == "mini-commerce", "service mismatch")
    active = timestamp(alert["startsAt"])
    require(start <= active <= stop, "firing outside fault interval")
    require(isinstance(o["resolved"], list) and not any(a.get("fingerprint") == fp for a in o["resolved"]), "alert remains unresolved")
    ids = []
    received = []
    for state in ("firing","resolved"):
        receipt = o["deliveryReceipt"][state]
        env = receipt["envelope"]
        require(env["Type"] == "Notification" and env["TopicArn"] == b["topicArn"], "SNS Notification topic mismatch")
        require(re.fullmatch(re.escape(b["topicArn"]) + r":[0-9a-f-]{36}",receipt["headers"]["x-amz-sns-subscription-arn"]), "subscriber identity missing or wrong topic")
        require(env["SignatureVersion"] in ("1","2") and bool(env["Signature"]), "SNS signature envelope missing")
        require(re.fullmatch(r"https://sns\." + re.escape(b["region"]) + r"\.amazonaws\.com/SimpleNotificationService-[A-Za-z0-9_-]+\.pem",env["SigningCertURL"]), "SNS certificate host invalid")
        require(re.fullmatch(r"[0-9a-f-]{36}",env["MessageId"]), "SNS message identity invalid")
        ids.append(env["MessageId"])
        sent, recv = timestamp(env["Timestamp"]), timestamp(receipt["receivedAt"])
        require(active <= sent <= recv <= captured, "SNS delivery timestamp invalid")
        received.append(recv)
        message = json.loads(env["Message"])
        require(message["status"] == state, "SNS event state mismatch")
        matches = [a for a in message["alerts"] if a.get("fingerprint") == fp]
        require(len(matches) == 1, "SNS fingerprint mismatch")
        item = matches[0]
        require(item["status"] == state and item["labels"] == alert["labels"] and timestamp(item["startsAt"]) == active, "SNS alert identity mismatch")
        if state == "resolved":
            ended = timestamp(item["endsAt"])
            require(stop <= ended <= sent and recv-stop <= args.resolve_timeout_minutes*60, "late or invalid resolved event")
    require(ids[0] != ids[1] and received[0] < received[1], "distinct firing/resolved delivery required")
    return {"schemaVersion":SCHEMA,"status":"CAPTURED_VALIDATED","evidenceGrade":expected_grade,"fingerprint":fp,"binding":b,"verificationLimit":LIMIT}

def collect(record, args):
    # Dependencies are imported only in explicit runtime collection; validation is offline stdlib.
    try:
        import boto3
        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest
    except ImportError as error:
        raise ValueError("COLLECTOR_PREREQUISITE: use a Python 3.10+ venv with scripts/requirements-amp-slo.txt; AWS CLI installation does not provide boto3") from error
    require(record["schemaVersion"] == SCHEMA and record["source"] == "captured" and record["evidenceGrade"] == "LIVE_NOT_VERIFIED", "collection requires captured operator input; fixtures cannot be promoted")
    b = binding(record)
    session = boto3.Session(region_name=b["region"])
    credentials = session.get_credentials()
    require(credentials is not None, "AWS credentials unavailable")
    base = "https://aps-workspaces." + b["region"] + ".amazonaws.com/workspaces/" + b["workspaceArn"].split("/")[-1]
    def get(path, query=None):
        url = base + path + ("?" + urllib.parse.urlencode(query) if query else "")
        request = AWSRequest(method="GET", url=url)
        SigV4Auth(credentials.get_frozen_credentials(), "aps", b["region"]).add_auth(request)
        with urllib.request.urlopen(urllib.request.Request(url, headers=dict(request.headers.items())), timeout=30) as response:
            require(response.status == 200, "AMP HTTP response failed")
            return json.load(response)
    o = record.setdefault("observations",{})
    o["identity"] = session.client("sts").get_caller_identity()
    require(o["identity"]["Account"] == b["accountId"], "runtime caller account mismatch")
    o["workspace"] = session.client("amp").describe_workspace(workspaceId=b["workspaceArn"].split("/")[-1])
    o["cluster"] = session.client("eks").describe_cluster(name=b["clusterArn"].split("/")[-1])
    o[args.phase] = get("/alertmanager/api/v2/alerts")
    if args.phase == "firing":
        selector = 'reporter="destination",destination_canonical_service="mini-commerce",destination_workload_namespace="app-' + b["environment"] + '",environment="' + b["environment"] + '"'
        o["query"] = get("/api/v1/query",{"query":"sum(rate(istio_requests_total{" + selector + "}[" + args.short_window + "]))"})
        o["longQuery"] = get("/api/v1/query",{"query":"sum(rate(istio_requests_total{" + selector + "}[" + args.long_window + "]))"})
        o["rules"] = get("/api/v1/rules")
    record["capturedAt"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00","Z")
    record["verificationLimit"] = LIMIT
    # Existing files are never overwritten; snapshots may contain subscriber identifiers.
    descriptor = os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(descriptor,"w") as handle:
        json.dump(record,handle,default=lambda x:x.isoformat() if isinstance(x,dt.datetime) else str(x),indent=2)
    return {"status":"CAPTURED","evidenceGrade":"LIVE_NOT_VERIFIED","output":args.output,"verificationLimit":LIMIT}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode",choices=("validate","collect"))
    parser.add_argument("--input",required=True)
    parser.add_argument("--output")
    parser.add_argument("--phase",choices=("firing","resolved"))
    parser.add_argument("--traffic-floor-rps",type=float,default=0.1)
    parser.add_argument("--resolve-timeout-minutes",type=float,default=15)
    parser.add_argument("--max-age-minutes",type=float,default=120)
    parser.add_argument("--short-window",default="5m")
    parser.add_argument("--long-window",default="1h")
    args=parser.parse_args()
    try:
        require(all(math.isfinite(v) and v>0 for v in (args.traffic_floor_rps,args.resolve_timeout_minutes,args.max_age_minutes)), "positive finite policy limits required")
        require(re.fullmatch(r"[1-9][0-9]*[mh]",args.short_window), "invalid query window")
        require(re.fullmatch(r"[1-9][0-9]*[mh]",args.long_window), "invalid long query window")
        if args.mode=="collect":
            require(args.output and args.phase, "collect requires --output and --phase")
        record=read(args.input)
        print(json.dumps(validate(record,args) if args.mode=="validate" else collect(record,args)))
    except Exception as error:
        # Never echo raw remote payloads or credentials.
        print("AMP_SLO_REJECTED: " + (str(error) if isinstance(error,ValueError) else type(error).__name__),file=sys.stderr)
        return 1
    return 0
if __name__=="__main__":
    sys.exit(main())
