mock_provider "aws" {}

variables {
  name                                 = "dev-course"
  cluster_name                         = "dev-course-eks"
  vpc_id                               = "vpc-12345678"
  public_subnet_ids                    = ["subnet-public"]
  private_subnet_ids                   = ["subnet-private"]
  cluster_endpoint_public_access_cidrs = ["203.0.113.10/32"]
  vpc_cni_addon_version                = "v1.20.4-eksbuild.1"
}

run "ch03_network_policy_disabled" {
  command = plan
  variables {
    vpc_cni_enable_network_policy = false
  }
  assert {
    condition     = output.vpc_cni_network_policy_enabled == false
    error_message = "Ch03 baseline must leave network policy disabled"
  }
}

run "ch14_standard_enforcement" {
  command = plan
  variables {
    vpc_cni_enable_network_policy         = true
    vpc_cni_network_policy_enforcing_mode = "standard"
  }
  assert {
    condition     = output.vpc_cni_network_policy_enforcing_mode == "standard"
    error_message = "Ch14 must first enable standard enforcement"
  }
}

run "strict_without_runtime_gate_is_rejected" {
  command = plan
  variables {
    vpc_cni_enable_network_policy         = true
    vpc_cni_network_policy_enforcing_mode = "strict"
  }
  expect_failures = [aws_eks_addon.vpc_cni]
}
