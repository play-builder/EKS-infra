#!/usr/bin/env bash
# =============================================================================
# destroy.sh - EKS Infrastructure 삭제 스크립트 (Partial Configuration 적용)
# =============================================================================
# 실행 순서: 04-workloads/app-tier → 03-platform → 02-eks → 01-network (역순!)
# =============================================================================

set -euo pipefail

# =============================================================================
# 설정
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 기본값
DEFAULT_ENV="dev"
SKIP_CONFIRM=false
TARGET_LAYER=""
ENVIRONMENT=""

# 레이어 정의 (삭제는 역순!)
declare -a LAYERS_REVERSE=(
    "04-workloads/app-tier"
    "03-platform"
    "02-eks"
    "01-network"
)

# =============================================================================
# 유틸리티 함수
# =============================================================================
log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1" >&2; }

log_step() {
    echo -e "\n${RED}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}${BOLD}  🗑️  $1${NC}"
    echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════════${NC}\n"
}

print_banner() {
    echo -e "${RED}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║          EKS Infrastructure - DESTROY (with Backend)          ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

usage() {
    cat << EOF
${BOLD}사용법:${NC}
    $(basename "$0") <environment> [options]

${BOLD}Environment:${NC}
    dev          개발 환경
    prod         프로덕션 환경

${BOLD}Options:${NC}
    -l, --layer LAYER    특정 레이어만 삭제
    -y, --yes            확인 프롬프트 건너뛰기
    -h, --help           도움말

${BOLD}Examples:${NC}
    $(basename "$0") dev
    $(basename "$0") dev -l 03-platform
    $(basename "$0") dev -y

EOF
}

# =============================================================================
# 인자 파싱
# =============================================================================
parse_args() {
    # 환경 설정
    if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
        ENVIRONMENT="$1"
        shift
    else
        ENVIRONMENT="${DEFAULT_ENV}"
    fi

    # 옵션 파싱
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--layer)
                TARGET_LAYER="$2"
                shift 2
                ;;
            -y|--yes)
                SKIP_CONFIRM=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "알 수 없는 옵션: $1"
                usage
                exit 1
                ;;
        esac
    done

    # 환경 디렉토리 검증
    ENV_DIR="${PROJECT_ROOT}/environments/${ENVIRONMENT}"
    if [[ ! -d "${ENV_DIR}" ]]; then
        log_error "환경 디렉토리가 없습니다: ${ENV_DIR}"
        exit 1
    fi
}

# =============================================================================
# Terraform 삭제 실행 (핵심 수정 적용)
# =============================================================================
run_terraform_destroy() {
    local layer_path="$1"
    local layer_name=$(basename "${layer_path}")
    
    # [설정 파일 찾기] deploy.sh와 동일한 로직 (숫자 제거)
    # 예: 01-network -> network.tfbackend
    local config_name=$(echo "${layer_name}" | sed -E 's/^[0-9]+-//')
    local config_file="${PROJECT_ROOT}/environments/${ENVIRONMENT}/config/${config_name}.tfbackend"

    log_step "Layer: ${layer_name} (Config: ${config_name}.tfbackend) 삭제 중..."

    cd "${layer_path}"

    # -------------------------------------------------------------------------
    # 0. 캐시 정리 (Backend configuration changed 에러 방지)
    # -------------------------------------------------------------------------
    if [[ -d ".terraform" ]]; then
        # log_info "기존 .terraform 캐시 정리 중..."
        rm -rf .terraform .terraform.lock.hcl
    fi

    # -------------------------------------------------------------------------
    # 1. Terraform Init (백엔드 설정 주입)
    # -------------------------------------------------------------------------
    log_info "terraform init 실행 중..."
    
    local init_cmd="terraform init -input=false -upgrade"

    # 설정 파일 주입
    if [[ -f "${config_file}" ]]; then
        log_info "백엔드 설정 적용: ${config_file}"
        init_cmd="${init_cmd} -backend-config=${config_file} -reconfigure"
    else
        log_warn "설정 파일을 찾을 수 없습니다 (기본 설정 사용): ${config_file}"
    fi

    # 명령어 실행 (매우 중요!)
    if ! ${init_cmd}; then
        log_error "terraform init 실패: ${layer_name}"
        return 1
    fi

    # 리소스 존재 여부 확인 (init 후 실행해야 함)
    local resource_count=$(terraform state list 2>/dev/null | wc -l || echo "0")
    if [[ "${resource_count}" -eq 0 ]]; then
        log_warn "${layer_name}: 삭제할 리소스 없음 (건너뜀)"
        return 0
    fi

    log_info "삭제 대상: ${resource_count}개 리소스"

    # -------------------------------------------------------------------------
    # 2. Terraform Destroy
    # -------------------------------------------------------------------------
    log_info "terraform destroy 실행 중..."
    if ! terraform destroy -auto-approve; then
        log_error "terraform destroy 실패: ${layer_name}"
        return 1
    fi

    log_success "✅ ${layer_name} 삭제 완료!"
}

# =============================================================================
# 확인 프롬프트 (삭제는 더 엄격하게!)
# =============================================================================
confirm_destroy() {
    if [[ "${SKIP_CONFIRM}" == true ]]; then
        return 0
    fi

    echo ""
    echo -e "${RED}${BOLD}⚠️  경고: 이 작업은 인프라를 삭제합니다!${NC}"
    echo ""
    echo -e "${YELLOW}📋 삭제 정보:${NC}"
    echo -e "   환경: ${BOLD}${ENVIRONMENT}${NC}"
    
    if [[ -n "${TARGET_LAYER}" ]]; then
        echo -e "   대상: ${BOLD}${TARGET_LAYER}${NC}"
    else
        echo -e "   대상: ${BOLD}전체 레이어${NC}"
        echo ""
        echo -e "${YELLOW}📦 삭제 순서 (역순):${NC}"
        local i=1
        for layer in "${LAYERS_REVERSE[@]}"; do
            echo -e "   ${i}. ${layer}"
            ((i++))
        done
    fi

    echo ""
    
    # prod 환경은 추가 확인
    if [[ "${ENVIRONMENT}" == "prod" ]]; then
        echo -e "${RED}${BOLD}🚨 프로덕션 환경입니다! 매우 신중하게 진행하세요.${NC}"
        echo ""
        read -p "환경 이름을 정확히 입력하세요 [${ENVIRONMENT}]: " confirm_env
        if [[ "${confirm_env}" != "${ENVIRONMENT}" ]]; then
            log_error "환경 이름이 일치하지 않습니다. 삭제를 취소합니다."
            exit 1
        fi
    fi

    read -p "정말로 삭제하시겠습니까? [yes/NO]: " confirm
    if [[ "${confirm}" != "yes" ]]; then
        log_info "삭제가 취소되었습니다."
        exit 0
    fi
}

# =============================================================================
# 메인 실행
# =============================================================================
main() {
    print_banner
    parse_args "$@"

    confirm_destroy

    local start_time=$(date +%s)
    local env_dir="${PROJECT_ROOT}/environments/${ENVIRONMENT}"

    # 실행할 레이어 결정
    if [[ -n "${TARGET_LAYER}" ]]; then
        local layer_path="${env_dir}/${TARGET_LAYER}"
        if [[ ! -d "${layer_path}" ]]; then
            log_error "레이어가 없습니다: ${TARGET_LAYER}"
            exit 1
        fi
        run_terraform_destroy "${layer_path}"
    else
        # 전체 레이어 역순 실행
        for layer in "${LAYERS_REVERSE[@]}"; do
            local layer_path="${env_dir}/${layer}"
            if [[ -d "${layer_path}" ]]; then
                run_terraform_destroy "${layer_path}"
            else
                log_warn "레이어 디렉토리 없음 (건너뜀): ${layer}"
            fi
        done
    fi

    # 완료 메시지
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    echo ""
    log_step "🗑️ 삭제 완료!"
    log_success "환경: ${ENVIRONMENT}"
    log_success "소요 시간: ${minutes}분 ${seconds}초"
}

main "$@"