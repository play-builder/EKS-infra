resource "aws_eks_addon" "coredns" {
  cluster_name                = var.cluster_name
  addon_name                  = "coredns"
  addon_version               = var.managed_addon_versions.coredns
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags
}
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = var.cluster_name
  addon_name                  = "kube-proxy"
  addon_version               = var.managed_addon_versions.kube_proxy
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags
  depends_on                  = [aws_eks_addon.coredns]
}
