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

resource "aws_iam_role" "operator" {
  name = "${var.name}-eks-operator"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = [var.trusted_sso_principal_arn, aws_iam_role.instance.arn] }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "instance_assume_operator" {
  name   = "${var.name}-assume-operator"
  role   = aws_iam_role.instance.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["sts:AssumeRole"], Resource = aws_iam_role.operator.arn }] })
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-operator-ssm"
  role = aws_iam_role.instance.name
  tags = var.tags
}

resource "aws_instance" "operator" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.operator.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    kubectl_version = var.kubectl_version
  })
  user_data_replace_on_change = true

  root_block_device {
    encrypted = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(var.tags, { Name = "${var.name}-operator-ssm" })
}

resource "aws_iam_role_policy" "operator_eks" {
  name = "${var.name}-private-eks-operator"
  role = aws_iam_role.operator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster"
      ]
      Resource = var.cluster_arn
    }]
  })
}

resource "aws_eks_access_entry" "operator" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.operator.arn
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "operator" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.operator.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  access_scope {
    type       = "namespace"
    namespaces = [var.authorization_namespace]
  }
  depends_on = [aws_eks_access_entry.operator]
}
