
# =============================================================================
# Kubernetes App 모듈 - Variables
# =============================================================================
# 실무 관점: Deployment + Service를 함께 관리하는 범용 앱 모듈
# 왜 분리: 
#   - 재사용성: 다른 프로젝트에서도 동일한 패턴 사용 가능
#   - 관심사 분리: Ingress는 별도 모듈로 분리
#   - 테스트 용이: 앱 단위로 독립적 테스트 가능
# =============================================================================

# -----------------------------------------------------------------------------
# 필수 변수
# -----------------------------------------------------------------------------
variable "app_name" {
  description = "애플리케이션 이름 (리소스 이름에 사용)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.app_name))
    error_message = "app_name은 소문자, 숫자, 하이픈만 허용됩니다."
  }
}

variable "environment" {
  description = "배포 환경 (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment는 dev, staging, prod 중 하나여야 합니다."
  }
}

variable "container_image" {
  description = "컨테이너 이미지 (예: nginx:1.21)"
  type        = string
}

# -----------------------------------------------------------------------------
# Namespace 설정
# -----------------------------------------------------------------------------
variable "namespace" {
  description = "Kubernetes 네임스페이스"
  type        = string
  default     = "default"
}

variable "create_namespace" {
  description = "네임스페이스 생성 여부"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Deployment 설정
# -----------------------------------------------------------------------------
variable "replicas" {
  description = "Pod 복제본 수"
  type        = number
  default     = 1

  validation {
    condition     = var.replicas >= 1
    error_message = "replicas는 1 이상이어야 합니다."
  }
}

variable "container_port" {
  description = "컨테이너 포트"
  type        = number
  default     = 80
}

# -----------------------------------------------------------------------------
# 리소스 제한 설정
# 실무: 프로덕션에서 필수! OOM Kill, CPU Throttling 방지
# -----------------------------------------------------------------------------
variable "resources" {
  description = "컨테이너 리소스 요청/제한"
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    requests = {
      cpu    = "100m"
      memory = "128Mi"
    }
    limits = {
      cpu    = "200m"
      memory = "256Mi"
    }
  }
}

# -----------------------------------------------------------------------------
# Health Check 설정
# 실무: Pod 상태 모니터링, 자동 복구의 핵심
# -----------------------------------------------------------------------------
variable "health_check_path" {
  description = "헬스체크 HTTP 경로"
  type        = string
  default     = "/"
}

variable "liveness_probe" {
  description = "Liveness Probe 설정 (Pod 재시작 트리거)"
  type = object({
    enabled               = bool
    initial_delay_seconds = number
    period_seconds        = number
    timeout_seconds       = number
    failure_threshold     = number
  })
  default = {
    enabled               = true
    initial_delay_seconds = 30
    period_seconds        = 10
    timeout_seconds       = 5
    failure_threshold     = 3
  }
}

variable "readiness_probe" {
  description = "Readiness Probe 설정 (트래픽 수신 여부)"
  type = object({
    enabled               = bool
    initial_delay_seconds = number
    period_seconds        = number
    timeout_seconds       = number
    failure_threshold     = number
  })
  default = {
    enabled               = true
    initial_delay_seconds = 5
    period_seconds        = 5
    timeout_seconds       = 3
    failure_threshold     = 3
  }
}

# -----------------------------------------------------------------------------
# Service 설정
# -----------------------------------------------------------------------------
variable "create_service" {
  description = "Service 생성 여부"
  type        = bool
  default     = true
}

variable "service_type" {
  description = "Service 타입 (ClusterIP, NodePort, LoadBalancer)"
  type        = string
  default     = "NodePort"

  validation {
    condition     = contains(["ClusterIP", "NodePort", "LoadBalancer"], var.service_type)
    error_message = "service_type은 ClusterIP, NodePort, LoadBalancer 중 하나여야 합니다."
  }
}

variable "service_port" {
  description = "Service 포트"
  type        = number
  default     = 80
}

variable "node_port" {
  description = "NodePort (지정하지 않으면 자동 할당)"
  type        = number
  default     = null
}

variable "service_annotations" {
  description = "Service에 추가할 annotations"
  type        = map(string)
  default     = {}

  # 실무: ALB Ingress Controller용 헬스체크 경로 등 지정
  # 예: { "alb.ingress.kubernetes.io/healthcheck-path" = "/health" }
}

# -----------------------------------------------------------------------------
# 환경 변수 설정
# -----------------------------------------------------------------------------
variable "env_vars" {
  description = "컨테이너 환경 변수"
  type        = map(string)
  default     = {}

  # 예: { "LOG_LEVEL" = "debug", "DB_HOST" = "mysql.svc" }
}

variable "env_from_secrets" {
  description = "Secret에서 환경 변수 로드"
  type = list(object({
    secret_name = string
    optional    = bool
  }))
  default = []
}

variable "env_from_configmaps" {
  description = "ConfigMap에서 환경 변수 로드"
  type = list(object({
    configmap_name = string
    optional       = bool
  }))
  default = []
}

# -----------------------------------------------------------------------------
# 볼륨 설정
# -----------------------------------------------------------------------------
variable "volumes" {
  description = "Pod에 마운트할 볼륨"
  type = list(object({
    name       = string
    mount_path = string
    type       = string # "emptyDir", "configMap", "secret", "pvc"
    source     = string # configMap/secret/pvc 이름 (emptyDir일 경우 빈 문자열)
    read_only  = bool
  }))
  default = []
}

# -----------------------------------------------------------------------------
# 추가 설정
# -----------------------------------------------------------------------------
variable "labels" {
  description = "리소스에 추가할 레이블"
  type        = map(string)
  default     = {}
}

variable "annotations" {
  description = "Deployment에 추가할 annotations"
  type        = map(string)
  default     = {}
}

variable "pod_annotations" {
  description = "Pod에 추가할 annotations"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# 고급 설정
# -----------------------------------------------------------------------------
variable "image_pull_policy" {
  description = "이미지 Pull 정책"
  type        = string
  default     = "IfNotPresent"

  validation {
    condition     = contains(["Always", "IfNotPresent", "Never"], var.image_pull_policy)
    error_message = "image_pull_policy는 Always, IfNotPresent, Never 중 하나여야 합니다."
  }
}

variable "service_account_name" {
  description = "사용할 ServiceAccount 이름"
  type        = string
  default     = null
}

variable "rolling_update" {
  description = "Rolling Update 전략 설정"
  type = object({
    max_surge       = string
    max_unavailable = string
  })
  default = {
    max_surge       = "25%"
    max_unavailable = "25%"
  }
}