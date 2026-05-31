#!/bin/bash
#set -x  # uncomment for debug
set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

export AWS_PAGER=""

AWS_PARTITION=${AWS_PARTITION:-"aws"}
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# --- Colors (TTY/NO_COLOR aware) -----------------------------------------------

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

# --- Logging ------------------------------------------------------------------

log_info() {
  if [[ "$LOG_LEVEL" == "DEBUG" || "$LOG_LEVEL" == "INFO" ]]; then
    echo -e "${BLUE}[INFO]${NC} $1" >&2
  fi
}
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_debug() {
  if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
    echo -e "${PURPLE}[DEBUG]${NC} $1" >&2
  fi
}
log_step() { echo -e "${CYAN}[STEP]${NC} $1" >&2; }

# --- Helpers ------------------------------------------------------------------

function random_suffix() {
  LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 13
}

# Check whether the publish S3 bucket exists.
function check_bucket() {
  local bucket_name=$1
  log_debug "Checking bucket: ${bucket_name}"

  if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
    echo "Bucket exists"
  else
    echo "Bucket does not exist"
  fi
}

# --- Policy generators --------------------------------------------------------

function generate_s3_policy() {
  local bucket_name=$1
  shift 1
  local roles=("$@")
  local account_id
  account_id=$(aws sts get-caller-identity --query 'Account' --output text)

  # Build a second statement scoped to only what the publish role needs, if roles were provided.
  local role_statement=""
  if [[ "${#roles[@]}" -gt 0 ]]; then
    local role_arns=""
    for role in "${roles[@]}"; do
      [[ -n "$role_arns" ]] && role_arns+=","
      role_arns+="\"arn:${AWS_PARTITION}:iam::${account_id}:role/${role}\""
    done
    role_statement=",
    {
      \"Sid\": \"PublishRoleAccess\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"AWS\": [${role_arns}]},
      \"Action\": [
        \"s3:HeadBucket\",
        \"s3:ListBucket\",
        \"s3:GetObject\",
        \"s3:PutObject\",
        \"s3:DeleteObject\",
        \"s3:GetEncryptionConfiguration\"
      ],
      \"Resource\": [
        \"arn:${AWS_PARTITION}:s3:::${bucket_name}\",
        \"arn:${AWS_PARTITION}:s3:::${bucket_name}/*\"
      ]
    }"
  fi

  echo "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"AdminFullAccess\",
        \"Effect\": \"Allow\",
        \"Principal\": {\"AWS\": \"arn:${AWS_PARTITION}:iam::${account_id}:root\"},
        \"Action\": \"s3:*\",
        \"Resource\": [
          \"arn:${AWS_PARTITION}:s3:::${bucket_name}\",
          \"arn:${AWS_PARTITION}:s3:::${bucket_name}/*\"
        ]
      }${role_statement}
    ]
  }"
}

function generate_kms_policy() {
  local roles=("$@")
  local account_id
  account_id=$(aws sts get-caller-identity --query 'Account' --output text)

  local role_statement=""
  if [[ "${#roles[@]}" -gt 0 ]]; then
    local role_arns=""
    for role in "${roles[@]}"; do
      [[ -n "$role_arns" ]] && role_arns+=","
      role_arns+="\"arn:${AWS_PARTITION}:iam::${account_id}:role/${role}\""
    done
    role_statement=",
    {
      \"Sid\": \"PublishRoleKeyUsage\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"AWS\": [${role_arns}]},
      \"Action\": [
        \"kms:Decrypt\",
        \"kms:GenerateDataKey\",
        \"kms:DescribeKey\"
      ],
      \"Resource\": \"*\"
    }"
  fi

  echo "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"AdminFullAccess\",
        \"Effect\": \"Allow\",
        \"Principal\": {\"AWS\": \"arn:${AWS_PARTITION}:iam::${account_id}:root\"},
        \"Action\": \"kms:*\",
        \"Resource\": \"*\"
      }${role_statement}
    ]
  }"
}

# --- KMS ----------------------------------------------------------------------

function create_kms_alias() {
  local kms_key_id=$1
  local alias_name=$2

  if [[ -z "$kms_key_id" ]]; then
    log_error "create_kms_alias: kms_key_id is empty"
    return 1
  fi

  log_debug "Creating KMS alias 'alias/${alias_name}' for key '${kms_key_id}'"

  if aws kms describe-key --key-id "alias/${alias_name}" >/dev/null 2>&1; then
    log_info "KMS alias 'alias/${alias_name}' already exists"
    return 0
  fi

  aws kms create-alias \
    --alias-name "alias/${alias_name}" \
    --target-key-id "${kms_key_id}"

  log_success "Created KMS alias 'alias/${alias_name}'"
}

function create_bucket_kms_key() {
  local roles=("$@")

  log_debug "Generating KMS policy for roles: ${roles[*]:-none}"
  local policy
  policy=$(generate_kms_policy "${roles[@]}")
  log_debug "KMS policy: ${policy}"

  # Retry to handle IAM eventual consistency — a newly created role may not be
  # immediately resolvable as a principal in a KMS key policy.
  local kms_key=""
  local attempt=1
  local max_attempts=5
  while [[ $attempt -le $max_attempts ]]; do
    kms_key=$(aws kms create-key --policy "$policy" --query 'KeyMetadata.KeyId' --output text 2>/dev/null) || true
    if [[ -n "$kms_key" ]] && [[ "$kms_key" != "None" ]]; then
      break
    fi
    local wait=$(( attempt * 5 ))
    log_warn "KMS key creation attempt ${attempt}/${max_attempts} failed (IAM propagation delay). Retrying in ${wait}s..."
    sleep "$wait"
    (( attempt++ ))
  done

  if [[ -z "$kms_key" ]] || [[ "$kms_key" == "None" ]]; then
    log_error "KMS key creation failed after ${max_attempts} attempts"
    return 1
  fi

  aws kms enable-key-rotation --key-id "$kms_key"
  log_success "KMS key created with annual rotation enabled: ${kms_key}"

  echo "$kms_key"
}

# --- S3 -----------------------------------------------------------------------

function create_bucket() {
  local bucket_name=$1
  local region=$2
  shift 2
  local roles=("$@")

  if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
    log_error "Bucket ${bucket_name} already exists"
    return 1
  fi

  log_debug "Creating KMS key for publish bucket"
  local kms_key
  kms_key=$(create_bucket_kms_key "${roles[@]}")

  if [[ -z "$kms_key" ]] || [[ "$kms_key" == "None" ]]; then
    log_error "KMS key creation failed; aborting bucket setup"
    return 1
  fi

  create_kms_alias "$kms_key" "$bucket_name"

  local policy
  policy=$(generate_s3_policy "${bucket_name}" "${roles[@]}")

  if [[ "$region" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$bucket_name" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "$bucket_name" \
      --create-bucket-configuration LocationConstraint="$region" >/dev/null
  fi

  aws s3api put-bucket-policy \
    --bucket "$bucket_name" \
    --policy "$policy" >/dev/null

  local account_id
  account_id=$(aws sts get-caller-identity --query 'Account' --output text)

  aws s3api put-bucket-encryption \
    --bucket "$bucket_name" \
    --server-side-encryption-configuration "{
      \"Rules\": [{
        \"ApplyServerSideEncryptionByDefault\": {
          \"SSEAlgorithm\": \"aws:kms\",
          \"KMSMasterKeyID\": \"arn:${AWS_PARTITION}:kms:${region}:${account_id}:key/${kms_key}\"
        }
      }]
    }" >/dev/null

  aws s3api put-public-access-block \
    --bucket "$bucket_name" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null

  aws s3api put-bucket-versioning \
    --bucket "$bucket_name" \
    --versioning-configuration Status=Enabled >/dev/null

  log_success "Created publish bucket: ${bucket_name}"
  echo "$kms_key"
}

# --- OIDC and publish role ----------------------------------------------------

function create_oidc_provider() {
  local account_id
  account_id=$(aws sts get-caller-identity --query 'Account' --output text)

  local provider_url="https://token.actions.githubusercontent.com"
  local provider_arn="arn:${AWS_PARTITION}:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"

  if aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn "$provider_arn" >/dev/null 2>&1; then
    log_info "OIDC provider already exists: ${provider_arn}"
    echo "$provider_arn"
    return 0
  fi

  # Both thumbprints are required; the second was added in 2023.
  aws iam create-open-id-connect-provider \
    --url "$provider_url" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list \
      "6938fd4d98bab03faadb97b34396831e3780aea1" \
      "1c58a3a8518e8759bf075b76b750d4f2df264fcd" >/dev/null

  log_success "Created GitHub Actions OIDC provider"
  echo "$provider_arn"
}

# create_publish_role: creates a single IAM role for GitHub Actions to publish
# module artifacts. The trust policy allows any ref in the repository (branches,
# tags, release events) — appropriate for module publishing.
#
# Role name derives from PROJECT_NAME env var (set by module.sh or the caller).
# Falls back to github_repo if PROJECT_NAME is unset.
function create_publish_role() {
  local github_org=$1
  local github_repo=$2
  local role_name="${PROJECT_NAME:-${github_repo}}-github-role"

  local account_id
  account_id=$(aws sts get-caller-identity --query 'Account' --output text)

  local provider_arn="arn:${AWS_PARTITION}:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"

  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    log_info "Publish role '${role_name}' already exists"
    local role_arn
    role_arn=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text)
    echo "$role_arn"
    return 0
  fi

  local trust_policy
  trust_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${github_org}/${github_repo}:*"
        }
      }
    }
  ]
}
EOF
)

  aws iam create-role \
    --role-name "$role_name" \
    --assume-role-policy-document "$trust_policy" >/dev/null

  local role_arn
  role_arn=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text)

  log_success "Created publish role '${role_name}'"
  log_warn "Attach S3 publish permissions to '${role_name}' before running publish workflows."
  echo "$role_arn"
}

# --- Backend config -----------------------------------------------------------

function create_backend_file() {
  log_debug "Creating backend state.config"
  local bucket_name=$1
  local kms_key=$2
  local region=$3
  local environment=$4

  # Write to the example's Terraform root when ENVS_ROOT is set (module.sh
  # exports it before calling this script). Fall back to the current directory
  # so the script still works when called standalone.
  local target_dir="${ENVS_ROOT:-.}/${environment}"
  local target_file="${target_dir}/state.config"

  if [[ ! -d "$target_dir" ]]; then
    log_warn "Example directory not found: ${target_dir}"
    log_warn "Writing state.config to current directory instead. Move it to ${target_dir} before running Terraform."
    target_file="state.config"
  fi

  cat > "$target_file" <<EOF
bucket       = "${bucket_name}"
key          = "${environment}/terraform.tfstate"
region       = "${region}"
encrypt      = true
kms_key_id   = "${kms_key}"
use_lockfile = true
EOF

  log_success "Created backend config: ${target_file}"
}

# --- Main ---------------------------------------------------------------------
#
# Usage: create_state [add_suffix] [bucket_name] [region] [github_org] [github_repo] [environment] [extra_roles...]
#
# add_suffix   — true|false; appends a random lowercase suffix to bucket_name
# bucket_name  — desired S3 bucket name for Terraform state and module artifacts
# region       — AWS region (e.g. us-east-1)
# github_org   — GitHub organisation or user (e.g. my-org)
# github_repo  — GitHub repository name (e.g. my-module)
# environment  — example/environment name used for the state key (e.g. basic)
# extra_roles  — optional additional IAM role names to grant bucket access
#
# Environment variables:
#   PROJECT_NAME        — module/project name used for role naming (default: github_repo)
#   SKIP_OIDC_AND_ROLE  — true to skip OIDC+role creation and write state.config from provided values
#   KMS_KEY_ID          — required when SKIP_OIDC_AND_ROLE=true
#   ENVS_ROOT           — parent of per-example Terraform roots (default: ./examples)
#   AWS_PARTITION       — aws | aws-cn | aws-us-gov (default: aws)
#   LOG_LEVEL           — INFO | DEBUG (default: INFO)
#   NO_COLOR            — set to disable ANSI color output

function create_state() {
  local add_suffix=$1
  local bucket_name=$2
  local region=$3
  local github_org=$4
  local github_repo=$5
  local environment=$6

  shift 6
  local extra_roles=("$@")

  if [[ "$add_suffix" == "true" ]]; then
    bucket_name="${bucket_name}-$(random_suffix)"
  fi

  # Config-only mode: skip all AWS API calls and write state.config directly
  # from caller-supplied values. Used in CI where the human bootstrap already
  # ran locally. KMS_KEY_ID must be provided as an env var; no AWS credentials
  # are required at this point, which allows this step to run before the OIDC
  # authentication step in the pipeline.
  if [[ "${SKIP_OIDC_AND_ROLE:-false}" == "true" ]]; then
    if [[ -z "${KMS_KEY_ID:-}" ]]; then
      log_error "SKIP_OIDC_AND_ROLE=true requires KMS_KEY_ID to be set (pass --kms-key)"
      return 1
    fi
    log_info "Config-only mode: writing state.config from provided values (bucket=${bucket_name})"
    create_backend_file "$bucket_name" "$KMS_KEY_ID" "$region" "$environment"
    log_success "Bootstrap complete (config-only). bucket=${bucket_name}"
    return 0
  fi

  log_info "Bootstrap: bucket=${bucket_name} region=${region} env=${environment}"
  log_info "Publish role name: ${PROJECT_NAME:-${github_repo}}-github-role"

  # OIDC and publish role must be created before the bucket so the role ARN is
  # valid when included in the bucket policy.
  log_step "Setting up GitHub Actions OIDC provider"
  create_oidc_provider

  log_step "Creating publish role for '${github_org}/${github_repo}'"
  local publish_role_arn
  publish_role_arn=$(create_publish_role "${github_org}" "${github_repo}")
  local publish_role_name="${PROJECT_NAME:-${github_repo}}-github-role"

  log_step "Creating Terraform state and publish bucket"
  local all_roles=("${publish_role_name}" "${extra_roles[@]+"${extra_roles[@]}"}")
  local kms_key

  if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
    log_info "Bucket '${bucket_name}' already exists — retrieving KMS key"
    kms_key=$(aws s3api get-bucket-encryption \
      --bucket "$bucket_name" \
      --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
      --output text)
  else
    kms_key=$(create_bucket "${bucket_name}" "${region}" "${all_roles[@]}")
  fi

  create_backend_file "$bucket_name" "$kms_key" "$region" "$environment"

  log_success "Bootstrap complete."
  log_info "  Bucket:       ${bucket_name}"
  log_info "  Publish role: ${publish_role_arn}"
  log_info "  state.config written for example: ${environment}"
  log_info ""
  log_info "Next steps:"
  log_info "  1. Set repository secret  AWS_ACCOUNT_ID = $(aws sts get-caller-identity --query 'Account' --output text)"
  log_info "  2. Set repository secret  S3_BUCKET_NAME = ${bucket_name}"
  log_info "  3. Set repository variable AWS_ROLE_NAME = ${publish_role_name}"
  log_info "  4. Attach Terraform state + S3 publish permissions to the publish role."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  create_state "$@"
fi
