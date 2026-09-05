mock_provider "aws" {}

variables {
  name                      = "prod-course"
  vpc_id                    = "vpc-0123456789abcdef0"
  subnet_id                 = "subnet-0123456789abcdef0"
  cluster_arn               = "arn:aws:eks:ap-northeast-2:123456789012:cluster/prod-course-eks"
  cluster_security_group_id = "sg-0fedcba9876543210"
  trusted_sso_principal_arn = "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_PlatformOperator_abc123"
  cluster_name              = "prod-course-eks"
  ami_id                    = "ami-0123456789abcdef0"
  tags = {
    PlatformInstanceId = "platform-123"
    Owner              = "platform-sre"
    CostCenter         = "cc-100"
    Environment        = "prod"
  }
}

run "rejects_missing_ownership_tags" {
  command = plan
  variables { tags = {} }
  expect_failures = [var.tags]
}

run "ssm_operator_is_private_and_has_no_ssh_key" {
  command = plan

  assert {
    condition = (
      aws_instance.operator.associate_public_ip_address == false &&
      aws_instance.operator.metadata_options[0].http_tokens == "required" &&
      output.operator_access_status.private_endpoint_required
    )
    error_message = "The operator instance must use IMDSv2 and remain private."
  }

  assert {
    condition = alltrue([
      for key in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] :
      try(length(trimspace(aws_iam_instance_profile.instance.tags[key])) > 0, false) &&
      try(length(trimspace(aws_iam_role.operator.tags[key])) > 0, false)
    ])
    error_message = "Operator identity and EKS access resources must carry the mandatory platform ownership tags."
  }
}

run "rejects_ssh_operator_mode" {
  command = plan
  variables { mode = "ssh" }
  expect_failures = [var.mode]
}

run "operator_can_reach_only_https_on_the_cluster_security_group" {
  command = plan

  override_resource {
    target          = aws_security_group.operator
    override_during = plan
    values          = { id = "sg-0123456789abcdef0" }
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.operator_eks_api.security_group_id == "sg-0fedcba9876543210" &&
      aws_vpc_security_group_ingress_rule.operator_eks_api.referenced_security_group_id == "sg-0123456789abcdef0" &&
      aws_vpc_security_group_ingress_rule.operator_eks_api.ip_protocol == "tcp" &&
      aws_vpc_security_group_ingress_rule.operator_eks_api.from_port == 443 &&
      aws_vpc_security_group_ingress_rule.operator_eks_api.to_port == 443 &&
      aws_vpc_security_group_ingress_rule.operator_eks_api.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.operator_eks_api.cidr_ipv6 == null &&
      aws_vpc_security_group_ingress_rule.operator_eks_api.prefix_list_id == null &&
      contains(aws_instance.operator.vpc_security_group_ids, "sg-0123456789abcdef0")
    )
    error_message = "Private EKS ingress must allow only TCP 443 from the SG actually attached to the operator instance."
  }
}
