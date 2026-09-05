output "versions" { value = var.managed_addon_versions }
output "owner_hash" { value = sha256(jsonencode({ coredns = "02-eks/managed-addons", kube_proxy = "02-eks/managed-addons", vpc_cni = "02-eks/cluster", ebs_csi = "03-platform/ebs-csi-driver", snapshot_controller = "03-platform/root" })) }
