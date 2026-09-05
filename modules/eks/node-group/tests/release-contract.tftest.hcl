mock_provider "aws" {}
variables {
 cluster_name = "fixture"
 cluster_version = "1.36"
 name = "fixture"
 node_group_name = "private"
 subnet_ids = ["subnet-0123456789abcdef0"]
 node_release_version = "1.36.0-20260901"
}
run "pins_requested_release" {
 command = plan
 assert {
  condition = aws_eks_node_group.this.release_version == "1.36.0-20260901"
  error_message = "Managed node release must never float."
 }
}
run "rejects_empty_release" {
 command = plan
 variables { node_release_version = "" }
 expect_failures = [var.node_release_version]
}
