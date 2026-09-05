import importlib.util
import json
import pathlib
import unittest
from copy import deepcopy
from datetime import datetime, timezone, timedelta

spec = importlib.util.spec_from_file_location("cleanup", pathlib.Path(__file__).resolve().parents[1] / "scripts/lib/enterprise-cleanup.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
KEY = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
FLOW = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc/flow"
APP = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/container/app"


def fixture():
    inventory = {"resources": [
        {"kind": "KmsLogKey", "id": KEY, "decision": "DELETE", "purpose": "cloudwatch-log-protection",
         "logGroupArns": [FLOW, APP], "deletionWindowInDays": 30,
         "retentionReleaseApproval": {"approvedBy": "operator", "approvedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "retentionReleased": True, "restoreRequired": False}},
        *[{"kind": "LogGroup", "id": arn, "kmsKeyArn": KEY, "decision": "DELETE"} for arn in [FLOW, APP]]]}
    key = {"address": "module.log_key.aws_kms_key.this", "type": "aws_kms_key", "change": {"actions": ["delete"], "before": {
        "arn": KEY, "deletion_window_in_days": 30, "policy": json.dumps({"Statement": [
            {"Sid": "RegionalLogsExactContext", "Principal": {"Service": "logs.us-east-1.amazonaws.com"},
             "Condition": {"ArnEquals": {"kms:EncryptionContext:aws:logs:arn": [FLOW, APP]}}}]})}}}
    groups = [{"address": addr, "type": "aws_cloudwatch_log_group", "change": {"actions": ["delete"],
               "before": {"arn": arn, "kms_key_id": KEY}}} for arn, addr in [
                   (FLOW, "module.vpc.aws_cloudwatch_log_group.vpc_flow[0]"), (APP, "module.container_insights.aws_cloudwatch_log_group.application")]]
    calls = {
        "vpc": {"expressions": {"vpc_flow_log_kms_key_arn": {"references": ["module.log_key.kms_key_arn"]}},
                "module": {"resources": [{"type": "aws_cloudwatch_log_group", "name": "vpc_flow", "expressions": {"kms_key_id": {"references": ["var.vpc_flow_log_kms_key_arn"]}}}]}},
        "log_key": {"module": {"outputs": {"kms_key_arn": {"expression": {"references": ["aws_kms_key.this.arn"]}}}}}}
    configuration = {"root_module": {"module_calls": calls}}
    plan = {"resource_changes": [key, groups[0]], "configuration": configuration}
    return plan, {"resource_changes": [key, *groups]}, inventory


class LogKey(unittest.TestCase):
    def test_scheduled_key_is_not_physical_absence_or_crypto_availability(self):
        _,_,i=fixture()
        deletion=(datetime.now(timezone.utc)+timedelta(days=30)).isoformat()
        def query(*args):
            return {"logGroups":[]} if args[0] == "logs" else {"KeyMetadata":{"Arn":KEY,"KeyState":"PendingDeletion","DeletionDate":deletion}}
        result=c.scheduled_log_key(KEY,i,query)
        self.assertEqual(result["keyState"],"PendingDeletion")
        for state in ("Enabled","Disabled","PendingReplicaDeletion"):
            with self.assertRaises(ValueError):
                c.scheduled_log_key(KEY,i,lambda *args: {"logGroups":[]} if args[0]=="logs" else {"KeyMetadata":{"Arn":KEY,"KeyState":state,"DeletionDate":deletion}})

    def test_exact_key_context_and_dependency_allow_only_local_flow_group(self):
        plan, aggregate, inventory = fixture()
        c.guard(plan, inventory, aggregate)
        c.log_key_ready(plan, inventory, aggregate, lambda *a: {"logGroups": []})
        calls = []
        c.log_key_ready(plan, inventory, aggregate, lambda *a: calls.append(a) or {"logGroups": []})
        self.assertEqual(len(calls), 1)
        self.assertIn("/aws/container/app", calls[0])

    def test_retained_unclassified_or_unapproved_key_is_rejected(self):
        for mutation in [
            lambda p,a,i: i["resources"][1].update(decision="RETAIN"),
            lambda p,a,i: i["resources"][0]["retentionReleaseApproval"].update(restoreRequired=True),
            lambda p,a,i: i["resources"][0]["retentionReleaseApproval"].update(approvedAt="2000-01-01T00:00:00Z"),
            lambda p,a,i: i["resources"][0].update(purpose="database"),
            lambda p,a,i: i["resources"][0].update(logGroupArns=[FLOW]),
            lambda p,a,i: i["resources"][1].update(kmsKeyArn="wrong"),
            lambda p,a,i: p["resource_changes"][0].update(address="module.backup.aws_kms_key.backup"),
            lambda p,a,i: p["resource_changes"][0]["change"]["before"].update(deletion_window_in_days=7),
            lambda p,a,i: a["resource_changes"][2]["change"].update(actions=["no-op"]),
        ]:
            p,a,i=fixture(); mutation(p,a,i)
            with self.assertRaises((ValueError, KeyError)):
                c.guard(p,i,a)

    def test_same_root_without_real_reference_or_foreign_logs_still_present_blocks(self):
        p,a,i=fixture()
        p["configuration"]["root_module"]["module_calls"]["vpc"]["expressions"]["vpc_flow_log_kms_key_arn"]["references"]=[]
        with self.assertRaises(ValueError): c.log_key_ready(p,i,a,lambda *args: {"logGroups":[]})
        p,a,i=fixture()
        with self.assertRaises(ValueError):
            c.log_key_ready(p,i,a,lambda *args: {"logGroups":[{"logGroupName":"/aws/container/app"}]})


if __name__ == "__main__": unittest.main()
