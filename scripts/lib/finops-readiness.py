#!/usr/bin/env python3
"""Read-only billing configuration gate. Never proves real alert delivery."""
import argparse
import datetime as dt
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str).encode()


def values(value):
    return value if isinstance(value, list) else [value]


def positive(value):
    number = Decimal(str(value))
    require(number.is_finite() and number > 0, "positive finite amount required")
    return number


def validate_contract(c, account, region, platform):
    require(c["schemaVersion"] == "platform.finops/v1", "unsupported contract")
    b, w = c["billingAccountId"], c["workloadAccountId"]
    require(re.fullmatch(r"[0-9]{12}", b) and re.fullmatch(r"[0-9]{12}", w), "account format")
    require(w == account and c["workloadRegion"] == region and region in ("us-east-1", "ap-northeast-2"), "workload binding mismatch")
    require(c["billingApiRegion"] == c["notificationRegion"] == "us-east-1", "billing Region mismatch")
    require(c["notificationOwnership"] == "EXTERNAL_SHARED", "external billing topic required")
    require(re.fullmatch(r"arn:aws:sns:us-east-1:" + b + r":[A-Za-z0-9_-]+", c["notificationTopicArn"]), "same-account standard SNS required")
    require(c["budgetArn"] == f"arn:aws:budgets::{b}:budget/{c['budgetName']}", "budget ARN mismatch")
    for key, prefix in (("monitorArn", "anomalymonitor"), ("subscriptionArn", "anomalysubscription")):
        require(re.fullmatch(r"arn:aws:ce::" + b + ":" + prefix + r"/[A-Za-z0-9-]+", c[key]), "regionless CE ARN mismatch")
    tags = c["requiredTags"]
    for key in ("PlatformInstanceId", "Owner", "CostCenter", "Environment", "ManagedBy"):
        require(isinstance(tags.get(key), str) and tags[key].strip(), "required cost metadata missing")
    require(tags["Environment"] == "prod" and tags["ManagedBy"] == "Terraform" and tags["PlatformInstanceId"] == platform, "platform ownership mismatch")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", platform), "canonical platform ID required")
    require(c["budgetScope"] == dict(linkedAccountId=w, tagKey="PlatformInstanceId", tagValue=platform), "budget scope mismatch")
    require(c["anomalyScope"] == dict(boundary="BILLING_ORGANIZATION", tagKey="PlatformInstanceId", tagValue=platform), "anomaly scope mismatch")
    require(sorted(c["thresholdPercentages"]) == [50, 80, 100], "fixed 50/80/100 thresholds required")
    positive(c["monthlyBudgetUsd"])
    positive(c["anomalyThresholdUsd"])


def policy_permits(raw, service, actions, resource, account, source, kms=False):
    """Conservative documented subset, not a general IAM policy simulator.

    Any explicit Deny or unsupported condition fails closed. A separate review
    must handle policies outside this subset; no force/override switch exists.
    """
    policy = json.loads(raw) if isinstance(raw, str) else raw
    statements = values(policy["Statement"])
    require(not any(s.get("Effect") == "Deny" for s in statements), "explicit policy Deny needs owner review")
    allowed = set()
    for s in statements:
        if s.get("Effect") != "Allow" or not isinstance(s.get("Principal"), dict):
            continue
        if values(s["Principal"].get("Service")) != [service]:
            continue
        if values(s.get("Resource")) not in ([resource], ["*"] if kms else [resource]):
            continue
        cond = s.get("Condition", {})
        supported = True
        bounded_account = bounded_source = False
        for op, entries in cond.items():
            for key, value in entries.items():
                if op == "StringEquals" and key.lower() == "aws:sourceaccount" and values(value) == [account]:
                    bounded_account = True
                elif op in ("ArnEquals", "ArnLike", "StringEquals") and key.lower() == "aws:sourcearn" and values(value) == [source]:
                    bounded_source = True
                else:
                    supported = False
        if not supported or (not kms and not (bounded_account and bounded_source)):
            continue
        allowed.update(a.lower() for a in values(s.get("Action", [])))
    require(all(a.lower() in allowed or (a == "kms:GenerateDataKey" and "kms:generatedatakey*" in allowed) for a in actions), "publisher policy permission missing or ambiguous")


def evaluate(c, o, now):
    at = dt.datetime.strptime(o["observedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    require(at.strftime("%Y-%m-%dT%H:%M:%SZ") == o["observedAt"] and 0 <= (now-at).total_seconds() <= 900, "stale or future observation")
    b, w, topic, platform = c["billingAccountId"], c["workloadAccountId"], c["notificationTopicArn"], c["requiredTags"]["PlatformInstanceId"]
    require(o["identity"]["Account"] == b and re.fullmatch(r"arn:aws:(iam|sts)::" + b + r":.+", o["identity"]["Arn"]), "billing caller mismatch")
    org = o["organization"]["Organization"]
    require(org["Id"] == c["organizationId"] and org["MasterAccountId"] == b, "existing management organization required")
    members = [a for a in o["accounts"] if a["Id"] == w]
    require(len(members) == 1 and members[0].get("State", members[0].get("Status")) == "ACTIVE", "active workload membership required")
    budget = o["budget"]["Budget"]
    require(budget["BudgetName"] == c["budgetName"] and budget["BudgetType"] == "COST" and budget["TimeUnit"] == "MONTHLY", "budget identity/type mismatch")
    require(positive(budget["BudgetLimit"]["Amount"]) == positive(c["monthlyBudgetUsd"]) and budget["BudgetLimit"]["Unit"] == "USD", "budget amount mismatch")
    require(budget["CostFilters"] == {"LinkedAccount": [w], "TagKeyValue": ["user:PlatformInstanceId$" + platform]}, "actual budget cost scope mismatch")
    notes = o["notifications"]
    require(len(notes) == 3 and sorted(n["notification"]["Threshold"] for n in notes) == [50, 80, 100], "actual notification thresholds mismatch")
    for n in notes:
        expected = dict(NotificationType="ACTUAL", ComparisonOperator="GREATER_THAN", Threshold=n["notification"]["Threshold"], ThresholdType="PERCENTAGE")
        require({k: n["notification"].get(k) for k in expected} == expected, "actual spend percentage notification required")
        require(n["subscribers"] == [{"SubscriptionType": "SNS", "Address": topic}], "exact budget SNS subscriber required")
    require(len(o["monitors"]) == 1, "one actual monitor required")
    monitor = o["monitors"][0]
    require(monitor["MonitorArn"] == c["monitorArn"] and monitor["MonitorType"] == "CUSTOM", "monitor mismatch")
    require(json.loads(monitor["MonitorSpecification"]) == {"Tags": {"Key": "PlatformInstanceId", "Values": [platform]}}, "actual organization tag-only monitor required")
    require(len(o["subscriptions"]) == 1, "one actual anomaly subscription required")
    sub = o["subscriptions"][0]
    require(sub["SubscriptionArn"] == c["subscriptionArn"] and sub["AccountId"] == b and sub["Frequency"] == "IMMEDIATE" and sub["MonitorArnList"] == [c["monitorArn"]], "anomaly subscription identity/frequency mismatch")
    require(len(sub["Subscribers"]) == 1 and sub["Subscribers"][0]["Type"] == "SNS" and sub["Subscribers"][0]["Address"] == topic and sub["Subscribers"][0].get("Status", "CONFIRMED") == "CONFIRMED", "anomaly SNS subscriber mismatch")
    expr = sub["ThresholdExpression"]
    require(set(expr) == {"Dimensions"}, "simple absolute impact threshold required")
    dim = expr["Dimensions"]
    require(dim["Key"] == "ANOMALY_TOTAL_IMPACT_ABSOLUTE" and dim["MatchOptions"] == ["GREATER_THAN_OR_EQUAL"] and len(dim["Values"]) == 1 and positive(dim["Values"][0]) == positive(c["anomalyThresholdUsd"]), "anomaly threshold mismatch")
    active = [t for t in o["costTags"] if t["TagKey"] == "PlatformInstanceId"]
    require(len(active) == 1 and active[0]["Status"] == "Active" and active[0]["Type"] == "UserDefined", "active cost allocation tag required")
    for kind in ("budget", "monitor", "subscription"):
        tag_list = o["resourceTags"][kind]
        tags = {t["Key"]: t["Value"] for t in tag_list}
        require(len(tags) == len(tag_list) and all(tags.get(k) == v for k, v in c["requiredTags"].items()), "actual resource cost metadata mismatch")
    attrs = o["topic"]["Attributes"]
    require(attrs["TopicArn"] == topic and attrs["Owner"] == b and attrs.get("FifoTopic", "false") == "false", "billing topic identity mismatch")
    for service, source in (("budgets.amazonaws.com", c["budgetArn"]), ("costalerts.amazonaws.com", c["subscriptionArn"])):
        policy_permits(attrs["Policy"], service, ["sns:Publish"], topic, b, source)
        if attrs.get("KmsMasterKeyId"):
            key = o["kms"]["KeyMetadata"]
            require(re.fullmatch(r"arn:aws:kms:us-east-1:" + b + r":key/[a-f0-9-]+", key["Arn"]) and key["KeyState"] == "Enabled" and key["KeyUsage"] == "ENCRYPT_DECRYPT" and key["KeyManager"] == "CUSTOMER", "enabled billing-region customer KMS key required")
            require(attrs["KmsMasterKeyId"] in (key["Arn"], key.get("KeyId"), o.get("kmsRequestedId")), "topic encryption key binding mismatch")
            policy_permits(o["kmsPolicy"]["Policy"], service, ["kms:GenerateDataKey", "kms:Decrypt"], key["Arn"], b, source, kms=True)
    destinations = o["destinations"]
    require(len(destinations) > 0 and all(d["TopicArn"] == topic and re.fullmatch(re.escape(topic) + r":[a-f0-9-]{36}", d["SubscriptionArn"]) for d in destinations), "all billing destinations must be confirmed")
    usage = o["costUsage"]
    require("Error" not in usage and usage.get("GroupDefinitions") == [{"Type": "DIMENSION", "Key": "LINKED_ACCOUNT"}], "billing scope query missing or denied")
    accounts = set()
    for period in usage["ResultsByTime"]:
        for group in period["Groups"]:
            require(len(group["Keys"]) == 1 and re.fullmatch(r"[0-9]{12}", group["Keys"][0]), "ambiguous billing scope")
            metric = group["Metrics"]["UnblendedCost"]
            require(metric["Unit"] == "USD" and Decimal(metric["Amount"]).is_finite(), "invalid billing amount")
            accounts.add(group["Keys"][0])
    require(accounts <= {w}, "organization-wide PlatformInstanceId collision")
    return {"configurationStatus": "CONFIGURED", "dataStatus": "DATA_OBSERVED" if accounts else "DATA_PENDING",
            "uniquenessStatus": "NO_COLLISION_OBSERVED_IN_WINDOW" if accounts else "NOT_YET_OBSERVABLE", "deliveryStatus": "NOT_VERIFIED"}


def collect_observations(c, client, now):
    """Only reads via supplied SDK clients; tests replace external I/O, not validation."""
    def read(service, operation, **params):
        return getattr(client(service), operation)(**params)

    def pages(service, operation, field, token="NextToken", **params):
        result, seen = [], set()
        while True:
            try:
                response = read(service, operation, **params)
            except Exception as error:
                if seen and operation == "get_cost_and_usage":
                    raise ValueError("incomplete paginated billing observation") from error
                raise
            if operation == "get_cost_and_usage":
                require(response.get("GroupDefinitions") == [{"Type": "DIMENSION", "Key": "LINKED_ACCOUNT"}], "ambiguous billing group response")
            result.extend(response[field])
            more = response.get(token)
            if not more:
                return result
            require(more not in seen, "repeated pagination token")
            seen.add(more)
            params[token] = more

    b, name = c["billingAccountId"], c["budgetName"]
    o = {"observedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
    o["identity"] = read("sts", "get_caller_identity")
    require(o["identity"]["Account"] == b, "billing caller mismatch before billing reads")
    o["organization"] = read("organizations", "describe_organization")
    require(o["organization"]["Organization"]["MasterAccountId"] == b, "management account required")
    o["accounts"] = pages("organizations", "list_accounts", "Accounts")
    o["budget"] = read("budgets", "describe_budget", AccountId=b, BudgetName=name)
    notifications = pages("budgets", "describe_notifications_for_budget", "Notifications", AccountId=b, BudgetName=name)
    o["notifications"] = [{"notification": n, "subscribers": pages("budgets", "describe_subscribers_for_notification", "Subscribers", AccountId=b, BudgetName=name, Notification=n)} for n in notifications]
    o["monitors"] = pages("ce", "get_anomaly_monitors", "AnomalyMonitors", token="NextPageToken", MonitorArnList=[c["monitorArn"]])
    o["subscriptions"] = pages("ce", "get_anomaly_subscriptions", "AnomalySubscriptions", token="NextPageToken", SubscriptionArnList=[c["subscriptionArn"]])
    o["costTags"] = pages("ce", "list_cost_allocation_tags", "CostAllocationTags", TagKeys=["PlatformInstanceId"])
    o["resourceTags"] = {kind: read(service, "list_tags_for_resource", **{parameter: c[key]})["ResourceTags"] for kind, service, key, parameter in (("budget", "budgets", "budgetArn", "ResourceARN"), ("monitor", "ce", "monitorArn", "ResourceArn"), ("subscription", "ce", "subscriptionArn", "ResourceArn"))}
    o["topic"] = read("sns", "get_topic_attributes", TopicArn=c["notificationTopicArn"])
    o["destinations"] = pages("sns", "list_subscriptions_by_topic", "Subscriptions", TopicArn=c["notificationTopicArn"])
    key = o["topic"]["Attributes"].get("KmsMasterKeyId")
    if key:
        o["kmsRequestedId"] = key
        o["kms"] = read("kms", "describe_key", KeyId=key)
        o["kmsPolicy"] = read("kms", "get_key_policy", KeyId=o["kms"]["KeyMetadata"]["Arn"], PolicyName="default")
    period = {"Start": (now.date()-dt.timedelta(days=30)).isoformat(), "End": now.date().isoformat()}
    try:
        records = pages("ce", "get_cost_and_usage", "ResultsByTime", token="NextPageToken", TimePeriod=period,
            Granularity="DAILY", Metrics=["UnblendedCost"], Filter={"Tags": {"Key": "PlatformInstanceId", "Values": [c["requiredTags"]["PlatformInstanceId"]]}},
            GroupBy=[{"Type": "DIMENSION", "Key": "LINKED_ACCOUNT"}])
    except Exception as error:
        # Only this documented CE data-warmup response is pending. Denials,
        # missing responses, malformed groups and other errors remain blockers.
        if getattr(error, "response", {}).get("Error", {}).get("Code") != "DataUnavailableException":
            raise
        records = []
        o["billingDataAvailability"] = "DataUnavailableException"
    o["costUsage"] = {"GroupDefinitions": [{"Type": "DIMENSION", "Key": "LINKED_ACCOUNT"}], "ResultsByTime": records}
    o["queryWindow"] = period
    return o


def runtime_clients(args):
    require(not os.environ.get("COURSE_CHECK_BIN_DIR"), "runtime collector refuses command doubles")
    require(not any(k.startswith("AWS_ENDPOINT_URL") for k in os.environ), "custom AWS endpoints prohibited")
    try:
        import boto3
        from botocore.config import Config
    except ImportError as error:
        raise ValueError("install scripts/requirements-amp-slo.txt in an isolated venv for runtime collection") from error
    session = boto3.Session(profile_name=args.profile, region_name="us-east-1")
    config = Config(ignore_configured_endpoint_urls=True, retries={"mode": "standard", "max_attempts": 3}, connect_timeout=10, read_timeout=30)
    if args.role_arn:
        require(re.fullmatch(r"arn:aws:iam::[0-9]{12}:role/[^*?]+", args.role_arn), "concrete billing role required")
        credentials = session.client("sts", config=config).assume_role(RoleArn=args.role_arn, RoleSessionName="finops-readiness")["Credentials"]
        session = boto3.Session(aws_access_key_id=credentials["AccessKeyId"], aws_secret_access_key=credentials["SecretAccessKey"], aws_session_token=credentials["SessionToken"], region_name="us-east-1")
    clients = {}
    def client(service):
        if service not in clients:
            clients[service] = session.client(service, region_name="us-east-1", config=config)
        return clients[service]
    return client


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=("fixture", "collect"))
    for option in ("contract", "account", "region", "platform-id", "output"):
        p.add_argument("--" + option, required=True)
    p.add_argument("--gate-policy", choices=("configuration-only",), required=True)
    p.add_argument("--observations")
    access = p.add_mutually_exclusive_group()
    access.add_argument("--profile")
    access.add_argument("--role-arn")
    args = p.parse_args()
    try:
        source = Path(args.contract).read_bytes()
        c = json.loads(source)
        validate_contract(c, args.account, args.region, args.platform_id)
        now = dt.datetime.now(dt.timezone.utc)
        if args.mode == "fixture":
            require(args.observations is not None and not args.profile and not args.role_arn, "fixture requires observations, not cloud credentials")
            o = json.loads(Path(args.observations).read_bytes())
        else:
            require(args.observations is None and (args.profile or args.role_arn), "collection requires explicit billing profile or role, not replayed observations")
            o = collect_observations(c, runtime_clients(args), now)
        states = evaluate(c, o, now)
        result = dict(schemaVersion="platform.finops-readiness/v1", evidenceGrade="LOCAL_VERIFIED" if args.mode == "fixture" else "CLOUD_RUNTIME",
            source=args.mode, gatePolicy=args.gate_policy, **states, accountId=c["workloadAccountId"], region=c["workloadRegion"],
            billingAccountId=c["billingAccountId"], billingApiRegion="us-east-1", platformInstanceId=args.platform_id,
            monitoringIdentity={"accountId": o["identity"]["Account"], "principalArn": o["identity"]["Arn"],
                "organizationId": o["organization"]["Organization"]["Id"], "managementAccountId": o["organization"]["Organization"]["MasterAccountId"]},
            observedAt=o["observedAt"], expiresAt=(dt.datetime.strptime(o["observedAt"], "%Y-%m-%dT%H:%M:%SZ")+dt.timedelta(minutes=15)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            bindings={"contractSha256": digest(source), "observationsSha256": digest(canonical(o)), "collectorSha256": digest(Path(__file__).read_bytes())},
            queryWindow=o.get("queryWindow"),
            verificationLimit="Configuration only; no SNS receipt, cost monitor operational verification, universal/future tag uniqueness or zero-spend claim. Runtime evidence is unsigned; retain trusted execution provenance.")
        path = Path(args.output)
        fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(result, handle, indent=2)
                handle.write("\n")
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print(f"PASS: [{result['evidenceGrade']}] CONFIGURED; {result['dataStatus']}; delivery NOT_VERIFIED")
    except Exception as error:
        # SDK exception text can include contact values. Never serialize it.
        detail = str(error) if isinstance(error, ValueError) else type(error).__name__
        print("ERROR: FINOPS_NOT_READY: " + detail, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
