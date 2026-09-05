variable "platform_image_publisher" {
  description = "Actual GitHub numeric identities; forks must supply their own repository and owner IDs."
  type        = object({ repository_full_name = string, repository_id = string, owner_id = string })
  default     = { repository_full_name = "play-builder/EKS-infra", repository_id = "405337777", owner_id = "42942042" }
  nullable    = false
  validation {
    condition = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$", var.platform_image_publisher.repository_full_name)) && alltrue([
      for id in [var.platform_image_publisher.repository_id, var.platform_image_publisher.owner_id] : can(regex("^[1-9][0-9]*$", id))
    ])
    error_message = "A concrete owner/repository and numeric owner/repository IDs are required; wildcard identities are forbidden."
  }
}

locals {
  platform_publisher_subject = format("repo:%s@%s/%s@%s:environment:production",
    split("/", var.platform_image_publisher.repository_full_name)[0], var.platform_image_publisher.owner_id,
  split("/", var.platform_image_publisher.repository_full_name)[1], var.platform_image_publisher.repository_id)
}

resource "aws_ecr_repository" "platform_istio_proxy" {
  name                 = "${var.project_name}/platform/istio-proxyv2"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  encryption_configuration { encryption_type = "AES256" }
  image_scanning_configuration { scan_on_push = true }
  tags = local.common_tags
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_role" "platform_image_publisher" {
  name = "${var.project_name}-platform-image-publisher"
  tags = local.common_tags
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRoleWithWebIdentity", Principal = { Federated = local.oidc_provider_arn },
    Condition = { StringEquals = {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub" = local.platform_publisher_subject
    } }
  }] })
}

resource "aws_iam_role_policy" "platform_image_publisher" {
  name = "platform-image-mirror"
  role = aws_iam_role.platform_image_publisher.name
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = local.attestation_actions, Resource = [aws_ecr_repository.platform_istio_proxy.arn] }
  ] })
}

output "platform_istio_proxy_repository_url" { value = aws_ecr_repository.platform_istio_proxy.repository_url }
output "platform_image_publisher_role_arn" { value = aws_iam_role.platform_image_publisher.arn }
output "platform_image_publisher" {
  value = {
    repositoryId  = var.platform_image_publisher.repository_id
    workflow      = "https://github.com/${var.platform_image_publisher.repository_full_name}/.github/workflows/publish-platform-images.yml@refs/heads/main"
    environment   = "production"
    roleArn       = aws_iam_role.platform_image_publisher.arn
    repositoryArn = aws_ecr_repository.platform_istio_proxy.arn
    repositoryUrl = aws_ecr_repository.platform_istio_proxy.repository_url
  }
}
