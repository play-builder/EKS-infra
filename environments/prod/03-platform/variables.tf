variable "aws_region" {
  description = "AWS Region"
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "playdevops"
}

variable "state_bucket_name" {
  description = "Exact S3 bucket name that stores this environment's Terraform states"
  type        = string
}

variable "course_id" {
  description = "Unique CourseId binding all course-owned resources and cleanup evidence"
  type        = string
  default     = "course-2026"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be a unique 8-63 character lowercase identifier."
  }
}

variable "division" {
  description = "Organizational or technical division"
  type        = string
  default     = "CloudInfra"
}

variable "acm_domain_name" {
  description = "Domain name for ACM certificate (e.g., playdevops.click)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 Hosted Zone ID (for DNS validation and ExternalDNS)"
  type        = string
}

variable "enable_ebs_csi_driver" {
  description = "Enable EBS CSI Driver add-on"
  type        = bool
  default     = true
}

variable "ebs_csi_driver_addon_version" {
  description = "EBS CSI Driver add-on version"
  type        = string
  default     = ""
}

variable "ebs_csi_driver_resolve_conflicts_on_create" {
  description = "How to resolve conflicts"
  type        = string
  default     = "OVERWRITE"
}

variable "ebs_csi_driver_use_aws_managed_policy" {
  description = "Use AWS managed IAM policy"
  type        = bool
  default     = true
}

variable "enable_course_storage_class" {
  description = "Create the non-default encrypted gp3 StorageClass used by the Stateful course lab"
  type        = bool
  default     = true
}

variable "enable_alb_controller" {
  description = "Enable AWS Load Balancer Controller"
  type        = bool
  default     = true
}

variable "alb_controller_chart_version" {
  description = "Helm chart version"
  type        = string
  default     = "3.5.0"
}

variable "alb_controller_ecr_account_id" {
  description = "AWS-owned ECR account ID that publishes the Load Balancer Controller image in aws_region"
  type        = string
  default     = "602401143452"
}

variable "alb_controller_ingress_class_name" {
  description = "Name of the Ingress Class"
  type        = string
  default     = "alb"
}

variable "alb_controller_is_default" {
  description = "Set as default Ingress Class"
  type        = bool
  default     = true
}

variable "enable_external_dns" {
  description = "Enable ExternalDNS add-on"
  type        = bool
  default     = true
}

variable "external_dns_chart_version" {
  description = "Helm chart version"
  type        = string
  default     = "1.21.1"
}

variable "external_dns_domain_filters" {
  description = "List of domains for ExternalDNS to manage"
  type        = list(string)
  default     = ["playdevops.click"]
}

variable "external_dns_exclude_domains" {
  description = "Subdomains that ExternalDNS must not manage"
  type        = list(string)
  default     = []
}

variable "enable_metrics_server" {
  description = "Enable Metrics Server installation"
  type        = bool
  default     = true
}

variable "metrics_server_chart_version" {
  description = "Metrics Server Helm chart version"
  type        = string
  default     = "3.14.0"
}

variable "enable_cluster_autoscaler" {
  description = "Enable Cluster Autoscaler installation"
  type        = bool
  default     = false
}

variable "cluster_autoscaler_chart_version" {
  description = "Cluster Autoscaler Helm chart version"
  type        = string
  default     = "9.59.0"
}

variable "enable_container_insights" {
  type    = bool
  default = true
  validation {
    condition     = var.enable_container_insights
    error_message = "Production requires the protected application and performance log collectors."
  }
}

variable "cloudwatch_agent_chart_version" {
  description = "CloudWatch Metrics Helm chart version"
  type        = string
  default     = "0.0.9"
}

variable "fluent_bit_chart_version" {
  description = "Fluent Bit Helm chart version"
  type        = string
  default     = "0.1.32"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

# ADOT Collector
variable "enable_adot_collector" {
  description = "Enable ADOT Collector for metrics/logs collection (replaces Container Insights)"
  type        = bool
  default     = true
}

# Amazon Managed Service for Prometheus
variable "enable_amp" {
  description = "Enable Amazon Managed Service for Prometheus"
  type        = bool
  default     = true
}

variable "amp_retention_days" {
  description = "AMP metrics retention in days"
  type        = number
  default     = 90
}

# Amazon Managed Grafana
variable "enable_amg" {
  description = "Enable Amazon Managed Grafana"
  type        = bool
  default     = false
}

variable "amg_authentication_providers" {
  description = "Authentication providers for AMG (AWS_SSO or SAML)"
  type        = list(string)
  default     = ["AWS_SSO"]
}

variable "enable_external_secrets" {
  description = "Install the Terraform-owned External Secrets controller from the Ch03 baseline"
  type        = bool
  default     = true
}

variable "external_secrets_chart_version" {
  description = "Pinned External Secrets chart version"
  type        = string
  default     = "2.10.0"
}

variable "external_secrets_ownership_mode" {
  description = "fresh creates a new release; adopted requires reviewed runtime adoption evidence"
  type        = string
  default     = "fresh"

  validation {
    condition     = contains(["fresh", "adopted"], var.external_secrets_ownership_mode)
    error_message = "external_secrets_ownership_mode must be fresh or adopted."
  }
}

variable "external_secrets_adoption_evidence_path" {
  description = "Path to course.platform-release-adoption/v1 evidence for an existing release"
  type        = string
  default     = null
  nullable    = true
}

variable "enable_reloader" {
  description = "Enable Reloader at the first Ch12 platform apply"
  type        = bool
  default     = false
}

variable "reloader_chart_version" {
  description = "Pinned Stakater Reloader chart version"
  type        = string
  default     = "2.2.16"
}

variable "enable_adot_xray" {
  description = "Enable OTLP trace ingestion and the AWS X-Ray exporter"
  type        = bool
  default     = false
}

variable "enable_amp_alerting" {
  description = "Enable AMP recording rules and Alertmanager only when explicitly approved"
  type        = bool
  default     = false
}

variable "amp_alert_owner" {
  type    = string
  default = "platform"
}

variable "amp_runbook_url" {
  type    = string
  default = "https://github.com/play-builder/EKS-infra/blob/main/docs/runbooks/amp-slo.md"
}

variable "slo" {
  type = object({
    success_target                = number
    latency_ms_target             = number
    short_window                  = string
    long_window                   = string
    short_burn_threshold          = number
    long_burn_threshold           = number
    traffic_floor_rps             = number
    paging_severity               = string
    escalation_route              = string
    alert_resolve_timeout_minutes = number
  })
  default = {
    success_target                = 0.999
    latency_ms_target             = 500
    short_window                  = "5m"
    long_window                   = "1h"
    short_burn_threshold          = 14.4
    long_burn_threshold           = 14.4
    traffic_floor_rps             = 0.1
    paging_severity               = "critical"
    escalation_route              = "platform-sns"
    alert_resolve_timeout_minutes = 15
  }
  validation {
    condition     = var.slo.success_target > 0 && var.slo.success_target < 1 && var.slo.latency_ms_target > 0 && var.slo.traffic_floor_rps > 0 && var.slo.short_burn_threshold > 0 && var.slo.long_burn_threshold > 0 && var.slo.alert_resolve_timeout_minutes > 0
    error_message = "SLO targets, burn thresholds, traffic floor and resolve timeout must be positive; success_target must be below one."
  }
  validation {
    condition     = can(regex("^[1-9][0-9]*[mh]$", var.slo.short_window)) && can(regex("^[1-9][0-9]*[mh]$", var.slo.long_window)) && try(tonumber(trimsuffix(trimsuffix(var.slo.short_window, "m"), "h")) * (endswith(var.slo.short_window, "h") ? 60 : 1) < tonumber(trimsuffix(trimsuffix(var.slo.long_window, "m"), "h")) * (endswith(var.slo.long_window, "h") ? 60 : 1), false)
    error_message = "Use positive minute/hour windows with short strictly below long."
  }
  validation {
    condition     = contains(["warning", "critical"], var.slo.paging_severity) && can(regex("^[a-z][a-z0-9-]+$", var.slo.escalation_route))
    error_message = "Use a bounded severity and an explicit receiver name."
  }
}

variable "enable_sns_alert_delivery" {
  description = "Enable SNS alert delivery after an endpoint is supplied"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_sns_alert_delivery || var.enable_amp_alerting
    error_message = "enable_sns_alert_delivery requires enable_amp_alerting=true."
  }
}

variable "sns_alert_email_endpoint" {
  description = "Optional email endpoint; confirmation is verified at runtime"
  type        = string
  default     = null
  nullable    = true
}

variable "enable_k6_operator" {
  description = "Course load generation is Dev-only and must stay disabled in Prod"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_k6_operator
    error_message = "K6_OPERATOR_DEV_ONLY: Prod must not install the course load controller."
  }
}

variable "enable_chaos_mesh" {
  description = "Enable the Ch25 Dev-only Chaos Mesh controller"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_chaos_mesh
    error_message = "CHAOS_MESH_DEV_ONLY: Chaos Mesh may not be enabled in prod."
  }
}

variable "chaos_mesh_chart_version" {
  description = "Pinned Chaos Mesh Helm chart version"
  type        = string
  default     = "2.8.0"
}

variable "chaos_mesh_namespace" {
  description = "Dedicated Chaos Mesh namespace"
  type        = string
  default     = "chaos-mesh"
}

variable "chaos_mesh_allowed_namespaces" {
  description = "Application namespaces eligible for Ch25 faults"
  type        = list(string)
  default     = ["app-dev"]
}

variable "chaos_mesh_max_fault_duration_seconds" {
  description = "Maximum duration for one Ch25 fault"
  type        = number
  default     = 60
}

variable "chaos_mesh_max_faults" {
  description = "Maximum number of simultaneous Ch25 faults"
  type        = number
  default     = 1

  validation {
    condition     = var.chaos_mesh_max_faults == 1
    error_message = "Ch25 admits exactly one fault per game-day run."
  }
}

variable "chaos_mesh_controller_cloud_wait_seconds" {
  description = "Readiness wait budget declared for Chaos Mesh"
  type        = number
  default     = 600
}

variable "k6_operator_chart_version" {
  description = "Pinned Grafana k6 operator chart version"
  type        = string
  default     = "4.6.0"
}

variable "k6_operator_namespace" {
  description = "Dedicated controller namespace for k6"
  type        = string
  default     = "k6-operator-system"
}

variable "enable_snapshot_controller" {
  description = "Enable the EKS managed snapshot-controller add-on at Ch23"
  type        = bool
  default     = false
}

variable "snapshot_controller_addon_version" {
  description = "Pinned EKS managed snapshot-controller add-on version"
  type        = string
  default     = "v8.2.0-eksbuild.1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.snapshot_controller_addon_version))
    error_message = "snapshot_controller_addon_version must be a pinned EKS add-on version."
  }
}

variable "volume_snapshot_class_name" {
  description = "Course-owned VolumeSnapshotClass name"
  type        = string
  default     = "course-ebs-snapshots"
}

variable "snapshot_driver" {
  description = "CSI driver used by the course VolumeSnapshotClass"
  type        = string
  default     = "ebs.csi.aws.com"

  validation {
    condition     = var.snapshot_driver == "ebs.csi.aws.com"
    error_message = "snapshot_driver must be ebs.csi.aws.com."
  }
}

variable "enable_recovery_secret_reader" {
  description = "Recovery DB secret reader is Dev-only"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_recovery_secret_reader
    error_message = "RECOVERY_SECRET_READER_DEV_ONLY: Prod must not create the recovery DB secret role."
  }
}
variable "autoscaling_mode" {
  type    = string
  default = "mng_cluster_autoscaler"
  validation {
    condition     = contains(["fixed", "mng_cluster_autoscaler"], var.autoscaling_mode) && (var.environment != "prod" || (var.autoscaling_mode == "mng_cluster_autoscaler" && var.enable_cluster_autoscaler))
    error_message = "Production requires enabled managed-node Cluster Autoscaler."
  }
}
variable "autoscaler_capacity" {
  type = object({
    min_nodes                    = number
    max_nodes                    = number
    max_pods_per_node            = number
    hpa_max_replicas             = number
    rollout_surge_replicas       = number
    platform_reserve_pods        = number
    stable_replicas              = number
    canary_replicas              = number
    usable_subnet_ips_by_az      = map(number)
    required_headroom_percentage = number
  })
  validation {
    condition = (
      var.autoscaler_capacity.min_nodes >= 1 &&
      var.autoscaler_capacity.max_nodes >= var.autoscaler_capacity.min_nodes &&
      var.autoscaler_capacity.max_pods_per_node >= 1 &&
      alltrue([for n in [var.autoscaler_capacity.hpa_max_replicas, var.autoscaler_capacity.rollout_surge_replicas, var.autoscaler_capacity.platform_reserve_pods, var.autoscaler_capacity.stable_replicas, var.autoscaler_capacity.canary_replicas] : n >= 0 && floor(n) == n]) &&
      var.autoscaler_capacity.required_headroom_percentage >= 10 &&
      var.autoscaler_capacity.required_headroom_percentage <= 100 &&
      (max(var.autoscaler_capacity.hpa_max_replicas, var.autoscaler_capacity.stable_replicas + var.autoscaler_capacity.canary_replicas) + var.autoscaler_capacity.rollout_surge_replicas + var.autoscaler_capacity.platform_reserve_pods) * (1 + var.autoscaler_capacity.required_headroom_percentage / 100) <= var.autoscaler_capacity.max_nodes * var.autoscaler_capacity.max_pods_per_node &&
      length(var.autoscaler_capacity.usable_subnet_ips_by_az) >= (var.environment == "prod" ? 3 : 2) &&
      alltrue([for ip in values(var.autoscaler_capacity.usable_subnet_ips_by_az) : ip >= ceil(var.autoscaler_capacity.max_nodes / max(length(var.autoscaler_capacity.usable_subnet_ips_by_az), 1)) * var.autoscaler_capacity.max_pods_per_node * (1 + var.autoscaler_capacity.required_headroom_percentage / 100)])
    )
    error_message = "Node/pod capacity and every AZ IP pool must cover workload, surge, reserve and headroom."
  }
}
variable "sigstore_controller_replicas" {
  type    = number
  default = 2
}
variable "sigstore_ecr_repository_arns" { type = set(string) }
variable "sigstore_api_server_cidrs" { type = set(string) }
variable "sigstore_https_egress_cidrs" { type = set(string) }
