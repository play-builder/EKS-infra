# ============================================
# Bastion Module - Main Configuration
# ============================================

# ============================================
# Data Source: Latest Amazon Linux 2 AMI
# ============================================
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ============================================
# Security Group for Bastion Host
# ============================================
resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion-sg"
  description = "Security group for Bastion Host"
  vpc_id      = var.vpc_id

  # Ingress: SSH from allowed CIDR blocks
  ingress {
    description = "SSH from allowed IPs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # Egress: Allow all outbound
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-bastion-sg"
    }
  )
}

# ============================================
# EC2 Instance: Bastion Host
# ============================================
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.instance_type
  key_name               = var.instance_keypair
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.bastion.id]

  # Enable detailed monitoring
  monitoring = true

  # User data for initial setup
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y nc wget curl
              EOF

  # Root volume
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true
  }

  # IMDSv2 required
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-bastion-host"
    }
  )
}

# ============================================
# Elastic IP for Bastion Host
# ============================================
resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-bastion-eip"
    }
  )

  depends_on = [aws_instance.bastion]
}
