# Platform cost controls

This module creates a monthly AWS Budget, a tag-scoped Cost Anomaly Monitor and an immediate SNS anomaly
subscription. The billing provider must use an existing Organizations **management account** in
`us-east-1`; `workload_account_id` and `workload_region` identify the independently deployed platform.

## Ownership and prerequisites

- Set explicit `billing_account_id` and `workload_account_id`. The provider caller must match the
  Organizations management account and the workload must belong to that organization. A normal member
  or standalone account cannot create the CUSTOM tag monitor. The module reads organization metadata
  to verify eligibility; denied Organizations reads fail rather than assuming eligibility. This module
  never creates an organization, changes account membership or assumes a billing role itself.
- Supply an independently managed standard SNS topic in the **billing management account**, `us-east-1`. This module does not
  create, delete or alter that topic, its policy, its encryption key or its subscribers.
- Activate `PlatformInstanceId` as a cost allocation tag and apply the same value to billable platform
  resources. Tag activation and billing-data availability can lag resource creation; an empty cost view
  does not establish zero spend.
- Reserve `PlatformInstanceId` uniquely across the billing organization. Readiness must reject evidence
  of that value on other workload accounts and record when current billing data cannot establish its
  scope. A self-declared uniqueness flag is not sufficient verification.
- The external topic policy must permit AWS Budgets and Cost Anomaly Detection to publish with bounded
  source conditions. An encrypted topic additionally requires the corresponding KMS permissions.
- Confirm subscription delivery separately. Resource ARNs and a successful Terraform plan do not prove
  that an on-call destination received a notification.

The budget selects `LinkedAccount=workload_account_id` **and** `PlatformInstanceId`; the CUSTOM monitor
uses the documented organization-wide tag-only selector. Their scopes are explicitly different and
only align for an organization-unique tag value. Neither represents costs for untagged resources.
The budget notifies on actual spend above 50%,
80% and 100%; it does not impose a spending cap or shut down resources. Immediate anomaly notification
uses an absolute USD impact threshold and depends on Cost Anomaly Detection processing.

## Inputs and outputs

`finops` contains positive USD budget/anomaly thresholds, the three budget percentages, the external
SNS ARN and nonempty `PlatformInstanceId`, `Owner`, `CostCenter`, `Environment=prod` tags. The module fixes
`ManagedBy=Terraform` on its owned resources. The output `finops_contract` binds both account identities,
billing/workload Regions, `budgetScope` and `anomalyScope` separately.
It is metadata for downstream checks, not a runtime verification result.

## Validation and cleanup

Terraform mock tests check planned resource attributes, scope, subscriptions, tags and rejection of
invalid thresholds, cross-account topics, ineligible/mismatched management identity, absent organization
membership and a workload-Region billing provider. They do not access AWS.
The calling root owns provider initialization and the provider dependency lock.

Keep cost controls until workload cleanup and retained billable-resource decisions are complete.
Destroying this module removes its budget/monitor/subscription only; the external topic and retained
snapshots, logs or KMS keys are separate owners and remain in place.

## References

- [AWS Budget notifications](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-sns-policy.html)
- [Cost allocation tag activation](https://docs.aws.amazon.com/cost-management/latest/userguide/activating-tags.html)
- [Cost Anomaly Detection](https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html)
- [Management-account eligibility for tag monitors](https://docs.aws.amazon.com/cost-management/latest/userguide/getting-started-ad.html)
- [Organizations identity data source](https://github.com/hashicorp/terraform-provider-aws/blob/v5.87.0/website/docs/d/organizations_organization.html.markdown)
- [Pinned AWS provider budget resource](https://github.com/hashicorp/terraform-provider-aws/blob/v5.87.0/website/docs/r/budgets_budget.html.markdown)
- [Pinned AWS provider anomaly subscription](https://github.com/hashicorp/terraform-provider-aws/blob/v5.87.0/website/docs/r/ce_anomaly_subscription.html.markdown)
