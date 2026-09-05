mock_provider "aws" {
  mock_data "aws_iam_policy_document" { defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::123456789012:policy/fixture" } }
}
variables {
  state_bucket_arns = ["arn:aws:s3:::course-state"]
  aws_region        = "ap-northeast-2"
  tags              = { PlatformInstanceId = "fixture", Owner = "fixture", CostCenter = "fixture" }
}
run "rejects_non_numeric_publisher_identity" {
  command = plan
  variables { platform_image_publisher = { repository_full_name = "play-builder/EKS-infra", repository_id = "*", owner_id = "42942042" } }
  expect_failures = [var.platform_image_publisher]
}
run "publisher_owns_only_the_protected_platform_repository" {
  command = apply
  override_resource {
    target = aws_ecr_repository.platform_istio_proxy
    values = {
      arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/playdevops/platform/istio-proxyv2"
      repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/playdevops/platform/istio-proxyv2"
    }
  }
  override_resource {
    target = aws_iam_role.platform_image_publisher
    values = { arn = "arn:aws:iam::123456789012:role/playdevops-platform-image-publisher" }
  }
  assert {
    condition     = aws_ecr_repository.platform_istio_proxy.image_tag_mutability == "IMMUTABLE" && !aws_ecr_repository.platform_istio_proxy.force_delete && one(aws_ecr_repository.platform_istio_proxy.encryption_configuration).encryption_type == "AES256"
    error_message = "Platform releases must not be overwritable or force-deleted."
  }
  assert {
    condition     = jsondecode(aws_iam_role.platform_image_publisher.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:play-builder@42942042/EKS-infra@405337777:environment:production" && jsondecode(aws_iam_role.platform_image_publisher.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "Publisher role requires the numeric platform repository and protected environment identity."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.platform_image_publisher.policy).Statement[1].Resource) == toset(["arn:aws:ecr:ap-northeast-2:123456789012:repository/playdevops/platform/istio-proxyv2"]) && toset(jsondecode(aws_iam_role_policy.platform_image_publisher.policy).Statement[1].Action) == toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"])
    error_message = "Publisher must not gain app image, repository deletion or broad AWS permissions."
  }
  assert {
    condition     = output.platform_istio_proxy_repository_url == "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/playdevops/platform/istio-proxyv2" && output.platform_image_publisher_role_arn == "arn:aws:iam::123456789012:role/playdevops-platform-image-publisher"
    error_message = "GitOps handoff must expose the actual new resource identities."
  }
}
