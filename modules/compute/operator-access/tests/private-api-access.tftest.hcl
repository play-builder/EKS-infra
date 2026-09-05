mock_provider "aws" {}

variables {
  name              = "prod-course"
  vpc_id            = "vpc-0123456789abcdef0"
  subnet_id         = "subnet-0123456789abcdef0"
  cluster_arn       = "arn:aws:eks:ap-northeast-2:123456789012:cluster/prod-course-eks"
  operator_role_arn = "arn:aws:iam::123456789012:role/AWSReservedSSO_PlatformOperator"
  ami_id            = "ami-0123456789abcdef0"
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
}

run "rejects_ssh_operator_mode" {
  command = plan
  variables { mode = "ssh" }
  expect_failures = [var.mode]
}
