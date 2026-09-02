package main

import rego.v1

test_warns_for_mutable_repository if {
  warnings := warn with input as {"resource_changes": [{
    "address": "aws_ecr_repository.sample_app",
    "type": "aws_ecr_repository",
    "change": {"after": {"image_tag_mutability": "MUTABLE"}},
  }]}
  count(warnings) == 1
}

test_allows_immutable_repository if {
  warnings := warn with input as {"resource_changes": [{
    "address": "aws_ecr_repository.sample_app",
    "type": "aws_ecr_repository",
    "change": {"after": {"image_tag_mutability": "IMMUTABLE"}},
  }]}
  count(warnings) == 0
}
