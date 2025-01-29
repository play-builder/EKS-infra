variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "namespace" {
  description = "Namespace where Ingress will be created"
  type        = string
  default     = "default"
}

variable "acm_certificate_arn" {
  description = "Existing ACM certificate ARN (required when create_acm_certificate=false)"
  type        = string
}

variable "ingress_name" {
  description = "Ingress resource name"
  type        = string
  default     = "alb-ssl-ingress"
}

variable "ingress_class_name" {
  description = "Ingress Class name"
  type        = string
  default     = "my-aws-ingress-class"
}

variable "load_balancer_name" {
  description = "ALB name (for AWS Console display)"
  type        = string
  default     = "ssl-ingress-alb"
}

variable "alb_scheme" {
  description = "ALB scheme (internet-facing, internal)"
  type        = string
  default     = "internet-facing"
}

variable "ingress_hostnames" {
  description = "List of hostnames to connect to Ingress (for ExternalDNS integration)"
  type        = list(string)
  default     = []
}

variable "additional_annotations" {
  description = "Additional annotations to merge into Ingress resource (e.g., group.name, group.order)"
  type        = map(string)
  default     = {}
}

variable "ssl_redirect_enabled" {
  description = "Enable HTTP to HTTPS redirect"
  type        = bool
  default     = true
}

variable "ssl_policy" {
  description = "SSL security policy"
  type        = string
  default     = "ELBSecurityPolicy-TLS-1-2-2017-01"
}

variable "health_check" {
  description = "ALB health check default settings"
  type = object({
    protocol            = string
    port                = string
    interval_seconds    = number
    timeout_seconds     = number
    healthy_threshold   = number
    unhealthy_threshold = number
    success_codes       = string
  })
  default = {
    protocol            = "HTTP"
    port                = "traffic-port"
    interval_seconds    = 15
    timeout_seconds     = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    success_codes       = "200"
  }
}

variable "backend_services" {
  description = "List of backend services to connect to Ingress"
  type = list(object({
    name              = string
    port              = number
    path              = string
    path_type         = string
    health_check_path = string
    is_default        = bool
  }))
}

variable "hosted_zone_id" {
  description = "Route53 Hosted Zone ID for ACM certificate validation"
  type        = string
  default     = null
}

variable "tags" {
  description = "AWS resource tags"
  type        = map(string)
  default     = {}
}
