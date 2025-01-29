variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
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
  default     = false
}

variable "enable_alb_controller" {
  description = "Enable AWS Load Balancer Controller"
  type        = bool
  default     = true
}

variable "alb_controller_chart_version" {
  description = "Helm chart version"
  type        = string
  default     = ""
}

variable "alb_controller_image_repository" {
  description = "Docker image repository"
  type        = string
  default     = "602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon/aws-load-balancer-controller"
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
  default     = "1.14.5"
}

variable "external_dns_domain_filters" {
  description = "List of domains for ExternalDNS to manage"
  type        = list(string)
  default     = ["playdevops.click"]
}

variable "enable_metrics_server" {
  description = "Enable Metrics Server installation"
  type        = bool
  default     = true
}

variable "metrics_server_chart_version" {
  description = "Metrics Server Helm chart version"
  type        = string
  default     = "3.12.0"
}

variable "enable_cluster_autoscaler" {
  description = "Enable Cluster Autoscaler installation"
  type        = bool
  default     = true
}

variable "cluster_autoscaler_chart_version" {
  description = "Cluster Autoscaler Helm chart version"
  type        = string
  default     = "9.37.0"
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights"
  type        = bool
  default     = true
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
