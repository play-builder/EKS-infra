# ALB SSL Ingress 모듈

## 📌 개요

ACM 인증서와 ALB Ingress를 관리하는 모듈입니다.  
**Deployment/Service는 별도의 `app` 모듈을 사용하세요.**

## 🎯 설계 원칙

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

## 📋 사용법

```hcl
# 1. App 모듈로 Deployment + Service 생성
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

# 2. Ingress 모듈로 ALB 생성 (app 모듈의 Service 참조)
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
