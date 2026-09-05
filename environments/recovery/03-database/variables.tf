variable "expected_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "An explicit AWS account ID is required."
  }
}
variable "aws_region" { type = string }
variable "state_bucket" { type = string }
variable "state_region" { type = string }
variable "identifier" { type = string }
variable "engine_version" { type = string }
variable "instance_class" { type = string }
variable "ca_cert_identifier" { type = string }
variable "client_security_group_ids" { type = set(string) }
variable "final_snapshot_identifier" { type = string }
variable "database_name" {
  type    = string
  default = "commerce"
}
variable "backup_retention_days" {
  type    = number
  default = 35
}
variable "max_allocated_storage" {
  type    = number
  default = 100
}
variable "deletion_protection" {
  type    = bool
  default = true
}
variable "tags" { type = map(string) }
variable "recovery_objectives" {
  type    = object({ rpo_minutes = number, rto_minutes = number, drill_max_age_days = number })
  default = { rpo_minutes = 60, rto_minutes = 120, drill_max_age_days = 30 }
}

variable "recovery_cluster_name" { type = string }
variable "restore_time" { type = string }
variable "apply_restore_changes_immediately" {
  type    = bool
  default = false
}
