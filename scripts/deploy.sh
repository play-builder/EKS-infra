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
DRY_RUN=false
SKIP_CONFIRM=false
VERBOSE=false
TARGET_LAYER=""
ENVIRONMENT=""
COMMAND=""

declare -a LAYERS=(
    "01-network"
    "02-eks"
    "03-platform"
    "04-workloads/app-tier"
)

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_step() {
    echo -e "\n${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}\n"
}

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║      Infrastructure Deployment Automation (with TF Backend)   ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

usage() {
    cat << EOF
${BOLD}Usage:${NC}
    $(basename "$0") <command> [environment] [options]

${BOLD}Commands:${NC}
    apply        Deploy full infrastructure
    destroy      Destroy full infrastructure
    plan         Show full infrastructure plan
    status       Show status of each layer

${BOLD}Environment:${NC}
    dev          Development environment (default)
    prod         Production environment

${BOLD}Options:${NC}
    -l, --layer LAYER    Execute specific layer only (e.g., 01-network)
    -y, --yes            Skip confirmation prompt
    -d, --dry-run        Output commands only without execution

${BOLD}Examples:${NC}
    $(basename "$0") apply dev
    $(basename "$0") destroy dev --yes
    $(basename "$0") plan dev -l 02-eks

EOF
}

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    COMMAND="$1"
    shift

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
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
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

    if [[ ! "${COMMAND}" =~ ^(apply|destroy|plan|status)$ ]]; then
        log_error "Unknown command: ${COMMAND}"
        usage
        exit 1
    fi

    ENV_DIR="${PROJECT_ROOT}/environments/${ENVIRONMENT}"
    if [[ ! -d "${ENV_DIR}" ]]; then
        log_error "Environment directory does not exist: ${ENV_DIR}"
        exit 1
    fi
}

run_terraform() {
    local layer_path="$1"
    local action="$2"
    local layer_name=$(basename "${layer_path}")
    
    local config_name=$(echo "${layer_name}" | sed -E 's/^[0-9]+-//')
    local config_file="${PROJECT_ROOT}/environments/${ENVIRONMENT}/config/${config_name}.tfbackend"
    
    log_step "Layer: ${layer_name} (Config: ${config_name}.tfbackend) - ${action^^}"
    
    cd "${layer_path}"
    
    if [[ "${DRY_RUN}" == true ]]; then
        log_warn "[DRY-RUN] The following commands will be executed:"
        echo "  cd ${layer_path}"
        
        if [[ -f "${config_file}" ]]; then
             echo "  # Remove existing .terraform"
             echo "  rm -rf .terraform .terraform.lock.hcl"
             echo "  terraform init -input=false -backend-config=${config_file} -reconfigure"
        else
             echo "  terraform init -input=false"
        fi
        
        echo "  terraform fmt -recursive"
        echo "  terraform validate"
        
        if [[ "${action}" == "apply" ]]; then
            echo "  terraform plan -out=tfplan"
            echo "  terraform apply -auto-approve tfplan"
        elif [[ "${action}" == "destroy" ]]; then
            echo "  terraform destroy -auto-approve"
        elif [[ "${action}" == "plan" ]]; then
            echo "  terraform plan"
        fi
        return 0
    fi

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

    log_info "Running terraform fmt..."
    terraform fmt -recursive

    log_info "Running terraform validate..."
    if ! terraform validate; then
        log_error "terraform validate failed: ${layer_name}"
        return 1
    fi

    case "${action}" in
        apply)
            log_info "Running terraform plan..."
            if ! terraform plan -out=tfplan; then
                log_error "terraform plan failed: ${layer_name}"
                return 1
            fi

            log_info "Running terraform apply..."
            if ! terraform apply -auto-approve tfplan; then
                log_error "terraform apply failed: ${layer_name}"
                return 1
            fi
            
            rm -f tfplan
            ;;
        destroy)
            log_info "Running terraform destroy..."
            if ! terraform destroy -auto-approve; then
                log_error "terraform destroy failed: ${layer_name}"
                return 1
            fi
            ;;
        plan)
            log_info "Running terraform plan..."
            terraform plan
            ;;
    esac

    log_success "Layer ${layer_name} ${action} completed!"
    return 0
}

check_layer_status() {
    local layer_path="$1"
    local layer_name=$(basename "${layer_path}")
    
    cd "${layer_path}"
    
    if [[ ! -d ".terraform" ]]; then
        echo -e "  ${YELLOW}○${NC} ${layer_name}: Not initialized"
        return
    fi

    if terraform state list &>/dev/null; then
        local resource_count=$(terraform state list 2>/dev/null | wc -l)
        if [[ ${resource_count} -gt 0 ]]; then
            echo -e "  ${GREEN}●${NC} ${layer_name}: Deployed (${resource_count} resources)"
        else
            echo -e "  ${YELLOW}○${NC} ${layer_name}: Initialized (no resources)"
        fi
    else
        echo -e "  ${YELLOW}○${NC} ${layer_name}: No state"
    fi
}

confirm_action() {
    local action="$1"
    local env="$2"
    
    if [[ "${SKIP_CONFIRM}" == true ]]; then
        return 0
    fi

    echo ""
    if [[ "${action}" == "destroy" ]]; then
        echo -e "${RED}${BOLD}WARNING: This will destroy all infrastructure!${NC}"
        echo -e "${RED}   Environment: ${env}${NC}"
        echo ""
    fi

    echo -e "${YELLOW}The following action will be performed:${NC}"
    echo -e "  Command: ${BOLD}${action}${NC}"
    echo -e "  Environment: ${BOLD}${env}${NC}"
    
    if [[ -n "${TARGET_LAYER}" ]]; then
        echo -e "  Target Layer: ${BOLD}${TARGET_LAYER}${NC}"
    else
        echo -e "  Target Layer: ${BOLD}All${NC}"
    fi
    
    echo ""
    
    if [[ "${action}" == "destroy" ]]; then
        read -p "Are you sure you want to destroy? Enter environment name [${env}]: " confirm
        if [[ "${confirm}" != "${env}" ]]; then
            log_error "Confirmation failed. Action cancelled."
            exit 1
        fi
    else
        read -p "Do you want to continue? [y/N]: " confirm
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
            log_info "Action cancelled."
            exit 0
        fi
    fi
}

execute_layers() {
    local action="$1"
    local env_dir="${PROJECT_ROOT}/environments/${ENVIRONMENT}"
    local layers_to_run=()
    local start_time=$(date +%s)

    if [[ -n "${TARGET_LAYER}" ]]; then
        local layer_path="${env_dir}/${TARGET_LAYER}"
        if [[ ! -d "${layer_path}" ]]; then
            log_error "Layer directory does not exist: ${layer_path}"
            exit 1
        fi
        layers_to_run=("${TARGET_LAYER}")
    else
        layers_to_run=("${LAYERS[@]}")
    fi

    if [[ "${action}" == "destroy" ]]; then
        local reversed=()
        for (( i=${#layers_to_run[@]}-1; i>=0; i-- )); do
            reversed+=("${layers_to_run[i]}")
        done
        layers_to_run=("${reversed[@]}")
    fi

    local failed_layer=""
    for layer in "${layers_to_run[@]}"; do
        local layer_path="${env_dir}/${layer}"
        
        if [[ ! -d "${layer_path}" ]]; then
            log_warn "Layer directory does not exist (skipping): ${layer_path}"
            continue
        fi

        if ! run_terraform "${layer_path}" "${action}"; then
            failed_layer="${layer}"
            break
        fi
    done

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    echo ""
    log_step "Execution Result"
    
    if [[ -n "${failed_layer}" ]]; then
        log_error "Action failed!"
        log_error "Failed layer: ${failed_layer}"
        log_info "Duration: ${minutes}m ${seconds}s"
        exit 1
    else
        log_success "All actions completed successfully!"
        log_info "Duration: ${minutes}m ${seconds}s"
    fi
}

show_status() {
    local env_dir="${PROJECT_ROOT}/environments/${ENVIRONMENT}"
    
    log_step "Infrastructure Status: ${ENVIRONMENT}"
    
    echo -e "\n${BOLD}Layer Status:${NC}"
    for layer in "${LAYERS[@]}"; do
        local layer_path="${env_dir}/${layer}"
        if [[ -d "${layer_path}" ]]; then
            check_layer_status "${layer_path}"
        else
            echo -e "  ${RED}X${NC} ${layer}: Directory not found"
        fi
    done
    echo ""
}

main() {
    print_banner
    parse_args "$@"

    log_info "Environment: ${ENVIRONMENT}"
    log_info "Command: ${COMMAND}"
    
    if [[ "${DRY_RUN}" == true ]]; then
        log_warn "DRY-RUN mode: Commands will be output without execution."
    fi

    case "${COMMAND}" in
        apply|destroy|plan)
            confirm_action "${COMMAND}" "${ENVIRONMENT}"
            execute_layers "${COMMAND}"
            ;;
        status)
            show_status
            ;;
    esac
}

main "$@"

