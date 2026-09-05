# Access Entry state migration
Existing installations must complete this operator-reviewed state migration before
applying the new 02-eks root. No live state was inspected during implementation.

## Stage 1: address-only migration

Preserve principal, cluster, policy ARN and access scope exactly. This helper only
validates address movement; it never authorizes policy changes or replacements.

1. Back up the exact backend state and record account/Region/backend/source identity.
2. Use terraform state list and state show to inventory every external principal entry
   and its policy association. Sources are module.eks_cluster creator[0]/admin[ARN]
   and module.operator_access operator addresses.
3. Build a JSON array of oldAddress, newAddress and principalArn. Targets are
   module.access_entries.aws_eks_access_entry.this["SEMANTIC-KEY"] and
   module.access_entries.aws_eks_access_policy_association.this["SEMANTIC-KEY"].
   Use platform-break-glass, platform-operator, release-automation, developer-readonly.
   Capture actual addresses; no universal ARN-indexed moved block is valid.
   Each association mapping must additionally include the existing
   `policyArn` and `accessScope`, for example
   `"policyArn": "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"`
   and `"accessScope": {"type":"namespace","namespaces":["platform-system","app-prod"]}`.
   Copy these values from the old association, not from a desired future policy.
   A current cluster-admin association must still map to that same admin policy
   and cluster scope during this stage; the View example only fits an existing
   View association with those exact namespaces.
4. Review each exact state mv or import locally. Keep an authenticated break-glass
   session open. Rehearse on a state copy. Preserve both the entry and association.
   Use a reviewed address-only configuration that represents existing attributes.
   The final typed module can reject old broad operator permissions; if so, stop
   and obtain a separately reviewed transitional configuration. Do not weaken its
   validation, fabricate a no-op plan or combine the two stages to bypass this gate.
5. Save terraform show -json output for the **old state before migration** and
   the actual **post-address-migration saved plan** from the rehearsal. Run
   bash scripts/access-entry-review.sh state-show.json mapping.json saved-plan.json.
   It requires the complete planned entry/association target set to match the
   mapping, preserving old principal, cluster, policy and scope. Planned policy/scope
   must equal both the old state and mapping (namespace order does not matter).
   It rejects missing/unrelated targets, incomplete pairs, duplicate addresses,
   any policy/scope changes, in-place access updates and access create/delete. An old no-op plan or
   a plan without `planned_values` is not evidence of the proposed migration.
6. Review namespace permissions and run live kubectl auth can-i checks per principal
   before closing the existing session. Preserve backup until the rollback window ends.

## Stage 2: separately reviewed least-privilege association change

Only after the address-only migration is complete, create a separate saved plan
for the final typed policy/scope inputs. In AWS provider 5.87.0, `policy_arn` and
`access_scope` (including namespaces/type) are `ForceNew`; an Admin-to-View or
scope change replaces the association, not an in-place update. See the
[pinned provider source](https://github.com/hashicorp/terraform-provider-aws/blob/v5.87.0/internal/service/eks/access_policy_association.go).

Review exact association replacements, unchanged principal/cluster identities,
the desired namespace privileges and any temporary access gap. AccessEntry
creation/deletion/replacement remains prohibited. Keep an independent tested
break-glass session, explicitly approve the separate plan and rollback procedure,
then verify `kubectl auth can-i` per principal after the user-run change.
This migration helper deliberately rejects that replacement plan and does not
approve or execute Stage 2. Do not remove its create/delete guard to proceed.

State validation is STATIC and does not perform a migration. Address-stage recovery
uses the backed-up exact state and prior configuration under operator approval.
After a real association-policy change, restoring state alone does not restore AWS
authorization; the separately reviewed rollback must restore the association and
verify effective access. IAM users and controller ServiceAccounts are not accepted.
