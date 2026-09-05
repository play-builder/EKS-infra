variable "identifier" {
  type     = string
  nullable = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.identifier)) && !endswith(var.identifier, "-") && !strcontains(var.identifier, "--")
    error_message = "Use a canonical RDS identifier of at most 63 lowercase letters, digits and single hyphens."
  }
}
variable "vpc_id" {
  type     = string
  nullable = false
  validation {
    condition     = can(regex("^vpc-([a-f0-9]{8}|[a-f0-9]{17})$", var.vpc_id))
    error_message = "Use an actual VPC ID."
  }
}
variable "subnet_ids" {
  type     = set(string)
  nullable = false
  validation {
    condition     = length(var.subnet_ids) >= 2 && alltrue([for id in var.subnet_ids : can(regex("^subnet-([a-f0-9]{8}|[a-f0-9]{17})$", id))])
    error_message = "At least two distinct database subnet IDs are required."
  }
}
variable "client_security_group_ids" {
  type     = set(string)
  nullable = false
  validation {
    condition     = length(var.client_security_group_ids) > 0 && alltrue([for id in var.client_security_group_ids : can(regex("^sg-([a-f0-9]{8}|[a-f0-9]{17})$", id))])
    error_message = "Explicit client security groups are required; CIDR-wide database ingress is not supported."
  }
}
variable "engine_version" {
  description = "Exact PostgreSQL minor release, verified available in the target Region before plan."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[1-9][0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "Pin an exact PostgreSQL major.minor version; do not use a floating major or latest."
  }
}
variable "instance_class" {
  description = "RDS class whose PostgreSQL version, gp3 and Multi-AZ availability is verified before plan."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "Use an explicit RDS DB instance class. Regional availability must be checked separately."
  }
}
variable "ca_cert_identifier" {
  description = "RDS CA identifier verified for the selected engine/Region; clients separately install the trusted CA bundle."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^rds-ca-[a-z0-9-]+$", var.ca_cert_identifier))
    error_message = "Select an explicit supported RDS CA identifier."
  }
}
variable "database_name" {
  type     = string
  default  = "commerce"
  nullable = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "Use a lowercase PostgreSQL database name of at most 63 characters."
  }
}
variable "master_username" {
  type     = string
  default  = "platform_admin"
  nullable = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,15}$", var.master_username)) && !contains(["postgres", "rdsadmin", "admin", "root"], var.master_username)
    error_message = "Use an explicit non-reserved master username, distinct from application roles."
  }
}
variable "allocated_storage" {
  type     = number
  default  = 20
  nullable = false
  validation {
    condition     = var.allocated_storage >= 20 && floor(var.allocated_storage) == var.allocated_storage
    error_message = "Initial gp3 capacity must be an integer of at least 20 GiB."
  }
}
variable "max_allocated_storage" {
  type     = number
  default  = 100
  nullable = false
  validation {
    condition     = var.max_allocated_storage >= ceil(var.allocated_storage * 1.1) && floor(var.max_allocated_storage) == var.max_allocated_storage
    error_message = "Storage autoscaling maximum must be an integer at least 10 percent above the initial capacity."
  }
}
variable "backup_retention_days" {
  type     = number
  default  = 35
  nullable = false
  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35 && floor(var.backup_retention_days) == var.backup_retention_days
    error_message = "Production backup policy requires 7 to 35 whole days; retention does not prove minute-level RPO."
  }
}
variable "storage_kms_key_arn" {
  description = "Optional pre-existing storage key; null uses the AWS-managed RDS key for a new instance. PITR inherits the source key."
  type        = string
  default     = null
  validation {
    condition     = var.storage_kms_key_arn == null ? true : can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", var.storage_kms_key_arn))
    error_message = "Use a concrete KMS key ARN, not an alias or plaintext key material."
  }
}
variable "deletion_protection" {
  description = "Disable only through a separately reviewed saved plan immediately before approved cleanup."
  type        = bool
  default     = true
  nullable    = false
}
variable "apply_restore_changes_immediately" {
  description = "Explicit temporary opt-in for reviewed reconciliation on an isolated restore target before traffic cutover."
  type        = bool
  default     = false
  nullable    = false
  validation {
    condition     = !var.apply_restore_changes_immediately || var.restore_to_point_in_time != null
    error_message = "Immediate reconciliation is supported only in an isolated PITR root, not the production source root."
  }
}
variable "final_snapshot_identifier" {
  description = "Unique final snapshot identifier reserved for this DB lifecycle."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,254}$", var.final_snapshot_identifier)) && !endswith(var.final_snapshot_identifier, "-") && !strcontains(var.final_snapshot_identifier, "--")
    error_message = "A canonical, unique final snapshot identifier is required; final snapshots cannot be skipped."
  }
}
variable "restore_to_point_in_time" {
  description = "Optional same-account/Region isolated source and exactly one restore time selector."
  type = object({
    source_db_instance_identifier = string
    restore_time                  = optional(string)
    use_latest_restorable_time    = optional(bool, false)
  })
  default = null
  validation {
    condition = var.restore_to_point_in_time == null ? true : (
      can(regex("^[a-z][a-z0-9-]{0,62}$", var.restore_to_point_in_time.source_db_instance_identifier)) &&
      !endswith(var.restore_to_point_in_time.source_db_instance_identifier, "-") &&
      !strcontains(var.restore_to_point_in_time.source_db_instance_identifier, "--") &&
      var.restore_to_point_in_time.source_db_instance_identifier != var.identifier &&
      ((var.restore_to_point_in_time.restore_time != null) != var.restore_to_point_in_time.use_latest_restorable_time) &&
      (var.restore_to_point_in_time.restore_time == null ? true : can(regex("Z$", var.restore_to_point_in_time.restore_time)) && can(timecmp(var.restore_to_point_in_time.restore_time, "2000-01-01T00:00:00Z")))
    )
    error_message = "PITR must create a different identifier and specify exactly one of UTC restore_time or use_latest_restorable_time=true."
  }
}
variable "recovery_objectives" {
  description = "Recovery targets, not achieved results or a replacement for SQL integrity evidence."
  type = object({
    rpo_minutes        = number
    rto_minutes        = number
    drill_max_age_days = number
  })
  default = {
    rpo_minutes        = 60
    rto_minutes        = 120
    drill_max_age_days = 30
  }
  nullable = false
  validation {
    condition     = alltrue([for v in values(var.recovery_objectives) : v > 0 && floor(v) == v])
    error_message = "RPO minutes, RTO minutes and maximum drill age days must be positive integers."
  }
}
variable "tags" {
  type     = map(string)
  nullable = false
  validation {
    condition     = alltrue([for key in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(length(trimspace(var.tags[key])) > 0, false)]) && try(var.tags.Environment == "prod", false)
    error_message = "Nonempty PlatformInstanceId, Owner, CostCenter and Environment=prod tags are required."
  }
}
