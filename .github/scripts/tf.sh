#!/bin/bash

# Terraform CI/CD Management Script - Version 2.3
#
# Usage: ./tf.sh [function] [arguments]
#
# Changelog from 2.2:
#     * Per-environment composition
#     * TERRAFORM_DIR is derived per-env from ENVS_ROOT + environment name
#     * Each env directory is a complete Terraform root
#     * terraform.tfvars is auto-loaded; no more -var-file plumbing
#     * state.config lives inside each env directory
#     * fmt and security scans target the repo root (modules/ + envs/)
#     * ENVIRONMENTS_DIR removed; replaced with ENVS_ROOT
#
# Changelog from 2.1:
#   - TF_SKIP_INIT env var
#   - TF_STATE_BACKUP_BUCKET / TF_STATE_BACKUP_KMS_KEY_ID — optional S3 backup
#   - Expanded security-scan to tfsec, conftest, shellcheck
#   - run_all_tests reordered — plan before security-scan
#
# Changelog from 2.0:
#   - Fixed default region (was us-gov-west-1)
#   - Fixed multi-tfvars handling (now obsolete in 2.3)
#   - Fixed cleanup outputs glob
#   - Fixed plan summary double-counting of replace actions
#   - Honest backup_state
#   - TTY/NO_COLOR-aware color output
#   - Expanded dependency checks
#   - Documentation aligned with code

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/tf-config.env"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Colors: only emit ANSI when stderr is a TTY and NO_COLOR is unset.
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; CYAN=''; NC=''
fi

# Load configuration if exists
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Default configuration
#
# Module model: each example under examples/ is its own Terraform root. The user
# specifies ENVS_ROOT (parent directory containing per-example subdirectories) and
# an example name. TERRAFORM_DIR is derived as "${ENVS_ROOT}/${ENVIRONMENT}".
#
# Examples of ENVS_ROOT in this project: ./examples
# (When called by module.sh, this is set to the absolute path.)
ENVS_ROOT="${ENVS_ROOT:-./examples}"

# TERRAFORM_ROOT is the module root — contains the module's own .tf files and is
# the target for repo-wide fmt and security scanning.
TERRAFORM_ROOT="${TERRAFORM_ROOT:-.}"

OUTPUT_DIR="${OUTPUT_DIR:-./outputs}"
PLANS_DIR="${PLANS_DIR:-./plans}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
PARALLELISM="${PARALLELISM:-10}"

# Skip implicit init, useful for CI where init was done in a prior step.
TF_SKIP_INIT="${TF_SKIP_INIT:-false}"

# Optional S3 state backup.
TF_STATE_BACKUP_BUCKET="${TF_STATE_BACKUP_BUCKET:-}"
TF_STATE_BACKUP_KMS_KEY_ID="${TF_STATE_BACKUP_KMS_KEY_ID:-}"

# Terraform-specific configuration
TF_LOG="${TF_LOG:-}"
TF_LOG_PATH="${TF_LOG_PATH:-}"
TF_DATA_DIR="${TF_DATA_DIR:-}"
TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-}"

# Logging functions
log_info()    { if [[ "$LOG_LEVEL" == "DEBUG" || "$LOG_LEVEL" == "INFO" ]]; then echo -e "${BLUE}[INFO]${NC} $1" >&2; fi; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_debug()   { if [[ "$LOG_LEVEL" == "DEBUG" ]]; then echo -e "${PURPLE}[DEBUG]${NC} $1" >&2; fi; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $1" >&2; }

# Utility functions
check_dependencies() {
    local required=("terraform" "jq")
    for dep in "${required[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "$dep is required but not installed"
            exit 1
        fi
    done

    local optional=("checkov:pip install checkov"
                    "tfsec:brew install tfsec (or see aquasecurity/tfsec)"
                    "conftest:brew install conftest (or see open-policy-agent/conftest)"
                    "shellcheck:apt install shellcheck / brew install shellcheck"
                    "infracost:brew install infracost (or see infracost.io/docs)")
    for entry in "${optional[@]}"; do
        local tool="${entry%%:*}"
        local install_hint="${entry#*:}"
        if ! command -v "$tool" &> /dev/null; then
            log_debug "Optional tool not found: $tool. Install: $install_hint"
        fi
    done
}

create_output_dirs() {
    mkdir -p "$OUTPUT_DIR" "$PLANS_DIR"
}

# env_dir: returns the absolute path to the Terraform working directory for
# the given environment.
env_dir() {
    local environment="$1"
    echo "${ENVS_ROOT%/}/${environment}"
}

# get_backend_config: returns the path (relative to env_dir) of the backend
# configuration file. Empty string + warning if not present.
get_backend_config() {
    local environment="$1"
    local backend_file
    backend_file="$(env_dir "$environment")/state.config"

    if [[ -f "$backend_file" ]]; then
        echo "state.config"
    else
        log_warn "No backend configuration file found at: $backend_file"
        echo ""
    fi
}

generate_plan_name() {
    local environment="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    echo "${environment}-plan-${timestamp}.tfplan"
}

# validate_environment: confirm the env directory exists and looks like a
# Terraform composition root.
validate_environment() {
    local environment="$1"
    local target
    target="$(env_dir "$environment")"

    if [[ ! -d "$target" ]]; then
        log_error "Environment directory not found: $target"
        log_info "Available environments under $ENVS_ROOT:"
        if [[ -d "$ENVS_ROOT" ]]; then
            find "$ENVS_ROOT" -maxdepth 1 -type d -not -path "$ENVS_ROOT" | while read -r dir; do
                echo "  - $(basename "$dir")"
            done
        fi
        return 1
    fi

    # Sanity check: at least one .tf file in the env directory
    if ! compgen -G "${target}/*.tf" > /dev/null; then
        log_error "No Terraform files found in env directory: $target"
        log_info "Each env directory must contain at minimum a main.tf"
        return 1
    fi

    log_debug "Environment validated: $target"
    return 0
}

# Terraform wrapper. Always cd's to the per-env working directory.
terraform_cmd() {
    local cmd="$1"
    shift

    local target
    target="$(env_dir "$ENVIRONMENT")"

    log_debug "Executing in $target: terraform $cmd $*"

    cd "$target"

    export TF_IN_AUTOMATION=1
    [[ -n "$TF_LOG" ]]              && export TF_LOG="$TF_LOG"
    [[ -n "$TF_LOG_PATH" ]]         && export TF_LOG_PATH="$TF_LOG_PATH"
    [[ -n "$TF_DATA_DIR" ]]         && export TF_DATA_DIR="$TF_DATA_DIR"
    [[ -n "$TF_PLUGIN_CACHE_DIR" ]] && export TF_PLUGIN_CACHE_DIR="$TF_PLUGIN_CACHE_DIR"

    terraform "$cmd" "$@"
    return $?
}

# Helper: skip init if TF_SKIP_INIT is truthy, else run it.
maybe_init() {
    local environment="$1"
    if [[ "$TF_SKIP_INIT" == "true" ]] || [[ "$TF_SKIP_INIT" == "1" ]]; then
        log_info "TF_SKIP_INIT is set; skipping terraform init"
        return 0
    fi
    init_terraform "$environment"
}

# Terraform initialization
init_terraform() {
    local environment="${1:-$ENVIRONMENT}"
    local upgrade="${2:-false}"

    # Ensure ENVIRONMENT is set for terraform_cmd
    ENVIRONMENT="$environment"

    log_step "Initializing Terraform for environment: $environment"

    if ! validate_environment "$environment"; then
        log_error "Environment not validated: $environment"
        return 1
    fi

    local init_args=()

    local backend_config
    backend_config=$(get_backend_config "$environment")
    if [[ -n "$backend_config" ]]; then
        log_info "Using backend config: $backend_config"
        init_args+=("-backend-config=$backend_config")
    else
        log_info "No backend config file found; using defaults from backend.tf"
    fi

    if [[ "$upgrade" == "--upgrade" ]] || [[ "$upgrade" == "true" ]]; then
        init_args+=("-upgrade")
        log_info "Upgrading provider plugins"
    fi

    init_args+=("-input=false")
    init_args+=("-reconfigure")

    if terraform_cmd "init" "${init_args[@]}"; then
        log_success "Terraform initialization completed for environment: $environment"
        return 0
    else
        log_error "Terraform initialization failed"
        return 1
    fi
}

# List available environments
list_environments() {
    log_info "Available environments under: $ENVS_ROOT"
    if [[ ! -d "$ENVS_ROOT" ]]; then
        log_error "Envs directory not found: $ENVS_ROOT"
        return 1
    fi

    find "$ENVS_ROOT" -maxdepth 1 -type d -not -path "$ENVS_ROOT" | while read -r env_dir; do
        if [[ -d "$env_dir" ]]; then
            local env_name
            env_name=$(basename "$env_dir")
            echo "  - $env_name"

            if [[ -f "${env_dir}/state.config" ]]; then
                echo "      backend: state.config (present)"
            else
                echo "      backend: NOT FOUND (state.config missing)"
            fi

            if [[ -f "${env_dir}/terraform.tfvars" ]]; then
                echo "      vars:    terraform.tfvars (auto-loaded)"
            else
                echo "      vars:    no terraform.tfvars (variables must come from env/CLI)"
            fi
            echo ""
        fi
    done
}


# Validation functions
validate_terraform() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"

    log_step "Validating Terraform configuration for env: $environment"

    if ! validate_environment "$environment"; then
        return 1
    fi

    if terraform_cmd "validate"; then
        log_success "Terraform validation passed"
        return 0
    else
        log_error "Terraform validation failed"
        return 1
    fi
}

# format_terraform: runs `terraform fmt -recursive` against the entire
# TERRAFORM_ROOT (which contains both modules/ and envs/). This catches
# formatting issues in shared modules even when invoked from a single env.
format_terraform() {
    local check_only="${1:-false}"

    log_step "Formatting Terraform configuration (root: $TERRAFORM_ROOT)"

    local fmt_args=("-recursive" "-diff")
    if [[ "$check_only" == "--check" ]] || [[ "$check_only" == "true" ]]; then
        fmt_args+=("-check")
        log_info "Checking format only (no changes will be made)"
    else
        log_info "Formatting files (changes will be made)"
    fi

    # We do NOT use terraform_cmd here because that cd's into an env directory.
    # fmt should run against the whole tree.
    if (cd "$TERRAFORM_ROOT" && terraform fmt "${fmt_args[@]}" .); then
        log_success "Terraform formatting completed"
        return 0
    else
        log_error "Terraform formatting failed or files need formatting"
        return 1
    fi
}

# Security scanning — runs each tool that is installed.
# Targets the repo's terraform/ root so modules/ are also covered.
security_scan_terraform() {
    local environment="${1:-$ENVIRONMENT}"
    local exit_code=0
    local tools_run=0
    local tools_skipped=0

    log_step "Running security scans (root: $TERRAFORM_ROOT)"
    create_output_dirs

    if command -v "checkov" &> /dev/null; then
        log_info "Running checkov"
        run_checkov_scan || exit_code=1
        (( tools_run++ ))
    else
        log_warn "checkov not found, skipping (install: pip install checkov)"
        (( tools_skipped++ ))
    fi

    if command -v "tfsec" &> /dev/null; then
        log_info "Running tfsec"
        run_tfsec_scan || exit_code=1
        (( tools_run++ ))
    else
        log_warn "tfsec not found, skipping (install: brew install tfsec)"
        (( tools_skipped++ ))
    fi

    if command -v "shellcheck" &> /dev/null; then
        log_info "Running shellcheck on scripts/"
        run_shellcheck_scan || exit_code=1
        (( tools_run++ ))
    else
        log_warn "shellcheck not found, skipping (install: brew install shellcheck)"
        (( tools_skipped++ ))
    fi

    # conftest — only meaningful if we have a plan artifact AND policies exist
    if ! command -v "conftest" &> /dev/null; then
        log_warn "conftest not found, skipping (install: brew install conftest)"
        (( tools_skipped++ ))
    elif [[ ! -d "${TERRAFORM_ROOT}/../policies/conftest" ]]; then
        log_warn "conftest installed but no policies found at policies/conftest/ — skipping"
        (( tools_skipped++ ))
    else
        local plan_summary="${OUTPUT_DIR}/plan-summary-${environment}.json"
        if [[ -f "$plan_summary" ]]; then
            log_info "Running conftest against plan output for $environment"
            run_conftest_scan "$plan_summary" || exit_code=1
            (( tools_run++ ))
        else
            log_warn "conftest available but no plan output found at $plan_summary"
            log_warn "Run 'plan $environment' first to enable conftest policy checks"
            (( tools_skipped++ ))
        fi
    fi

    echo ""
    log_info "Security scan summary: ${tools_run} tool(s) ran, ${tools_skipped} skipped"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Security scan found issues — see above"
    elif [[ $tools_skipped -gt 0 && $tools_run -eq 0 ]]; then
        log_warn "Security scan incomplete: no tools ran — install missing tools before merging"
    elif [[ $tools_skipped -gt 0 ]]; then
        log_warn "Security scan partial: ${tools_skipped} tool(s) were skipped — results are not exhaustive"
    else
        log_success "Security scan clean: all tools ran and found no issues"
    fi

    return $exit_code
}

run_checkov_scan() {
    local output_file="${OUTPUT_DIR}/checkov-results.json"
    local config_file="${TERRAFORM_ROOT}/../policies/checkov/.checkov.yml"
    local checkov_args=(-d "$TERRAFORM_ROOT" --framework terraform)

    if [[ -f "$config_file" ]]; then
        checkov_args+=(--config-file "$config_file")
    else
        log_warn "Checkov config not found at $config_file — running without policy config"
    fi

    # Run checkov and capture JSON output. Checkov exits non-zero both when it
    # finds issues AND on hard errors, so we drive pass/fail from the JSON file,
    # not the exit code. Use || true so set -e doesn't fire prematurely.
    checkov "${checkov_args[@]}" --output json > "$output_file" 2>&1 || true

    # Checkov 2.x wraps results under a `.results` key; checkov 3.x emits a flat
    # summary `{passed, failed, skipped, resource_count}` — including when no
    # resources matched any checks (resource_count=0). Support both.
    local failed_checks
    if jq -e '.results.failed_checks' "$output_file" > /dev/null 2>&1; then
        failed_checks=$(jq '.results.failed_checks | length' "$output_file")
    elif jq -e '.failed' "$output_file" > /dev/null 2>&1; then
        failed_checks=$(jq '.failed' "$output_file")
    else
        log_error "Checkov scan failed — could not parse output (see ${output_file})"
        cat "$output_file" >&2 || true
        return 1
    fi

    if [[ "$failed_checks" -gt 0 ]]; then
        log_warn "Checkov found $failed_checks security issue(s)"
        checkov "${checkov_args[@]}" --compact || true
        return 1
    fi

    log_success "Checkov scan completed"
    return 0
}

run_tfsec_scan() {
    local output_file="${OUTPUT_DIR}/tfsec-results.json"

    if tfsec "$TERRAFORM_ROOT" --format json > "$output_file" 2>/dev/null; then
        log_success "tfsec scan completed with no issues"
        return 0
    else
        local exit_code=$?
        local issue_count
        issue_count=$(jq '.results | length' "$output_file" 2>/dev/null || echo "0")

        if [[ "$issue_count" -gt 0 ]]; then
            log_warn "tfsec found $issue_count issue(s)"
            tfsec "$TERRAFORM_ROOT" --soft-fail >&2 || true
            return 1
        else
            log_error "tfsec scan failed (exit $exit_code)"
            return 1
        fi
    fi
}

run_shellcheck_scan() {
    local failed=0
    local script_files=()
    while IFS= read -r -d '' f; do
        script_files+=("$f")
    done < <(find "${SCRIPT_DIR}" -type f \( -name "*.sh" -o -name "*.bash" \) -print0)

    if [[ ${#script_files[@]} -eq 0 ]]; then
        log_debug "No shell scripts found under ${SCRIPT_DIR}"
        return 0
    fi

    for script in "${script_files[@]}"; do
        if ! shellcheck "$script"; then
            failed=1
        fi
    done

    if [[ $failed -eq 0 ]]; then
        log_success "shellcheck passed on ${#script_files[@]} script(s)"
        return 0
    else
        log_warn "shellcheck found issues"
        return 1
    fi
}

run_conftest_scan() {
    local plan_json="$1"
    local policy_dir="./policies/conftest"
    local output_file="${OUTPUT_DIR}/conftest-results.json"

    if conftest test --policy "$policy_dir" --output json "$plan_json" > "$output_file"; then
        log_success "conftest policies passed"
        return 0
    else
        log_warn "conftest found policy violations"
        conftest test --policy "$policy_dir" "$plan_json" >&2 || true
        return 1
    fi
}


# Planning
#
# Note: terraform.tfvars in the env directory is auto-loaded by Terraform.
# We do not need to pass -var-file explicitly.
plan_terraform() {
    local environment="${1:-$ENVIRONMENT}"
    local destroy_plan="${2:-false}"
    local detailed_exitcode="${3:-false}"

    ENVIRONMENT="$environment"

    log_step "Creating Terraform execution plan for environment: $environment"

    if ! validate_environment "$environment"; then
        return 1
    fi

    create_output_dirs
    local plan_file
    plan_file="${PLANS_DIR}/$(generate_plan_name "$environment")"

    local plan_args=()
    plan_args+=("-input=false")
    plan_args+=("-out=$plan_file")
    plan_args+=("-parallelism=$PARALLELISM")

    if [[ "$detailed_exitcode" == "--detailed-exitcode" ]] || [[ "$detailed_exitcode" == "true" ]]; then
        plan_args+=("-detailed-exitcode")
    fi

    if [[ "$destroy_plan" == "--destroy" ]] || [[ "$destroy_plan" == "true" ]]; then
        plan_args+=("-destroy")
        log_info "Creating destroy plan"
    fi

    log_debug "Plan arguments: ${plan_args[*]}"

    if terraform_cmd "plan" "${plan_args[@]}"; then
        log_success "Terraform plan created successfully"
        log_info "Plan saved to: $plan_file"
        echo "$plan_file" > "${OUTPUT_DIR}/latest-plan-${environment}.txt"
        show_plan_summary "$plan_file" "$environment"
        return 0
    else
        local exit_code=$?
        if [[ "$detailed_exitcode" == "true" ]] && [[ $exit_code -eq 2 ]]; then
            log_info "Plan completed with changes (exit code 2)"
            log_info "Plan saved to: $plan_file"
            echo "$plan_file" > "${OUTPUT_DIR}/latest-plan-${environment}.txt"
            show_plan_summary "$plan_file" "$environment"
            return 0
        else
            log_error "Terraform plan failed"
            return $exit_code
        fi
    fi
}

show_plan_summary() {
    local plan_file="$1"
    local environment="$2"

    log_info "=== PLAN SUMMARY ==="

    local summary_file="${OUTPUT_DIR}/plan-summary-${environment}.json"
    if terraform_cmd "show" "-json" "$plan_file" > "$summary_file"; then
        local to_add to_change to_destroy to_replace
        to_add=$(jq     '[.resource_changes[] | select((.change.actions | sort) == ["create"])]          | length' "$summary_file")
        to_change=$(jq  '[.resource_changes[] | select((.change.actions | sort) == ["update"])]          | length' "$summary_file")
        to_destroy=$(jq '[.resource_changes[] | select((.change.actions | sort) == ["delete"])]          | length' "$summary_file")
        to_replace=$(jq '[.resource_changes[] | select((.change.actions | sort) == ["create","delete"])] | length' "$summary_file")

        echo "Resources to add:     $to_add"
        echo "Resources to change:  $to_change"
        echo "Resources to destroy: $to_destroy"
        echo "Resources to replace: $to_replace"
        echo ""

        local total=$((to_add + to_change + to_destroy + to_replace))
        if [[ $total -gt 0 ]]; then
            log_info "=== DETAILED CHANGES ==="

            if [[ $to_add -gt 0 ]]; then
                echo "Resources to be created:"
                jq -r '.resource_changes[] | select((.change.actions | sort) == ["create"]) | "  + \(.address)"' "$summary_file"
                echo ""
            fi
            if [[ $to_change -gt 0 ]]; then
                echo "Resources to be modified:"
                jq -r '.resource_changes[] | select((.change.actions | sort) == ["update"]) | "  ~ \(.address)"' "$summary_file"
                echo ""
            fi
            if [[ $to_destroy -gt 0 ]]; then
                echo "Resources to be destroyed:"
                jq -r '.resource_changes[] | select((.change.actions | sort) == ["delete"]) | "  - \(.address)"' "$summary_file"
                echo ""
            fi
            if [[ $to_replace -gt 0 ]]; then
                echo "Resources to be replaced (destroy + recreate):"
                jq -r '.resource_changes[] | select((.change.actions | sort) == ["create","delete"]) | "  ± \(.address)"' "$summary_file"
                echo ""
            fi
        else
            log_info "No changes. Infrastructure is up-to-date."
        fi

        {
            echo "Plan Summary - $(date)"
            echo "Environment: $environment"
            echo "====================="
            echo "Resources to add:     $to_add"
            echo "Resources to change:  $to_change"
            echo "Resources to destroy: $to_destroy"
            echo "Resources to replace: $to_replace"
            echo ""
            echo "Plan file: $plan_file"
        } > "${OUTPUT_DIR}/plan-summary-${environment}.txt"
    else
        log_warn "Could not generate plan summary"
        terraform_cmd "show" "$plan_file"
    fi
}

# Apply changes
apply_terraform() {
    local environment="${1:-$ENVIRONMENT}"
    local plan_file="${2:-}"
    local auto_approve="${3:-$AUTO_APPROVE}"

    ENVIRONMENT="$environment"

    log_step "Applying Terraform configuration for environment: $environment"

    if ! validate_environment "$environment"; then
        return 1
    fi

    local apply_args=()
    apply_args+=("-input=false")
    apply_args+=("-parallelism=$PARALLELISM")

    # If a plan file path is given, ensure it's absolute (we'll cd into env dir).
    if [[ -n "$plan_file" ]]; then
        if [[ ! -f "$plan_file" ]]; then
            log_error "Plan file not found: $plan_file"
            return 1
        fi
        # Resolve to absolute path before terraform_cmd cd's away.
        plan_file="$(cd "$(dirname "$plan_file")" && pwd)/$(basename "$plan_file")"
    else
        if [[ -f "${OUTPUT_DIR}/latest-plan-${environment}.txt" ]]; then
            plan_file=$(cat "${OUTPUT_DIR}/latest-plan-${environment}.txt")
            if [[ -f "$plan_file" ]]; then
                plan_file="$(cd "$(dirname "$plan_file")" && pwd)/$(basename "$plan_file")"
                log_info "Using latest plan file: $plan_file"
            else
                log_warn "Latest plan file not found, applying without plan"
                plan_file=""
            fi
        else
            log_info "No plan file specified, applying current configuration"
        fi
    fi

    if [[ "$auto_approve" == "--auto-approve" ]] || [[ "$auto_approve" == "true" ]]; then
        apply_args+=("-auto-approve")
        log_info "Auto-approve enabled"
    fi

    if [[ -n "$plan_file" ]]; then
        apply_args+=("$plan_file")
    fi

    log_debug "Apply arguments: ${apply_args[*]}"

    backup_state "$environment"

    if terraform_cmd "apply" "${apply_args[@]}"; then
        log_success "Terraform apply completed successfully"
        get_terraform_outputs "$environment"

        if [[ -n "$plan_file" ]] && [[ -f "$plan_file" ]]; then
            log_info "Cleaning up plan file: $plan_file"
            rm -f "$plan_file"
            rm -f "${OUTPUT_DIR}/latest-plan-${environment}.txt"
        fi

        return 0
    else
        log_error "Terraform apply failed"
        return 1
    fi
}

# Destroy infrastructure
destroy_terraform() {
    local environment="${1:-$ENVIRONMENT}"
    local auto_approve="${2:-false}"
    local target="${3:-}"

    ENVIRONMENT="$environment"

    log_step "Destroying Terraform-managed infrastructure for environment: $environment"

    if ! validate_environment "$environment"; then
        return 1
    fi

    local destroy_args=()
    destroy_args+=("-input=false")
    destroy_args+=("-parallelism=$PARALLELISM")

    if [[ "$auto_approve" == "--auto-approve" ]] || [[ "$auto_approve" == "true" ]]; then
        destroy_args+=("-auto-approve")
        log_info "Auto-approve enabled"
    fi

    if [[ -n "$target" ]]; then
        destroy_args+=("-target=$target")
        log_info "Targeting specific resource: $target"
    fi

    log_debug "Destroy arguments: ${destroy_args[*]}"

    backup_state "$environment"

    if [[ "$auto_approve" != "true" ]] && [[ "$auto_approve" != "--auto-approve" ]]; then
        log_warn "This will destroy infrastructure managed by Terraform!"
        log_warn "Environment: $environment"
        log_warn "Make sure you have backups and this is what you want to do."
    fi

    if terraform_cmd "destroy" "${destroy_args[@]}"; then
        log_success "Terraform destroy completed successfully"
        return 0
    else
        log_error "Terraform destroy failed"
        return 1
    fi
}

# State management
backup_state() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"

    create_output_dirs
    local backup_file
    # Resolve to an absolute path before terraform_cmd cd's into the env dir;
    # a relative OUTPUT_DIR would silently resolve to the wrong location after the cd.
    backup_file="$(cd "${OUTPUT_DIR}" && pwd)/terraform-state-backup-${environment}-$(date +%Y%m%d-%H%M%S).tfstate"

    log_info "Creating state backup: $backup_file"

    if terraform_cmd "state" "pull" > "$backup_file" && [[ -s "$backup_file" ]]; then
        log_success "State backup created: $backup_file"

        if [[ -n "$TF_STATE_BACKUP_BUCKET" ]]; then
            upload_state_backup_to_s3 "$backup_file" "$environment" || true
        else
            log_debug "TF_STATE_BACKUP_BUCKET not set; state backup is local-only"
        fi
        return 0
    else
        log_warn "Failed to create state backup (empty or error)"
        rm -f "$backup_file"
        return 1
    fi
}

upload_state_backup_to_s3() {
    local backup_file="$1"
    local environment="$2"

    if ! command -v aws &> /dev/null; then
        log_warn "aws CLI not available; skipping S3 state backup upload"
        return 1
    fi

    local backup_filename
    backup_filename=$(basename "$backup_file")
    local s3_path="s3://${TF_STATE_BACKUP_BUCKET}/terraform-state-backups/${environment}/${backup_filename}"

    local aws_args=("s3" "cp" "$backup_file" "$s3_path")
    if [[ -n "$TF_STATE_BACKUP_KMS_KEY_ID" ]]; then
        aws_args+=("--sse" "aws:kms" "--sse-kms-key-id" "$TF_STATE_BACKUP_KMS_KEY_ID")
        log_info "Uploading state backup to S3 with SSE-KMS: $s3_path"
    else
        aws_args+=("--sse" "AES256")
        log_info "Uploading state backup to S3 with SSE-S3: $s3_path"
    fi

    if aws "${aws_args[@]}"; then
        log_success "State backup uploaded to: $s3_path"
        return 0
    else
        log_warn "Failed to upload state backup to S3: $s3_path (local backup still available)"
        return 1
    fi
}

refresh_state() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"

    log_step "Refreshing Terraform state for environment: $environment"

    if ! validate_environment "$environment"; then
        return 1
    fi

    backup_state "$environment"

    if terraform_cmd "refresh" "-input=false"; then
        log_success "Terraform state refreshed successfully"
        return 0
    else
        log_error "Terraform state refresh failed"
        return 1
    fi
}

list_state_resources() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"
    log_info "Listing resources in Terraform state for env: $environment"
    terraform_cmd "state" "list"
}

show_state_resource() {
    local environment="${1:-$ENVIRONMENT}"
    local resource="${2:-}"
    ENVIRONMENT="$environment"

    if [[ -z "$resource" ]]; then
        log_error "Resource address is required"
        return 1
    fi
    log_info "Showing state for resource: $resource"
    terraform_cmd "state" "show" "$resource"
}

# Import existing resources
import_resource() {
    local environment="${1:-$ENVIRONMENT}"
    local resource_address="${2:-}"
    local resource_id="${3:-}"

    ENVIRONMENT="$environment"

    if [[ -z "$resource_address" ]] || [[ -z "$resource_id" ]]; then
        log_error "Resource address and resource ID are required"
        log_info "Usage: import <environment> <resource_address> <resource_id>"
        return 1
    fi

    log_step "Importing existing resource into Terraform state"
    log_info "Environment: $environment"
    log_info "Resource address: $resource_address"
    log_info "Resource ID: $resource_id"

    if ! validate_environment "$environment"; then
        return 1
    fi

    backup_state "$environment"

    if terraform_cmd "import" "$resource_address" "$resource_id"; then
        log_success "Resource imported successfully"
        return 0
    else
        log_error "Resource import failed"
        return 1
    fi
}

# Taint/Untaint resources (legacy — replace with `terraform apply -replace=...` in newer code)
taint_resource() {
    local environment="${1:-$ENVIRONMENT}"
    local resource="${2:-}"
    ENVIRONMENT="$environment"

    if [[ -z "$resource" ]]; then
        log_error "Resource address is required"
        return 1
    fi
    log_step "Tainting resource for recreation: $resource"
    if terraform_cmd "taint" "$resource"; then
        log_success "Resource tainted successfully"
        return 0
    else
        log_error "Failed to taint resource"
        return 1
    fi
}

untaint_resource() {
    local environment="${1:-$ENVIRONMENT}"
    local resource="${2:-}"
    ENVIRONMENT="$environment"

    if [[ -z "$resource" ]]; then
        log_error "Resource address is required"
        return 1
    fi
    log_step "Removing taint from resource: $resource"
    if terraform_cmd "untaint" "$resource"; then
        log_success "Resource untainted successfully"
        return 0
    else
        log_error "Failed to untaint resource"
        return 1
    fi
}

# Output management
get_terraform_outputs() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"
    log_info "Getting Terraform outputs for environment: $environment"
    create_output_dirs

    if terraform_cmd "output" "-json" > "${OUTPUT_DIR}/terraform-outputs-${environment}.json"; then
        terraform_cmd "output"
        log_info "Outputs saved to: ${OUTPUT_DIR}/terraform-outputs-${environment}.json"
        return 0
    else
        log_warn "No outputs found or failed to get outputs"
        return 1
    fi
}

get_specific_output() {
    local environment="${1:-$ENVIRONMENT}"
    local output_name="${2:-}"
    ENVIRONMENT="$environment"

    if [[ -z "$output_name" ]]; then
        log_error "Output name is required"
        return 1
    fi
    terraform_cmd "output" "$output_name"
}

# Show commands
show_plan_file() {
    local environment="${1:-$ENVIRONMENT}"
    local plan_file="${2:-}"
    ENVIRONMENT="$environment"

    if [[ -z "$plan_file" ]]; then
        if [[ -f "${OUTPUT_DIR}/latest-plan-${environment}.txt" ]]; then
            plan_file=$(cat "${OUTPUT_DIR}/latest-plan-${environment}.txt")
        else
            log_error "No plan file specified and no latest plan found for environment: $environment"
            return 1
        fi
    fi

    if [[ ! -f "$plan_file" ]]; then
        log_error "Plan file not found: $plan_file"
        return 1
    fi

    plan_file="$(cd "$(dirname "$plan_file")" && pwd)/$(basename "$plan_file")"
    log_info "Showing plan file: $plan_file"
    terraform_cmd "show" "$plan_file"
}

# Graph generation
generate_graph() {
    local environment="${1:-$ENVIRONMENT}"
    local output_format="${2:-dot}"
    local output_file="${3:-}"

    ENVIRONMENT="$environment"

    log_step "Generating Terraform dependency graph for environment: $environment"

    if ! validate_environment "$environment"; then
        return 1
    fi

    create_output_dirs

    if [[ -z "$output_file" ]]; then
        # Make absolute since terraform_cmd will cd into env dir
        output_file="$(cd "$OUTPUT_DIR" && pwd)/terraform-graph-${environment}.${output_format}"
    fi

    local graph_args=()
    if [[ "$output_format" != "dot" ]]; then
        graph_args+=("-type=$output_format")
    fi

    if terraform_cmd "graph" "${graph_args[@]}" > "$output_file"; then
        log_success "Dependency graph generated: $output_file"
        if [[ "$output_format" == "dot" ]]; then
            log_info "To visualize: dot -Tpng $output_file -o ${output_file%.dot}.png"
        fi
        return 0
    else
        log_error "Failed to generate dependency graph"
        return 1
    fi
}

# Provider management
show_providers() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"
    log_info "Showing provider requirements for env: $environment"
    terraform_cmd "providers"
}

show_provider_schemas() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"
    local output_file="${OUTPUT_DIR}/provider-schemas-${environment}.json"
    log_info "Generating provider schemas for env: $environment"
    create_output_dirs

    if terraform_cmd "providers" "schema" "-json" > "$output_file"; then
        log_success "Provider schemas saved to: $output_file"
        log_info "Provider summary:"
        jq -r '.provider_schemas | keys[]' "$output_file" | while read -r provider; do
            echo "  - $provider"
        done
        return 0
    else
        log_error "Failed to generate provider schemas"
        return 1
    fi
}

# Console
open_console() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"
    log_info "Opening Terraform console for environment: $environment"

    if ! validate_environment "$environment"; then
        return 1
    fi

    log_info "Type 'exit' to quit the console"
    terraform_cmd "console"
}

show_version() {
    log_info "Terraform version information:"
    terraform version
}

# Force unlock state
force_unlock_state() {
    local environment="${1:-$ENVIRONMENT}"
    local lock_id="${2:-}"
    local force="${3:-false}"

    ENVIRONMENT="$environment"

    if [[ -z "$lock_id" ]]; then
        log_error "Lock ID is required"
        log_info "Usage: force-unlock <environment> <lock_id> [--force]"
        return 1
    fi

    log_step "Force unlocking Terraform state for env: $environment"
    log_warn "Lock ID: $lock_id"

    local unlock_args=("$lock_id")
    if [[ "$force" == "--force" ]] || [[ "$force" == "true" ]]; then
        unlock_args=("-force" "$lock_id")
        log_warn "Force flag enabled - no confirmation will be requested"
    fi

    if terraform_cmd "force-unlock" "${unlock_args[@]}"; then
        log_success "State unlocked successfully"
        return 0
    else
        log_error "Failed to unlock state"
        return 1
    fi
}

# Test runner
# Order: init -> fmt-check -> validate -> plan -> security-scan
run_all_tests() {
    local environment="${1:-$ENVIRONMENT}"
    ENVIRONMENT="$environment"

    log_step "Running all Terraform tests and validations for environment: $environment"

    local exit_code=0

    log_info "Step 1: Ensuring Terraform is initialized for environment: $environment"
    if ! init_terraform "$environment"; then
        exit_code=1
    fi

    log_info "Step 2: Checking Terraform formatting (entire tree)"
    if ! format_terraform "--check"; then
        exit_code=1
    fi

    log_info "Step 3: Validating Terraform configuration for $environment"
    if ! validate_terraform "$environment"; then
        exit_code=1
    fi

    log_info "Step 4: Running terraform plan for environment: $environment (read-only; output used by conftest in step 5)"
    if ! plan_terraform "$environment" "false" "true"; then
        exit_code=1
    fi

    log_info "Step 5: Running security scans (including policy checks against plan)"
    if ! security_scan_terraform "$environment"; then
        exit_code=1
    fi

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log_success "All tests passed successfully!"
        log_info "Configuration is ready for deployment to environment: $environment"
    else
        log_error "Some tests failed!"
        log_info "Please review the output above and fix any issues"
    fi

    return $exit_code
}

# Cost estimation (if tools available)
#
# plan_json (optional): path to a terraform show -json plan file. If provided,
# infracost uses it instead of scanning the Terraform directory, avoiding a
# second plan run. deploy.sh passes the auto-generated plan-summary-<env>.json
# when it exists; callers can also pass a custom path via --plan-file.
estimate_costs() {
    local environment="${1:-$ENVIRONMENT}"
    local plan_json="${2:-}"
    ENVIRONMENT="$environment"
    log_step "Estimating infrastructure costs for environment: $environment"

    if ! validate_environment "$environment"; then
        return 1
    fi

    create_output_dirs

    if command -v "infracost" &> /dev/null; then
        run_infracost_estimate "$environment" "$plan_json"
    else
        log_warn "infracost not found (install: brew install infracost)"
        log_warn "See https://www.infracost.io/docs for all install options"
        return 1
    fi
}

run_infracost_estimate() {
    local environment="$1"
    local plan_json="${2:-}"
    local target
    target="$(env_dir "$environment")"

    create_output_dirs
    local cost_file="${OUTPUT_DIR}/cost-estimate-${environment}.json"
    local cost_html="${OUTPUT_DIR}/cost-estimate-${environment}.html"
    local cost_txt="${OUTPUT_DIR}/cost-estimate-${environment}.txt"

    local infracost_path
    if [[ -n "$plan_json" ]]; then
        if [[ ! -f "$plan_json" ]]; then
            log_error "Plan JSON file not found: $plan_json"
            return 1
        fi
        log_info "Using plan JSON: $plan_json"
        infracost_path="$plan_json"
    else
        # infracost can target a Terraform directory directly. Since terraform.tfvars
        # is auto-loaded, we don't need --terraform-var-file.
        log_info "Scanning Terraform directory: $target"
        infracost_path="$target"
    fi

    if infracost breakdown --path "$infracost_path" --format json > "$cost_file"; then
        log_success "Cost estimate generated: $cost_file"
        if infracost output --path "$cost_file" --format html > "$cost_html"; then
            log_info "HTML cost report: $cost_html"
        fi
        infracost output --path "$cost_file" --format table | tee "$cost_txt"
        log_info "Text cost report: $cost_txt"
        return 0
    else
        log_error "Cost estimation failed"
        return 1
    fi
}

# Clean up function
cleanup_terraform() {
    local environment="${1:-$ENVIRONMENT}"
    local cleanup_type="${2:-plans}"

    log_step "Cleaning up Terraform artifacts for environment: $environment"

    case "$cleanup_type" in
        "plans")
            log_info "Cleaning up plan files older than 7 days"
            find "$PLANS_DIR" -name "${environment}-plan-*.tfplan" -mtime +7 -delete 2>/dev/null || true
            log_success "Old plan files cleaned up"
            ;;
        "outputs")
            log_info "Cleaning up output files for environment: $environment"
            rm -f "${OUTPUT_DIR}/terraform-outputs-${environment}.json" \
                  "${OUTPUT_DIR}/terraform-graph-${environment}".* \
                  "${OUTPUT_DIR}/cost-estimate-${environment}".* \
                  "${OUTPUT_DIR}/plan-summary-${environment}".* \
                  "${OUTPUT_DIR}/provider-schemas-${environment}.json" \
                  "${OUTPUT_DIR}/latest-plan-${environment}.txt" \
                  "${OUTPUT_DIR}/terraform-state-backup-${environment}-"*.tfstate
            log_success "Output files cleaned up"
            ;;
        "cache")
            local target
            target="$(env_dir "$environment")"
            log_info "Cleaning up Terraform cache for env: $environment"
            rm -rf "${target}/.terraform"
            log_success "Terraform cache cleaned up"
            ;;
        "all")
            cleanup_terraform "$environment" "plans"
            cleanup_terraform "$environment" "outputs"
            cleanup_terraform "$environment" "cache"
            ;;
        *)
            log_error "Unknown cleanup type: $cleanup_type"
            log_info "Available types: plans, outputs, cache, all"
            return 1
            ;;
    esac
}

# Help function
show_help() {
    cat << 'EOF'
Terraform CI/CD Management Script - Version 2.3

Usage: ./tf.sh <command> [environment] [arguments]

Most commands take an environment name (e.g. "dev", "prod") as the first
positional argument. The environment must correspond to a directory under
ENVS_ROOT containing a Terraform composition root (main.tf, etc.).

INITIALIZATION & VALIDATION:
    init <env> [--upgrade]               - Initialize Terraform for an environment
    validate <env>                       - Validate Terraform configuration
    fmt [--check]                        - Format Terraform across the whole tree
    security-scan <env>                  - Run checkov, tfsec, shellcheck, conftest
    test <env>                           - Run all validation: init/fmt/validate/plan/scan
    environments                         - List available environments

PLANNING & DEPLOYMENT:
    plan <env> [--destroy] [--detailed-exitcode]
    apply <env> [plan_file] [--auto-approve]
    destroy <env> [--auto-approve] [target]
    refresh <env>

STATE MANAGEMENT:
    state list <env>                     - List resources in state
    state show <env> <resource>          - Show specific resource in state
    state backup <env>                   - Create state backup (+ optional S3 upload)
    import <env> <address> <id>          - Import existing resource
    taint <env> <resource>               - Taint resource for recreation
    untaint <env> <resource>             - Remove taint from resource

INFORMATION & UTILITIES:
    output <env> [output_name]           - Show Terraform outputs
    show <env> [plan_file]               - Show saved plan
    graph <env> [format] [file]          - Generate dependency graph
    providers <env> [schema]             - Show provider requirements or schema
    console <env>                        - Interactive Terraform console
    version                              - Show Terraform version

ADVANCED:
    force-unlock <env> <lock_id> [--force]
    cost-estimate <env> [plan.json]      - Estimate costs via infracost (local install; plan JSON optional)
    cleanup <env> [type]                 - Clean artifacts (plans|outputs|cache|all)
    help                                 - Show this help message

Environment Variables:
    ENVS_ROOT                   - Parent directory of per-example Terraform roots (default: ./examples)
    TERRAFORM_ROOT              - Module root containing module .tf files (default: .)
    OUTPUT_DIR                  - Output directory (default: ./outputs)
    PLANS_DIR                   - Plans directory (default: ./plans)
    ENVIRONMENT                 - Default example name (default: dev)
    AUTO_APPROVE                - Auto-approve applies (default: false)
    PARALLELISM                 - Terraform parallelism (default: 10)
    LOG_LEVEL                   - Logging level (INFO, DEBUG)
    NO_COLOR                    - Set to disable ANSI color output
    TF_SKIP_INIT                - If "true", skip implicit init on plan/apply/destroy/refresh
    TF_STATE_BACKUP_BUCKET      - Optional S3 bucket for state backup uploads
    TF_STATE_BACKUP_KMS_KEY_ID  - Optional KMS key for SSE-KMS on state backups

Backend Configuration:
    Each example directory contains its own provider.tf and versions.tf.
    Variables are auto-loaded from terraform.tfvars in the example directory.

Directory Structure:
    .                                <- TERRAFORM_ROOT (module root)
    ├── main.tf, variables.tf, outputs.tf, versions.tf
    └── examples/                    <- ENVS_ROOT
        └── basic/                   <- A complete Terraform root (testable example)
            ├── main.tf              <- Calls the parent module
            ├── variables.tf
            ├── outputs.tf
            ├── provider.tf
            └── versions.tf

Dependencies:
    Required: terraform, jq
    Optional: checkov, tfsec, conftest, shellcheck, infracost, aws

Version: 2.3 - Per-env composition root (Model B)
EOF
}

# Main script logic
#
# 2.3 dispatch: most commands take environment as first positional arg.
# Where it's optional we fall back to $ENVIRONMENT.
main() {
    check_dependencies

    local action="${1:-help}"
    shift || true

    case "$action" in
        "init")          init_terraform "${1:-$ENVIRONMENT}" "${2:-false}" ;;
        "validate")      validate_terraform "${1:-$ENVIRONMENT}" ;;
        "fmt")           format_terraform "${1:-false}" ;;
        "security-scan") security_scan_terraform "${1:-$ENVIRONMENT}" ;;
        "test")          run_all_tests "${1:-$ENVIRONMENT}" ;;
        "environments")  list_environments ;;

        "plan")
            if ! maybe_init "${1:-$ENVIRONMENT}"; then exit 1; fi
            plan_terraform "${1:-$ENVIRONMENT}" "${2:-false}" "${3:-false}"
            ;;
        "apply")
            if ! maybe_init "${1:-$ENVIRONMENT}"; then exit 1; fi
            apply_terraform "${1:-$ENVIRONMENT}" "${2:-}" "${3:-$AUTO_APPROVE}"
            ;;
        "destroy")
            if ! maybe_init "${1:-$ENVIRONMENT}"; then exit 1; fi
            destroy_terraform "${1:-$ENVIRONMENT}" "${2:-false}" "${3:-}"
            ;;
        "refresh")
            if ! maybe_init "${1:-$ENVIRONMENT}"; then exit 1; fi
            refresh_state "${1:-$ENVIRONMENT}"
            ;;

        "state")
            local subcmd="${1:-}"
            shift || true
            case "$subcmd" in
                "list")   list_state_resources "${1:-$ENVIRONMENT}" ;;
                "show")   show_state_resource "${1:-$ENVIRONMENT}" "${2:-}" ;;
                "backup") backup_state "${1:-$ENVIRONMENT}" ;;
                *)
                    log_error "Unknown state command: $subcmd"
                    log_info "Available: list, show, backup"
                    exit 1
                    ;;
            esac
            ;;
        "import")
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]] || [[ -z "${3:-}" ]]; then
                log_error "Usage: $0 import <environment> <resource_address> <resource_id>"
                exit 1
            fi
            import_resource "$1" "$2" "$3"
            ;;
        "taint")
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 taint <environment> <resource>"
                exit 1
            fi
            taint_resource "$1" "$2"
            ;;
        "untaint")
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 untaint <environment> <resource>"
                exit 1
            fi
            untaint_resource "$1" "$2"
            ;;

        "output")
            if [[ -n "${2:-}" ]]; then
                get_specific_output "${1:-$ENVIRONMENT}" "$2"
            else
                get_terraform_outputs "${1:-$ENVIRONMENT}"
            fi
            ;;
        "show")        show_plan_file "${1:-$ENVIRONMENT}" "${2:-}" ;;
        "graph")       generate_graph "${1:-$ENVIRONMENT}" "${2:-dot}" "${3:-}" ;;
        "providers")
            local env_arg="${1:-$ENVIRONMENT}"
            case "${2:-}" in
                "schema") show_provider_schemas "$env_arg" ;;
                *)        show_providers "$env_arg" ;;
            esac
            ;;
        "console")     open_console "${1:-$ENVIRONMENT}" ;;
        "version")     show_version ;;

        "force-unlock")
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 force-unlock <environment> <lock_id> [--force]"
                exit 1
            fi
            force_unlock_state "$1" "$2" "${3:-false}"
            ;;
        "cost-estimate") estimate_costs "${1:-$ENVIRONMENT}" "${2:-}" ;;
        "cleanup")       cleanup_terraform "${1:-$ENVIRONMENT}" "${2:-plans}" ;;

        "help"|"-h"|"--help") show_help ;;

        *)
            log_error "Unknown action: $action"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi