# RDS PostgreSQL bootstrap and isolated recovery

The production root creates a private protected PostgreSQL instance; the recovery root creates a distinct
PITR target and dedicated recovery secret shells/readers. Collectors read AWS, Kubernetes and SQL state.
Only explicit bootstrap execution writes PostgreSQL roles/markers and Secrets Manager values. No script
creates, restores, modifies or deletes an AWS resource.

Contents: [Prerequisites](#prerequisites), [Roots](#terraform-roots), [Bootstrap](#credential-bootstrap),
[Capture](#consistent-cutoff-and-recovery), [Rebuild](#platform-rebuild), [Evidence](#evidence-and-failure-semantics),
[Cleanup](#protected-cleanup).

## Prerequisites

Use a short-lived assumed-role AWS session in the expected workload account and Region, a private network
path to PostgreSQL, `aws`, `psql`, Python 3.9+, and an explicitly trusted RDS CA bundle. Bootstrap validates
the caller, RDS ARN/resource ID, endpoint, master-secret ARN and converged RDS configuration before reading
credentials. Credentials never enter Terraform, command arguments, normal output or shell tracing.

- Verify the exact PostgreSQL release, instance class, gp3/Multi-AZ support and CA in the target Region.
  The `.tfvars.example` placeholders intentionally do not assert regional availability.
- Confirm database-only subnets have no public/NAT route and span at least two AZs. Pass actual app,
  migration and operator client security groups. Terraform checks subnet/VPC/AZ and SG/VPC identity;
  it does not prove routes or network reachability.
- Ensure PostgreSQL statement/audit instrumentation does not record credential SQL. The managed parameter
  group and session disable statement/error-payload logging. An independently installed audit extension
  must be reviewed before bootstrap. Temporary `pgpass` and secret-value files live in private temporary
  directories and are removed automatically; no password is accepted on a CLI argument.
- Give the bootstrap operator only required RDS/STS/Secrets Manager access; separate app/migration ESO
  readers from the master secret. Recovery role trust must use the rebuilt cluster's OIDC issuer.
- Keep all collectors and raw artifacts in a trusted runner. A JSON file cannot authenticate AWS/SQL
  execution, and injected local CLIs can imitate cloud output. These scripts never self-assign
  `CLOUD_RUNTIME` or `RECOVERY_VERIFIED`.

The [RDS-managed master-secret contract](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html)
and [PostgreSQL verify-full semantics](https://www.postgresql.org/docs/current/libpq-ssl.html) are the runtime basis.

## Terraform roots

Both roots read the production network state. Production consumes existing `03-platform` application
secret metadata. Recovery reads production DB/cluster state, creates unique `recovery-<identifier>` secret
shells and scopes readers to `app-recovery` on a distinct actual cluster/OIDC provider. This does not
change source application secrets. Recovery requires that rebuilt cluster and its IAM OIDC provider first.

| Root | State key | Secret ownership |
| --- | --- | --- |
| `environments/prod/03-database` | `prod/03-database/terraform.tfstate` | Reads production platform shells |
| `environments/recovery/03-database` | `recovery/03-database/terraform.tfstate` | Owns isolated shells/readers |

Provide the state bucket/Region explicitly at init and match them to `state_bucket`/`state_region` inputs.
Use the repository's reviewed saved-plan workflow once its root/backend/IAM allowlists include both roots.
Do not reuse a production saved plan or source DB identifier for recovery. Terraform backend state keys
are fixed in the corresponding `config/database.tfbackend`. Root output metadata is not a substitute for
checking the initialized backend and saved plan's actual state identity.

```bash
terraform -chdir=environments/prod/03-database init \
  -backend-config=../config/database.tfbackend \
  -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$TF_STATE_REGION"
terraform -chdir=environments/prod/03-database plan -out=production-database.tfplan
```

After a separately reviewed apply, export `terraform output -json database_contract` to a private
`source-database.json`. Use the recovery root's output for `target-database.json`; do not edit the source
contract into a target contract. Recovery `restore_time` is mandatory and must match the consistent cutoff.

AWS provider 5.87 PITR creation does not immediately converge every configured CA, backup retention or
window. Re-plan the recovery root after restore, review/apply remaining changes, wait for RDS `available`,
empty `PendingModifiedValues` and parameter-group `in-sync`, then collect. The collector checks the actual
CA/retention/backup/maintenance windows against `expectedConfiguration`. An optional reviewed
`apply_restore_changes_immediately=true` is allowed only on the isolated target before traffic cutover;
remove it afterward. All waiting counts toward the recovery interval. See the
[pinned provider resource contract](https://github.com/hashicorp/terraform-provider-aws/blob/v5.87.0/website/docs/r/db_instance.html.markdown).

## Credential bootstrap

Run bootstrap once to prepare roles, execute the existing sample-app migrations with the migration
credential, then rerun bootstrap to grant access to the now-existing app tables/sequences. Reruns reuse
the current app secret password and reject endpoint/user/database mismatch. They do not rotate a working
credential implicitly. If a Secret value write fails after SQL commit, repair the permissions and rerun;
partial secret publication is an explicit failure, not success.

```bash
bash scripts/bootstrap-mini-commerce-db.sh --execute \
  --contract source-database.json --ca /absolute/path/rds-ca-bundle.pem
```

`commerce_migration` owns `public` and creates schema objects through `sample-app/scripts/migrate.mjs`.
`commerce_runtime` receives SELECT on products, SELECT/UPDATE on inventory, SELECT/INSERT on orders/items,
and USAGE/SELECT on order/item sequences. It receives no DELETE, DDL, role administration, database
creation, replication or bypass-RLS privileges. Existing membership in other roles is rejected.
Default privileges deny automatic runtime access to arbitrary future tables, including migration ledgers.
Rerun after supported migrations; review any new table separately rather than grant all future tables.

For PostgreSQL 17's NOSUPERUSER master, the transfer temporarily grants database CREATE to migration and
SET membership to the master before changing the schema owner. Grants run under the migration owner;
CREATE and the master's SET option are removed before commit. The master retains ADMIN-only membership
(INHERIT=false, SET=false) to manage these two roles on reruns, plus schema USAGE and SELECT on the four
app tables for integrity capture. Existing elevated app attributes/memberships fail closed instead of
attempting SUPERUSER/REPLICATION/BYPASSRLS changes as a non-superuser. See
[ALTER SCHEMA prerequisites](https://www.postgresql.org/docs/17/sql-alterschema.html) and
[PostgreSQL role administration](https://www.postgresql.org/docs/17/sql-alterrole.html).

`tests/rds-bootstrap-postgres-regression.py --execute-postgres-regression` is an optional **unrun** SQL
regression for an explicitly disposable PostgreSQL 17 database named `bootstrap_regression_*`. Supply
PGDATABASE/PGUSER for its NOSUPERUSER CREATEROLE CREATEDB owner, with absent commerce roles and permission
to set the logging parameters used by bootstrap. It runs the production SQL twice, checks final grants,
and rolls back the single transaction. It is not part of local/static tests and requires separate approval
for actual PostgreSQL execution. Statement-order fixtures alone do not verify server permission semantics.

Application and migration shells contain only `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`.
The application must additionally use its existing `DB_SSL=true` and trusted CA configuration. The master
secret is never copied into either shell. The recovery contract only permits the isolated recovery prefix.

## Consistent cutoff and recovery

Use a bounded write quiesce for a drill: stop/deny all application writers, complete in-flight transactions,
prepare the marker, capture a repeatable-read snapshot, select a cutoff after that capture, and keep writers
quiesced through the cutoff. The source must contain at least one valid order/item and nonempty inventory.
This contract rejects empty data and never compares an actively changing current source to an older target.

```bash
bash scripts/bootstrap-mini-commerce-db.sh --execute --prepare-marker \
  --contract source-database.json --ca /absolute/path/rds-ca-bundle.pem --output marker.raw
bash scripts/rds-recovery-check.sh --snapshot \
  --contract source-database.json --ca /absolute/path/rds-ca-bundle.pem \
  --marker-proof marker.raw --output source-observation.json
```

Marker preparation creates only `platform_recovery.markers` in PostgreSQL, outside the app schema. It
records a server timestamp, inserts the next sequential marker inside `BEGIN`/`COMMIT`, observes successful
COMMIT, and records another server timestamp in the same connection. The raw psql transcript includes
command tags and backend PID/database/server address. It contains no password. Do not use quiet psql or
rewrite this transcript. Failed/rolled-back inserts, missing acknowledgment and inverted intervals fail.
Application/migration roles have no access to this schema. No `track_commit_timestamp` setting is needed.

Choose an explicit UTC cutoff at or after `source-observation.json.completedAt`, wait for the source's
`LatestRestorableTime` to include it, and record the actual incident/drill start time. The marker upper
bound and source snapshot must precede cutoff; cutoff must precede incident. Restore the isolated root
through the reviewed Terraform saved plan and complete its convergence checks. Do not reset the incident
clock while waiting for cluster creation, restore, maintenance or verification.

```bash
bash scripts/rds-recovery-check.sh --capture --contract target-database.json \
  --ca /absolute/path/rds-ca-bundle.pem --source source-observation.json \
  --incident-at "$INCIDENT_AT" --target target-observation.json --output rds-recovery.json
```

The capture reads the actual isolated DB through verify-full TLS and a read-only repeatable-read SQL
transaction. It records the RDS instances, caller, raw integrity query, last contiguous marker and hashes.
The source's `DescribeDBInstanceAutomatedBackups` response must contain exactly one active encrypted
backup for its ARN, identifier, DbiResourceId and Region; cutoff must lie inside its
`RestoreWindow.EarliestTime/LatestTime` and the current source DBInstance `LatestRestorableTime`.
DBInstance has no `EarliestRestorableTime`; retention days are not a substitute for this observation.
See the [automated backup API shape](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_DBInstanceAutomatedBackup.html).
It also looks up the target's CloudTrail `RestoreDBInstanceToPointInTime` event. That event must match the
account, Region, source, target, explicit restoreTime, successful response, Terraform user agent and
incident interval, with request/event IDs. If CloudTrail is delayed, denied or has no unique correlated
event, the result remains PENDING; wait and retry with new artifact names. Unknown service field shapes
remain PENDING until checked against actual CloudTrail output; do not manufacture a matching record.
The parser requires operation-specific `requestParameters.targetDBInstanceIdentifier`,
`sourceDBInstanceIdentifier` and `restoreTime`. This target key spelling is a provisional serialization
contract inferred from the [Restore API input](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_RestoreDBInstanceToPointInTime.html),
not a verified raw Restore CloudTrail event. The AWS CloudTrail guide's CreateDBInstance example cannot
establish restore spelling. `dBInstanceIdentifier` in requestParameters is rejected; unknown/missing keys
remain PENDING until a trusted restore-specific raw event is available and reviewed. SDK Stubber validates
the API envelope but cannot validate CloudTrailEvent's opaque JSON string. Do not claim this gap closed by
the synthetic fixture or manufacture a matching event.

RPO is the conservative interval `incidentAt - marker.commitNotBefore`; the true commit happened between
the two recorded server times. The report exposes that uncertainty interval. RTO is
`target capture completion (including backup/API/event collection) - incidentAt`. Backup retention does not establish either metric.
Orders, totals, item count, inventory checksum, marker sequence and selected read-back order must match
the frozen source. Totals/item arithmetic, orphan rows, duplicate idempotency and negative stock must pass.

```bash
bash scripts/rds-recovery-check.sh --validate --source source-observation.json \
  --target target-observation.json --incident-at "$INCIDENT_AT" --output rechecked-rds.json
```

Validation independently recomputes derived values from the raw files. It does not upgrade their origin
or claim a new cloud execution. Keep original raw-file SHA-256 values in the drill's change record.

## Platform rebuild

A complete rebuild adds a new cluster/OIDC, three Argo credential ExternalSecrets, matching SecretStore
and IRSA trust, current OIDC user/RBAC, HA controllers, healthy synced Applications, exact source Git SHA,
app digest/Istio revision, WAF association, active ALB/healthy targets and application order read-back.
The application read-back must match the restored DB query. The isolated DB proof alone cannot pass.

Prepare `rebuild-spec.json` from actual Terraform/GitOps metadata. Required identity fields are
`accountId`, `region`, `sourceCluster`, `targetCluster`, `argocdHost`, `rbacSubject`, `oidcIssuer`,
`gitRevision` (40-character source GitOps commit), nonempty `applications` array, `imageDigest`,
`istioRevision`, `loadBalancerArn`, `targetGroupArn`, `webAclArn`, `applicationUrl` (HTTPS `/orders/<id>`),
and positive `rtoMinutes`. `externalSecrets` must contain exactly `oidc`, `notifications`,
`repositoryCredentials`; each has actual `name`, `targetName`, `sourceName`, `roleArn`, `serviceAccount`.
Use the separately emitted recovery/Argo contracts; never include credentials or claimed achieved values.

Also supply `traffic` with actual `gatewayName`, `httpRouteName`, `ingressServiceName`, `istioGatewayName`,
`virtualServiceName` and `appServiceName`. This collector supports the repository's Gateway API HTTPS443
→ HTTPRoute → Istio ingress Service → Istio Gateway/VirtualService → recovery stable Service path,
with IP-type TargetGroupBinding and one 100% stable route. Unsupported routing shapes remain PENDING.

The read-back order ID is `target-observation.json.sql.readbackOrder.id`. The Argo CLI must already have a
short-lived corporate OIDC session for the target server; the collector does not log in or mutate RBAC.
It creates a temporary kubeconfig bound to the target EKS endpoint/CA and AWS exec authentication, so
the user's current kubectl context cannot silently select the source cluster.
The Argo public URL is checked against the target cluster's `argocd-cm`. The HTTPS application read uses
the observed target ALB DNS name through curl `--connect-to`, retaining certificate/hostname verification;
it cannot silently read the source application's public DNS target. HA includes ApplicationSet and
three ready Redis HA members. The actual injector status annotation supplies the Istio revision.

ALB ownership tag `elbv2.k8s.aws/cluster`, Gateway address, HTTPS listener's selected rule and target group
must bind the new cluster. Healthy target IPs/ports must equal the ingress Service's ready EndpointSlices
and Pod UIDs. Istio routing must terminate at the recovery namespace stable Service, whose EndpointSlices
bind ready application Pod UIDs. Application DB env secret references and ready ExternalSecret mappings
must use the isolated recovery database shell, never a source shell.

For each recovery app Pod, read-only `kubectl exec` runs a short Node query with the image's existing
`config.js` and `createDatabasePool`, including its CA verification. It emits only configured host/port,
SQL database/user/server address/TLS/time and selected order summary, not passwords or a full environment.
The observation must match restored DB identity and SQL read-back, and a second Pod read confirms its UID
did not change. Denied exec or unavailable image modules stays PENDING. This proves an observed connection
using that Pod's shipped configuration, not a packet trace of the long-running app's pool; trusted runner
and immutable-image assumptions remain necessary. Keep the bounded write quiesce through collection.

```bash
bash scripts/platform-rebuild-dr-check.sh --capture --spec rebuild-spec.json \
  --source source-observation.json --target target-observation.json \
  --incident-at "$INCIDENT_AT" --raw rebuild-observations.json --output rebuild-dr.json
```

Recheck the raw observations using `--validate` with the same `--raw`, `--source`, `--target`,
`--incident-at` and a new `--output`. Platform RTO extends through the final application read-back and
must meet its own objective. Requires read-only EKS/IAM/WAF/ELB APIs, Kubernetes resource reads,
Argo account reads, explicitly authorized read-only app `pods/exec`, and HTTPS access. No Kubernetes Secret
value read occurs. The Kubernetes exec API is operationally powerful even when this fixed command is
read-only; restrict its authorization to the isolated recovery namespace and collector identity.

## Evidence and failure semantics

Exit 0 means the observed local contract is internally consistent, with `status=OBSERVED`,
`evidenceGrade=LOCAL_VERIFIED`, `liveStatus=LIVE_NOT_VERIFIED`. Exit 2 emits an explicit PENDING reason.
There is no silent PASS. Missing/denied APIs, SQL failures, missing files, stale/future/inverted times,
source/target reuse, mismatched integrity, old pending RDS settings, missing controllers/credentials or
objective overrun cannot satisfy the contract. Raw caller `CLOUD_RUNTIME` or achieved-minute fields are
rejected. All file outputs use exclusive creation; use new names when retrying.

The checked-in tests use external API/SQL doubles; they are LOCAL_VERIFIED. Terraform mock tests are
STATIC_VERIFIED. No actual restore, TLS connection, secret write, application read-back, SSO or rebuild
has been performed by this implementation. Record actual trusted-runner execution separately and retain
the raw data plus hashes before making an operational recovery claim.

## Protected cleanup

Keep source deletion protection enabled throughout drills. Stop isolated traffic and complete evidence
retention first. Review a recovery-only saved plan that temporarily disables target deletion protection;
verify its state key, unique identifier and final snapshot name. Apply that reviewed change, then review
the protected target destroy separately. Retain final/manual/automated snapshots, their storage key and
required audit records according to the retention decision. Never delete a KMS key needed by a snapshot.

Recovery secret shells intentionally inherit `prevent_destroy` from the secret-owner module. A final
cleanup needs an explicit owner-approved retention/state decision; do not bypass it by changing source
addresses or force deletion. DB, snapshot, secret, key and rebuilt cluster cleanup are separate decisions.
The global cleanup/IAM/saved-plan root integrations must be complete before treating this root as part of
automated teardown. A retained artifact may remain billable; an unavailable API is not evidence of zero.
