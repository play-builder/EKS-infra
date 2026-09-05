"""Behavior contracts: losing any observed billing control must close the gate."""
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

ROOT = Path(__file__).resolve().parents[1]


def fixture():
    billing, workload = "123456789012", "123456789012"
    topic = f"arn:aws:sns:us-east-1:{billing}:billing-alerts"
    monitor = f"arn:aws:ce::{billing}:anomalymonitor/12345678-1234-1234-1234-123456789012"
    subscription = f"arn:aws:ce::{billing}:anomalysubscription/12345678-1234-1234-1234-123456789012"
    tags = dict(PlatformInstanceId="commerce-123", Owner="platform-team", CostCenter="cc100", Environment="prod", ManagedBy="Terraform")
    contract = dict(schemaVersion="platform.finops/v1", billingAccountId=billing, workloadAccountId=workload,
                    organizationId="o-example1234", billingApiRegion="us-east-1", workloadRegion="ap-northeast-2",
                    notificationRegion="us-east-1", notificationOwnership="EXTERNAL_SHARED", notificationTopicArn=topic,
                    budgetArn=f"arn:aws:budgets::{billing}:budget/platform-prod", budgetName="platform-prod",
                    monitorArn=monitor, subscriptionArn=subscription, monthlyBudgetUsd=500,
                    thresholdPercentages=[50, 80, 100], anomalyThresholdUsd=25, requiredTags=tags,
                    budgetScope=dict(linkedAccountId=workload, tagKey="PlatformInstanceId", tagValue="commerce-123"),
                    anomalyScope=dict(boundary="BILLING_ORGANIZATION", tagKey="PlatformInstanceId", tagValue="commerce-123"))
    tag = {"Tags": {"Key": "PlatformInstanceId", "Values": ["commerce-123"]}}
    notifications = [dict(NotificationType="ACTUAL", ComparisonOperator="GREATER_THAN", Threshold=n, ThresholdType="PERCENTAGE") for n in (50, 80, 100)]
    policy = {"Version": "2012-10-17", "Statement": [
        dict(Effect="Allow", Principal={"Service": service}, Action="SNS:Publish", Resource=topic,
             Condition={"StringEquals": {"aws:SourceAccount": billing}, "ArnEquals": {"aws:SourceArn": arn}})
        for service, arn in (("budgets.amazonaws.com", contract["budgetArn"]), ("costalerts.amazonaws.com", subscription))]}
    observation = dict(observedAt=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        identity={"Account": billing, "Arn": f"arn:aws:sts::{billing}:assumed-role/Billing/readiness"},
        organization={"Organization": {"Id": contract["organizationId"], "MasterAccountId": billing}},
        accounts=[{"Id": workload, "State": "ACTIVE"}],
        budget={"Budget": {"BudgetName": "platform-prod", "BudgetType": "COST", "TimeUnit": "MONTHLY",
            "BudgetLimit": {"Amount": "500.0", "Unit": "USD"},
            "CostFilters": {"LinkedAccount": [workload], "TagKeyValue": ["user:PlatformInstanceId$commerce-123"]}}},
        notifications=[{"notification": n, "subscribers": [{"SubscriptionType": "SNS", "Address": topic}]} for n in notifications],
        monitors=[{"MonitorArn": monitor, "MonitorType": "CUSTOM", "MonitorSpecification": json.dumps(tag)}],
        subscriptions=[{"AccountId": billing, "SubscriptionArn": subscription, "Frequency": "IMMEDIATE", "MonitorArnList": [monitor],
            "Subscribers": [{"Type": "SNS", "Address": topic, "Status": "CONFIRMED"}],
            "ThresholdExpression": {"Dimensions": {"Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE", "Values": ["25"], "MatchOptions": ["GREATER_THAN_OR_EQUAL"]}}}],
        costTags=[{"TagKey": "PlatformInstanceId", "Type": "UserDefined", "Status": "Active"}],
        resourceTags={key: [{"Key": k, "Value": v} for k, v in tags.items()] for key in ("budget", "monitor", "subscription")},
        topic={"Attributes": {"TopicArn": topic, "Owner": billing, "Policy": json.dumps(policy)}},
        destinations=[{"TopicArn": topic, "SubscriptionArn": topic + ":12345678-1234-1234-1234-123456789012", "Protocol": "https", "Endpoint": "https://example.invalid/alerts"}],
        costUsage={"GroupDefinitions": [{"Type": "DIMENSION", "Key": "LINKED_ACCOUNT"}], "ResultsByTime": []})
    return contract, observation


class Readiness(unittest.TestCase):
    def run_check(self, contract=None, observation=None, extra=(), env=None):
        c, o = fixture()
        c = c if contract is None else contract
        o = o if observation is None else observation
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)
            (path / "contract.json").write_text(json.dumps(c))
            (path / "observation.json").write_text(json.dumps(o))
            result = subprocess.run(["bash", str(ROOT / "scripts/finops-readiness-check.sh"), "fixture",
                "--contract", str(path / "contract.json"), "--observations", str(path / "observation.json"),
                "--account", "123456789012", "--region", "ap-northeast-2", "--platform-id", "commerce-123",
                "--gate-policy", "configuration-only", "--output", str(path / "out.json"), *extra],
                text=True, capture_output=True, env={**os.environ, **(env or {})})
            output = json.loads((path / "out.json").read_text()) if (path / "out.json").exists() else None
            return result, output

    def test_configured_empty_billing_is_pending_not_verified_delivery(self):
        result, output = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["configurationStatus"], "CONFIGURED")
        self.assertEqual(output["dataStatus"], "DATA_PENDING")
        self.assertEqual(output["deliveryStatus"], "NOT_VERIFIED")
        self.assertEqual(output["uniquenessStatus"], "NOT_YET_OBSERVABLE")
        self.assertEqual(output["evidenceGrade"], "LOCAL_VERIFIED")
        self.assertRegex(output["bindings"]["contractSha256"], r"^sha256:[a-f0-9]{64}$")
        self.assertNotIn("Endpoint", json.dumps(output))

    def test_controls_fail_closed(self):
        mutations = {
            "caller": lambda o: o["identity"].update(Account="999999999999"),
            "management": lambda o: o["organization"]["Organization"].update(MasterAccountId="999999999999"),
            "membership": lambda o: o.update(accounts=[]),
            "budget-scope": lambda o: o["budget"]["Budget"].update(CostFilters={}),
            "budget-limit": lambda o: o["budget"]["Budget"]["BudgetLimit"].update(Amount="1"),
            "missing-100": lambda o: o["notifications"].pop(),
            "forecast": lambda o: o["notifications"][0]["notification"].update(NotificationType="FORECASTED"),
            "subscriber": lambda o: o["notifications"][0].update(subscribers=[]),
            "monitor-scope": lambda o: o["monitors"][0].update(MonitorSpecification='{"Dimensions":{"Key":"SERVICE"}}'),
            "duplicate-monitor": lambda o: o["monitors"].append(o["monitors"][0]),
            "subscription-frequency": lambda o: o["subscriptions"][0].update(Frequency="DAILY"),
            "subscription-threshold": lambda o: o["subscriptions"][0]["ThresholdExpression"]["Dimensions"].update(Values=["0"]),
            "inactive-tag": lambda o: o["costTags"][0].update(Status="Inactive"),
            "missing-resource-owner": lambda o: o["resourceTags"].update(budget=[]),
            "sns-policy": lambda o: o["topic"]["Attributes"].update(Policy='{"Statement":[]}'),
            "sns-deny": lambda o: o["topic"]["Attributes"].update(Policy=json.dumps({"Statement": json.loads(o["topic"]["Attributes"]["Policy"])["Statement"] + [{"Effect":"Deny","Principal":"*","Action":"sns:Publish","Resource":"*"}]})),
            "kms-missing": lambda o: o["topic"]["Attributes"].update(KmsMasterKeyId="alias/billing"),
            "destination-pending": lambda o: o["destinations"][0].update(SubscriptionArn="PendingConfirmation"),
            "stale": lambda o: o.update(observedAt="2020-01-01T00:00:00Z"),
            "future": lambda o: o.update(observedAt="2099-01-01T00:00:00Z"),
            "denied": lambda o: o.update(costUsage={"Error": {"Code": "AccessDenied"}}),
            "other-account-collision": lambda o: o["costUsage"].update(ResultsByTime=[{"Groups":[{"Keys":["999999999999"],"Metrics":{"UnblendedCost":{"Amount":"0","Unit":"USD"}}}]}]),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                c, o = fixture()
                mutate(o)
                result, output = self.run_check(c, o)
                self.assertNotEqual(result.returncode, 0, name)
                self.assertIsNone(output, name)

    def test_scope_and_grade_cannot_be_overridden(self):
        for field, value in (("workloadRegion", "us-east-1"), ("workloadAccountId", "999999999999"),
                             ("billingApiRegion", "ap-northeast-2"), ("thresholdPercentages", [50, 80])):
            with self.subTest(field=field):
                c, o = fixture()
                c[field] = value
                result, _ = self.run_check(c, o)
                self.assertNotEqual(result.returncode, 0)
        c, o = fixture()
        o.update(evidenceGrade="CLOUD_RUNTIME", configured=True, deliveryVerified=True, unique=True)
        result, output = self.run_check(c, o)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["evidenceGrade"], "LOCAL_VERIFIED")
        self.assertEqual(output["deliveryStatus"], "NOT_VERIFIED")
        result, _ = self.run_check(extra=("--runtime-verified",))
        self.assertNotEqual(result.returncode, 0)

    def test_observed_cost_scope_does_not_claim_delivery(self):
        c, o = fixture()
        o["costUsage"]["ResultsByTime"] = [{"Groups":[{"Keys":[c["workloadAccountId"]],"Metrics":{"UnblendedCost":{"Amount":"1.25","Unit":"USD"}}}]}]
        result, output = self.run_check(c, o)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["dataStatus"], "DATA_OBSERVED")
        self.assertEqual(output["uniquenessStatus"], "NO_COLLISION_OBSERVED_IN_WINDOW")
        self.assertEqual(output["deliveryStatus"], "NOT_VERIFIED")

    def test_encrypted_topic_requires_both_publishers_on_actual_key(self):
        c, o = fixture()
        key = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
        o["topic"]["Attributes"]["KmsMasterKeyId"] = key
        o["kms"] = {"KeyMetadata": {"Arn": key, "KeyState": "Enabled", "KeyUsage": "ENCRYPT_DECRYPT", "KeyManager":"CUSTOMER"}}
        o["kmsPolicy"] = {"Policy": json.dumps({"Statement": [dict(Effect="Allow", Principal={"Service": s}, Action=["kms:GenerateDataKey*", "kms:Decrypt"], Resource="*") for s in ("budgets.amazonaws.com", "costalerts.amazonaws.com")]})}
        result, _ = self.run_check(c, o)
        self.assertEqual(result.returncode, 0, result.stderr)
        o["kmsPolicy"] = {"Policy": json.dumps({"Statement": [{"Effect":"Allow", "Principal":{"Service":"budgets.amazonaws.com"},"Action":["kms:GenerateDataKey*","kms:Decrypt"],"Resource":"*"}]})}
        result, _ = self.run_check(c, o)
        self.assertNotEqual(result.returncode, 0)


class Collector(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("finops", ROOT / "scripts/lib/finops-readiness.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.c, self.o = fixture()
        self.now = dt.datetime.now(dt.timezone.utc)

    def clients(self, *, collision=False, bad_group=False, denied=False, warming=False):
        c, o = self.c, self.o
        owner = self
        class Client:
            def __init__(self, service):
                self.service = service
            def __getattr__(self, operation):
                def call(**params):
                    service = self.service
                    if operation == "get_caller_identity":
                        return o["identity"]
                    if operation == "describe_organization":
                        return o["organization"]
                    if operation == "list_accounts":
                        return {"Accounts": o["accounts"]}
                    if service == "budgets":
                        if operation == "list_tags_for_resource":
                            owner.assertEqual(params, {"ResourceARN": c["budgetArn"]})
                            return {"ResourceTags": o["resourceTags"]["budget"]}
                        owner.assertEqual(params["AccountId"], c["billingAccountId"])
                        owner.assertEqual(params["BudgetName"], c["budgetName"])
                        if operation == "describe_budget":
                            return o["budget"]
                        if operation == "describe_notifications_for_budget":
                            return {"Notifications": [n["notification"] for n in o["notifications"]]}
                        if operation == "describe_subscribers_for_notification":
                            return {"Subscribers": next(n["subscribers"] for n in o["notifications"] if n["notification"] == params["Notification"])}
                    if service == "ce":
                        if operation == "list_tags_for_resource":
                            owner.assertEqual(set(params), {"ResourceArn"})
                            kind = "monitor" if params["ResourceArn"] == c["monitorArn"] else "subscription"
                            owner.assertEqual(params["ResourceArn"], c[kind + "Arn"])
                            return {"ResourceTags": o["resourceTags"][kind]}
                        if operation == "get_anomaly_monitors":
                            owner.assertEqual(params, {"MonitorArnList": [c["monitorArn"]]})
                            return {"AnomalyMonitors": o["monitors"]}
                        if operation == "get_anomaly_subscriptions":
                            owner.assertEqual(params, {"SubscriptionArnList": [c["subscriptionArn"]]})
                            return {"AnomalySubscriptions": o["subscriptions"]}
                        if operation == "list_cost_allocation_tags":
                            return {"CostAllocationTags": o["costTags"]}
                        if operation == "get_cost_and_usage":
                            if warming is True or (warming == "second" and params.get("NextPageToken")):
                                error = RuntimeError("billing data not yet available")
                                error.response = {"Error": {"Code": "DataUnavailableException"}}
                                raise error
                            if denied:
                                raise PermissionError("denied billing scope")
                            owner.assertEqual(params["Filter"], {"Tags": {"Key": "PlatformInstanceId", "Values": ["commerce-123"]}})
                            owner.assertEqual(params["GroupBy"], [{"Type": "DIMENSION", "Key": "LINKED_ACCOUNT"}])
                            data = copy.deepcopy(o["costUsage"])
                            if bad_group:
                                data["GroupDefinitions"] = []
                            if collision and not params.get("NextPageToken"):
                                data["NextPageToken"] = "second"
                            elif collision:
                                owner.assertEqual(params["NextPageToken"], "second")
                                data["ResultsByTime"] = [{"Groups":[{"Keys":["999999999999"],"Metrics":{"UnblendedCost":{"Amount":"1","Unit":"USD"}}}]}]
                            return data
                    if operation == "get_topic_attributes":
                        return o["topic"]
                    if operation == "list_subscriptions_by_topic":
                        return {"Subscriptions": o["destinations"]}
                    raise AssertionError(f"unexpected API: {service}.{operation}")
                return call
        return Client

    def test_api_request_shapes_and_configuration_evaluation(self):
        observed = self.module.collect_observations(self.c, self.clients(), self.now)
        self.assertEqual(self.module.evaluate(self.c, observed, self.now)["configurationStatus"], "CONFIGURED")
        self.assertNotIn("evidenceGrade", observed)

    def test_second_page_cost_collision_is_rejected(self):
        observed = self.module.collect_observations(self.c, self.clients(collision=True), self.now)
        with self.assertRaisesRegex(ValueError, "collision"):
            self.module.evaluate(self.c, observed, self.now)

    def test_denied_or_ambiguous_cost_response_is_not_pending(self):
        with self.assertRaises(PermissionError):
            self.module.collect_observations(self.c, self.clients(denied=True), self.now)
        with self.assertRaises(ValueError):
            self.module.collect_observations(self.c, self.clients(bad_group=True), self.now)

    def test_explicit_billing_data_warmup_keeps_configuration_gate_distinct(self):
        observed = self.module.collect_observations(self.c, self.clients(warming=True), self.now)
        result = self.module.evaluate(self.c, observed, self.now)
        self.assertEqual(result["configurationStatus"], "CONFIGURED")
        self.assertEqual(result["dataStatus"], "DATA_PENDING")
        self.assertEqual(result["deliveryStatus"], "NOT_VERIFIED")

    def test_later_page_warmup_cannot_erase_partial_scope_observation(self):
        with self.assertRaises(ValueError):
            self.module.collect_observations(self.c, self.clients(collision=True, warming="second"), self.now)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--export-fixture":
        c, o = fixture()
        Path(sys.argv[2]).write_text(json.dumps(c))
        Path(sys.argv[3]).write_text(json.dumps(o))
    else:
        unittest.main()
