output "contract" {
  value = {
    ownerMode                   = var.configuration.ownership_mode
    scanType                    = var.configuration.scan_type
    scanFrequency               = var.configuration.scan_frequency
    requiredRepositories        = var.required_repositories
    repositoryFilters           = var.configuration.repository_filters
    scanOnPushRepositoryFilters = var.configuration.scan_on_push_repository_filters
    handoffRequired             = var.configuration.ownership_mode == "terraform"
    liveVerified                = false
  }
}
