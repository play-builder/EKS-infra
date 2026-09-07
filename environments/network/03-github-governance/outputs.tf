output "ruleset_id" {
  value = github_repository_ruleset.main_protection.ruleset_id
}

output "repository_delivery_settings" {
  value = {
    allow_auto_merge       = github_repository.gitops_settings.allow_auto_merge
    allow_squash_merge     = github_repository.gitops_settings.allow_squash_merge
    allow_merge_commit     = github_repository.gitops_settings.allow_merge_commit
    allow_rebase_merge     = github_repository.gitops_settings.allow_rebase_merge
    delete_branch_on_merge = github_repository.gitops_settings.delete_branch_on_merge
    vulnerability_alerts   = github_repository_vulnerability_alerts.gitops.enabled
  }
}
