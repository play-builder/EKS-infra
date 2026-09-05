locals {
  operator_role_name = element(reverse(split("/", var.operator_role_arn)), 0)
}

resource "aws_security_group" "operator" {
  name        = "${var.name}-operator-ssm"
  description = "Outbound-only security group for the private SSM operator instance"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to SSM, EKS, and ECR endpoints through private networking"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_iam_role" "instance" {
  name = "${var.name}-operator-ssm-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-operator-ssm"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "operator" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.operator.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(var.tags, { Name = "${var.name}-operator-ssm" })
}

resource "aws_iam_role_policy" "operator_eks" {
  name = "${var.name}-private-eks-operator"
  role = local.operator_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:AccessKubernetesApi",
        "eks:DescribeAccessEntry",
        "eks:DescribeCluster",
        "eks:ListAccessEntries"
      ]
      Resource = var.cluster_arn
    }]
  })
}
