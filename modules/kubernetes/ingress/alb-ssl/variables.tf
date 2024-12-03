# =============================================================================
# ALB SSL Ingress 모듈 - Variables
# =============================================================================
# 실무 관점: Ingress + ACM 인증서만 담당 (Deployment/Service는 app 모듈)
# 왜 분리: 
#   - 관심사 분리: 앱 배포와 트래픽 라우팅 분리
#   - 유연성: 여러 앱 모듈의 Service를 하나의 Ingress로 묶기
#   - 재사용: Ingress 설정 패턴 표준화
# =============================================================================

# -----------------------------------------------------------------------------
# 공통 설정
# -----------------------------------------------------------------------------
variable "environment" {
  description = "배포 환경 (dev, staging, prod)"
  type        = string
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
}

variable "namespace" {
  description = "Ingress가 생성될 네임스페이스"
  type        = string
  default     = "default"
}

# -----------------------------------------------------------------------------
# ACM 인증서 설정
# -----------------------------------------------------------------------------


variable "acm_certificate_arn" {
  description = "기존 ACM 인증서 ARN (create_acm_certificate=false 시 필수)"
  type        = string
}




# -----------------------------------------------------------------------------
# Ingress 기본 설정
# -----------------------------------------------------------------------------
variable "ingress_name" {
  description = "Ingress 리소스 이름"
  type        = string
  default     = "alb-ssl-ingress"
}

variable "ingress_class_name" {
  description = "Ingress Class 이름"
  type        = string
  default     = "my-aws-ingress-class"
}

variable "load_balancer_name" {
  description = "ALB 이름 (AWS 콘솔 표시용)"
  type        = string
  default     = "ssl-ingress-alb"
}

variable "alb_scheme" {
  description = "ALB 스킴 (internet-facing, internal)"
  type        = string
  default     = "internet-facing" # or "internal"
}

variable "ingress_hostnames" {
  description = "Ingress에 연결할 호스트네임 목록 (ExternalDNS 연동용)"
  type        = list(string)
  default     = [] # 예: ["playdevops.click", "api.playdevops.click"]
}

# =============================================================================
# 추가 Annotations (Ingress Group, WAF 등 설정 주입용)
# =============================================================================variable "additional_annotations" {
variable "additional_annotations" {
  description = "Ingress 리소스에 병합할 추가 Annotations (예: group.name, group.order)"
  type        = map(string)
  default     = {}
}
# -----------------------------------------------------------------------------
# SSL/TLS 설정
# -----------------------------------------------------------------------------
variable "ssl_redirect_enabled" {
  description = "HTTP → HTTPS 리다이렉트 활성화"
  type        = bool
  default     = true
}

variable "ssl_policy" {
  description = "SSL 보안 정책"
  type        = string
  default     = "ELBSecurityPolicy-TLS-1-2-2017-01"
}

# -----------------------------------------------------------------------------
# Health Check 설정 (기본값)
# -----------------------------------------------------------------------------
variable "health_check" {
  description = "ALB 헬스체크 기본 설정"
  type = object({
    protocol            = string
    port                = string
    interval_seconds    = number
    timeout_seconds     = number
    healthy_threshold   = number
    unhealthy_threshold = number
    success_codes       = string
  })
  default = {
    protocol            = "HTTP"
    port                = "traffic-port"
    interval_seconds    = 15
    timeout_seconds     = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    success_codes       = "200"
  }
}

# -----------------------------------------------------------------------------
# 백엔드 서비스 설정 (핵심!)
# 실무: app 모듈에서 생성한 Service들을 여기서 참조
# -----------------------------------------------------------------------------
variable "backend_services" {
  description = "Ingress에 연결할 백엔드 서비스 목록"
  type = list(object({
    name              = string # Service 이름
    port              = number # Service 포트
    path              = string # Ingress 라우팅 경로 (예: /app1)
    path_type         = string # Prefix, Exact, ImplementationSpecific
    health_check_path = string # ALB 헬스체크 경로
    is_default        = bool   # 기본 백엔드 여부
  }))




}

# =============================================================================
# [추가] Route53 설정 (DNS 검증용)
# =============================================================================
variable "hosted_zone_id" {
  description = "ACM 인증서 검증을 위한 Route53 Hosted Zone ID"
  type        = string
  default     = null # 기존 인증서 사용 시 불필요할 수 있으므로 null 허용
}

# -----------------------------------------------------------------------------
# 태그 설정
# -----------------------------------------------------------------------------
variable "tags" {
  description = "AWS 리소스 태그"
  type        = map(string)
  default     = {}
}