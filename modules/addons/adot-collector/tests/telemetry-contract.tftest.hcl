mock_provider "aws" {
  mock_resource "aws_iam_role" {
    override_during = plan
    defaults = {
      arn = "arn:aws:iam::123456789012:role/course-dev-adot-collector-role"
    }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  eks_cluster_name       = "course-dev"
  aws_region             = "ap-northeast-2"
  oidc_provider_arn      = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE"
  oidc_provider          = "oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE"
  amp_workspace_endpoint = "https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/ws-example/"
  amp_workspace_arn      = "arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-example"
}

run "bounded_metrics_and_active_xray_contract" {
  command = plan

  variables {
    enable_xray = true
  }

  assert {
    condition = alltrue(flatten([
      for scrape in kubernetes_manifest.otel_collector[0].manifest.spec.config.receivers.prometheus.config.scrape_configs : [
        for relabel in scrape.relabel_configs : try(relabel.action, "replace") != "labelmap"
      ]
    ]))
    error_message = "Prometheus discovery must not copy arbitrary Kubernetes labels"
  }

  assert {
    condition = toset([
      for relabel in kubernetes_manifest.otel_collector[0].manifest.spec.config.receivers.prometheus.config.scrape_configs[0].relabel_configs : relabel.target_label
      if contains(keys(relabel), "target_label")
    ]) == toset(["__metrics_path__", "__address__", "namespace", "pod", "app", "rollouts_pod_template_hash"])
    error_message = "pod metrics must retain only routing fields plus namespace, pod, app, and rollouts_pod_template_hash"
  }

  assert {
    condition = one([
      for relabel in kubernetes_manifest.otel_collector[0].manifest.spec.config.receivers.prometheus.config.scrape_configs[0].relabel_configs : relabel.source_labels
      if try(relabel.target_label, "") == "app"
    ]) == ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    error_message = "the AMP app target must discover the chart-standard app.kubernetes.io/name pod label"
  }

  assert {
    condition     = output.otlp_http_traces_endpoint == "http://adot-collector-prometheus-collector.opentelemetry-operator-system.svc.cluster.local:4318/v1/traces"
    error_message = "active X-Ray must publish the full OTLP HTTP traces endpoint"
  }

  assert {
    condition     = output.otlp_traces_protocol == "http/protobuf"
    error_message = "active X-Ray must publish the OTLP HTTP/protobuf protocol"
  }

  assert {
    condition     = output.otlp_http_port == 4318 && output.otlp_http_traces_path == "/v1/traces" && output.xray_enabled
    error_message = "active X-Ray must publish port 4318, /v1/traces, and enabled phase state"
  }
}

run "inactive_xray_withholds_trace_inputs" {
  command = plan

  variables {
    enable_xray = false
  }

  assert {
    condition = (
      output.otlp_http_traces_endpoint == null &&
      output.otlp_traces_protocol == null &&
      output.otlp_http_port == null &&
      output.otlp_http_traces_path == null &&
      output.xray_enabled == false
    )
    error_message = "inactive X-Ray must not publish application trace inputs"
  }
}

run "xray_requires_a_real_collector_endpoint" {
  command = plan

  variables {
    enable_xray            = true
    amp_workspace_endpoint = ""
  }

  expect_failures = [var.enable_xray]
}
