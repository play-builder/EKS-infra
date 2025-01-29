# Kubernetes App Module

## 📌 Overview

A reusable module for managing Kubernetes Deployment and Service together.

## 🎯 Key Features

- **Deployment Management**: Rolling updates, replica management, resource limits
- **Service Management**: ClusterIP, NodePort, LoadBalancer support
- **Health Check**: Liveness/Readiness Probe configuration
- **Environment Variables**: Direct definition, Secret, ConfigMap support
- **Volume Mount**: EmptyDir, ConfigMap, Secret, PVC support

## 📋 Usage

### Basic Usage

```hcl
module "app" {
  source = "../../modules/kubernetes/app"

  app_name        = "my-app"
  environment     = "dev"
  container_image = "nginx:1.21"
  replicas        = 2

  health_check_path = "/health"
  service_type      = "NodePort"
}
```

### Using with ALB Ingress

```hcl
module "app1" {
  source = "../../modules/kubernetes/app"

  app_name        = "app1"
  environment     = "dev"
  container_image = "myapp/frontend:v1"
  replicas        = 2

  health_check_path = "/app1/health"
  service_type      = "NodePort"

  # Health check path for ALB Ingress Controller
  service_annotations = {
    "alb.ingress.kubernetes.io/healthcheck-path" = "/app1/health"
  }
}

module "alb_ingress" {
  source = "../../modules/kubernetes/ingress/alb-ssl"

  # Reference output from app1 module
  backend_services = [
    {
      name = module.app1.service_name
      port = module.app1.service_port
      path = "/app1"
    }
  ]
}
```

## ⚙️ Input Variables

| Variable          | Type   | Required | Description                         |
| ----------------- | ------ | -------- | ----------------------------------- |
| `app_name`        | string | ✅       | Application name                    |
| `environment`     | string | ✅       | Environment (dev/staging/prod)      |
| `container_image` | string | ✅       | Container image                     |
| `replicas`        | number |          | Number of Pod replicas (default: 1) |
| `service_type`    | string |          | Service type (default: NodePort)    |

## 📤 Outputs

| Output            | Description                  |
| ----------------- | ---------------------------- |
| `deployment_name` | Deployment name              |
| `service_name`    | Service name                 |
| `service_port`    | Service port                 |
| `app_info`        | App info summary for Ingress |
