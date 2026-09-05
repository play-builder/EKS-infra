mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
}

variables {
  state_bucket_name                    = "course-state"
  aws_region                           = "ap-northeast-2"
  cluster_endpoint_public_access_cidrs = []
  vpc_cni_addon_version                = "v1.20.4-eksbuild.1"
  managed_addon_versions               = { coredns = "v1.12.1-eksbuild.1", kube_proxy = "v1.36.0-eksbuild.1" }
  node_release_version                 = "1.36.0-20260901"
  platform_instance_id                 = "platform-123"
  owner                                = "platform-sre"
  cost_center                          = "cc-100"
  enable_private_node_group            = false
  operator_access = {
    mode                      = "ssm"
    trusted_sso_principal_arn = "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_PlatformOperator_abc123"
    subnet_id                 = "subnet-0123456789abcdef0"
    ami_id                    = "ami-0123456789abcdef0"
    instance_type             = "t3.micro"
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      eks_cluster_name   = "prod-course-eks"
      logging_contract   = { cluster_name = "prod-course-eks", aws_region = "ap-northeast-2", account_id = "123456789012", kms_key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555", log_group_names = { control_plane = "/aws/eks/prod-course-eks/cluster" } }
      audit_log_groups   = {}
      vpc_id             = "vpc-0123456789abcdef0"
      public_subnet_ids  = ["subnet-00123456789abcdef"]
      private_subnet_ids = ["subnet-0123456789abcdef0"]
    }
  }
}

override_module {
  target = module.eks_cluster
  outputs = {
    cluster_id                            = "prod-course-eks"
    cluster_name                          = "prod-course-eks"
    cluster_arn                           = "arn:aws:eks:ap-northeast-2:123456789012:cluster/prod-course-eks"
    cluster_endpoint                      = "https://eks.example.invalid"
    cluster_version                       = "1.36"
    cluster_certificate_authority_data    = "ZmFrZQ=="
    cluster_security_group_id             = "sg-0fedcba9876543210"
    oidc_provider_arn                     = "arn:aws:iam::123456789012:oidc-provider/eks.example.invalid"
    oidc_provider                         = "eks.example.invalid"
    vpc_cni_addon_version                 = "v1.20.4-eksbuild.1"
    vpc_cni_network_policy_enabled        = false
    vpc_cni_network_policy_enforcing_mode = "standard"
    audit_log_groups                      = {}
  }
}

run "prod_connects_operator_ingress_to_its_eks_cluster" {
  command = plan

  assert {
    condition = (
      output.operator_access_status.cluster_security_group_id == "sg-0fedcba9876543210" &&
      output.operator_access_status.cluster_security_group_id == output.cluster_security_group_id
    )
    error_message = "The production operator ingress must target the security group exported by this EKS cluster."
  }
}
