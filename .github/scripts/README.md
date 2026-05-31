# Deployment Scripts

Three scripts form the complete deployment lifecycle. They are layered deliberately: each script has one responsibility and the layers never cross.

```
deploy.sh          ← entry point for every operation (humans and CI both call this)
  └─ tf.sh         ← Terraform-only lifecycle (init, plan, apply, destroy, security scans)
       └─ terraform ← the actual binary, never called directly
bootstrap.sh       ← one-time per-account setup, called by deploy.sh bootstrap command
```

**Rules that are never broken:**

- Humans and CI call `deploy.sh`. Never `tf.sh` directly (except for local debugging). Never `terraform` directly.
- CI calls `deploy.sh`. Never `tf.sh` directly.
- Adding a new pipeline stage means adding it to environment folder and referencing it using the --env flag for `deploy.sh`. No new scripts are created for each stage.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [bootstrap.sh](#2-bootstrapsh)
3. [tf.sh](#3-tfsh)
4. [deploy.sh](#4-deploysh)
5. [Bash Concepts Reference](#5-bash-concepts-reference)
6. [Local Development Workflows](#6-local-development-workflows)
7. [CI/CD Pipeline Integration](#7-cicd-pipeline-integration)
8. [Adapting to a New Project](#8-adapting-to-a-new-project)

---

## 1. Architecture Overview

### Why three scripts?

**`bootstrap.sh`** creates the infrastructure that Terraform itself needs to function: the S3 state bucket, the KMS key that encrypts it, the GitHub Actions OIDC provider, and the per-environment deploy role. It runs once per AWS account per environment. It uses only the AWS CLI — no Terraform — because it is creating the backend that Terraform will use.

**`tf.sh`** is a Terraform lifecycle wrapper. It knows about the per-environment directory model, how to find `state.config`, how to generate and save plan files, and how to run the security scanning suite. It calls `terraform` and nothing else. Every invocation runs `cd` into the correct environment directory before calling `terraform`.

**`deploy.sh`** is the orchestrator. It parses flags, sets environment variables, and calls `tf.sh` for Terraform steps plus handles the non-Terraform steps that happen after a deploy (CloudFront cache invalidation, smoke tests). This is the only script with knowledge of the full deployment lifecycle.

### The per-environment composition model

Both `tf.sh` and `deploy.sh` work from these two path concepts:

| Variable         | Default            | Meaning                                                      |
| ---------------- | ------------------ | ------------------------------------------------------------ |
| `ENVS_ROOT`      | `./terraform/envs` | Parent directory containing per-env subdirectories           |
| `TERRAFORM_ROOT` | `./terraform`      | Root of the Terraform tree (contains `modules/` and `envs/`) |

For any environment `dev`, the Terraform working directory is `${ENVS_ROOT}/dev`. Every `terraform` command runs from that directory. This means `terraform.tfvars` in that directory is auto-loaded, `.terraform/` cache lives there, and `state.config` is read from there via `-backend-config`.

---

## 2. bootstrap.sh

### Purpose

One-time setup per AWS account per environment. Creates:

1. **GitHub Actions OIDC provider** — allows GitHub Actions to request short-lived AWS credentials without storing a static access key anywhere
2. **Deploy role** (`filebridge-deploy-{env}`) — the IAM role GitHub Actions assumes; trust policy is scoped to the specific repo and GitHub Environment
3. **KMS key** — encrypts the Terraform state bucket; key policy grants access only to the deploy role
4. **S3 state bucket** — stores Terraform state; versioning enabled, public access blocked, SSE-KMS enforced

### Usage

```bash
# Full bootstrap (creates everything above)
./scripts/deploy.sh bootstrap \
  --env        dev \
  --region     us-east-2 \
  --bucket     my-project-tfstate \
  --github-org my-github-org \
  --github-repo my-repo \
  --yes

# With a random suffix appended to the bucket name (avoids global name conflicts)
./scripts/deploy.sh bootstrap \
  --env        dev \
  --bucket     my-project-tfstate \
  --github-org my-github-org \
  --github-repo my-repo \
  --add-suffix \
  --yes

# Config-only mode: regenerate state.config without any AWS calls
# Used in CI after a human has already run the full bootstrap
./scripts/deploy.sh bootstrap \
  --env             dev \
  --bucket          my-project-tfstate-abc123 \
  --kms-key         arn:aws:kms:us-east-2:123456789012:key/... \
  --skip-oidc-and-role
```

### How it works

#### OIDC provider creation

```bash
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
```

The function checks first whether the provider already exists (`aws iam get-open-id-connect-provider`). If it does, it returns the existing ARN. Only one OIDC provider for `token.actions.githubusercontent.com` is needed per AWS account regardless of how many repositories or environments you have — the scoping happens in the role's trust policy.

Two thumbprints are registered because GitHub rotated their OIDC certificate in 2023. Both remain valid.

#### Deploy role trust policy

The trust policy is built as a here-document and scoped with a `StringLike` condition on the GitHub `sub` claim:

```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": "repo:{org}/{repo}:environment:{environment}"
}
```

This means only a workflow running in the named GitHub Environment (`dev` or `prod`) can assume this role. A workflow on a branch that has not been assigned to that environment cannot assume it, even within the same repository.

#### IAM eventual consistency retry loop

When a new IAM role is included as a principal in a KMS key policy immediately after creation, AWS sometimes returns an error because IAM changes have not yet propagated globally. The script handles this with an exponential backoff loop:

```bash
local attempt=1
local max_attempts=5
while [[ $attempt -le $max_attempts ]]; do
    kms_key=$(aws kms create-key --policy "$policy" ... 2>/dev/null) || true
    if [[ -n "$kms_key" ]] && [[ "$kms_key" != "None" ]]; then
        break
    fi
    local wait=$(( attempt * 5 ))  # 5s, 10s, 15s, 20s, 25s
    sleep "$wait"
    (( attempt++ ))
done
```

`|| true` after the `aws kms create-key` prevents `set -e` from killing the script on a retryable failure. The loop continues as long as `$kms_key` is empty or the literal string `"None"` (what the AWS CLI outputs when a query returns null).

#### Config-only mode (CI usage)

```bash
if [[ "${SKIP_OIDC_AND_ROLE:-false}" == "true" ]]; then
    create_backend_file "$bucket_name" "$KMS_KEY_ID" "$region" "$environment"
    return 0
fi
```

When `SKIP_OIDC_AND_ROLE=true`, the script skips all AWS API calls and writes `state.config` directly from the supplied values. This is safe because:

- The bucket and KMS key already exist from the one-time human-run bootstrap
- `state.config` only contains names and IDs, not secrets
- This step runs before OIDC authentication in CI, making the config available to the init step

#### Policy generators

Both `generate_s3_policy` and `generate_kms_policy` build JSON inline from bash variables. They take a list of role names and produce a policy with two statements: broad root-account admin access (so you can always manage the key even if roles change), and a narrower statement granting only what Terraform needs to the deploy role(s).

```bash
function generate_s3_policy() {
  local bucket_name=$1
  shift 1               # consume first arg, leave the rest
  local roles=("$@")   # collect remaining args into an array
  ...
  for role in "${roles[@]}"; do
    [[ -n "$role_arns" ]] && role_arns+=","  # comma-separated JSON array construction
    role_arns+="\"arn:...:role/${role}\""
  done
```

`shift 1` consumes the `bucket_name` argument from `$@`. Everything remaining becomes the `roles` array. This is a standard bash pattern for functions that take a fixed number of named parameters followed by a variadic list.

#### `state.config` output

```bash
local target_dir="${ENVS_ROOT:-.}/${environment}"
```

`${ENVS_ROOT:-.}` is a bash parameter expansion that means: use `$ENVS_ROOT` if it is set and non-empty, otherwise use `.` (current directory). This lets the script work both when called from `deploy.sh` (which exports `ENVS_ROOT`) and when called standalone.

The written file uses a here-document (`<<EOF`):

```
bucket       = "my-project-tfstate"
key          = "dev/terraform.tfstate"
region       = "us-east-2"
encrypt      = true
kms_key_id   = "arn:aws:kms:..."
use_lockfile = true
```

This is a partial Terraform backend configuration passed to `terraform init -backend-config=state.config`. The `use_lockfile = true` enables S3-native state locking (Terraform ≥ 1.10), eliminating the need for a DynamoDB table.

---

## 3. tf.sh

### Purpose

The Terraform lifecycle wrapper. Every command that calls `terraform` goes through this script. It knows about the per-environment directory model, manages plan file naming and storage, generates plan summaries, and runs the security scanning suite.

### All commands

```bash
# Initialize Terraform for an environment
./scripts/tf.sh init dev

# Validate configuration
./scripts/tf.sh validate dev

# Format the entire Terraform tree (check only, no writes)
./scripts/tf.sh fmt --check

# Format and apply changes
./scripts/tf.sh fmt

# Plan
./scripts/tf.sh plan dev

# Plan with destroy (generates a destroy plan, does not destroy)
./scripts/tf.sh plan dev --destroy

# Apply (uses latest saved plan if present, otherwise runs a plan inline)
./scripts/tf.sh apply dev

# Apply a specific plan file
./scripts/tf.sh apply dev plans/dev-plan-20260501-120000.tfplan

# Apply without prompting (CI)
./scripts/tf.sh apply dev "" --auto-approve

# Destroy
./scripts/tf.sh destroy dev --auto-approve

# Run all checks: init → fmt → validate → plan → security scan
./scripts/tf.sh test dev

# Run security scans only
./scripts/tf.sh security-scan dev

# State operations
./scripts/tf.sh state list dev
./scripts/tf.sh state show dev module.api.aws_lambda_function.upload
./scripts/tf.sh state backup dev

# Cost estimate (requires infracost)
./scripts/tf.sh cost-estimate dev
./scripts/tf.sh cost-estimate dev outputs/plan-summary-dev.json

# List available environments
./scripts/tf.sh environments

# Show saved plan
./scripts/tf.sh show dev plans/dev-plan-20260501-120000.tfplan
```

### How it works

#### The `terraform_cmd` function

This is the core abstraction:

```bash
terraform_cmd() {
    local cmd="$1"
    shift

    local target
    target="$(env_dir "$ENVIRONMENT")"

    cd "$target"
    terraform "$cmd" "$@"
    return $?
}
```

`cd "$target"` changes the working directory to the environment's Terraform root before calling `terraform`. This ensures:

- `terraform.tfvars` in that directory is auto-loaded (Terraform reads it automatically from the working directory)
- `.terraform/` provider cache is per-environment
- Relative paths in Terraform code resolve correctly

**Caution:** Because `terraform_cmd` calls `cd`, any path arguments must be made absolute before calling it. `tf.sh` does this explicitly in several places:

```bash
plan_file="$(cd "$(dirname "$plan_file")" && pwd)/$(basename "$plan_file")"
```

This two-step expansion (`cd` to the directory, `pwd` to get the absolute path, then append the filename) converts a relative path to absolute before the working directory changes.

#### `env_dir` and environment validation

```bash
env_dir() {
    local environment="$1"
    echo "${ENVS_ROOT%/}/${environment}"
}
```

`${ENVS_ROOT%/}` strips a trailing slash from `ENVS_ROOT` if present, preventing double-slash paths like `/terraform/envs//dev`.

`validate_environment` (called by every Terraform command) checks only two things: the directory exists, and it contains at least one `.tf` file. There is no allowlist. Any name passed to `--env` that has a corresponding directory under `ENVS_ROOT` is valid — `dev`, `prod`, `test`, `staging`, `joe-local`, anything. The scripts never need to be updated when a new environment is added.

#### `maybe_init`

```bash
maybe_init() {
    local environment="$1"
    if [[ "$TF_SKIP_INIT" == "true" ]]; then
        return 0
    fi
    init_terraform "$environment"
}
```

Called before `plan`, `apply`, `destroy`, and `refresh`. In CI, the workflow runs an explicit `./scripts/tf.sh init dev` once, then sets `TF_SKIP_INIT=true` so subsequent `deploy.sh` invocations (which call into `tf.sh`) skip init. This avoids downloading providers multiple times per pipeline run.

#### Plan file naming and storage

```bash
generate_plan_name() {
    local environment="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    echo "${environment}-plan-${timestamp}.tfplan"
}
```

Plans are saved to `${PLANS_DIR}/${environment}-plan-${timestamp}.tfplan`. After saving, the path is written to `${OUTPUT_DIR}/latest-plan-${environment}.txt` so `apply` can find it:

```bash
echo "$plan_file" > "${OUTPUT_DIR}/latest-plan-${environment}.txt"
```

On apply, if no explicit plan file is given:

```bash
plan_file=$(cat "${OUTPUT_DIR}/latest-plan-${environment}.txt")
```

#### Plan summary (the JSON file)

After every successful plan, `show_plan_summary` runs `terraform show -json plan.tfplan > plan-summary-dev.json`. This JSON file serves two purposes:

1. Human-readable summary (counts of adds/changes/destroys/replaces)
2. Input for `conftest` policy checks and `infracost` cost estimation (avoids a second plan)

#### Security scanning

`security_scan_terraform` runs each security tool that is installed. Missing tools are warned about but do not fail the build. This design allows the suite to run partially in environments where not all tools are present.

```bash
if command -v "checkov" &> /dev/null; then
    run_checkov_scan || exit_code=1
    (( tools_run++ ))
else
    log_warn "checkov not found, skipping"
    (( tools_skipped++ ))
fi
```

The exit code accumulates failures across all tools. At the end, the function returns 0 only if every tool that ran passed. A partial scan (some tools skipped) logs a warning but does not fail unless the user explicitly requires all tools to run.

#### Checkov output parsing

```bash
checkov "${checkov_args[@]}" --output json > "$output_file" 2>&1 || true

if ! jq -e '.results' "$output_file" > /dev/null 2>&1; then
    log_error "Checkov scan failed"
    return 1
fi

failed_checks=$(jq '.results.failed_checks | length' "$output_file")
```

`|| true` prevents `set -e` from terminating the script when checkov exits non-zero (it exits non-zero for both "found issues" and hard errors). The script then reads the JSON output to determine whether the non-zero exit was "found issues" (parseable JSON with failed_checks > 0) or a hard error (unparseable JSON).

#### S3 state backup

```bash
backup_file="$(cd "${OUTPUT_DIR}" && pwd)/terraform-state-backup-${environment}-$(date +%Y%m%d-%H%M%S).tfstate"
terraform_cmd "state" "pull" > "$backup_file"
```

The path is made absolute before `terraform_cmd` calls `cd`. `terraform state pull` writes the current state to stdout. If `TF_STATE_BACKUP_BUCKET` is set, the backup is also uploaded to S3 with optional SSE-KMS.

### Environment variables

| Variable                     | Default               | Description                                               |
| ---------------------------- | --------------------- | --------------------------------------------------------- |
| `ENVS_ROOT`                  | `./envs`              | Parent directory of per-env Terraform roots               |
| `TERRAFORM_ROOT`             | parent of `ENVS_ROOT` | Root of the full Terraform tree (modules + envs)          |
| `OUTPUT_DIR`                 | `./outputs`           | Where outputs, plan summaries, cost estimates are written |
| `PLANS_DIR`                  | `./plans`             | Where binary plan files are saved                         |
| `ENVIRONMENT`                | `dev`                 | Default environment when not passed as positional arg     |
| `AUTO_APPROVE`               | `false`               | Set to `true` for non-interactive apply/destroy           |
| `TF_SKIP_INIT`               | `false`               | Skip implicit init on plan/apply/destroy/refresh          |
| `TF_STATE_BACKUP_BUCKET`     | (empty)               | S3 bucket for state backup uploads                        |
| `TF_STATE_BACKUP_KMS_KEY_ID` | (empty)               | KMS key ID for SSE-KMS on state backups                   |
| `LOG_LEVEL`                  | `INFO`                | Set to `DEBUG` for verbose output                         |

---

## 4. deploy.sh

### Purpose

The single entry point for all deployment operations. It is the only file that knows the full lifecycle: validate, plan, apply, CloudFront cache invalidation, smoke tests, destroy, bootstrap, and cost estimation. GitHub Actions workflows call this script and nothing else.

### All commands

```bash
# Validate (no AWS writes): lint + fmt-check + validate + plan + security scan
./scripts/deploy.sh validate --env dev

# Plan only
./scripts/deploy.sh plan --env dev

# Apply (prompts for confirmation unless --yes)
./scripts/deploy.sh apply --env dev
./scripts/deploy.sh apply --env dev --yes            # non-interactive
./scripts/deploy.sh apply --env dev --skip-smoke     # skip smoke tests

# Destroy (refuses prod without --allow-prod-destroy)
./scripts/deploy.sh destroy --env dev --yes
./scripts/deploy.sh destroy --env dev                # prompts for env name

# Cost estimate
./scripts/deploy.sh cost --env dev
./scripts/deploy.sh cost --env dev --plan-file outputs/plan-summary-dev.json

# Smoke tests only (no Terraform)
./scripts/deploy.sh smoke --env dev

# Bootstrap (one-time per account)
./scripts/deploy.sh bootstrap --env dev --bucket my-bucket --github-org myorg --github-repo myrepo --yes

# Config-only bootstrap (CI: writes state.config without AWS calls)
./scripts/deploy.sh bootstrap --env dev --bucket my-bucket --kms-key <key-arn> --skip-oidc-and-role
```

### Flag-to-variable mapping

Every `--flag` sets a corresponding environment variable:

| Flag                   | Variable                  | Effect                                                                         |
| ---------------------- | ------------------------- | ------------------------------------------------------------------------------ |
| `--env <name>`         | `ENVIRONMENT=<name>`      | Target environment — any name that matches a directory under `terraform/envs/` |
| `--region us-east-2`   | `AWS_REGION=us-east-2`    | AWS region                                                                     |
| `--yes`                | `AUTO_APPROVE=true`       | Skip confirmation prompts                                                      |
| `--skip-init`          | `TF_SKIP_INIT=true`       | Skip terraform init                                                            |
| `--skip-smoke`         | `SKIP_SMOKE=true`         | Skip smoke tests after apply                                                   |
| `--plan-file path`     | `PLAN_FILE=path`          | Binary plan for apply, or JSON for cost                                        |
| `--allow-prod-destroy` | `ALLOW_PROD_DESTROY=true` | Override prod destroy guard                                                    |

All variables are exported before calling `tf.sh`:

```bash
export ENVIRONMENT AWS_REGION AUTO_APPROVE TF_SKIP_INIT ...
```

`tf.sh` reads them from the environment, so no flags need to be passed on the command line when `deploy.sh` calls it.

### The `cmd_apply` flow

```bash
cmd_apply() {
    confirm_destructive "apply Terraform changes"

    if [[ -n "$PLAN_FILE" ]]; then
        call_tf apply "$ENVIRONMENT" "$PLAN_FILE" "$AUTO_APPROVE"
    else
        call_tf apply "$ENVIRONMENT" "" "$AUTO_APPROVE"
    fi

    invalidate_cloudfront || log_warn "Continuing despite CloudFront invalidation failure"
    run_smoke_tests
}
```

Three distinct stages run sequentially. The `||` on `invalidate_cloudfront` means a failed invalidation logs a warning but does not abort the function — the apply has already succeeded and the smoke tests should still run to verify the deployment. `run_smoke_tests` (without `||`) will propagate its exit code if it fails, which causes `deploy.sh` to exit non-zero and fail the CI job.

### `confirm_destructive`

```bash
confirm_destructive() {
    local action="$1"
    if [[ "$AUTO_APPROVE" == "true" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_error "Cannot prompt: stdin is not a TTY and AUTO_APPROVE is not set."
        exit 1
    fi
    read -r -p "Type the environment name to confirm: " confirmation
    if [[ "$confirmation" != "$ENVIRONMENT" ]]; then
        log_error "Confirmation did not match. Aborting."
        exit 1
    fi
}
```

`[[ ! -t 0 ]]` tests whether file descriptor 0 (stdin) is a terminal. In CI, stdin is not a TTY, so this check catches the case where `AUTO_APPROVE` was forgotten and the script would otherwise hang waiting for input that never comes.

The confirmation pattern (typing the environment name) prevents accidental execution with a mis-typed `--env` flag.

### The prod destroy guard

```bash
cmd_destroy() {
    if [[ "$ENVIRONMENT" == "prod" && "$ALLOW_PROD_DESTROY" != "true" ]]; then
        log_error "Refusing to destroy 'prod' via this script."
        log_error "To destroy prod from CI, pass --allow-prod-destroy."
        exit 1
    fi
    confirm_destructive "DESTROY all resources in $ENVIRONMENT"
    call_tf destroy "$ENVIRONMENT" "$AUTO_APPROVE"
}
```

`prod-destroy.yml` is the only caller that passes `--allow-prod-destroy`. That workflow requires a human reviewer via GitHub Environment protection rules. The combination means that destroying prod requires both a code path (`--allow-prod-destroy`) and a human approval (GitHub Environment gate). Neither alone is sufficient.

### CloudFront invalidation

```bash
invalidate_cloudfront() {
    local outputs_file="${OUTPUT_DIR}/terraform-outputs-${ENVIRONMENT}.json"
    local distribution_id
    distribution_id=$(jq -r '.cloudfront_distribution_id.value // empty' "$outputs_file" 2>/dev/null)

    if [[ -z "$distribution_id" ]] || [[ "$distribution_id" == "null" ]]; then
        log_warn "No cloudfront_distribution_id output; skipping"
        return 0
    fi

    aws cloudfront create-invalidation \
        --distribution-id "$distribution_id" \
        --paths "/*" \
        --output json > "${OUTPUT_DIR}/cloudfront-invalidation-${ENVIRONMENT}.json"
}
```

`jq -r '.cloudfront_distribution_id.value // empty'` reads the distribution ID from the Terraform outputs JSON written by `tf.sh` after apply. The `// empty` is a jq alternative operator: if `.cloudfront_distribution_id.value` is null or missing, return an empty string. The `-r` flag outputs raw text without JSON quotes.

### `call_tf`

```bash
call_tf() {
    bash "$TF_SH" "$@"
}
```

Explicitly calling `bash` rather than executing `tf.sh` directly means the shebang line in `tf.sh` is irrelevant — it always runs in bash regardless of the user's default shell. `"$@"` passes all positional arguments unchanged, preserving any spaces in values.

---

## 5. Bash Concepts Reference

### `set -euo pipefail`

All three scripts start with this (or `set -e` for bootstrap.sh). What each flag does:

- `-e`: exit immediately if any command returns a non-zero exit code
- `-u`: treat unset variables as errors (prevents silent bugs from typos like `$ENVIRONEMNT`)
- `-o pipefail`: a pipeline (`cmd1 | cmd2`) fails if any command in it fails, not just the last

```bash
# Without -o pipefail:
grep "pattern" missing_file | wc -l   # exits 0 because wc -l succeeded
# With -o pipefail:
grep "pattern" missing_file | wc -l   # exits 2 because grep failed
```

**Escaping `set -e`:** Use `|| true` or `|| :` to allow a command to fail without killing the script:

```bash
result=$(aws kms create-key ...) || true   # failure is expected and handled below
```

### `local` and function scope

```bash
function create_bucket() {
    local bucket_name=$1
    local region=$2
    ...
}
```

`local` declares a variable that exists only within the current function. Without `local`, variables are global in bash and can bleed across function calls in unexpected ways. All function parameters and intermediate variables should be `local`.

### Arrays and `"$@"` expansion

```bash
function generate_s3_policy() {
    local bucket_name=$1
    shift 1
    local roles=("$@")   # collect remaining args into array
    ...
    for role in "${roles[@]}"; do   # always quote array expansion
        ...
    done
}
```

`"${roles[@]}"` — always quote array expansions with double quotes. Without quotes, elements containing spaces would be word-split into multiple arguments. `"$@"` has the same property: it expands each positional argument as a separate quoted word.

`shift N` removes the first N positional arguments from `$@`, shifting the rest down. After `shift 1`, `$1` becomes what was `$2`, `$2` becomes what was `$3`, etc.

### `${variable:-default}` parameter expansion

```bash
ENVIRONMENT="${ENVIRONMENT:-dev}"
local target_dir="${ENVS_ROOT:-.}/${environment}"
```

`${VAR:-default}` returns `default` if `VAR` is unset or empty. `${VAR:-.}` returns `.` if `VAR` is unset or empty. Other forms:

| Form                  | Meaning                                                 |
| --------------------- | ------------------------------------------------------- |
| `${VAR:-default}`     | Use `default` if unset or empty                         |
| `${VAR:=default}`     | Use `default` and assign it if unset or empty           |
| `${VAR:+replacement}` | Use `replacement` if set and non-empty; otherwise empty |
| `${VAR%pattern}`      | Remove shortest matching pattern from end               |
| `${VAR%%pattern}`     | Remove longest matching pattern from end                |
| `${VAR#pattern}`      | Remove shortest matching pattern from start             |

`${ENVS_ROOT%/}` removes a trailing `/` from `ENVS_ROOT`, preventing double-slash paths.

### `[[ ... ]]` conditional tests

```bash
if [[ -z "$ENVIRONMENT" ]]; then   # -z: true if string is empty
if [[ -n "$plan_file" ]]; then     # -n: true if string is non-empty
if [[ -f "$output_file" ]]; then   # -f: true if file exists and is a regular file
if [[ -d "$target_dir" ]]; then    # -d: true if path exists and is a directory
if [[ ! -t 0 ]]; then              # -t 0: true if stdin is a terminal; ! negates
if [[ "$a" == "$b" ]]; then        # string equality
if [[ "$a" != "$b" ]]; then        # string inequality
if [[ "$a" && "$b" ]]; then        # logical AND within [[ ]]
if [[ "$a" || "$b" ]]; then        # logical OR within [[ ]]
```

Always use `[[ ]]` over `[ ]` in bash. `[[ ]]` is a bash keyword with safer string handling (no word-splitting on variables, supports `&&` and `||` directly, supports `=~` for regex).

### Arithmetic with `(( ))`

```bash
local wait=$(( attempt * 5 ))
(( attempt++ ))
(( tools_run++ ))
```

`(( expr ))` evaluates an arithmetic expression. The exit code is 1 if the result is 0 (falsy), 0 if non-zero (truthy) — this is the inverse of how you might expect it to work.

**Important caveat with `set -e`:** `(( counter++ ))` fails (exit code 1) when `counter` is 0, because post-increment returns the old value (0), which is falsy. Under `set -e`, this kills the script. Solutions:

```bash
# Safe: always succeeds (plain assignment)
counter=$(( counter + 1 ))

# Safe: pre-increment returns new value (always ≥ 1)
(( ++counter ))

# Safe: explicitly ignore exit code
(( counter++ )) || true

# Unsafe with set -e when counter == 0:
(( counter++ ))
```

### Here-documents (`<<EOF`)

```bash
trust_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${provider_arn}" },
      ...
    }
  ]
}
EOF
)
```

`<<EOF` starts a here-document that ends at the next line containing only `EOF`. Variable interpolation (`${provider_arn}`) happens inside unless you quote the delimiter (`<<'EOF'`). The `$(cat <<EOF ... EOF)` pattern captures the output into a variable.

Use `<<'EOF'` (single-quoted delimiter) to prevent variable expansion:

```bash
cat > "$target_file" <<'EOF'
bucket = "${LITERAL_NOT_EXPANDED}"
EOF
```

### `trap` for error context

```bash
trap 'echo "Error on line $LINENO"; exit 1' ERR
```

`trap COMMAND SIGNAL` runs `COMMAND` when `SIGNAL` is received. The `ERR` pseudo-signal fires whenever a command exits non-zero (combined with `set -e`). `$LINENO` is a bash built-in that expands to the current line number. This gives a precise error location instead of a silent exit.

### `command -v`

```bash
if command -v "infracost" &> /dev/null; then
```

`command -v tool` prints the path to `tool` if it is on `PATH`, or exits non-zero if not found. Redirect stdout and stderr to `/dev/null` to silence the output — the exit code is all that matters here. Prefer `command -v` over `which` because `which` is not POSIX and behaves differently across systems.

### String operations

```bash
# Strip trailing slash
ENVS_ROOT="${ENVS_ROOT%/}"

# Strip leading "https://"
api_domain="${api_endpoint#https://}"

# Check if string starts with value
[[ "$region" == us-east-* ]]

# Substring: get everything before first colon
tool="${entry%%:*}"
install_hint="${entry#*:}"
```

### `$(command)` vs backticks

Always use `$(command)` for command substitution, never `` `command` ``. `$()` is nestable, readable, and unambiguous. Backticks cannot be nested and are harder to read with backslashes.

### Quoting rules

```bash
# Always quote variable expansions in comparisons and command args
if [[ "$var" == "value" ]]; then
call_tf apply "$ENVIRONMENT" "$PLAN_FILE" "$AUTO_APPROVE"

# Always quote array expansions
for f in "${files[@]}"; do

# Quote glob patterns that should not expand
find "${PLANS_DIR}" -name "${environment}-plan-*.tfplan"
```

Unquoted variable expansions undergo word-splitting and glob expansion. `"${var}"` suppresses both. When in doubt, quote it.

---

## 6. Local Development Workflows

### First-time setup for a new environment

```bash
# 1. Bootstrap the AWS account (one time per environment)
./scripts/deploy.sh bootstrap \
  --env        dev \
  --region     us-east-2 \
  --bucket     my-project-tfstate \
  --github-org my-github-org \
  --github-repo my-repo \
  --yes

# 2. Attach the deployment permissions policy to the deploy role
# (do this in the AWS console or via aws iam put-role-policy)

# 3. Validate (no AWS writes)
./scripts/deploy.sh validate --env dev

# 4. Plan
./scripts/deploy.sh plan --env dev

# 5. Apply
./scripts/deploy.sh apply --env dev
```

### Day-to-day development

```bash
# Validate before pushing (what CI runs on every PR)
./scripts/deploy.sh validate --env dev

# Plan to preview changes
./scripts/deploy.sh plan --env dev

# Apply interactively (prompts for confirmation)
./scripts/deploy.sh apply --env dev

# Apply non-interactively
./scripts/deploy.sh apply --env dev --yes

# Check costs after a plan
./scripts/deploy.sh cost --env dev
./scripts/deploy.sh cost --env dev --plan-file outputs/plan-summary-dev.json

# Run smoke tests only (no Terraform)
./scripts/deploy.sh smoke --env dev

# Tear down dev environment
./scripts/deploy.sh destroy --env dev --yes
```

### Debugging Terraform directly (local only)

The CLAUDE.md rule "never call terraform directly" applies to pipelines and documented procedures. For local debugging, `tf.sh` provides direct access to Terraform sub-commands:

```bash
# List all resources in state
./scripts/tf.sh state list dev

# Inspect a specific resource
./scripts/tf.sh state show dev module.storage.aws_s3_bucket.objects

# Generate a dependency graph
./scripts/tf.sh graph dev png
# Opens: outputs/terraform-graph-dev.png

# Open an interactive Terraform console
./scripts/tf.sh console dev

# Show provider versions in use
./scripts/tf.sh providers dev

# Force unlock a stuck state lock
./scripts/tf.sh force-unlock dev <lock-id>
```

### Skipping init for repeated local operations

```bash
# Init once
./scripts/tf.sh init dev

# Then set TF_SKIP_INIT to avoid re-downloading providers on every command
export TF_SKIP_INIT=true

./scripts/deploy.sh plan --env dev
./scripts/deploy.sh apply --env dev --yes
```

---

## 7. CI/CD Pipeline Integration

### How CI uses these scripts

GitHub Actions workflows are thin wrappers. They set up credentials and write the gitignored config files (`state.config`, `terraform.tfvars`), then delegate everything to `deploy.sh`.

A typical deploy workflow job:

```yaml
- name: Write Terraform backend config
  env:
    TF_STATE_BUCKET: ${{ secrets.TF_STATE_BUCKET }}
    TF_STATE_KMS_KEY_ID: ${{ secrets.TF_STATE_KMS_KEY_ID }}
  run: |
    ./scripts/deploy.sh bootstrap \
      --env "${{ inputs.environment }}" \
      --skip-oidc-and-role

- name: Write terraform.tfvars
  run: |
    cat > "terraform/envs/${{ inputs.environment }}/terraform.tfvars" <<EOF
    project_name = "${{ vars.TF_PROJECT_NAME }}"
    environment  = "${{ inputs.environment }}"
    aws_region   = "${{ env.AWS_REGION }}"
    domain_name  = "${{ vars.TF_DOMAIN_NAME }}"
    EOF

- name: Configure AWS credentials (OIDC)
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
    aws-region: ${{ env.AWS_REGION }}

- name: Initialize Terraform
  run: ./scripts/tf.sh init "${{ inputs.environment }}"

- name: Apply
  env:
    TF_SKIP_INIT: "true"
    AUTO_APPROVE: "true"
    TF_STATE_BACKUP_BUCKET: ${{ secrets.TF_STATE_BUCKET }}
    TF_STATE_BACKUP_KMS_KEY_ID: ${{ secrets.TF_STATE_KMS_KEY_ID }}
  run: |
    ./scripts/deploy.sh apply \
      --env    "${{ inputs.environment }}" \
      --yes \
      --skip-init
```

### Required secrets and variables

| Name                  | Type            | Used by            | Description                             |
| --------------------- | --------------- | ------------------ | --------------------------------------- |
| `AWS_DEPLOY_ROLE_ARN` | Secret (env)    | All jobs with AWS  | ARN of the OIDC deploy role             |
| `TF_STATE_BUCKET`     | Secret (env)    | All Terraform jobs | S3 bucket for Terraform state           |
| `TF_STATE_KMS_KEY_ID` | Secret (env)    | All Terraform jobs | KMS key for state encryption            |
| `INFRACOST_API_KEY`   | Secret (repo)   | Cost job           | Free key from infracost.io              |
| `AWS_REGION`          | Variable (repo) | All jobs           | e.g. `us-east-2`                        |
| `TF_PROJECT_NAME`     | Variable (repo) | All jobs           | e.g. `filebridge`                       |
| `TF_HOSTED_ZONE_NAME` | Variable (repo) | All jobs           | e.g. `cloudplatformguide.com`           |
| `TF_DOMAIN_NAME`      | Variable (env)  | All jobs           | e.g. `dev.share.cloudplatformguide.com` |

Secrets marked `(env)` live in GitHub Environment settings (different values for dev vs prod). Secrets marked `(repo)` live in repository-level settings (same across all environments).

### The `TF_SKIP_INIT` pattern

Each CI job runs on a fresh runner. Provider downloads are expensive. The pattern is:

```yaml
# Explicit init (downloads providers once, ~30s)
- run: ./scripts/tf.sh init "${{ inputs.environment }}"

# All subsequent commands skip init via env var
- env:
    TF_SKIP_INIT: "true"
  run: ./scripts/deploy.sh apply --env dev --yes --skip-init
```

The `--skip-init` flag and `TF_SKIP_INIT=true` env var are redundant (either alone works). Using both makes intent explicit.

### Split plan/apply jobs

In this project's pipeline, plan and apply run as separate jobs on separate runners. This enables the prod approval gate (a human approves the plan before apply runs) and ensures the apply uses exactly the plan that was reviewed.

**Critical:** the plan binary and Lambda ZIP artifacts must be uploaded from the plan job and downloaded in the apply job:

```yaml
# In plan job:
- uses: actions/upload-artifact@v4
  with:
    name: tfplan-${{ inputs.environment }}-${{ github.run_id }}
    path: |
      plans/
      outputs/latest-plan-${{ inputs.environment }}.txt
      outputs/plan-summary-${{ inputs.environment }}.json
      terraform/envs/${{ inputs.environment }}/tmp/   # Lambda ZIPs built during plan

# In apply job:
- uses: actions/download-artifact@v4
  with:
    name: tfplan-${{ inputs.environment }}-${{ github.run_id }}
    path: ${{ github.workspace }}
```

`archive_file` data sources in Terraform write ZIP files during `terraform plan`. They must live in the workspace (`${path.root}/tmp/`) not in `/tmp/`, or they will not survive the runner boundary.

---

## 8. Adapting to a New Project

### Minimal changes required

1. **`bootstrap.sh`**: Change the role naming pattern on line 341:

   ```bash
   local role_name="myproject-deploy-${environment}"
   ```

2. **`tf.sh`**: The script is fully generic. No project-specific changes needed. Set `ENVS_ROOT` and `TERRAFORM_ROOT` to point at your directory layout.

3. **`deploy.sh`**: The `invalidate_cloudfront` function reads `cloudfront_distribution_id` from Terraform outputs. If your project does not use CloudFront, this is a no-op (the function checks for the output and skips if absent). For other post-apply steps, add them to `cmd_apply`.

4. **Directory layout**: The scripts assume this structure (configurable via env vars):

   ```
   project/
   ├── scripts/
   │   ├── deploy.sh
   │   ├── tf.sh
   │   └── bootstrap.sh
   ├── terraform/
   │   ├── modules/
   │   └── envs/
   │       ├── dev/
   │       │   ├── main.tf
   │       │   ├── terraform.tfvars    ← gitignored, written by CI
   │       │   └── state.config        ← gitignored, written by bootstrap
   │       └── prod/
   └── tests/
       └── smoke/
           └── smoke.sh
   ```

5. **Environment variables to set in CI:**
   ```yaml
   env:
     ENVS_ROOT: ${{ github.workspace }}/terraform/envs
     TERRAFORM_ROOT: ${{ github.workspace }}/terraform
     OUTPUT_DIR: ${{ github.workspace }}/outputs
     PLANS_DIR: ${{ github.workspace }}/plans
   ```

### Project-specific extension points

| Extension point              | How                                                                                                                                                                                                                                                           |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Add a post-apply step        | Add a function in `deploy.sh` and call it from `cmd_apply`                                                                                                                                                                                                    |
| Add a new environment        | Create `terraform/envs/<name>/` with the standard structure (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `providers.tf`, `backend.tf`), run `deploy.sh bootstrap` to generate `state.config`, and use `--env <name>`. No script changes required. |
| Add a security scanning tool | Add it to `security_scan_terraform` in `tf.sh`                                                                                                                                                                                                                |
| Change plan file retention   | Modify `cleanup_terraform` in `tf.sh`                                                                                                                                                                                                                         |
| Add pre-apply hooks          | Add checks in `cmd_apply` before calling `call_tf apply`                                                                                                                                                                                                      |
| Change state bucket layout   | Modify `create_backend_file` in `bootstrap.sh`                                                                                                                                                                                                                |
