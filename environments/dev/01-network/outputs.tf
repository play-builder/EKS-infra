output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr
}

output "vpc_arn" {
  description = "VPC ARN"
  value       = module.vpc.vpc_arn
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "database_subnet_ids" {
  description = "Database subnet IDs"
  value       = module.vpc.database_subnet_ids
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  value       = module.vpc.public_subnet_cidrs
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  value       = module.vpc.private_subnet_cidrs
}

output "public_route_table_ids" {
  description = "Public route table IDs"
  value       = module.vpc.public_route_table_ids
}

output "private_route_table_ids" {
  description = "Private route table IDs"
  value       = module.vpc.private_route_table_ids
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs"
  value       = module.vpc.nat_gateway_ids
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway public IPs"
  value       = module.vpc.nat_gateway_public_ips
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = module.vpc.internet_gateway_id
}

output "availability_zones" {
  description = "List of availability zones"
  value       = module.vpc.availability_zones
}

output "eks_cluster_name" {
  description = "EKS Cluster name (for reference)"
  value       = "${var.environment}-${var.project_name}-eks"
}