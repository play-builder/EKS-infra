package main

import rego.v1

warn contains msg if {
  some resource in input.resource_changes
  resource.type == "aws_ecr_repository"
  resource.change.after.image_tag_mutability != "IMMUTABLE"
  msg := sprintf("%s should use IMMUTABLE tags", [resource.address])
}
