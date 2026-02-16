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

# --- IAM Policy: AMP Remote Write + CloudWatch ---
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
          "aps:RemoteWrite",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Sid    = "XRay"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- EKS ADOT Addon ---
resource "aws_eks_addon" "adot" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "adot"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.adot.arn

  tags = merge(var.tags, { Name = "${var.eks_cluster_name}-adot-addon" })

  depends_on = [aws_iam_role_policy.adot]
}

resource "kubernetes_manifest" "otel_collector" {
  count = var.amp_workspace_endpoint != "" ? 1 : 0

  manifest = {
    apiVersion = "opentelemetry.io/v1alpha1"
    kind       = "OpenTelemetryCollector"
    metadata = {
      name      = "adot-collector-prometheus"
      namespace = "opentelemetry-operator-system"
    }
    spec = {
      mode           = "daemonset"
      serviceAccount = "adot-collector"
      config = yamlencode({
        receivers = {
          prometheus = {
            config = {
              global = {
                scrape_interval = "60s"
                scrape_timeout  = "15s"
              }
              scrape_configs = [
                {
                  job_name     = "kubernetes-pods"
                  sample_limit = 10000
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
                  bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
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
            timeout         = "60s"
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
      })
    }
  }

  depends_on = [aws_eks_addon.adot]
}