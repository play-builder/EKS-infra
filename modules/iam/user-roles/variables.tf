variable "admin_iam_users" {
  description = "List of IAM User names to grant cluster-admin access"
  type        = list(string)
  default     = []
}

variable "developer_iam_roles" {
  description = "List of IAM Role ARNs to grant developer access (roles assumed by dev group members)"
  type        = list(string)
  default     = []
}

variable "readonly_iam_roles" {
  description = "List of IAM Role ARNs to grant read-only access"
  type        = list(string)
  default     = []
}