# Kubernetes App 모듈

## 📌 개요

Kubernetes Deployment와 Service를 함께 관리하는 범용 애플리케이션 모듈입니다.

## 🎯 주요 기능

- **Deployment 관리**: 롤링 업데이트, 복제본 관리, 리소스 제한
- **Service 관리**: ClusterIP, NodePort, LoadBalancer 지원
- **Health Check**: Liveness/Readiness Probe 설정
- **환경 변수**: 직접 정의, Secret, ConfigMap 지원
- **볼륨 마운트**: EmptyDir, ConfigMap, Secret, PVC 지원

## 📋 사용법

### 기본 사용

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

### ALB Ingress와 함께 사용

```hcl
module "app1" {
  source = "../../modules/kubernetes/app"

  app_name        = "app1"
  environment     = "dev"
  container_image = "myapp/frontend:v1"
  replicas        = 2

  health_check_path = "/app1/health"
  service_type      = "NodePort"

  # ALB Ingress Controller용 헬스체크 경로
  service_annotations = {
    "alb.ingress.kubernetes.io/healthcheck-path" = "/app1/health"
  }
}

module "alb_ingress" {
  source = "../../modules/kubernetes/ingress/alb-ssl"

  # app1 모듈의 output 참조
  backend_services = [
    {
      name = module.app1.service_name
      port = module.app1.service_port
      path = "/app1"
    }
  ]
}
```

## ⚙️ 입력 변수

| 변수              | 타입   | 필수 | 설명                          |
| ----------------- | ------ | ---- | ----------------------------- |
| `app_name`        | string | ✅   | 애플리케이션 이름             |
| `environment`     | string | ✅   | 환경 (dev/staging/prod)       |
| `container_image` | string | ✅   | 컨테이너 이미지               |
| `replicas`        | number |      | Pod 복제본 수 (기본: 1)       |
| `service_type`    | string |      | Service 타입 (기본: NodePort) |

## 📤 출력값

| 출력              | 설명                        |
| ----------------- | --------------------------- |
| `deployment_name` | Deployment 이름             |
| `service_name`    | Service 이름                |
| `service_port`    | Service 포트                |
| `app_info`        | Ingress 연동용 앱 정보 요약 |
