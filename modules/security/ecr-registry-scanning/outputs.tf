output "contract" {
  value = { ownerMode = var.configuration.ownership_mode, scanType = var.configuration.scan_type, scanFrequency = var.configuration.scan_frequency, repositoryFilters = var.configuration.repository_filters, handoffRequired = true }
}
