
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.7.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.22.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.0.0"
    }
  }
}
