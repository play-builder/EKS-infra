# Enterprise root integration and retained-resource cleanup

## 실행 경로

핵심 요약: workload roots와 관리계정·보호 백업 roots는 실행 권한을 공유하지 않습니다.
Static matrix는 모든 root를 검사하지만 operator-only root는 일반 CI apply 선택지에 없습니다.

| Root | Canonical backend | State key / lane |
| --- | --- | --- |
| `environments/prod/00-finops` | `environments/prod/config/finops.tfbackend` | `prod/00-finops/terraform.tfstate`, management operator |
| `environments/prod/03-database` | `environments/prod/config/database.tfbackend` | `prod/03-database/terraform.tfstate`, workload |
| `environments/recovery/03-database` | `environments/recovery/config/database.tfbackend` | `recovery/03-database/terraform.tfstate`, workload |
| `terraform/platform-backup` | `terraform/platform-backup/backend.tfbackend` | `shared/platform-backup/terraform.tfstate`, protected operator |

Backend files contain only key/encryption/lock settings. Supply actual bucket and Region at init;
saved-plan identity must bind that exact tuple. Workload OIDC can Get/Put exact state objects and
Get/Put/Delete their `.tflock` objects, not Delete state. Management and backup state grants belong to
separate approved operators; no new management-account trust is implicitly created.
[FinOps readiness](finops-readiness.md) remains mandatory before prod cost creation, distinct from
static design GO. Do not bypass the protected plan/apply lane.

Runtime order: FinOps → network/private access → EKS/platform/controllers → GitOps Istio CNI/node
readiness → application admission → RDS bootstrap/migration → delivery/SLO/DR evidence.
The recovery root requires a separately produced, actually distinct EKS/OIDC identity.

Argo ExternalSecret health follows the pinned ESO v2.10.0 producer: Ready=True with
reason SecretSynced/message `secret synced`, nonempty refreshTime and the current generation prefix
of syncedResourceVersion. ESO does not emit observedGeneration. Deleting, stale, missing/deleted and
retained-secret cases are not Healthy; Ready=False is Degraded. Health does not claim a time-bounded
DR refresh or verify the metadata hash—those require the separate producer/consumer DR contract.
See [ESO resource version](https://github.com/external-secrets/external-secrets/blob/v2.10.0/pkg/controllers/util/util.go)
and [ESO reconciliation](https://github.com/external-secrets/external-secrets/blob/v2.10.0/pkg/controllers/externalsecret/externalsecret_controller.go).

## IAM inputs and secret ownership

핵심 요약: IAM scopes are explicit operator inputs. Empty sets grant no corresponding lifecycle
permission; Terraform mocks verify JSON construction, not effective AWS authorization.

Set exact `workload_state_bucket_names` and `enterprise_resource_arns={rds,secrets,kms,waf,sns}`
in the workload account/Region. Include DB/subnet-group/parameter-group/source/final-snapshot ARNs
as applicable. Key administration also requires the key's explicit admin policy, including the
bootstrap execution principal; key/alias identities must be approved separately.
`enterprise_secret_names` permits literal shell names plus AWS's six-character suffix;
`enterprise_waf_names` permits literal regional WebACL names plus service-generated UUIDs.
Key creation requires matching PlatformInstanceId/ManagedBy request tags.
The RDS `rds!db-*` namespace receives CreateSecret/TagResource only when RDS scope is configured.

The provisioner does not GetSecretValue, PutSecretValue, UpdateSecret, decrypt log data, publish SNS,
delete DB snapshots or assume runtime/database/migration/billing/backup roles. CreateSecret itself
can carry an initial value; IAM cannot make that API metadata-only. Repository modules create shells
only and the ownership test rejects secret-version resources/data. Existing secret metadata changes
needing UpdateSecret require operator review because the same API can replace a value.
Existing broad EC2/EKS/IAM provisioning rights are not a boundary against malicious administrators;
account SCP/permissions-boundary design remains separately reviewed.

For the trusted FinOps collector only, optional `billing_monitor_role_arn` adds exact sts:AssumeRole
to an externally managed read-only observer. Configure that role's trust and read-only permissions
separately; this is not a billing provisioning role. This root exposes one workload infra role.
If CI plan/apply use other pre-existing roles, each needs that same exact observer grant; no separate
role policy is silently attached by this root.

RDS-managed passwords require CreateSecret/TagResource/DescribeKey. Customer-key grants are scoped
to exact keys and AWS-resource/RDS-service conditions. See
[RDS Secrets Manager permissions](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html)
and [AWS authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/reference_policies_actions-resources-contextkeys.html).
Never add blanket decrypt or wildcard account trusts to work around initialization failure.

The platform publisher stays separate. Scanning includes legacy/new Mini Commerce image prefixes and
`playdevops/platform/istio-proxyv2*`; Sigstore gets the exact repository ARN.
Custom names require matching scan filters and GitOps locked mirror evidence.

## Cleanup and retention

핵심 요약: normal cleanup removes approved runtime layers, not protected backup, billing or account
identity. Zero unapproved residuals does not mean zero retained objects or zero future cost.

1. Inventory actual ARNs (or service-native identifiers), CourseId, account/Region/environment and
   explicit DELETE/RETAIN/EXTERNAL_SHARED decisions. New kinds: `RdsInstance` (prod or recovery),
   `RdsSnapshot`, `RdsAutomatedBackup`, `RdsSubnetGroup`, `RdsParameterGroup`, `KmsKey`,
   `LogGroup`, `WafWebAcl`, `S3BackupBucket`, `IamOidcProvider`, `Budget`,
   `CostAnomalyMonitor`, `CostAnomalySubscription`, `CostAllocationTag`, `BillingSnsTopic`.
   Retain `S3StateBucket`, `TerraformState` and local `CourseEvidence` explicitly as well.
   Existing EcrRepository/SecretsManagerSecret/state/evidence ownership remains.
2. Disable RDS deletion protection through a separately approved change before creating destroy plans.
   Require skip_final_snapshot=false and a retained exact future final snapshot ARN; the final scanner
   must observe that snapshot. Guard checks run on each saved root plan.
3. Order: controllers → recovery DB → prod DB → platform → EKS → network. DB roots enter from the
   inventory. A retained live DB blocks network teardown; use separately reviewed partial teardown.
   Recovery EKS itself remains externally owned.
4. Backup/RDS/unclassified `KmsKey`, versioned 120-day GOVERNANCE backup buckets, automated backups, account OIDC and FinOps
   kinds cannot be DELETE in normal cleanup. No bypass-governance, force-empty or snapshot eraser
   is supplied. Terraform prevent_destroy and Object Lock remain intact.

The scanner describes each declared identity, fails on denial/malformed responses, and discovers
CourseId-tagged RDS/KMS/log/WAF/S3/ECR resources omitted from inventory. Tags do not prove historical
completeness: compare retained state/resource exports and billing evidence, including removed tags.
External billing SNS/account settings and OIDC must be explicitly declared, not inferred from tags.
FinOps observations require FINOPS_BILLING_PROFILE and FINOPS_BILLING_ACCOUNT_ID with STS verification
in us-east-1. Cross-account backup reads require BACKUP_PROFILE/BACKUP_ACCOUNT_ID/BACKUP_REGION and
explicit S3 owner verification. No credentials are persisted.
The only KMS deletion exception is the exact network `module.log_key.aws_kms_key.this` with a
30-day window, not a generic key-purpose tag. Classify it as `KmsLogKey`, decision DELETE,
purpose `cloudwatch-log-protection`, `deletionWindowInDays: 30`, and list exact `logGroupArns`.
Every listed LogGroup inventory entry must have the same `kmsKeyArn` and explicit DELETE approval.
`retentionReleaseApproval` requires approvedBy, canonical UTC approvedAt (within 24h),
retentionReleased=true and restoreRequired=false. This is a separate operator authorization;
existing retention obligations are never automatically waived.

The guard compares the saved key policy's complete encryption-context ARN set, inventory bindings,
and all aggregate-plan log bindings. RETAIN/shared/unknown bindings fail closed. Other-root groups
(including declared groups never created) must be actually absent before the network root apply.
Only `module.vpc.aws_cloudwatch_log_group.vpc_flow[0]` may remain in that same network saved plan:
exact DELETE, before ARN/key equality and the actual saved-configuration reference chain are required.
`tests/log-key-dag-contract.py` compiles the real Terraform graph proving log-group-to-key dependency;
normal Terraform destroy reverses it. No targeted apply, state removal or AWS CLI log deletion is used.

The residual report separately records `scheduledKeyDeletions` with DescribeKey's actual
PendingDeletion state and deletion date after all bound logs are absent. This is **not physical
deletion**: the key becomes unavailable for cryptographic use immediately during the waiting period.
AWS can extend the scheduled 30 days by up to 24 hours. Review the retained handle until physical
deletion; canceling deletion before expiry is a separate authorized recovery action, not automatic.
See [AWS key deletion](https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html)
and [DescribeKey metadata](https://docs.aws.amazon.com/kms/latest/APIReference/API_KeyMetadata.html).
Retained manual/automated snapshots, ECR images and S3 versions can continue accruing cost.

## Scheduled read-only drift

핵심 요약: `terraform-drift.yml` runs at 02:17 UTC daily (and manual dispatch), with no remediation.
FinOps management and backup operator roots are excluded; missing credentials or inputs fail closed.

Set GitHub secret `TERRAFORM_DRIFT_ROLE_ARN` to a separately managed read-only workload role, and
`TERRAFORM_DRIFT_INPUTS_JSON` to an object keyed by the ten exact workload root paths, each containing
its non-empty Terraform input object. Configure AWS_REGION/AWS_ACCOUNT_ID/STATE_BUCKET_NAME variables.
The role requires resource observation, exact state GetObject/ListBucket and `.tflock` Get/Put/Delete;
no resource mutation or automatic trust expansion is supplied. Bind its OIDC trust to this repository's
approved default branch. Plan/apply roles remain separate GitHub secrets TERRAFORM_PLAN_ROLE_ARN and
TERRAFORM_APPLY_ROLE_ARN; the IAM root's infra role is only a provisioned alias, not those role producers.
Exit 0 is clean, 2 is drift and 1 is error; either nonzero fails the workflow. Only redacted drift JSON
is retained seven days, never tfvars or the binary plan. Scheduled execution is LIVE_NOT_VERIFIED.

## Static verification and tools

핵심 요약: the default runner is fixture-only; the complete runner also initializes providers and
evaluates real pinned charts/PromQL. Neither executes cloud workloads.

```bash
bash tests/run-contract-tests.sh
ENTERPRISE_PYTHON=/path/to/isolated-venv/bin/python3 RUN_SDK_CONTRACTS=true \
  bash tests/run-enterprise-static-tests.sh
```

Use Terraform 1.16.0, Helm 4.2.4, promtool 3.14.0, yq4.53.6, jq/Ruby/rg and Python 3.10+.
Health behavior uses real Lua5.1.5: `bash scripts/install-lua.sh /absolute/bin` downloads the official
source, checks its pinned SHA256 before extraction/build, and requires cc/make. Put that directory
on PATH or set LUA_BIN to its lua executable. This is a local test tool, not a workload dependency.
Install scripts/requirements-argocd-backup.txt in the isolated venv (pinned AMP SDK + PyYAML6.0.3).
AWS CLI does not imply importable boto3. Without RUN_SDK_CONTRACTS=true the SDK gates report NOT_RUN.
Each render test checksum-checks its actual chart archive; use its documented CHART_ARCHIVE override.
TFLint0.64.0, Trivy0.74.0 and Conftest0.69.0 remain separate required CI gates.
Results are STATIC_VERIFIED/LOCAL_VERIFIED only. AWS apply/destroy, SSO, injection/admission, billing,
notification delivery, PITR and backup restore remain LIVE_NOT_VERIFIED until separately authorized.
