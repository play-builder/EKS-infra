# ============================================
# Bastion Module Outputs
# ============================================

output "instance_id" {
  description = "Bastion Host instance ID"
  value       = aws_instance.bastion.id
}

output "instance_arn" {
  description = "Bastion Host instance ARN"
  value       = aws_instance.bastion.arn
}

output "public_ip" {
  description = "Elastic IP associated with Bastion Host"
  value       = aws_eip.bastion.public_ip
}

output "public_dns" {
  description = "Public DNS name"
  value       = aws_instance.bastion.public_dns
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.bastion.private_ip
}

output "security_group_id" {
  description = "Security group ID of Bastion Host"
  value       = aws_security_group.bastion.id
}

output "ami_id" {
  description = "AMI ID used for Bastion Host"
  value       = aws_instance.bastion.ami
}

output "ssh_command" {
  description = "SSH command to connect to Bastion"
  value       = "ssh -i private-key/${var.instance_keypair}.pem ec2-user@${aws_eip.bastion.public_ip}"
}