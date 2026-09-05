
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

output "public_route_table_ids" {
  description = "Public route table IDs"
  value       = [aws_route_table.public.id]
}

output "private_route_table_ids" {
  description = "Private route table IDs"
  value       = aws_route_table.private[*].id
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs"
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_ids_by_az" {
  description = "NAT Gateway IDs keyed by AZ when the per-AZ topology is enabled"
  value = var.enable_nat_gateway && !var.single_nat_gateway && var.one_nat_gateway_per_az ? {
    for index, availability_zone in var.availability_zones : availability_zone => aws_nat_gateway.this[index].id
  } : {}
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway public IPs"
  value       = aws_eip.nat[*].public_ip
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.this.id
}

output "availability_zones" {
  description = "List of availability zones"
  value       = var.availability_zones
}

output "audit_log_groups" {
  value = tomap({ for group in aws_cloudwatch_log_group.vpc_flow : "vpc_flow" => {
    arn            = trimsuffix(group.arn, ":*")
    retention_days = group.retention_in_days
    kms_key_arn    = group.kms_key_id
  } })
}
