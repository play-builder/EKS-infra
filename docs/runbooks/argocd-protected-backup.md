# Argo CD protected backup and isolated recovery

## Scope and ownership

Platform/SRE owns the backup bucket, KMS key and operator access. Terraform creates storage;
`argocd admin export/import` operates on Argo CD 3.5.2. The archive is real recovery data, not merely
a JSON evidence record. Local unit/mock success does not prove that an export, import or service
recovery has run.

The dedicated `terraform/platform-backup` state survives cluster teardown. It has private access,
versioning, KMS rotation and 120-day GOVERNANCE Object Lock (minimum90 days). Ordinary backup operators
cannot delete versions, shorten retention or bypass governance. Storage and KMS incur retained costs;
cleanup must report them as retained, never as an empty inventory. A later separately reviewed retention
disposal must preserve the key while any archive still needs decryption.

Administrator and backup operator role sets must be disjoint. Combining them would give the archive
operator key-administration privileges that can defeat recovery even while Object Lock retains bytes.
Organizations must also review identity-policy grants and role-assumption paths outside this module.

## Prerequisites

Use same-account, short-lived operator credentials; configure real administrator and operator IAM role
ARNs in `terraform.tfvars`. Key administrator is not automatically an archive reader. Apply uses the
reviewed plan and the repository's operator-only root procedure. IAM/SCP denial is a stop condition,
not a reason to grant wildcard secrets or key access.

The source and isolated target must be different actual EKS clusters. Install the same Argo CD 3.5.2
on the target through Terraform, with `enable_bootstrap=false` while preparing restore. Rehydrate
`argocd-oidc`, `argocd-notifications-secret`, and `argocd-repository-credentials` using the GitOps
ExternalSecret objects and target cluster IRSA. The script checks current Ready generations without
reading their Kubernetes Secret values. ExternalSecret readiness does not prove SSO login or paging.

Install the fixed CLI separately and confirm `argocd version --client --short`. Use Python3.10+ with
the repository requirements in an isolated venv, AWS CLI/kubeconfig authentication, and `kubectl`.

```bash
python3 -m venv "$HOME/.local/share/platform-backup-venv"
source "$HOME/.local/share/platform-backup-venv/bin/activate"
python3 -m pip install -r scripts/requirements-argocd-backup.txt
```

These commands assume the EKS-infra repository root. Prepare an evidence directory outside Git and
configure `AWS_PROFILE`, `SOURCE_CONTEXT`, `SOURCE_CLUSTER_ARN`, `RECOVERY_CONTEXT`,
`RECOVERY_CLUSTER_ARN`, `GITOPS_REVISION` (actual40-hex Synced revision), and `EVIDENCE_DIR`.

```bash
mkdir -p "$EVIDENCE_DIR"
terraform -chdir=terraform/platform-backup output -json backup > "$EVIDENCE_DIR/backup-storage.json"
```

Expected: metadata contains the actual account, Region, bucket, KMS ARN and retention. Never substitute
handwritten passing metadata for actual Terraform outputs and collector reads.

## Export

The script verifies caller/storage protection, EKS API endpoint versus kube-context, CLI/server version,
server readiness and the selected application's Git revision. It captures the raw export only in memory,
drops every Secret, strips live status/operation and annotations, and rejects recognized inline credential
forms. The archive is not a general-purpose PII detector: credentials must already live in Secret/ESO,
never arbitrary ConfigMaps or Helm values. The script does not print raw export or CLI stderr.

```bash
bash scripts/argocd-backup.sh export --storage "$EVIDENCE_DIR/backup-storage.json" \
  --context "$SOURCE_CONTEXT" --cluster-arn "$SOURCE_CLUSTER_ARN" \
  --gitops-revision "$GITOPS_REVISION" --application mini-commerce-prod \
  --output "$EVIDENCE_DIR/argocd-export.json" --execute
```

Expected: `CAPTURED`, `restored=null`. A unique object key is uploaded with a checksum and
`If-None-Match:*`; the exact version is read back to verify SSE-KMS, retention, checksum and a source
identity hash stored with the object. Existing metadata files are not overwritten.

## Isolated import

Review the source/target ARNs and kube-context explicitly. Import never targets the original cluster.
Terraform recreates platform ConfigMaps; External Secrets supplies credentials; ApplicationSets are
recreated from the reviewed Git revision. The importer restores AppProjects (except the default project)
and Applications only, removes finalizers/active operations/auto-sync, and permits only in-cluster
destinations. Unrelated or actively operating target Applications block import. It does not use prune,
conflict override, source cluster credentials or source-cluster API destinations.

```bash
bash scripts/argocd-backup.sh restore --storage "$EVIDENCE_DIR/backup-storage.json" \
  --context "$RECOVERY_CONTEXT" --cluster-arn "$RECOVERY_CLUSTER_ARN" \
  --metadata "$EVIDENCE_DIR/argocd-export.json" \
  --confirm-isolated-target "$RECOVERY_CLUSTER_ARN" --execute \
  --output "$EVIDENCE_DIR/argocd-import.json"
```

Expected: an import receipt with object names and archive/source binding, not a recovered application
claim. The script reads imported objects back because Argo import can log individual permission failures
without necessarily making every import operation fatal. Missing/mismatched specs block success.

Before manually syncing business applications, verify the isolated RDS endpoint, recovery namespace,
TLS CA, split DB/runtime/migration credentials and source configuration. Do not sync copied Prod values
against the original production database. Use the GitOps `data-and-telemetry-cutover` procedure and RDS
recovery runbook. A changed recovery Git revision requires a newly reviewed/bound backup baseline;
do not edit evidence JSON to make revisions match. The same-revision Argo snapshot check is narrower
than a full platform failover or business RPO/RTO assessment.

## Read-only recovery verification

After approved manual sync, run the read-only verifier. It checks exact stored bytes/version and source
hash again, the new cluster's identity/server version, Secret rehydration, recent import receipt and
actual selected Application `Synced`/`Healthy` revision. It never performs a sync or promotion.

```bash
bash scripts/argocd-backup.sh verify --storage "$EVIDENCE_DIR/backup-storage.json" \
  --context "$RECOVERY_CONTEXT" --cluster-arn "$RECOVERY_CLUSTER_ARN" \
  --metadata "$EVIDENCE_DIR/argocd-export.json" \
  --restore-receipt "$EVIDENCE_DIR/argocd-import.json" \
  --output "$EVIDENCE_DIR/argocd-restored.json"
```

Only this operator-run live observation path writes `CLOUD_RUNTIME`; pure unit evaluation writes
`LOCAL_VERIFIED`. Keep the original import receipt in protected evidence storage: it is an operator
capture, not a cryptographically signed Kubernetes audit log. `CLOUD_RUNTIME` here covers S3/Argo
observations only, not SSO, alerts, Istio traffic, RDS data integrity or end-to-end RPO/RTO. Those require
their separate collectors and the platform rebuild evidence. Stop on stale/foreign identity, missing
archive version, checksum/KMS mismatch, Secret not Ready, or a non-Healthy/non-Synced application.

## Local verification

```bash
bash tests/argocd-backup-contract.sh
python3 tests/argocd-backup-sdk-contract.py
terraform -chdir=modules/storage/protected-backup test
terraform -chdir=terraform/platform-backup test
```

SDK tests use local Botocore Stubber, not AWS. Terraform tests use mock providers; they neither create
an archive bucket nor perform an actual restore. No plaintext archive or secrets are committed.

## References

- [Argo CD disaster recovery](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/)
- [Pinned Argo CD export/import source](https://github.com/argoproj/argo-cd/blob/v3.5.2/cmd/argocd/commands/admin/backup.go)
- [S3 Object Lock modes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)
- [S3 SSE-KMS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/specifying-kms-encryption.html)
