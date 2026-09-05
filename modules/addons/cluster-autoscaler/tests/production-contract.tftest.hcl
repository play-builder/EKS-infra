mock_provider "aws" {
 mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::123456789012:policy/fixture" } }
 mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/fixture" } }
}
mock_provider "helm" {}
override_data {
 target = data.aws_iam_policy_document.cluster_autoscaler
 values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
variables {
 cluster_name = "fixture"
 oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE"
 oidc_provider = "oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE"
 aws_region = "ap-northeast-2"
 environment = "prod"
 autoscaling_mode = "mng_cluster_autoscaler"
 autoscaler_capacity = {
  min_nodes = 3
  max_nodes = 6
  max_pods_per_node = 20
  hpa_max_replicas = 20
  rollout_surge_replicas = 4
  platform_reserve_pods = 15
  stable_replicas = 3
  canary_replicas = 3
  usable_subnet_ips_by_az = { a = 64, b = 64, c = 64 }
  required_headroom_percentage = 20
 }
}
run "controller_pin_is_136_digest" {
 command = apply
 assert {
  condition = yamldecode(helm_release.cluster_autoscaler.values[0]).image.tag == "v1.36.0@sha256:dc5d62770338c2902f31b01f95c9fc8c456fd88baa5364ca154d6e47069ec885"
  error_message = "Chart default is 1.35; explicit 1.36 digest override required."
 }
}
run "rejects_fixed_prod" {
 command = plan
 variables { autoscaling_mode = "fixed" }
 expect_failures = [var.autoscaling_mode]
}
run "rejects_capacity_shortfall" {
 command = plan
 variables {
  autoscaler_capacity = {
   min_nodes = 3
   max_nodes = 3
   max_pods_per_node = 5
   hpa_max_replicas = 20
   rollout_surge_replicas = 4
   platform_reserve_pods = 15
   stable_replicas = 3
   canary_replicas = 3
   usable_subnet_ips_by_az = { a = 64, b = 64, c = 1 }
   required_headroom_percentage = 20
  }
 }
 expect_failures = [var.autoscaler_capacity]
}
