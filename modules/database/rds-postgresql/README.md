# Private PostgreSQL and isolated PITR

This module owns a PostgreSQL DB instance, its database subnet group, identity-scoped ingress and TLS
parameter group. It does not own application credentials, Kubernetes Secrets, database schemas or
application traffic cutover. A separate root/state must own each isolated restore target.

## Production contract

- Multi-AZ, private access and encrypted storage are fixed. Subnets must span at least two AZs and
  belong to the selected VPC without public IP assignment; independently verify their private routing.
- Only explicit same-VPC client security groups receive TCP 5432 ingress. Include the application
  network identity and the approved private operator identity, not a public CIDR.
- RDS manages the master password in Secrets Manager. Terraform exposes its ARN, never its value.
  Application DML and migration DDL users/credential shells remain separate and cannot read the master
  secret. SQL bootstrap creates those roles after provisioning.
- PostgreSQL requires TLS. Clients must trust the RDS CA bundle and verify the endpoint hostname;
  `ssl=true` without the correct trust store is insufficient. The CA identifier, engine minor version
  and instance class are explicit inputs whose regional support must be checked before plan.
- Backups default to 35 days with an independent platform minimum of 7 days. These durations do not
  demonstrate RPO/RTO. Deletion protection is on, final snapshots cannot be skipped, snapshot tags are
  copied, and automated backups are retained on deletion.
- Engine patches are pinned, automatic minor/major upgrades are off, and ordinary modifications wait
  for the maintenance window. A reviewed upgrade plan and version availability check are required.
- SQL statement logging and error-statement payload logging are disabled to reduce credential/PII
  exposure. This reduces query-debugging detail; use sanitized application spans and explicit,
  time-bounded DBA diagnostics rather than enabling parameter payload logging by default.

The optional storage KMS key must already exist in the same account/Region. Without it, a new encrypted
instance uses the AWS-managed RDS key. This module does not create or destroy either encryption key.
Keep the source key usable for all retained snapshots, backups and restore targets.

## Restore and cleanup boundaries

`restore_to_point_in_time` creates a new identifier from an exact same-account/Region source. Specify
one UTC cutoff or latest-restorable-time selection, never both. The source must be private, encrypted,
backed up and match the requested engine version/database. Restore inherits the source storage capacity
and key; it must not attempt to shrink or re-encrypt the source. The new target has its own subnet/SG,
parameter group and managed master secret.

**AWS provider 5.87.0 convergence:** the initial PITR create path does not apply every requested CA,
backup retention or backup/maintenance window. An initial successful apply is not restore readiness.
After it finishes, obtain a new reviewed saved plan and apply remaining changes. By default those
changes wait for maintenance. Before routing any traffic to the isolated target, an operator can opt
into `apply_restore_changes_immediately=true` through that reviewed plan; the source root rejects this
option. Remove the temporary opt-in before promoting the target into ordinary operation.

The recovery collector must compare live CA, retention, backup/maintenance windows and parameter-group
status with `database_contract.expectedConfiguration`, and reject relevant pending modifications.
`restore.requiresPostRestoreConvergence` states this requirement; it is not a success result. Waiting
for maintenance can exceed the RTO objective, which must then be reported as a failed objective rather
than silently excluded from measured recovery time. Do not bypass Terraform with an AWS modify wrapper.

Before apply, query the source's live restorable window and record the cutoff. Terraform's configuration
checks cannot demonstrate that a historical SQL transaction was recovered. After restore, compare
same-cutoff order totals, item counts, inventory checksum and transaction markers. Derive actual RPO/RTO
from observed timestamps and SQL integrity, not the objective values exported by this module.

An isolated restore must not write its endpoint into the source application's credential shells or
change source traffic. A platform rebuild needs separate secret rehydration, cluster/IAM identity,
GitOps, ingress and business transaction verification.

For cleanup, first review a saved plan that disables only the target's deletion protection. Then review
the destroy plan and its exact final snapshot identifier, retained backups and key dependencies. Do not
delete an existing snapshot merely to reuse its name; choose a new lifecycle-specific identifier.

## Validation

Terraform mock tests exercise protected resource attributes, scoped ingress, two-AZ validation,
backup/objective rejection, isolated PITR identity/cutoff and source encryption/capacity inheritance.
The fixture engine release and CA are test inputs, not proof of regional availability. Root modules own
provider initialization/locks and runtime evidence collection. No actual database is started by mocks.

## References

- [Pinned RDS provider resource and PITR inputs](https://github.com/hashicorp/terraform-provider-aws/blob/v5.87.0/website/docs/r/db_instance.html.markdown)
- [Pinned provider restore implementation](https://github.com/hashicorp/terraform-provider-aws/blob/v5.87.0/internal/service/rds/instance.go)
- [RDS instance/network prerequisites](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateDBInstance.html)
- [RDS point-in-time restore](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html)
- [RDS PostgreSQL TLS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html)
