mock_provider "aws" {}

variables {
  name                 = "prod-course"
  environment          = "prod"
  vpc_cidr             = "10.1.0.0/16"
  availability_zones   = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
  private_subnet_cidrs = ["10.1.11.0/24", "10.1.12.0/24", "10.1.13.0/24"]
  eks_cluster_name     = "prod-course-eks"
  tags = {
    PlatformInstanceId = "platform-123"
    Owner              = "platform-sre"
    CostCenter         = "cc-100"
    Environment        = "prod"
  }
}

run "rejects_missing_production_ownership_tags" {
  command = plan

  variables {
    tags                    = {}
    enable_nat_gateway      = true
    single_nat_gateway      = false
    one_nat_gateway_per_az  = true
    production_nat_topology = "per_az"
    enable_vpc_flow_logs    = true
  }

  expect_failures = [var.tags]
}

run "rejects_single_nat_for_prod" {
  command = plan

  variables {
    enable_nat_gateway      = true
    single_nat_gateway      = true
    one_nat_gateway_per_az  = false
    production_nat_topology = "per_az"
  }

  expect_failures = [var.production_nat_topology]
}

run "creates_one_nat_route_per_az_and_flow_logs" {
  command = plan

  variables {
    enable_nat_gateway      = true
    single_nat_gateway      = false
    one_nat_gateway_per_az  = true
    production_nat_topology = "per_az"
    enable_vpc_flow_logs    = true
  }

  assert {
    condition     = length(output.nat_gateway_ids_by_az) == 3
    error_message = "Production per-AZ NAT topology must expose one NAT gateway ID for every selected AZ."
  }

  assert {
    condition     = aws_flow_log.vpc[0].traffic_type == "ALL"
    error_message = "VPC Flow Logs must capture all accepted and rejected VPC traffic."
  }

  assert {
    condition = alltrue([
      for key in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] :
      try(length(trimspace(aws_flow_log.vpc[0].tags[key])) > 0, false)
    ])
    error_message = "VPC Flow Logs must carry the mandatory platform ownership tags."
  }
}
