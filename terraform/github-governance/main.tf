resource "terraform_data" "course_ownership" {
  input = {
    CourseId    = var.course_id
    AccountId   = var.account_id
    Region      = var.aws_region
    Project     = var.gitops_repository
    Environment = "shared"
    Layer       = "governance"
    ManagedBy   = "Terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_repository" "gitops_settings" {
  name = var.gitops_repository

  allow_auto_merge       = true
  allow_squash_merge     = true
  allow_merge_commit     = false
  allow_rebase_merge     = false
  delete_branch_on_merge = true

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = github_repository.gitops_settings
  id = var.gitops_repository
}

resource "github_repository_vulnerability_alerts" "gitops" {
  repository = github_repository.gitops_settings.name
  enabled    = true
}

resource "github_repository_ruleset" "gitops_prod" {
  name        = "main-protection"
  repository  = github_repository.gitops_settings.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      required_approving_review_count   = 0
      required_review_thread_resolution = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true

      required_check {
        context = var.required_check
      }
    }
  }
}
