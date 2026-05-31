#!/bin/bash

# Terraform Module Lifecycle Script
#
# Usage: ./module.sh <command> [options]
#
# This is the single entry point for local module development and CI/CD.
# It works identically on a developer laptop and in GitHub Actions.
#
# Commands:
#   validate          - fmt-check, terraform validate, and security scan (no AWS credentials)
#   test [name]       - terraform test with mock providers (no AWS credentials)
#   plan [name]       - terraform plan for the named example (default: basic)
#   apply [name]      - terraform apply for the named example (default: basic)
#   docs              - generate README via terraform-docs
#   publish           - package module zip and upload to S3
#   bootstrap         - one-time: create S3 publish bucket + GitHub OIDC role
#   help              - show this help

set -euo pipefail

# ─── Locate scripts ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_SH="${SCRIPT_DIR}/tf.sh"
BOOTSTRAP_SH="${SCRIPT_DIR}/bootstrap.sh"

# ─── Colors (TTY/NO_COLOR aware) ─────────────────────────────────────────────
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

log_info()    { echo -e "${BLUE}[module]${NC} $1" >&2; }
log_warn()    { echo -e "${YELLOW}[module WARN]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[module ERROR]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[module OK]${NC} $1" >&2; }
log_step()    { echo -e "${CYAN}[module STEP]${NC} $1" >&2; }

# ─── Defaults ────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"

# PROJECT_NAME: used for role naming in bootstrap and zip naming in publish.
# In CI, GITHUB_REPOSITORY is set automatically (org/repo). Locally, set
# PROJECT_NAME explicitly or let it default to the repo directory name.
PROJECT_NAME="${PROJECT_NAME:-${GITHUB_REPOSITORY##*/}}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$REPO_ROOT")}"

# ─── Environment exports for tf.sh ───────────────────────────────────────────
export_tf_env() {
    export ENVS_ROOT="${REPO_ROOT}/examples"
    export TERRAFORM_ROOT="${REPO_ROOT}"
    export OUTPUT_DIR="${REPO_ROOT}/outputs"
    export PLANS_DIR="${REPO_ROOT}/plans"
    export AWS_REGION
    export AWS_DEFAULT_REGION="$AWS_REGION"
    export PROJECT_NAME
}

# ─── Commands ────────────────────────────────────────────────────────────────

# validate: fmt-check + terraform validate + security scan.
# Runs entirely against the module root — no AWS credentials required.
cmd_validate() {
    log_step "Validating module"

    log_info "Checking formatting..."
    if ! terraform -chdir="${REPO_ROOT}" fmt -check -recursive .; then
        log_error "Formatting check failed. Run: terraform fmt -recursive ."
        return 1
    fi
    log_success "Formatting OK"

    log_info "Initializing (backend=false)..."
    terraform -chdir="${REPO_ROOT}" init -backend=false -input=false >/dev/null

    log_info "Validating configuration..."
    terraform -chdir="${REPO_ROOT}" validate
    log_success "Validation OK"

    log_info "Running security scan..."
    export_tf_env
    # Source tf.sh as a library so we can call security_scan_terraform.
    # shellcheck source=tf.sh
    source "$TF_SH"
    security_scan_terraform

    log_success "Validation complete"
}

# test [name]: run terraform test using mock providers.
# No AWS credentials required — all assertions use mock_provider blocks.
#
# Without [name]: runs all *.tftest.hcl files under tests/.
# With [name]:    runs only tests/<name>.tftest.hcl.
cmd_test() {
    local filter_arg="${1:-}"

    log_step "Running terraform test"

    local test_args=("-no-color")
    if [[ -n "$filter_arg" ]]; then
        test_args+=("-filter=tests/${filter_arg}.tftest.hcl")
        log_info "Filtering to: tests/${filter_arg}.tftest.hcl"
    fi

    if [[ ! -d "${REPO_ROOT}/tests" ]]; then
        log_warn "No tests/ directory found — skipping"
        return 0
    fi

    log_info "Initializing (backend=false)..."
    terraform -chdir="${REPO_ROOT}" init -backend=false -input=false >/dev/null

    log_info "Running tests..."
    terraform -chdir="${REPO_ROOT}" test "${test_args[@]}"

    log_success "All tests passed"
}

# docs: regenerate README.md via terraform-docs.
cmd_docs() {
    log_step "Generating documentation"

    if ! command -v terraform-docs &>/dev/null; then
        log_error "terraform-docs not found."
        log_info "Install: brew install terraform-docs"
        log_info "         or: https://terraform-docs.io/user-guide/installation/"
        return 1
    fi

    local config_file="${REPO_ROOT}/.docs/.terraform-docs.yml"
    if [[ ! -f "$config_file" ]]; then
        log_error "terraform-docs config not found: ${config_file}"
        return 1
    fi

    terraform-docs --config "$config_file" "${REPO_ROOT}"
    log_success "Documentation updated: README.md"
}

# publish [--version v1.0.0] [--bucket name]: zip the module and upload to S3.
# Requires AWS credentials (OIDC in CI, local profile or env vars locally).
cmd_publish() {
    local version=""
    local bucket="${S3_BUCKET_NAME:-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            --bucket)  bucket="$2";  shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Determine version from arg, then latest git tag, then fail.
    if [[ -z "$version" ]]; then
        version=$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null || echo "")
        if [[ -z "$version" ]]; then
            log_error "No version specified and no git tags found. Use --version v1.0.0"
            return 1
        fi
        log_info "Using latest git tag: ${version}"
    fi

    if [[ -z "$bucket" ]]; then
        log_error "S3 bucket not specified. Set S3_BUCKET_NAME or pass --bucket <name>"
        return 1
    fi

    local module_name="${PROJECT_NAME}"
    local zip_name="${module_name}-${version}.zip"
    local dist_dir="${REPO_ROOT}/dist"

    log_step "Publishing ${module_name} ${version} to s3://${bucket}/modules/${zip_name}"

    mkdir -p "${dist_dir}"

    log_info "Packaging module..."
    (
        cd "${REPO_ROOT}"
        zip -r "${dist_dir}/${zip_name}" . \
            -x "*.git*" \
            -x "dist/*" \
            -x ".github/*" \
            -x ".DS_Store" \
            -x "outputs/*" \
            -x "plans/*"
    )
    log_success "Created: ${dist_dir}/${zip_name}"

    log_info "Uploading to S3..."
    aws s3 cp "${dist_dir}/${zip_name}" \
        "s3://${bucket}/modules/${zip_name}" \
        --region "${AWS_REGION}"

    log_success "Published: s3://${bucket}/modules/${zip_name}"

    # Clean up local zip after upload.
    rm -f "${dist_dir}/${zip_name}"
}

# plan [example]: run terraform plan for the named example (default: basic).
# Requires AWS credentials and a state.config in the example directory.
# Set TF_SKIP_INIT=true to skip init (e.g. when re-running on the same runner).
cmd_plan() {
    local example="${1:-basic}"
    export_tf_env
    source "$TF_SH"
    if ! maybe_init "$example"; then return 1; fi
    plan_terraform "$example"
}

# apply [example]: terraform apply for the named example (default: basic).
# Requires AWS credentials and a state.config in the example directory.
# Consumes the saved plan artifact written by a prior plan run when present.
# Set AUTO_APPROVE=true to skip the interactive confirmation prompt.
cmd_apply() {
    local example="${1:-basic}"
    export_tf_env
    source "$TF_SH"
    if ! maybe_init "$example"; then return 1; fi
    apply_terraform "$example"
}

# destroy [example]: terraform destroy for the named example (default: basic).
# Requires AWS credentials. Prompts for confirmation unless AUTO_APPROVE=true.
cmd_destroy() {
    local example="${1:-basic}"
    export_tf_env
    source "$TF_SH"
    if ! maybe_init "$example"; then return 1; fi
    destroy_terraform "$example"
}

# bootstrap: one-time setup of S3 state/publish bucket and GitHub OIDC role.
# Also writes state.config into the target example directory.
cmd_bootstrap() {
    local add_suffix="false"
    local bucket=""
    local environment="basic"
    local github_org=""
    local github_repo=""
    local kms_key_id=""
    local project_name="${PROJECT_NAME:-}"
    local region="${AWS_REGION}"
    local skip_oidc_and_role="false"
    local extra_roles=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project-name)       project_name="$2";        shift 2 ;;
            --bucket)             bucket="$2";               shift 2 ;;
            --environment)        environment="$2";          shift 2 ;;
            --github-org)         github_org="$2";           shift 2 ;;
            --github-repo)        github_repo="$2";          shift 2 ;;
            --region)             region="$2";               shift 2 ;;
            --add-suffix)         add_suffix="true";         shift   ;;
            --kms-key)            kms_key_id="$2";           shift 2 ;;
            --skip-oidc-and-role) skip_oidc_and_role="true"; shift   ;;
            --extra-role)         extra_roles+=("$2");       shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$bucket" ]]; then
        log_error "--bucket is required"
        return 1
    fi
    if [[ -z "$github_org" ]]; then
        log_error "--github-org is required"
        return 1
    fi
    if [[ -z "$github_repo" ]]; then
        log_error "--github-repo is required"
        return 1
    fi

    export PROJECT_NAME="${project_name:-${github_repo}}"
    export SKIP_OIDC_AND_ROLE="$skip_oidc_and_role"
    export KMS_KEY_ID="$kms_key_id"
    export AWS_REGION="$region"
    export ENVS_ROOT="${REPO_ROOT}/examples"

    log_step "Bootstrapping state backend and publish infrastructure"
    "${BOOTSTRAP_SH}" "$add_suffix" "$bucket" "$region" "$github_org" "$github_repo" "$environment" "${extra_roles[@]+"${extra_roles[@]}"}"
}

# ─── Help ────────────────────────────────────────────────────────────────────

show_help() {
    cat <<'EOF'
Terraform Module Lifecycle Script

Usage: ./module.sh <command> [options]

COMMANDS:
  validate                  - fmt-check + terraform validate + security scan (no AWS creds)
  test [name]               - terraform test with mock providers (no AWS creds)
                              [name] filters to tests/<name>.tftest.hcl
  plan [example]            - terraform plan the named example (default: basic)
  apply [example]           - terraform apply the named example (default: basic)
                              consumes the saved plan artifact from a prior plan run
  destroy [example]         - terraform destroy the named example (default: basic)
  publish                   - package module zip and upload to S3
  bootstrap                 - one-time: create S3 state/publish bucket + GitHub OIDC role
  help                      - show this help

PUBLISH OPTIONS:
  --version v1.0.0          Explicit version tag (default: latest git tag)
  --bucket  name            S3 bucket name (default: $S3_BUCKET_NAME env var)

BOOTSTRAP OPTIONS:
  --project-name  name      Module/project name for role naming (default: repo name)
  --bucket        name      S3 bucket name for state and module artifacts (required)
  --environment   name      Example name for state key and state.config path (default: basic)
  --github-org    org       GitHub organisation (required)
  --github-repo   repo      GitHub repository name (required)
  --region        region    AWS region (default: us-east-1)
  --add-suffix              Append random suffix to bucket name
  --kms-key       key-id    KMS key ID (required with --skip-oidc-and-role)
  --skip-oidc-and-role      Skip OIDC/role creation; write state.config from provided values
  --extra-role    name      Additional IAM role to grant bucket access (repeatable)

ENVIRONMENT VARIABLES:
  PROJECT_NAME              Module name for role/zip naming (default: repo directory name)
  AWS_REGION                Default AWS region (default: us-east-1)
  S3_BUCKET_NAME            Publish bucket for 'publish' command
  NO_COLOR                  Set to disable ANSI color output
  LOG_LEVEL                 INFO | DEBUG (default: INFO)

EXAMPLES:
  # Local development (no AWS credentials)
  ./module.sh validate
  ./module.sh test
  ./module.sh test unit
  ./module.sh docs

  # Deploy and tear down the basic example
  ./module.sh apply basic
  ./module.sh destroy basic

  # Publish a specific version
  AWS_REGION=us-east-1 S3_BUCKET_NAME=my-bucket ./module.sh publish --version v1.2.0

  # First-time bootstrap (creates S3 bucket, OIDC provider, publish role, state.config)
  ./module.sh bootstrap \
    --project-name my-module \
    --bucket my-org-tf-modules \
    --environment basic \
    --github-org my-org \
    --github-repo my-module \
    --region us-east-1
EOF
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        validate)  cmd_validate "$@" ;;
        test)      cmd_test "$@" ;;
        plan)      cmd_plan "$@" ;;
        apply)     cmd_apply "$@" ;;
        destroy)   cmd_destroy "$@" ;;
        publish)   cmd_publish "$@" ;;
        bootstrap) cmd_bootstrap "$@" ;;
        help|--help|-h) show_help ;;
        *)
            log_error "Unknown command: ${command}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
