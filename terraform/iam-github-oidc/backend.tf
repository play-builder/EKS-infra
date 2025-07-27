terraform {
  backend "s3" {
    bucket       = "playdevops-infra-tf-dev"
    key          = "shared/iam-github-oidc/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}