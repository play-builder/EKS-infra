# ============================================
# Bastion Module Variables
# ============================================

variable "name" {
  description = "Name prefix for resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID for bastion"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "instance_keypair" {
  description = "EC2 Key Pair name"
  type        = string
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed to SSH"
  type        = list(string)
  default     = []
}

variable "private_key_path" {
  description = "Path to private key for provisioning"
  type        = string
  default     = "private-key/eks-terraform-key.pem"
}

variable "enable_provisioners" {
  description = "Enable provisioners (file, remote-exec)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}