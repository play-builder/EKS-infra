#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DEFAULT_ENV="dev"
SKIP_CONFIRM=false
TARGET_LAYER=""
ENVIRONMENT=""

declare -a LAYERS_REVERSE=(
    "04-workloads/app-tier"
    "03-platform"
    "02-eks"
    "01-network"
)

log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1" >&2; }

log_step() {
    echo -e "\n${RED}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}${BOLD}  $1${NC}"
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
${BOLD}Usage:${NC}
    $(basename "$0") <environment> [options]

${BOLD}Environment:${NC}
    dev          Development environment
    prod         Production environment

${BOLD}Options:${NC}
    -l, --layer LAYER    Destroy specific layer only
    -y, --yes            Skip confirmation prompt
    -h, --help           Show help

${BOLD}Examples:${NC}
    $(basename "$0") dev
    $(basename "$0") dev -l 03-platform
    $(basename "$0") dev -y

EOF
}

parse_args() {
    if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
        ENVIRONMENT="$1"
        shift
    else
        ENVIRONMENT="${DEFAULT_ENV}"
    fi

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
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    ENV_DIR="${PROJECT_ROOT}/environments/${ENVIRONMENT}"
    if [[ ! -d "${ENV_DIR}" ]]; then
        log_error "Environment directory not found: ${ENV_DIR}"
        exit 1
    fi
}

run_terraform_destroy() {
    local layer_path="$1"
    local layer_name=$(basename "${layer_path}")
    
    local config_name=$(echo "${layer_name}" | sed -E 's/^[0-9]+-//')
    local config_file="${PROJECT_ROOT}/environments/${ENVIRONMENT}/config/${config_name}.tfbackend"

    log_step "Layer: ${layer_name} (Config: ${config_name}.tfbackend) Destroying..."

    cd "${layer_path}"

    if [[ -d ".terraform" ]]; then
        rm -rf .terraform .terraform.lock.hcl
    fi

    log_info "Running terraform init..."
    
    local init_cmd="terraform init -input=false -upgrade"

    if [[ -f "${config_file}" ]]; then
        log_info "Applying backend config: ${config_file}"
        init_cmd="${init_cmd} -backend-config=${config_file} -reconfigure"
    else
        log_warn "Config file not found (using default): ${config_file}"
    fi

    if ! ${init_cmd}; then
        log_error "terraform init failed: ${layer_name}"
        return 1
    fi

    local resource_count=$(terraform state list 2>/dev/null | wc -l || echo "0")
    if [[ "${resource_count}" -eq 0 ]]; then
        log_warn "${layer_name}: No resources to destroy (skipping)"
        return 0
    fi

    log_info "Destroy target: ${resource_count} resources"

    log_info "Running terraform destroy..."
    if ! terraform destroy -auto-approve; then
        log_error "terraform destroy failed: ${layer_name}"
        return 1
    fi

    log_success "${layer_name} destroy completed!"
}

confirm_destroy() {
    if [[ "${SKIP_CONFIRM}" == true ]]; then
        return 0
    fi

    echo ""
    echo -e "${RED}${BOLD}WARNING: This will destroy infrastructure!${NC}"
    echo ""
    echo -e "${YELLOW}Destroy Info:${NC}"
    echo -e "   Environment: ${BOLD}${ENVIRONMENT}${NC}"
    
    if [[ -n "${TARGET_LAYER}" ]]; then
        echo -e "   Target: ${BOLD}${TARGET_LAYER}${NC}"
    else
        echo -e "   Target: ${BOLD}All Layers${NC}"
        echo ""
        echo -e "${YELLOW}Destroy Order (reverse):${NC}"
        local i=1
        for layer in "${LAYERS_REVERSE[@]}"; do
            echo -e "   ${i}. ${layer}"
            ((i++))
        done
    fi

    echo ""
    
    if [[ "${ENVIRONMENT}" == "prod" ]]; then
        echo -e "${RED}${BOLD}PRODUCTION environment! Proceed with caution.${NC}"
        echo ""
        read -p "Enter environment name exactly [${ENVIRONMENT}]: " confirm_env
        if [[ "${confirm_env}" != "${ENVIRONMENT}" ]]; then
            log_error "Environment name does not match. Destroy cancelled."
            exit 1
        fi
    fi

    read -p "Are you sure you want to destroy? [yes/NO]: " confirm
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Destroy cancelled."
        exit 0
    fi
}

main() {
    print_banner
    parse_args "$@"

    confirm_destroy

    local start_time=$(date +%s)
    local env_dir="${PROJECT_ROOT}/environments/${ENVIRONMENT}"

    if [[ -n "${TARGET_LAYER}" ]]; then
        local layer_path="${env_dir}/${TARGET_LAYER}"
        if [[ ! -d "${layer_path}" ]]; then
            log_error "Layer not found: ${TARGET_LAYER}"
            exit 1
        fi
        run_terraform_destroy "${layer_path}"
    else
        for layer in "${LAYERS_REVERSE[@]}"; do
            local layer_path="${env_dir}/${layer}"
            if [[ -d "${layer_path}" ]]; then
                run_terraform_destroy "${layer_path}"
            else
                log_warn "Layer directory not found (skipping): ${layer}"
            fi
        done
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    echo ""
    log_step "Destroy completed!"
    log_success "Environment: ${ENVIRONMENT}"
    log_success "Duration: ${minutes}m ${seconds}s"
}

main "$@"

