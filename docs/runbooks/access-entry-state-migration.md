# Access Entry state migration
Existing installations must complete this operator-reviewed state migration before
applying the new 02-eks root. No live state was inspected during implementation.

1. Back up the exact backend state and record account/Region/backend/source identity.
2. Use terraform state list and state show to inventory every external principal entry
   and its policy association. Sources are module.eks_cluster creator[0]/admin[ARN]
   and module.operator_access operator addresses.
3. Build a JSON array of oldAddress, newAddress and principalArn. Targets are
   module.access_entries.aws_eks_access_entry.this["SEMANTIC-KEY"] and
   module.access_entries.aws_eks_access_policy_association.this["SEMANTIC-KEY"].
   Use platform-break-glass, platform-operator, release-automation, developer-readonly.
   Capture actual addresses; no universal ARN-indexed moved block is valid.
4. Review each exact state mv or import locally. Keep an authenticated break-glass
   session open. Rehearse on a state copy. Preserve both the entry and association.
5. Save terraform show -json output for the state and proposed plan. Run
   bash scripts/access-entry-review.sh state-show.json mapping.json saved-plan.json.
   It rejects omissions, duplicate principals/targets and access create/delete.
6. Review namespace permissions and run live kubectl auth can-i checks per principal
   before closing the existing session. Preserve backup until the rollback window ends.

The module's resource address changes intentionally require migration; applying a
replacement plan is prohibited. State validation is STATIC and does not perform a
migration. Recovery uses the backed-up exact state and prior configuration under
operator approval. IAM users and controller ServiceAccounts are not accepted.
