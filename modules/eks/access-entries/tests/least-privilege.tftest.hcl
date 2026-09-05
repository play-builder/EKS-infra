mock_provider "aws" {}
variables {
  cluster_name = "fixture"
  tags         = { PlatformInstanceId = "fixture", Owner = "fixture", CostCenter = "fixture", Environment = "dev" }
  access_entries = {
    developer-readonly = { principal_arn = "arn:aws:iam::123456789012:role/developer", policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy", scope_type = "namespace", namespaces = ["app-dev"], break_glass = false }
  }
}
run "namespace_scope_is_preserved" {
  command = plan
  assert {
    condition     = aws_eks_access_policy_association.this["developer-readonly"].access_scope[0].type == "namespace" && aws_eks_access_policy_association.this["developer-readonly"].access_scope[0].namespaces == toset(["app-dev"])
    error_message = "Readonly access scope must not widen."
  }
}
run "rejects_iam_user" {
  command = plan
  variables { access_entries = { developer-readonly = { principal_arn = "arn:aws:iam::123456789012:user/developer", policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy", scope_type = "namespace", namespaces = ["app-dev"], break_glass = false } } }
  expect_failures = [var.access_entries]
}
run "rejects_service_account" {
  command = plan
  variables { access_entries = { developer-readonly = { principal_arn = "system:serviceaccount:argocd:argocd", policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy", scope_type = "namespace", namespaces = ["app-dev"], break_glass = false } } }
  expect_failures = [var.access_entries]
}
run "rejects_empty_namespace" {
  command = plan
  variables { access_entries = { developer-readonly = { principal_arn = "arn:aws:iam::123456789012:role/developer", policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy", scope_type = "namespace", namespaces = [], break_glass = false } } }
  expect_failures = [var.access_entries]
}
run "rejects_operator_admin" {
  command = plan
  variables { access_entries = { platform-operator = { principal_arn = "arn:aws:iam::123456789012:role/operator", policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy", scope_type = "cluster", namespaces = [], break_glass = false } } }
  expect_failures = [var.access_entries]
}
run "rejects_unmarked_break_glass" {
  command = plan
  variables { access_entries = { platform-break-glass = { principal_arn = "arn:aws:iam::123456789012:role/emergency", policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy", scope_type = "cluster", namespaces = [], break_glass = false } } }
  expect_failures = [var.access_entries]
}
run "rejects_readonly_edit" {
  command = plan
  variables { access_entries = { developer-readonly = { principal_arn = "arn:aws:iam::123456789012:role/developer", policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy", scope_type = "namespace", namespaces = ["app-dev"], break_glass = false } } }
  expect_failures = [var.access_entries]
}
