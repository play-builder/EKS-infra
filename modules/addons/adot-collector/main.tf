resource "aws_iam_role" "adot" {
  name = "${var.eks_cluster_name}-adot-collector-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${var.oidc_provider}:sub" = "system:serviceaccount:opentelemetry-operator-system:adot-collector"
            "${var.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.eks_cluster_name}-adot-collector-role" })
}

# The collector only writes metrics to this environment's AMP workspace.
resource "aws_iam_role_policy" "adot" {
  name = "${var.eks_cluster_name}-adot-collector-policy"
  role = aws_iam_role.adot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AMPRemoteWrite"
        Effect = "Allow"
        Action = [
          "aps:RemoteWrite"
        ]
        Resource = var.amp_workspace_arn
      }
    ]
  })
}

# The ADOT EKS add-on installs an operator and requires cert-manager first.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "oci://quay.io/jetstack/charts"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true
  atomic           = true
  timeout          = 600

  values = [
    yamlencode({
      crds = {
        enabled = true
      }
    })
  ]
}

# The EKS add-on installs the OpenTelemetry operator and CRDs.
resource "aws_eks_addon" "adot" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "adot"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(var.tags, { Name = "${var.eks_cluster_name}-adot-addon" })

  depends_on = [
    aws_iam_role_policy.adot,
    helm_release.cert_manager,
  ]
}

resource "kubernetes_service_account_v1" "adot_collector" {
  count = var.amp_workspace_endpoint != "" ? 1 : 0

  metadata {
    name      = "adot-collector"
    namespace = "opentelemetry-operator-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.adot.arn
    }
  }

  depends_on = [aws_eks_addon.adot]
}

resource "kubernetes_cluster_role_v1" "adot_collector" {
  count = var.amp_workspace_endpoint != "" ? 1 : 0

  metadata {
    name = "${var.eks_cluster_name}-adot-prometheus-reader"
  }

  rule {
    api_groups = [""]
    resources  = ["endpoints", "nodes", "nodes/proxy", "pods", "services"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    non_resource_urls = ["/metrics", "/metrics/cadvisor"]
    verbs             = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "adot_collector" {
  count = var.amp_workspace_endpoint != "" ? 1 : 0

  metadata {
    name = "${var.eks_cluster_name}-adot-prometheus-reader"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.adot_collector[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.adot_collector[0].metadata[0].name
    namespace = kubernetes_service_account_v1.adot_collector[0].metadata[0].namespace
  }
}

resource "kubernetes_manifest" "otel_collector" {
  count = var.amp_workspace_endpoint != "" ? 1 : 0

  manifest = {
    apiVersion = "opentelemetry.io/v1beta1"
    kind       = "OpenTelemetryCollector"
    metadata = {
      name      = "adot-collector-prometheus"
      namespace = "opentelemetry-operator-system"
    }
    spec = {
      mode           = "deployment"
      replicas       = 1
      serviceAccount = kubernetes_service_account_v1.adot_collector[0].metadata[0].name
      image          = var.collector_image
      config = {
        receivers = {
          prometheus = {
            config = {
              global = {
                scrape_interval = "15s"
                scrape_timeout  = "10s"
              }
              scrape_configs = [
                {
                  job_name              = "kubernetes-pods"
                  sample_limit          = 10000
                  kubernetes_sd_configs = [{ role = "pod" }]
                  relabel_configs = [
                    {
                      source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
                      action        = "keep"
                      regex         = "true"
                    },
                    {
                      source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_path"]
                      action        = "replace"
                      target_label  = "__metrics_path__"
                      regex         = "(.+)"
                    },
                    {
                      source_labels = ["__address__", "__meta_kubernetes_pod_annotation_prometheus_io_port"]
                      action        = "replace"
                      regex         = "([^:]+)(?::\\d+)?;(\\d+)"
                      replacement   = "$1:$2"
                      target_label  = "__address__"
                    },
                    {
                      action = "labelmap"
                      regex  = "__meta_kubernetes_pod_label_(.+)"
                    },
                    {
                      source_labels = ["__meta_kubernetes_namespace"]
                      action        = "replace"
                      target_label  = "namespace"
                    },
                    {
                      source_labels = ["__meta_kubernetes_pod_name"]
                      action        = "replace"
                      target_label  = "pod"
                    }
                  ]
                },
                {
                  job_name = "kubernetes-nodes-cadvisor"
                  scheme   = "https"
                  tls_config = {
                    ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
                    insecure_skip_verify = true
                  }
                  bearer_token_file     = "/var/run/secrets/kubernetes.io/serviceaccount/token"
                  kubernetes_sd_configs = [{ role = "node" }]
                  relabel_configs = [
                    {
                      action = "labelmap"
                      regex  = "__meta_kubernetes_node_label_(.+)"
                    },
                    {
                      target_label = "__address__"
                      replacement  = "kubernetes.default.svc:443"
                    },
                    {
                      source_labels = ["__meta_kubernetes_node_name"]
                      regex         = "(.+)"
                      target_label  = "__metrics_path__"
                      replacement   = "/api/v1/nodes/$1/proxy/metrics/cadvisor"
                    }
                  ]
                  metric_relabel_configs = [
                    {
                      source_labels = ["__name__"]
                      regex         = "container_cpu_usage_seconds_total|container_memory_working_set_bytes|container_network_receive_bytes_total|container_network_transmit_bytes_total|container_fs_reads_bytes_total|container_fs_writes_bytes_total"
                      action        = "keep"
                    }
                  ]
                }
              ]
            }
          }
        }

        processors = {
          batch = {
            timeout         = "5s"
            send_batch_size = 1000
          }
        }

        exporters = {
          prometheusremotewrite = {
            endpoint = "${var.amp_workspace_endpoint}api/v1/remote_write"
            auth = {
              authenticator = "sigv4auth"
            }
          }
        }

        extensions = {
          sigv4auth = {
            region  = var.aws_region
            service = "aps"
          }
        }

        service = {
          extensions = ["sigv4auth"]
          pipelines = {
            metrics = {
              receivers  = ["prometheus"]
              processors = ["batch"]
              exporters  = ["prometheusremotewrite"]
            }
          }
        }
      }
    }
  }

  depends_on = [
    aws_eks_addon.adot,
    kubernetes_cluster_role_binding_v1.adot_collector,
  ]
}
