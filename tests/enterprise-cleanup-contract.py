import importlib.util
import pathlib
import unittest
from copy import deepcopy

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cleanup", ROOT / "scripts/lib/enterprise-cleanup.py")
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class Cleanup(unittest.TestCase):
    def test_rds_requires_explicit_final_snapshot_retention(self):
        plan = {"resource_changes": [{"type": "aws_db_instance", "change": {
            "actions": ["delete"], "before": {"id": "prod-db", "deletion_protection": False,
                "skip_final_snapshot": False, "final_snapshot_identifier": "prod-db-final"}}}]}
        inventory = {"resources": [{"kind": "RdsSnapshot", "id": "arn:aws:rds:us-east-1:123456789012:snapshot:prod-db-final", "decision": "RETAIN"}]}
        cleanup.guard(plan, inventory)
        for key, value in [("deletion_protection", True), ("skip_final_snapshot", True), ("final_snapshot_identifier", "")]:
            candidate = deepcopy(plan)
            candidate["resource_changes"][0]["change"]["before"][key] = value
            with self.assertRaises(ValueError):
                cleanup.guard(candidate, inventory)
        with self.assertRaises(ValueError):
            cleanup.guard(plan, {"resources": []})

    def test_protected_objects_cannot_be_deleted(self):
        for kind in ["KmsKey", "S3BackupBucket", "Budget", "CostAnomalyMonitor", "CostAnomalySubscription", "CostAllocationTag", "IamOidcProvider"]:
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                cleanup.guard({"resource_changes": []}, {"resources": [{"kind": kind, "decision": "DELETE"}]})
        for resource_type in ["aws_kms_key", "aws_s3_bucket", "aws_budgets_budget", "aws_iam_openid_connect_provider"]:
            with self.subTest(resource_type=resource_type), self.assertRaises(ValueError):
                cleanup.guard({"resource_changes": [{"type": resource_type, "change": {"actions": ["delete"], "before": {"arn": "arn:protected", "id": "protected"}}}]},
                              {"resources": [{"kind": "NatGateway", "id": "arn:protected", "decision": "DELETE"}]})

    def test_dependency_order_and_retained_database_boundary(self):
        resources = [{"kind": "RdsInstance", "environment": e, "decision": "DELETE"} for e in ["prod", "recovery"]]
        result = cleanup.layers({"resources": resources})
        self.assertLess(result.index("environments/recovery/03-database"), result.index("environments/prod/03-database"))
        self.assertLess(result.index("environments/prod/03-database"), result.index("environments/prod/03-platform"))
        resources[0]["decision"] = "RETAIN"
        with self.assertRaises(ValueError):
            cleanup.layers({"resources": resources})

    def test_unknown_tagged_resource_is_not_zero(self):
        with self.assertRaises(ValueError):
            cleanup.discover({"courseId": "fixture", "resources": []}, lambda *a: {"ResourceTagMappingList": [{"ResourceARN": "arn:aws:rds:us-east-1:123456789012:db:forgotten"}]})
        cleanup.discover({"courseId": "fixture", "resources": [{"id": "arn:db"}]}, lambda *a: {"ResourceTagMappingList": [{"ResourceARN": "arn:db"}]})
        with self.assertRaises(ValueError):
            cleanup.discover({"courseId": "fixture", "resources": []}, lambda *a: {})

    def test_actual_api_response_shapes(self):
        cases = [
            ("RdsInstance", "arn:aws:rds:us-east-1:123456789012:db:prod-db", {"DBInstances": [{"DBInstanceArn": "arn:aws:rds:us-east-1:123456789012:db:prod-db"}]}, ("rds", "describe-db-instances")),
            ("RdsSnapshot", "arn:aws:rds:us-east-1:123456789012:snapshot:final", {"DBSnapshots": [{"DBSnapshotArn": "arn:aws:rds:us-east-1:123456789012:snapshot:final"}]}, ("rds", "describe-db-snapshots")),
            ("KmsKey", "arn:key", {"KeyMetadata": {"Arn": "arn:key", "KeyState": "PendingDeletion"}}, ("kms", "describe-key")),
            ("LogGroup", "arn:aws:logs:us-east-1:123456789012:log-group:/aws/eks/x", {"logGroups": [{"logGroupName": "/aws/eks/x"}]}, ("logs", "describe-log-groups")),
        ]
        for kind, ident, response, operation in cases:
            calls = []
            def query(*args):
                calls.append(args)
                return response
            self.assertTrue(cleanup.present(kind, ident, query), kind)
            self.assertEqual(calls[0][:2], operation)
        with self.assertRaises((ValueError, KeyError)):
            cleanup.present("KmsKey", "arn:key", lambda *a: {})


if __name__ == "__main__":
    unittest.main()
