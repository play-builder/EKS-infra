# ============================================
# Networking Module Outputs
# ============================================

# VPC
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "vpc_arn" {
  description = "VPC ARN"
  value       = aws_vpc.this.arn
}

# Subnets
output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "Database subnet IDs"
  value       = aws_subnet.database[*].id
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  value       = aws_subnet.public[*].cidr_block
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  value       = aws_subnet.private[*].cidr_block
}

# Route Tables
output "public_route_table_ids" {
  description = "Public route table IDs"
  value       = [aws_route_table.public.id]
}

output "private_route_table_ids" {
  description = "Private route table IDs"
  value       = aws_route_table.private[*].id
}

# NAT Gateways
output "nat_gateway_ids" {
  description = "NAT Gateway IDs"
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway public IPs"
  value       = aws_eip.nat[*].public_ip
}

# Internet Gateway
output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.this.id
}

# Availability Zones
output "availability_zones" {
  description = "List of availability zones"
  value       = var.availability_zones
}