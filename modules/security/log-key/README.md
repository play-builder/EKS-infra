# CloudWatch Logs KMS key

The module creates a rotating symmetric key and alias. It accepts explicit existing same-account administrator roles; include the Terraform execution role so KMS lockout protection can confirm future `PutKeyPolicy` access. The execution role also needs identity permissions to create/manage the alias ARN.

## Integration contract

Compute `log_group_names` from naming inputs before downstream resources exist. For the platform pass the control-plane, VPC flow, application, **performance**, and WAF names. The module builds exact group ARNs with no stream suffix and verifies provider account/Region against its declared inputs.

`caller_role_arns` is an optional set of exact log API caller roles. Include the precomputed CloudWatch agent and Fluent Bit ARNs, and the VPC delivery/approved reader roles where required. This is same-account delegation conditioned on exact `aws:PrincipalArn`, regional `kms:ViaService`, and exact log group encryption contexts; callers must also have matching identity policies. Role ARNs in conditions avoid requiring future downstream roles to exist at key creation. No account-wide administrative grant is created.

The Logs service principal has exact encryption-context constraints. The key-policy `Resource = "*"` means this key, not every key. Administrator actions and principals have no wildcards; rotation and 30-day deletion wait are fixed.

## Verification and limits

`terraform test` uses mock AWS responses and evaluates the real rendered policy. It cannot prove live IAM/KMS authorization. Before deploying, verify administrator existence, exact group names, calling-role policies, and a reviewed plan. Preserve old keys until retained logs are no longer needed.

References: [CloudWatch KMS](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html), [KMS account delegation](https://docs.aws.amazon.com/kms/latest/developerguide/determining-access-key-policy.html), [IAM principal ARN conditions](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_principal.html).

The key always resolves `ManagedBy=Terraform`; callers supply the other four platform tags and cannot override the Terraform owner.
