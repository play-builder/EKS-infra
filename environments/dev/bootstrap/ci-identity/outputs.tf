output "oidc_provider_arn" { value = local.oidc_provider_arn }

output "infra_role_arn" {
  description = "DEPRECATED/RETIRED: this role denies all operations. Never configure it as a plan, apply or drift role."
  value       = aws_iam_role.infra.arn
}

output "trusted_subject" {
  description = "Legacy subject only; the retired role denies it. Use ci_role_contract for current environment subjects."
  value       = local.infra_main_subject
}

output "ci_role_arns" {
  description = "Validated external roles, or empty when CI is disabled. Map plan/apply/drift to their account-scoped GitHub environments."
  value       = { for purpose, role in data.aws_iam_role.ci : purpose => role.arn }
  depends_on  = [terraform_data.ci_identity]
}

output "ci_role_contract" {
  description = "Identity/state contract only. Service permissions, EKS access entries/RBAC, runner connectivity and live policy simulation remain external prerequisites."
  value = { for purpose, subject in local.ci_subjects : purpose => {
    github_environment            = local.ci_environments[purpose]
    trusted_subject               = subject
    trust_policy_json             = data.aws_iam_policy_document.ci_trust[purpose].json
    state_access_policy_json      = data.aws_iam_policy_document.state_access[purpose].json
    required_boundary_denies_json = data.aws_iam_policy_document.required_boundary_denies[purpose].json
    state_keys                    = local.state_keys
    permission_owner              = "external"
    live_verified                 = false
  } }
}
