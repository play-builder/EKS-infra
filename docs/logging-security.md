# Logging security and deployment contract

This Terraform chain owns five independent log planes under one environment-specific rotating KMS key. Production retains every plane for at least 90 supported CloudWatch days. Local tests validate rendered configuration; they do not prove IAM authorization, log arrival, WAF blocking or cluster compatibility.

## Ownership and order

`01-network` creates the key and protects the existing VPC Flow Log group. Its `logging_contract` contains account, Region, planned cluster name, WAF name, five exact group names, key ARN and platform tags. Future caller role ARNs are precomputed strings; downstream resource references never feed the key.

`02-eks` consumes that contract and attaches the key to the existing `module.eks_cluster.aws_cloudwatch_log_group.cluster`. It rejects a cluster name, Region or provider account mismatch and exports the control-plane and Flow Log `audit_log_groups`.

`03-platform` requires matching network/EKS contracts, creates WAF and the application/performance groups, and installs distinct CloudWatch-agent/Fluent-Bit IRSA roles. Outputs `web_acl_arn`, `waf_log_group_arn`, `audit_log_groups` and `audit_log_protection` supply the integration handoff. GitOps owns ALB WAF association.

The output `audit_log_groups` shape is `map(object({ arn=string, retention_days=number, kms_key_arn=string }))`. Keys are `control_plane`, `vpc_flow`, `application`, `performance`, `waf`; Dev may omit application/performance if its optional collector is disabled. Production requires enabled Flow Logs and collectors.

## Operator inputs

Supply actual environment values through ignored tfvars:

- Network: `platform_instance_id`, `owner`, `cost_center`, and `log_key_administrator_role_arns` containing **existing same-account roles**, including the Terraform executor. The executor also needs alias ARN management permissions. Optional `cluster_name` must match 02-eks; null derives `<environment>-<project>-eks`.
- Optional `log_reader_role_arns` must name approved same-account reader roles with matching identity policies. The module does not create readers or grant log payload access.
- Flow retention: `vpc_flow_log_retention_in_days`; control plane: `cluster_log_retention_in_days`; platform: `application_log_retention_in_days`, `performance_log_retention_in_days`, `waf_log_retention_in_days`. These remain independent. Prod defaults are 90 days; unsupported or shorter values fail.
- WAF `waf_rate_limit` defaults to 2000 requests/IP/300 seconds. Managed rules and rate thresholds need controlled traffic verification.
- The old prod `vpc_flow_log_kms_key_arn` input must stay null; this root now owns the selected key. Preserve any old key until historical logs no longer require it.

Network ownership tags propagate downstream. All newly owned taggable logging resources enforce `ManagedBy=Terraform`; conflicting caller tags cannot transfer ownership. KMS aliases, IAM attachments and WAF logging/resource-policy objects have no tag field in AWS provider 5.87 and remain identified through Terraform ownership.

## Existing state and import

Back up the correct environment state through the operator's approved workflow and inspect a saved plan before deployment. No state operation has been executed by this implementation.

The three IAM moved blocks inside `module.container_insights[0]` map:

| Old suffix | New suffix |
| --- | --- |
| `module.irsa_role.aws_iam_role.this` | `aws_iam_role.cloudwatch_agent` |
| `module.irsa_role.aws_iam_policy.this[0]` | `aws_iam_policy.cloudwatch_agent` |
| `module.irsa_role.aws_iam_role_policy_attachment.this[0]` | `aws_iam_role_policy_attachment.cloudwatch_agent` |

Existing AWS names remain `<cluster>-container-insights-role` and `<cluster>-container-insights-policy`; existing Helm/namespace addresses remain. Fluent Bit gets a new `<cluster>-fluent-bit-role`. A plan showing replacement of the old IAM role/policy requires investigation.

If the old agents already created application or performance groups, import those exact groups into the initialized 03-platform state **before** applying the ownership plan:

```bash
terraform import 'module.container_insights[0].aws_cloudwatch_log_group.this["application"]' "/aws/containerinsights/<cluster>/application"
terraform import 'module.container_insights[0].aws_cloudwatch_log_group.this["performance"]' "/aws/containerinsights/<cluster>/performance"
```

If an existing Flow or control-plane group is already managed at its original address, preserve that state. If it exists in AWS but is absent from the correct state, investigate ownership, then import only the confirmed exact group:

```bash
# In 01-network, only when the existing group is not yet tracked:
terraform import 'module.vpc.aws_cloudwatch_log_group.vpc_flow[0]' "/aws/vpc/<environment>-<project>/flow-logs"
```

```bash
# In 02-eks, only when the existing group is not yet tracked:
terraform import 'module.eks_cluster.aws_cloudwatch_log_group.cluster' "/aws/eks/<cluster>/cluster"
```

Do not delete a group to resolve ResourceAlreadyExists. Newly associating a key encrypts subsequent log data; keep any previous key accessible for historical data. Retention changes can expire older logs. Reverting a Terraform commit does not recover already-expired logs.

Apply the approved network saved plan, then refresh/plan EKS against its new output, then platform. Use the repository saved-plan identity workflow; never bypass it with a fresh unreviewed apply. Each downstream contract verifies identity; a stale EKS handoff must be refreshed before platform.

## Checks and operational limits

```bash
bash tests/log-plane-integration-contract.sh
```

This executes mock-only Terraform tests and provider schema validation, including all six roots. It requires installed Terraform/provider dependencies; initialization may download providers. It never invokes AWS deployment, state migration or log-reading commands.

Before operational acceptance, operators must confirm exact key policy access, IRSA STS exchange, arrival in all five groups, retention/KMS association, and WAF ALB association with approved test traffic. Check `AccessDenied`, group-name mismatch, missing imported groups, log delivery permissions and throttling when telemetry is absent. Sampling is disabled and WAF credential headers/query strings are redacted; application payload sanitation remains the application's responsibility. Never print credential-bearing logs as evidence.

Pinned CloudWatch agent/Fluent Bit charts remain 0.0.9/0.1.32. Their templates were checked, but their existing images were not run on EKS 1.36. KMS/CloudWatch/WAF incur costs; exact current costs depend on retention, request/log volume and regional pricing.

References: [CloudWatch KMS](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html), [Logs delivery policy](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AWS-logs-infrastructure-CWL.html), [WAF logging](https://docs.aws.amazon.com/waf/latest/developerguide/logging-cw-logs.html).
