# No role/policy attachments are made to these external identities.
# Data checks establish exact trust, role separation and the reviewed boundary, not full effective AWS permissions.
data "aws_iam_policy_document" "ci_trust" {
  for_each = local.ci_subjects
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_issuer}:sub"
      values   = [each.value]
    }
  }
}

# Backend policies are exported for the external owner, not attached by this state.
# Plan takes the native lock; drift uses -lock=false; only apply may write state.
data "aws_iam_policy_document" "state_access" {
  for_each = local.ci_subjects
  statement {
    sid       = "ListExactStatePrefixes"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values   = concat(local.state_keys, [for key in local.state_keys : "${key}.tflock"])
    }
  }
  statement {
    sid       = "ReadStateBucketMetadata"
    actions   = ["s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]
  }
  statement {
    sid       = "ExactStateObjects"
    actions   = each.key == "apply" ? ["s3:GetObject", "s3:PutObject"] : ["s3:GetObject"]
    resources = local.state_object_arns
  }
  dynamic "statement" {
    for_each = each.key == "drift" ? [] : [1]
    content {
      sid       = "ExactLockObjects"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = local.lock_object_arns
    }
  }
}

# Required explicit denies in every external boundary. Additional service allows must be reviewed separately.
# Compare these statements exactly (including Sid) after canonical JSON encoding.
data "aws_iam_policy_document" "required_boundary_denies" {
  for_each = local.ci_subjects
  statement {
    sid       = "DenyCiIdentityMutation"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = local.protected_identity_arns
  }
  statement {
    sid           = "DenyOtherStateObjects"
    effect        = "Deny"
    actions       = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*"]
    not_resources = concat(local.state_object_arns, local.lock_object_arns)
  }
  statement {
    sid       = "DenyStateDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteObject*"]
    resources = local.state_object_arns
  }
  dynamic "statement" {
    for_each = each.key == "apply" ? [] : [1]
    content {
      sid       = "DenyStateMutation"
      effect    = "Deny"
      actions   = ["s3:PutObject*", "s3:DeleteObject*"]
      resources = each.key == "drift" ? concat(local.state_object_arns, local.lock_object_arns) : local.state_object_arns
    }
  }
  dynamic "statement" {
    for_each = each.key == "apply" ? [] : [1]
    content {
      sid    = "DenyNonReadActions"
      effect = "Deny"
      not_actions = concat([
        "ec2:Describe*", "ec2:Get*", "eks:Describe*", "eks:List*", "eks:AccessKubernetesApi",
        "iam:Get*", "iam:List*", "s3:Get*", "s3:List*", "ecr:Describe*", "ecr:Get*", "ecr:List*",
        "ecr:BatchGet*", "ecr:BatchCheckLayerAvailability", "logs:Describe*", "logs:Get*", "logs:List*",
        "cloudwatch:Get*", "cloudwatch:List*", "cloudwatch:Describe*", "aps:Describe*", "aps:List*",
        "aps:Get*", "aps:QueryMetrics", "secretsmanager:Describe*", "secretsmanager:Get*", "secretsmanager:List*",
        "ssm:Describe*", "ssm:Get*", "ssm:List*", "kms:Describe*", "kms:Get*", "kms:List*", "kms:Decrypt",
        "rds:Describe*", "rds:List*", "route53:Get*", "route53:List*", "elasticloadbalancing:Describe*",
        "autoscaling:Describe*", "events:Describe*", "events:List*", "tag:Get*", "sts:GetCallerIdentity",
        "acm:Describe*", "acm:Get*", "acm:List*", "sns:Get*", "sns:List*",
      ], each.key == "plan" ? ["s3:PutObject", "s3:DeleteObject"] : [])
      resources = ["*"]
    }
  }
}

data "aws_iam_role" "ci" {
  for_each = var.enable_external_ci_roles ? var.external_ci_roles : {}
  name     = element(reverse(split("/", each.value.role_arn)), 0)
}

data "aws_iam_policy" "ci_boundary" {
  for_each = var.enable_external_ci_roles ? var.external_ci_roles : {}
  arn      = each.value.permissions_boundary_arn
}

# The independent guard is evaluated even with Terraform data overrides in offline tests.
# It creates no AWS object and prevents output activation until all external reads agree.
resource "terraform_data" "ci_identity" {
  for_each = var.enable_external_ci_roles ? var.external_ci_roles : {}
  input    = each.value.role_arn
  lifecycle {

    precondition {
      condition = (
        data.aws_iam_role.ci[each.key].arn == each.value.role_arn && startswith(data.aws_iam_role.ci[each.key].arn, "${local.account_arn_prefix}:role/") &&
        data.aws_iam_role.ci[each.key].arn != local.legacy_role_arn && data.aws_iam_role.ci[each.key].permissions_boundary == each.value.permissions_boundary_arn
      )
      error_message = "CI roles must be distinct non-legacy roles in this account with the selected permissions boundary."
    }
    precondition {
      # AWS normalizes single-element policy arrays to strings; accept both representations, not extra statements/principals.
      condition = try(
        length(jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement) == 1 &&
        jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement[0].Effect == "Allow" &&
        toset(flatten([jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement[0].Action])) == toset(["sts:AssumeRoleWithWebIdentity"]) &&
        keys(jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement[0].Principal) == ["Federated"] &&
        toset(flatten([jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement[0].Principal.Federated])) == toset([local.oidc_provider_arn]) &&
        keys(jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement[0].Condition) == ["StringEquals"] &&
        toset(keys(jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement[0].Condition.StringEquals)) == toset(["${local.github_issuer}:aud", "${local.github_issuer}:sub"]) &&
        toset(flatten([jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement[0].Condition.StringEquals["${local.github_issuer}:aud"]])) == toset(["sts.amazonaws.com"]) &&
        toset(flatten([jsondecode(data.aws_iam_role.ci[each.key].assume_role_policy).Statement[0].Condition.StringEquals["${local.github_issuer}:sub"]])) == toset([local.ci_subjects[each.key]]), false
      )
      error_message = "CI trust must allow only the exact immutable repository and purpose-specific GitHub environment, with sts.amazonaws.com audience."
    }

    precondition {
      condition = (
        startswith(data.aws_iam_policy.ci_boundary[each.key].arn, "${local.account_arn_prefix}:policy/") &&
        sha256(jsonencode(jsondecode(data.aws_iam_policy.ci_boundary[each.key].policy))) == each.value.permissions_boundary_policy_sha256
      )
      error_message = "Pin the current account's reviewed customer-managed boundary using SHA-256 of canonical JSON, not a generic AWS managed policy."
    }
    precondition {
      condition = try(alltrue([
        for required in jsondecode(data.aws_iam_policy_document.required_boundary_denies[each.key].json).Statement :
        contains([for actual in jsondecode(data.aws_iam_policy.ci_boundary[each.key].policy).Statement : jsonencode(actual)], jsonencode(required))
      ]), false)
      error_message = "The external boundary must include the exact required deny statements for CI identity protection and state/read-only scope."
    }
  }
}
