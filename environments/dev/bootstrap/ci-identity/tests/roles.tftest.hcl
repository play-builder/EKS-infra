# Real provider renders IAM policy JSON locally. Every remote data read is overridden;
# all runs are plans, with dummy credentials and credential/metadata requests disabled.
provider "aws" {
  region                      = "ap-northeast-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}
override_resource {
  target          = aws_iam_openid_connect_provider.github
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
}
override_data {
  target = data.aws_iam_openid_connect_provider.external
  values = {
    arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    url            = "token.actions.githubusercontent.com"
    client_id_list = ["sts.amazonaws.com"]
  }
}
variables {
  aws_region          = "ap-northeast-2"
  state_bucket_name   = "fixture-state"
  github_owner        = "fixture-owner"
  github_owner_id     = "12345"
  infra_repository_id = "67890"
  external_ci_roles = { for purpose in ["plan", "apply", "drift"] : purpose => {
    role_arn                           = "arn:aws:iam::123456789012:role/fixture-${purpose}"
    permissions_boundary_arn           = "arn:aws:iam::123456789012:policy/fixture-${purpose}-boundary"
    permissions_boundary_policy_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  } }
}
run "prepare_contract" {
  command = plan
  assert {
    condition = output.ci_role_arns == {} && (
      output.ci_role_contract.plan.trusted_subject == "repo:fixture-owner@12345/EKS-infra@67890:environment:dev-plan" &&
      output.ci_role_contract.apply.trusted_subject == "repo:fixture-owner@12345/EKS-infra@67890:environment:dev" &&
      output.ci_role_contract.drift.trusted_subject == "repo:fixture-owner@12345/EKS-infra@67890:environment:dev-drift"
    )
    error_message = "Preparation must grant no CI role and must match the account-scoped workflow environments."
  }
  assert {
    condition = jsondecode(data.aws_iam_policy_document.infra_extra.json).Statement == [{
      Sid = "RetiredRoleDenyAll", Effect = "Deny", Action = "*", Resource = "*"
    }] && jsondecode(aws_iam_role.infra.assume_role_policy).Statement[0].Effect == "Deny"
    error_message = "The legacy broad role must be denied, including previously issued sessions."
  }
}
run "prod_environments" {
  command = plan
  variables { environment = "prod" }
  assert {
    condition     = output.ci_role_contract.plan.github_environment == "production-plan" && output.ci_role_contract.apply.github_environment == "production" && output.ci_role_contract.drift.github_environment == "production-drift" && contains(output.ci_role_contract.apply.state_keys, "prod/03-database/terraform.tfstate")
    error_message = "Wrong account-scoped environment or database state mapping."
  }
}
run "recovery_environments" {
  command = plan
  variables { environment = "recovery" }
  assert {
    condition     = output.ci_role_contract.plan.github_environment == "recovery-plan" && output.ci_role_contract.apply.github_environment == "recovery" && output.ci_role_contract.drift.github_environment == "recovery-drift" && contains(output.ci_role_contract.apply.state_keys, "recovery/03-database/terraform.tfstate")
    error_message = "Wrong account-scoped environment or database state mapping."
  }
}
run "accepts_reviewed_distinct_external_roles" {
  command = plan
  variables {
    enable_external_ci_roles = true
    external_ci_roles = { for purpose in ["plan", "apply", "drift"] : purpose => {
      role_arn                           = "arn:aws:iam::123456789012:role/fixture-${purpose}"
      permissions_boundary_arn           = "arn:aws:iam::123456789012:policy/fixture-${purpose}-boundary"
      permissions_boundary_policy_sha256 = sha256(jsonencode(jsondecode(jsondecode(file("tests/fixtures/ci-contract.json"))[purpose].required_boundary_denies_json)))
    } }
  }
  override_data {
    target = data.aws_iam_role.ci["plan"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-plan"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).plan.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["plan"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).plan.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["apply"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-apply"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).apply.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["apply"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).apply.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["drift"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-drift"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).drift.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["drift"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).drift.required_boundary_denies_json
    }
  }
  assert {
    condition     = length(output.ci_role_arns) == 3
    error_message = "Three verified external roles must be exposed."
  }
}
run "rejects_legacy_branch_subject" {
  command = plan
  variables {
    enable_external_ci_roles = true
    external_ci_roles = { for purpose in ["plan", "apply", "drift"] : purpose => {
      role_arn                           = "arn:aws:iam::123456789012:role/fixture-${purpose}"
      permissions_boundary_arn           = "arn:aws:iam::123456789012:policy/fixture-${purpose}-boundary"
      permissions_boundary_policy_sha256 = sha256(jsonencode(jsondecode(jsondecode(file("tests/fixtures/ci-contract.json"))[purpose].required_boundary_denies_json)))
    } }
  }
  override_data {
    target = data.aws_iam_role.ci["plan"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-plan"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).plan.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["plan"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).plan.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["apply"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-apply"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      assume_role_policy   = replace(jsondecode(file("tests/fixtures/ci-contract.json")).apply.trust_policy_json, "environment:dev", "ref:refs/heads/main")
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["apply"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).apply.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["drift"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-drift"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).drift.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["drift"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).drift.required_boundary_denies_json
    }
  }
  expect_failures = [terraform_data.ci_identity["apply"]]
}
run "rejects_wrong_account_environment" {
  command = plan
  variables {
    enable_external_ci_roles = true
    external_ci_roles = { for purpose in ["plan", "apply", "drift"] : purpose => {
      role_arn                           = "arn:aws:iam::123456789012:role/fixture-${purpose}"
      permissions_boundary_arn           = "arn:aws:iam::123456789012:policy/fixture-${purpose}-boundary"
      permissions_boundary_policy_sha256 = sha256(jsonencode(jsondecode(jsondecode(file("tests/fixtures/ci-contract.json"))[purpose].required_boundary_denies_json)))
    } }
  }
  override_data {
    target = data.aws_iam_role.ci["plan"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-plan"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).plan.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["plan"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).plan.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["apply"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-apply"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      assume_role_policy   = replace(jsondecode(file("tests/fixtures/ci-contract.json")).apply.trust_policy_json, "environment:dev", "environment:production")
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["apply"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).apply.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["drift"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-drift"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).drift.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["drift"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).drift.required_boundary_denies_json
    }
  }
  expect_failures = [terraform_data.ci_identity["apply"]]
}
run "rejects_cross_account_role" {
  command = plan
  variables {
    enable_external_ci_roles = true
    external_ci_roles = { for purpose in ["plan", "apply", "drift"] : purpose => {
      role_arn                           = "arn:aws:iam::123456789012:role/fixture-${purpose}"
      permissions_boundary_arn           = "arn:aws:iam::123456789012:policy/fixture-${purpose}-boundary"
      permissions_boundary_policy_sha256 = sha256(jsonencode(jsondecode(jsondecode(file("tests/fixtures/ci-contract.json"))[purpose].required_boundary_denies_json)))
    } }
  }
  override_data {
    target = data.aws_iam_role.ci["plan"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-plan"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).plan.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["plan"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).plan.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["apply"]
    values = {
      arn                  = "arn:aws:iam::999999999999:role/fixture-apply"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).apply.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["apply"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).apply.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["drift"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-drift"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).drift.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["drift"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).drift.required_boundary_denies_json
    }
  }
  expect_failures = [terraform_data.ci_identity["apply"]]
}
run "rejects_missing_boundary" {
  command = plan
  variables {
    enable_external_ci_roles = true
    external_ci_roles = { for purpose in ["plan", "apply", "drift"] : purpose => {
      role_arn                           = "arn:aws:iam::123456789012:role/fixture-${purpose}"
      permissions_boundary_arn           = "arn:aws:iam::123456789012:policy/fixture-${purpose}-boundary"
      permissions_boundary_policy_sha256 = sha256(jsonencode(jsondecode(jsondecode(file("tests/fixtures/ci-contract.json"))[purpose].required_boundary_denies_json)))
    } }
  }
  override_data {
    target = data.aws_iam_role.ci["plan"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-plan"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).plan.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["plan"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).plan.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["apply"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-apply"
      permissions_boundary = ""
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).apply.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["apply"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).apply.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["drift"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-drift"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).drift.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["drift"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).drift.required_boundary_denies_json
    }
  }
  expect_failures = [terraform_data.ci_identity["apply"]]
}
run "rejects_boundary_drift" {
  command = plan
  variables {
    enable_external_ci_roles = true
    external_ci_roles = { for purpose in ["plan", "apply", "drift"] : purpose => {
      role_arn                           = "arn:aws:iam::123456789012:role/fixture-${purpose}"
      permissions_boundary_arn           = "arn:aws:iam::123456789012:policy/fixture-${purpose}-boundary"
      permissions_boundary_policy_sha256 = sha256(jsonencode(jsondecode(jsondecode(file("tests/fixtures/ci-contract.json"))[purpose].required_boundary_denies_json)))
    } }
  }
  override_data {
    target = data.aws_iam_role.ci["plan"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-plan"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).plan.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["plan"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-plan-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).plan.required_boundary_denies_json
    }
  }
  override_data {
    target = data.aws_iam_role.ci["apply"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-apply"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).apply.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["apply"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-apply-boundary"
      policy = replace(jsondecode(file("tests/fixtures/ci-contract.json")).apply.required_boundary_denies_json, "DenyCiIdentityMutation", "UnreviewedChange")
    }
  }
  override_data {
    target = data.aws_iam_role.ci["drift"]
    values = {
      arn                  = "arn:aws:iam::123456789012:role/fixture-drift"
      permissions_boundary = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      assume_role_policy   = jsondecode(file("tests/fixtures/ci-contract.json")).drift.trust_policy_json
    }
  }
  override_data {
    target = data.aws_iam_policy.ci_boundary["drift"]
    values = {
      arn    = "arn:aws:iam::123456789012:policy/fixture-drift-boundary"
      policy = jsondecode(file("tests/fixtures/ci-contract.json")).drift.required_boundary_denies_json
    }
  }
  expect_failures = [terraform_data.ci_identity["apply"]]
}
run "rejects_shared_role" {
  command = plan
  variables { external_ci_roles = { for purpose in ["plan", "apply", "drift"] : purpose => {
    role_arn                           = "arn:aws:iam::123456789012:role/shared"
    permissions_boundary_arn           = "arn:aws:iam::123456789012:policy/boundary"
    permissions_boundary_policy_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  } } }
  expect_failures = [var.external_ci_roles]
}
run "rejects_enabled_without_mapping" {
  command = plan
  variables {
    external_ci_roles        = {}
    enable_external_ci_roles = true
  }
  expect_failures = [var.enable_external_ci_roles]
}
