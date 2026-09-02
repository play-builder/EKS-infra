terraform {
  required_version = ">= 1.15.9, < 2.0.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "= 6.13.0"
    }
  }
}
