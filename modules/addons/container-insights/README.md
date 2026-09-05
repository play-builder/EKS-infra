# Container Insights protected log planes

CloudWatch agent and Fluent Bit use distinct IRSA roles with exact ServiceAccount subjects and STS audience. Terraform precreates encrypted `application` and `performance` groups with independently configured finite retention; prod requires at least 90 days for both. New required inputs are `environment`, `account_id`, and `kms_key_arn`.

## Integration and permission boundary

Include both group names and both precomputed role ARNs in the upstream log-key contract:

- `/aws/containerinsights/<cluster>/application` → `<cluster>-fluent-bit-role`.
- `/aws/containerinsights/<cluster>/performance` → `<cluster>-container-insights-role`.

Fluent Bit receives log-stream permissions for application only. CloudWatch agent receives performance stream access, ContainerInsights-only metric publishing, and the existing EC2 metadata reads. Neither role can create log groups. KMS caller policies restrict the exact key, regional Logs ViaService and each role's own group context. The key policy must also permit those callers.

Chart `aws-cloudwatch-metrics 0.0.9` was inspected: it configures the Kubernetes metrics collector through `logs.metrics_collected.kubernetes.cluster_name`, producing performance log events. Chart `aws-for-fluent-bit 0.1.32` uses the configured application group. Its template omits `auto_create_group` when `autoCreateGroup=false`; the CloudWatch output plugin's default is false. Arbitrary application payload sanitation remains the application producer's responsibility; this module never reads or prints log contents.

## Existing-state migration

The module contains these exact static moves; existing AWS role and policy names stay unchanged:

| Previous address within module | New address within module |
| --- | --- |
| `module.irsa_role.aws_iam_role.this` | `aws_iam_role.cloudwatch_agent` |
| `module.irsa_role.aws_iam_policy.this[0]` | `aws_iam_policy.cloudwatch_agent` |
| `module.irsa_role.aws_iam_role_policy_attachment.this[0]` | `aws_iam_role_policy_attachment.cloudwatch_agent` |

The existing Helm and namespace resource addresses remain. The legacy `iam_role_arn` output continues to mean the CloudWatch agent; the new `fluent_bit_iam_role_arn` is separate.

If a previous agent already created either group, import it into the appropriate environment's initialized 03-platform state before reviewing the migration plan. Do not delete the existing group to resolve a name conflict:

```bash
terraform import 'module.container_insights[0].aws_cloudwatch_log_group.this["application"]' "/aws/containerinsights/<cluster>/application"
terraform import 'module.container_insights[0].aws_cloudwatch_log_group.this["performance"]' "/aws/containerinsights/<cluster>/performance"
```

Only import groups confirmed to belong to this cluster/environment. Review that the three moved IAM resources update in place, Fluent Bit has a new role, and existing log groups are retained. No state migration or import was executed during implementation.

## Verification ceiling

Terraform tests decode actual IAM and Helm values with mocked external providers. Pinned chart templates were also rendered locally. This does not prove EKS 1.36 compatibility of these existing old agents, IRSA credential exchange, log delivery, redaction of application payloads, or live KMS authorization.

References: [AWS chart repository](https://github.com/aws/eks-charts), [EKS performance events](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-reference-performance-logs-EKS.html), [CloudWatch KMS](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html).

All owned taggable resources force `ManagedBy=Terraform`, even when caller tags omit it or specify another owner.
