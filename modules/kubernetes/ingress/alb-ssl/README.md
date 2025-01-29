# ALB SSL Ingress Module

## Overview

Module for managing ACM certificates and ALB Ingress.  
**Use the separate `app` module for Deployment/Service.**

## Design Principles

```
┌─────────────────────────────────────────────────────────┐
│ environments/dev/04-workloads/ingress-tier/main.tf     │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  module "app1" ─────────┐                              │
│    (kubernetes/app)     │                              │
│                         ├──→ module "ingress"          │
│  module "app2" ─────────┤      (ingress/alb-ssl)       │
│    (kubernetes/app)     │                              │
│                         │                              │
│  module "app3" ─────────┘                              │
│    (kubernetes/app)                                     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## Usage

```hcl
# 1. Create Deployment + Service using App module
module "app1" {
  source          = "../../modules/kubernetes/app"
  app_name        = "app1"
  environment     = "dev"
  container_image = "nginx:1.21"
  health_check_path = "/app1/index.html"
  service_type    = "NodePort"
  service_annotations = {
    "alb.ingress.kubernetes.io/healthcheck-path" = "/app1/index.html"
  }
}

# 2. Create ALB using Ingress module (reference app module's Service)
module "alb_ingress" {
  source = "../../modules/kubernetes/ingress/alb-ssl"

  environment    = "dev"
  project_name   = "myapp"
  acm_domain_name = "*.example.com"

  backend_services = [
    {
      name              = module.app1.service_name
      port              = module.app1.service_port
      path              = "/app1"
      path_type         = "Prefix"
      health_check_path = "/app1/index.html"
      is_default        = false
    }
  ]
}

```
