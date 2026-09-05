#!/usr/bin/env python3
"""Read-only enterprise residual observations and fail-closed deletion guards."""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

BILLING = {"Budget", "CostAnomalyMonitor", "CostAnomalySubscription", "CostAllocationTag"}
PROTECTED = BILLING | {"KmsKey", "S3BackupBucket", "S3StateBucket", "TerraformState", "CourseEvidence", "IamOidcProvider", "RdsAutomatedBackup", "BillingSnsTopic"}
KINDS = PROTECTED | {"RdsInstance", "RdsSnapshot", "RdsSubnetGroup", "RdsParameterGroup", "LogGroup", "WafWebAcl", "SecretsManagerSecret"}


def guard(plan, inventory, aggregate=None):
    aggregate = aggregate or plan
    for resource in inventory["resources"]:
        if resource["kind"] in PROTECTED and resource["decision"] == "DELETE":
            raise ValueError("PROTECTED_ENTERPRISE_DELETE_BLOCKED")
    for resource in plan["resource_changes"]:
        if "delete" not in resource["change"]["actions"]:
            continue
        before = resource["change"].get("before") or {}
        if resource["type"] == "aws_kms_key":
            log_key_approval(resource, inventory, aggregate)
        if resource["type"] in {"aws_s3_bucket", "aws_budgets_budget", "aws_ce_anomaly_monitor", "aws_ce_anomaly_subscription", "aws_ce_cost_allocation_tag"}:
            raise ValueError("PROTECTED_ENTERPRISE_RESOURCE_TYPE_DELETE_BLOCKED")
        if resource["type"] == "aws_iam_openid_connect_provider" and (
                not before.get("url") or before["url"].removeprefix("https://") == "token.actions.githubusercontent.com"):
            raise ValueError("EXTERNAL_RESOURCE_DELETE_BLOCKED: account OIDC")
        if resource["type"] == "aws_db_instance":
            if before.get("deletion_protection") is not False:
                raise ValueError("RDS_DELETION_PROTECTION_APPROVAL_REQUIRED")
            snapshot = before.get("final_snapshot_identifier")
            if before.get("skip_final_snapshot") is not False or not isinstance(snapshot, str) or not snapshot.strip():
                raise ValueError("RDS_FINAL_SNAPSHOT_REQUIRED")
            if not any(r["kind"] == "RdsSnapshot" and r["decision"] == "RETAIN" and
                       r["id"].rsplit(":snapshot:", 1)[-1] == snapshot for r in inventory["resources"]):
                raise ValueError("RDS_FINAL_SNAPSHOT_RETENTION_APPROVAL_REQUIRED")


def log_key_approval(change, inventory, aggregate):
    before = change["change"]["before"]
    key = before["arn"]
    if not re.fullmatch(r"arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]{36}", key) or change["change"]["actions"] != ["delete"] or change.get("address") != "module.log_key.aws_kms_key.this" or before.get("deletion_window_in_days") != 30:
        raise ValueError("ONLY_EXACT_30_DAY_LOG_KEY_CAN_BE_SCHEDULED")
    matches = [r for r in inventory["resources"] if r.get("id") == key]
    if len(matches) != 1:
        raise ValueError("LOG_KEY_INVENTORY_REQUIRED")
    entry = matches[0]
    if entry["kind"] != "KmsLogKey" or entry["decision"] != "DELETE" or entry.get("purpose") != "cloudwatch-log-protection" or entry.get("deletionWindowInDays") != 30:
        raise ValueError("LOG_KEY_PURPOSE_APPROVAL_REQUIRED")
    approval = entry["retentionReleaseApproval"]
    approved_at = datetime.strptime(approval["approvedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    age = (datetime.now(timezone.utc) - approved_at).total_seconds()
    if not isinstance(approval.get("approvedBy"), str) or not approval["approvedBy"].strip() or not 0 <= age <= 86400 or approval.get("retentionReleased") is not True or approval.get("restoreRequired") is not False:
        raise ValueError("LOG_RETENTION_RELEASE_AND_NO_RESTORE_APPROVAL_REQUIRED")
    context = set()
    policy = json.loads(before["policy"])
    regional = False
    for statement in policy["Statement"]:
        if statement.get("Sid") not in {"ExplicitAdministrators", "RegionalLogsExactContext", "LogCallersViaRegionalLogs"}:
            raise ValueError("UNCLASSIFIED_LOG_KEY_POLICY_STATEMENT")
        actions = statement.get("Action", [])
        if isinstance(actions, str):
            actions = [actions]
        constraints = statement.get("Condition", {}).get("ArnEquals", {}).get("kms:EncryptionContext:aws:logs:arn")
        if constraints is not None:
            if not isinstance(constraints, list) or not constraints:
                raise ValueError("EXACT_LOG_CONTEXT_LIST_REQUIRED")
            context.update(constraints)
        if statement.get("Sid") == "RegionalLogsExactContext":
            regional = statement.get("Principal", {}).get("Service") == "logs." + key.split(":")[3] + ".amazonaws.com"
        if any(a in ("kms:Decrypt", "kms:*", "*") for a in actions) and constraints is None:
            raise ValueError("UNCLASSIFIED_KEY_DECRYPT_PRINCIPAL")
    declared = entry.get("logGroupArns")
    if not regional or not isinstance(declared, list) or not context or len(declared) != len(set(declared)) or set(declared) != context:
        raise ValueError("LOG_KEY_POLICY_CONTEXT_MISMATCH")
    bound = [r for r in inventory["resources"] if r.get("kmsKeyArn") == key]
    if len(bound) != len(context) or {r["id"].removesuffix(":*") for r in bound} != context or any(r["kind"] != "LogGroup" or r["decision"] != "DELETE" for r in bound):
        raise ValueError("ALL_BOUND_LOGS_MUST_HAVE_EXPLICIT_DELETE_APPROVAL")
    changes = {}
    for item in aggregate["resource_changes"]:
        prior = item.get("change", {}).get("before") or {}
        if item.get("type") == "aws_cloudwatch_log_group" and prior.get("kms_key_id") == key:
            arn = prior["arn"].removesuffix(":*")
            if arn in changes or item["change"]["actions"] != ["delete"]:
                raise ValueError("AMBIGUOUS_OR_RETAINED_BOUND_LOG")
            changes[arn] = item
    if not set(changes).issubset(context):
        raise ValueError("AGGREGATE_PLAN_LOG_BINDINGS_INCOMPLETE")
    return entry, changes


def log_key_ready(plan, inventory, aggregate, query=None):
    query = query or aws
    for change in plan["resource_changes"]:
        if change["type"] != "aws_kms_key" or "delete" not in change["change"]["actions"]:
            continue
        entry, groups = log_key_approval(change, inventory, aggregate)
        local_resources = {r["address"]: r for r in plan["resource_changes"] if "delete" in r["change"]["actions"]}
        for arn in entry["logGroupArns"]:
            group = groups.get(arn)
            if group and group["address"] in local_resources:
                if group["address"] != "module.vpc.aws_cloudwatch_log_group.vpc_flow[0]":
                    raise ValueError("ONLY_BOUNDED_FLOW_LOG_DAG_EXCEPTION_ALLOWED")
                actual = local_resources[group["address"]]
                if actual["change"]["actions"] != ["delete"] or actual["change"]["before"]["kms_key_id"] != entry["id"] or actual["change"]["before"]["arn"].removesuffix(":*") != arn:
                    raise ValueError("LOCAL_FLOW_LOG_KEY_BINDING_MISMATCH")
                calls = plan["configuration"]["root_module"]["module_calls"]
                source = calls["vpc"]["expressions"]["vpc_flow_log_kms_key_arn"]["references"]
                resources = [r for r in calls["vpc"]["module"]["resources"] if r["type"] == "aws_cloudwatch_log_group" and r["name"] == "vpc_flow"]
                target = calls["log_key"]["module"]["outputs"]["kms_key_arn"]["expression"]["references"]
                if "module.log_key.kms_key_arn" not in source or len(resources) != 1 or "var.vpc_flow_log_kms_key_arn" not in resources[0]["expressions"]["kms_key_id"]["references"] or "aws_kms_key.this.arn" not in target:
                    raise ValueError("SAVED_PLAN_FLOW_LOG_KEY_DEPENDENCY_MISSING")
            elif present("LogGroup", arn, query):
                raise ValueError("BOUND_LOG_STILL_PRESENT_BEFORE_KEY_DELETION")


def scheduled_log_key(ident, inventory, query=None):
    query = query or aws
    entry = next(r for r in inventory["resources"] if r["kind"] == "KmsLogKey" and r["id"] == ident and r["decision"] == "DELETE")
    for arn in entry["logGroupArns"]:
        if present("LogGroup", arn, query):
            raise ValueError("BOUND_LOG_REMAINS_AFTER_KEY_SCHEDULING")
    response = query("kms", "describe-key", "--key-id", ident)
    metadata = response["KeyMetadata"]
    if metadata["Arn"] != ident or metadata["KeyState"] != "PendingDeletion" or not metadata.get("DeletionDate"):
        raise ValueError("EXPECTED_PENDING_DELETION_LOG_KEY_HANDLE")
    deletion = datetime.fromisoformat(metadata["DeletionDate"].replace("Z", "+00:00"))
    if deletion.tzinfo is None or not 0 < (deletion - datetime.now(timezone.utc)).total_seconds() <= 31 * 86400:
        raise ValueError("LOG_KEY_DELETION_DATE_OUTSIDE_APPROVED_WINDOW")
    return {"keyArn": ident, "keyState": "PendingDeletion", "deletionDate": deletion.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}


def layers(inventory):
    databases = [r for r in inventory["resources"] if r["kind"] == "RdsInstance"]
    if any(r["decision"] != "DELETE" for r in databases):
        raise ValueError("RETAINED_DATABASE_BLOCKS_NETWORK_TEARDOWN")
    result = ["environments/prod/04-workloads/argocd", "environments/dev/04-workloads/argocd"]
    if any(r["environment"] == "recovery" for r in databases):
        result.append("environments/recovery/03-database")
    if any(r["environment"] == "prod" for r in databases):
        result.append("environments/prod/03-database")
    result += ["environments/" + env + "/" + layer for layer in ["03-platform", "02-eks", "01-network"] for env in ["prod", "dev"]]
    return result


def aws(*args):
    profile = os.environ["AWS_PROFILE"]
    region = os.environ["AWS_REGION"]
    if os.environ.get("ENTERPRISE_EXTERNAL_BACKUP") == "true":
        profile = os.environ["BACKUP_PROFILE"]
        region = os.environ["BACKUP_REGION"]
        identity = subprocess.run(["aws", "sts", "get-caller-identity", "--profile", profile,
                                  "--region", region, "--output", "json", "--no-cli-pager"],
                                 capture_output=True, text=True, check=True)
        if json.loads(identity.stdout)["Account"] != os.environ["BACKUP_ACCOUNT_ID"]:
            raise ValueError("BACKUP_ACCOUNT_IDENTITY_MISMATCH")
    if args[0] in ("budgets", "ce") or args[:2] == ("sns", "get-topic-attributes") and os.environ.get("ENTERPRISE_EXTERNAL_BILLING") == "true":
        profile = os.environ["FINOPS_BILLING_PROFILE"]
        region = "us-east-1"
        expected = os.environ["FINOPS_BILLING_ACCOUNT_ID"]
        identity = subprocess.run(["aws", "sts", "get-caller-identity", "--profile", profile,
                                   "--region", region, "--output", "json", "--no-cli-pager"],
                                  capture_output=True, text=True, check=True)
        if json.loads(identity.stdout)["Account"] != expected:
            raise ValueError("BILLING_ACCOUNT_IDENTITY_MISMATCH")
    result = subprocess.run(["aws", *args, "--profile", profile, "--region", region,
                             "--output", "json", "--no-cli-pager"], capture_output=True, text=True)
    if result.returncode:
        match = re.search(r"An error occurred \(([^)]+)\)", result.stderr)
        absent = {"DBInstanceNotFound", "DBInstanceNotFoundFault", "DBSnapshotNotFound", "DBSnapshotNotFoundFault",
                  "DBSubnetGroupNotFoundFault", "DBParameterGroupNotFound", "ResourceNotFoundException",
                  "NotFoundException", "NoSuchEntity", "NoSuchBucket", "WAFNonexistentItemException"}
        if match and match.group(1) in absent:
            return None
        raise ValueError("ENTERPRISE_RESIDUAL_API_FAILED")
    response = json.loads(result.stdout)
    if not isinstance(response, dict):
        raise ValueError("ENTERPRISE_RESIDUAL_RESPONSE_INVALID")
    return response


def rows(response, key):
    if response is None:
        return []
    if not isinstance(response.get(key), list):
        raise ValueError("ENTERPRISE_RESIDUAL_RESPONSE_INVALID")
    return response[key]


def discover(inventory, query=aws):
    response = query("resourcegroupstaggingapi", "get-resources", "--tag-filters",
                     "Key=CourseId,Values=" + inventory["courseId"], "--resource-type-filters",
                     "rds:db", "rds:snapshot", "rds:subgrp", "rds:pg", "kms:key", "logs:log-group",
                     "wafv2:webacl", "s3:bucket", "ecr:repository")
    if response is None:
        raise ValueError("ENTERPRISE_DISCOVERY_FAILED")
    known = {r["id"].removesuffix(":*") if hasattr(str, "removesuffix") else r["id"].rstrip(":*") for r in inventory["resources"]}
    for item in rows(response, "ResourceTagMappingList"):
        arn = item["ResourceARN"]
        if arn not in known and arn.rstrip(":*") not in known:
            raise ValueError("UNCLASSIFIED_ENTERPRISE_RESIDUAL: " + arn)


def present(kind, ident, query=aws):
    if kind == "S3BackupBucket" and os.environ.get("BACKUP_PROFILE") or kind == "KmsKey" and ident.startswith("arn:aws:kms:") and ident.split(":")[4] != os.environ.get("AWS_ACCOUNT_ID", ident.split(":")[4]):
        if kind == "KmsKey" and ident.split(":")[4] != os.environ["BACKUP_ACCOUNT_ID"]:
            raise ValueError("BACKUP_KEY_ACCOUNT_MISMATCH")
        os.environ["ENTERPRISE_EXTERNAL_BACKUP"] = "true"
    if kind == "RdsInstance":
        return any(r["DBInstanceArn"] == ident or r.get("DBInstanceIdentifier") == ident
                   for r in rows(query("rds", "describe-db-instances", "--db-instance-identifier", ident), "DBInstances"))
    if kind == "RdsSnapshot":
        return any(r["DBSnapshotArn"] == ident or r.get("DBSnapshotIdentifier") == ident
                   for r in rows(query("rds", "describe-db-snapshots", "--db-snapshot-identifier", ident), "DBSnapshots"))
    if kind == "RdsAutomatedBackup":
        return any(r["DBInstanceAutomatedBackupsArn"] == ident for r in
                   rows(query("rds", "describe-db-instance-automated-backups"), "DBInstanceAutomatedBackups"))
    if kind in ("RdsSubnetGroup", "RdsParameterGroup"):
        subnet = kind == "RdsSubnetGroup"
        key, operation, flag, arn = ("DBSubnetGroups", "describe-db-subnet-groups", "--db-subnet-group-name", "DBSubnetGroupArn") if subnet else ("DBParameterGroups", "describe-db-parameter-groups", "--db-parameter-group-name", "DBParameterGroupArn")
        return any(r[arn] == ident for r in rows(query("rds", operation, flag, ident.rsplit(":", 1)[-1]), key))
    if kind == "KmsKey":
        response = query("kms", "describe-key", "--key-id", ident)
        return response is not None and response["KeyMetadata"]["Arn"] == ident
    if kind == "LogGroup":
        name = ident.split(":log-group:", 1)[-1].removesuffix(":*")
        return any(r["logGroupName"] == name for r in rows(query("logs", "describe-log-groups", "--log-group-name-prefix", name), "logGroups"))
    if kind == "WafWebAcl":
        scope, _, name, uuid = ident.split(":", 5)[-1].split("/")
        if scope != "regional":
            raise ValueError("WAF_REGIONAL_SCOPE_REQUIRED")
        response = query("wafv2", "get-web-acl", "--scope", "REGIONAL", "--name", name, "--id", uuid)
        return response is not None and response["WebACL"]["ARN"] == ident
    if kind == "S3BackupBucket":
        name = ident.removeprefix("arn:aws:s3:::")
        owner = os.environ["BACKUP_ACCOUNT_ID"] if os.environ.get("ENTERPRISE_EXTERNAL_BACKUP") == "true" else os.environ["AWS_ACCOUNT_ID"]
        response = query("s3api", "get-bucket-versioning", "--bucket", name, "--expected-bucket-owner", owner)
        if response is None:
            return False
        if response.get("Status") != "Enabled":
            raise ValueError("PROTECTED_BACKUP_VERSIONING_CHANGED")
        lock = query("s3api", "get-object-lock-configuration", "--bucket", name, "--expected-bucket-owner", owner)
        retention = lock["ObjectLockConfiguration"]["Rule"]["DefaultRetention"]
        if retention.get("Mode") != "GOVERNANCE" or retention.get("Days", 0) < 120:
            raise ValueError("PROTECTED_BACKUP_RETENTION_CHANGED")
        return True
    if kind == "S3StateBucket":
        response = query("s3api", "get-bucket-versioning", "--bucket", ident.removeprefix("arn:aws:s3:::"), "--expected-bucket-owner", os.environ["AWS_ACCOUNT_ID"])
        return response is not None and response.get("Status") == "Enabled"
    if kind == "TerraformState":
        bucket, key = ident.removeprefix("arn:aws:s3:::").split("/", 1)
        response = query("s3api", "head-object", "--bucket", bucket, "--key", key, "--expected-bucket-owner", os.environ["AWS_ACCOUNT_ID"])
        return response is not None and response["ContentLength"] > 0
    if kind == "CourseEvidence":
        return os.path.isfile(ident) and not os.path.islink(ident)
    if kind == "IamOidcProvider":
        response = query("iam", "get-open-id-connect-provider", "--open-id-connect-provider-arn", ident)
        return response is not None and response["Url"] == "token.actions.githubusercontent.com" and "sts.amazonaws.com" in response["ClientIDList"]
    if kind == "SecretsManagerSecret":
        response = query("secretsmanager", "describe-secret", "--secret-id", ident)
        return response is not None and response["ARN"] == ident
    if kind in BILLING:
        account = os.environ["FINOPS_BILLING_ACCOUNT_ID"]
        if kind != "CostAllocationTag" and ident.split(":")[4] != account:
            raise ValueError("BILLING_RESOURCE_ACCOUNT_MISMATCH")
        if kind == "Budget":
            response = query("budgets", "describe-budget", "--account-id", account, "--budget-name", ident.split(":budget/", 1)[-1])
            return response is not None and response["Budget"]["BudgetName"] == ident.split(":budget/", 1)[-1]
        if kind == "CostAnomalyMonitor":
            return any(r["MonitorArn"] == ident for r in rows(query("ce", "get-anomaly-monitors", "--monitor-arn-list", ident), "AnomalyMonitors"))
        if kind == "CostAnomalySubscription":
            return any(r["SubscriptionArn"] == ident for r in rows(query("ce", "get-anomaly-subscriptions", "--subscription-arn-list", ident), "AnomalySubscriptions"))
        return any(r["TagKey"] == ident and r["Status"] == "Active" for r in rows(query("ce", "list-cost-allocation-tags", "--tag-keys", ident), "CostAllocationTags"))
    if kind == "BillingSnsTopic":
        if ident.split(":")[4] != os.environ["FINOPS_BILLING_ACCOUNT_ID"]:
            raise ValueError("BILLING_RESOURCE_ACCOUNT_MISMATCH")
        os.environ["ENTERPRISE_EXTERNAL_BILLING"] = "true"
        response = query("sns", "get-topic-attributes", "--topic-arn", ident)
        return response is not None and response["Attributes"]["TopicArn"] == ident
    raise ValueError("UNSUPPORTED_ENTERPRISE_KIND")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "guard":
            aggregate = json.load(open(os.environ["ENTERPRISE_CLEANUP_AGGREGATE_PLAN"])) if os.environ.get("ENTERPRISE_CLEANUP_AGGREGATE_PLAN") else None
            guard(json.load(open(sys.argv[2])), json.load(open(sys.argv[3])), aggregate)
        elif sys.argv[1] == "log-key-ready":
            log_key_ready(json.load(open(sys.argv[2])), json.load(open(sys.argv[3])), json.load(open(os.environ["ENTERPRISE_CLEANUP_AGGREGATE_PLAN"])))
        elif sys.argv[1] == "scheduled-log-key":
            print(json.dumps(scheduled_log_key(sys.argv[2], json.load(open(sys.argv[3])))))
        elif sys.argv[1] == "discover":
            discover(json.load(open(sys.argv[2])))
        elif sys.argv[1] == "layers":
            print("\n".join(layers(json.load(open(sys.argv[2])))))
        elif sys.argv[1] == "present":
            sys.exit(0 if present(sys.argv[2], sys.argv[3]) else 1)
        else:
            raise ValueError("ENTERPRISE_CLEANUP_USAGE")
    except (ValueError, KeyError, IndexError, TypeError, StopIteration, OSError, subprocess.SubprocessError) as error:
        print(str(error) if isinstance(error, ValueError) else "ENTERPRISE_RESIDUAL_RESPONSE_OR_PREREQUISITE_INVALID", file=sys.stderr)
        sys.exit(3)
