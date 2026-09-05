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
    Statement = concat(
      [
        {
          Sid      = "AMPRemoteWrite"
          Effect   = "Allow"
          Action   = ["aps:RemoteWrite"]
          Resource = var.amp_workspace_arn
        }
      ],
      var.enable_xray ? [
        {
          Sid      = "XRayWrite"
          Effect   = "Allow"
          Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
          Resource = "*"
        }
      ] : []
    )
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
        receivers = merge(
          {
            prometheus = {
              config = {
                global = {
                  scrape_interval = "15s"
                  scrape_timeout  = "10s"
                }
                scrape_configs = [
                  {
                    job_name              = "mini-commerce-management"
                    metrics_path          = "/metrics"
                    sample_limit          = 10000
                    kubernetes_sd_configs = [{ role = "pod" }]
                    relabel_configs = [
                      {
                        source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_label_app_kubernetes_io_name", "__meta_kubernetes_pod_container_port_name", "__meta_kubernetes_pod_container_port_number"]
                        action        = "keep"
                        regex         = "app-${var.environment};mini-commerce;management;3001"
                      },
                      {
                        source_labels = ["__meta_kubernetes_pod_phase"]
                        action        = "keep"
                        regex         = "Running"
                      },
                      {
                        source_labels = ["__meta_kubernetes_pod_ip"]
                        action        = "replace"
                        target_label  = "__address__"
                        regex         = "(.+)"
                        replacement   = "$1:3001"
                      },
                      {
                        target_label = "environment"
                        replacement  = var.environment
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
                    metric_relabel_configs = [{
                      source_labels = ["__name__"]
                      regex         = "mini_commerce_.*"
                      action        = "keep"
                    }]
                  },
                  {
                    job_name              = "istio-proxy"
                    metrics_path          = "/stats/prometheus"
                    sample_limit          = 10000
                    kubernetes_sd_configs = [{ role = "pod" }]
                    relabel_configs = [
                      {
                        source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_container_name", "__meta_kubernetes_pod_container_port_name", "__meta_kubernetes_pod_container_port_number"]
                        regex         = "app-${var.environment};istio-proxy;http-envoy-prom;15090"
                        action        = "keep"
                      },
                      {
                        source_labels = ["__meta_kubernetes_pod_phase"]
                        regex         = "Running"
                        action        = "keep"
                      },
                      {
                        target_label = "environment"
                        replacement  = var.environment
                      },
                      {
                        source_labels = ["__meta_kubernetes_namespace"]
                        target_label  = "namespace"
                      },
                      {
                        source_labels = ["__meta_kubernetes_pod_name"]
                        target_label  = "pod"
                      }
                    ]
                    metric_relabel_configs = [{
                      source_labels = ["__name__"]
                      regex         = "istio_requests_total|istio_request_duration_milliseconds_(bucket|sum|count)"
                      action        = "keep"
                    }]
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
          },
          var.enable_xray ? {
            otlp = {
              protocols = {
                # The sample application contract is OTLP/HTTP with protobuf.
                # The SDK appends /v1/traces to this receiver endpoint.
                http = { endpoint = "0.0.0.0:4318" }
              }
            }
          } : {}
        )

        processors = {
          batch = {
            timeout         = "5s"
            send_batch_size = 1000
          }
        }

        exporters = merge(
          {
            prometheusremotewrite = {
              endpoint = "${var.amp_workspace_endpoint}api/v1/remote_write"
              auth = {
                authenticator = "sigv4auth"
              }
            }
          },
          var.enable_xray ? {
            awsxray = {
              region = var.aws_region
            }
          } : {}
        )

        extensions = {
          sigv4auth = {
            region  = var.aws_region
            service = "aps"
          }
        }

        service = {
          extensions = ["sigv4auth"]
          pipelines = merge(
            {
              metrics = {
                receivers  = ["prometheus"]
                processors = ["batch"]
                exporters  = ["prometheusremotewrite"]
              }
            },
            var.enable_xray ? {
              traces = {
                receivers  = ["otlp"]
                processors = ["batch"]
                exporters  = ["awsxray"]
              }
            } : {}
          )
        }
      }
    }
  }

  depends_on = [
    aws_eks_addon.adot,
    kubernetes_cluster_role_binding_v1.adot_collector,
  ]
}
