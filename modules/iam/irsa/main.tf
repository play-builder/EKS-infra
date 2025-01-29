data "aws_iam_policy_document" "this" {
  dynamic "statement" {
    for_each = var.iam_policy_statements
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_policy" "this" {
  count = length(var.iam_policy_statements) > 0 ? 1 : 0

  name        = "${var.name}-policy"
  description = "IAM Policy for ${var.name}"
  policy      = data.aws_iam_policy_document.this.json
  tags        = var.tags
}

resource "aws_iam_role" "this" {
  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${var.oidc_provider}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account_name}",
            "${var.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  count = length(var.iam_policy_statements) > 0 ? 1 : 0

  role       = aws_iam_role.this.name
  policy_arn = length(aws_iam_policy.this) > 0 ? aws_iam_policy.this[0].arn : ""
}
