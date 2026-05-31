# Policies

This directory holds security and compliance policies that run automatically during `module.sh validate`. Two frameworks are supported: **Checkov** (static analysis of Terraform source) and **Conftest/OPA** (policy-as-code against a Terraform plan JSON).

```
policies/
  checkov/
    .checkov.yml                    # Checkov configuration (required)
    check_<name>.py                 # Custom Python checks (one per file)
  conftest/
    <policy>.rego                   # OPA/Rego policies evaluated against plan JSON
```

---

## How policies are invoked

`module.sh validate` calls `security_scan_terraform` from `tf.sh`, which runs each installed tool in sequence. Missing tools are warned about and skipped — they do not fail the build. All tools that are present must pass for the step to succeed.

| Tool | What it scans | When it runs |
|------|--------------|--------------|
| Checkov | Terraform source (`.tf` files) | Always, if installed |
| tfsec | Terraform source (`.tf` files) | Always, if installed |
| shellcheck | Shell scripts under `.github/scripts/` | Always, if installed |
| Conftest | Plan JSON from a prior `module.sh plan` run | Only if plan JSON exists |

---

## Checkov

Checkov scans Terraform source files against its built-in rule library and any custom checks defined here. Configuration lives in `checkov/.checkov.yml`.

### Configuration — `checkov/.checkov.yml`

```yaml
# Point Checkov at this directory for custom Python checks.
external-checks-dir:
  - policies/checkov

# Suppress specific built-in checks that don't apply to this module.
# skip-check:
#   - CKV_AWS_123
```

The path in `external-checks-dir` is relative to the Terraform root (the directory Checkov is invoked from), not relative to the config file itself.

### Writing a custom check

Each custom check is a Python file that subclasses `BaseResourceCheck`. The file must instantiate the check class at module level so Checkov auto-discovers it.

```python
from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck


class MyCheck(BaseResourceCheck):
    def __init__(self):
        super().__init__(
            name="Human-readable description of what this enforces",
            id="CKV_CUSTOM_<N>",        # must be unique across all checks
            categories=[CheckCategories.GENERAL_SECURITY],
            supported_resources=["aws_s3_bucket"],  # resource type(s) to evaluate
        )

    def scan_resource_conf(self, conf):
        # conf is a dict of the resource's attribute values.
        # Each value is typically wrapped in a list: conf.get("attr") → ["value"]
        value = conf.get("some_attribute", [None])[0]
        if value:
            return CheckResult.PASSED
        return CheckResult.FAILED


check = MyCheck()
```

**`conf` structure:** Checkov wraps each attribute value in a list. A block attribute like `encryption { enabled = true }` arrives as `[{"enabled": [True]}]`. Test your parsing with a small script before committing.

**Check IDs:** Use `CKV_CUSTOM_<SCOPE>_<N>` (e.g. `CKV_CUSTOM_TIME_1`) to avoid collisions with Checkov's built-in `CKV_AWS_*` / `CKV_GCP_*` namespace.

### Existing custom checks

| File | Check ID | Enforces |
|------|----------|---------|
| `check_time_static_triggers.py` | `CKV_CUSTOM_TIME_1` | `time_static` resources must define `triggers` so timestamps can be refreshed intentionally |

### References

- [Checkov documentation](https://www.checkov.io/1.Welcome/What%20is%20Checkov.html)
- [Custom Python checks](https://www.checkov.io/3.Custom%20Policies/Python%20Custom%20Policies.html)
- [Configuration reference](https://www.checkov.io/2.Basics/CLI%20Command%20Reference.html)
- [Built-in Terraform checks](https://www.checkov.io/5.Policy%20Index/terraform.html)
- [Check severity and skip directives](https://www.checkov.io/2.Basics/Suppressing%20and%20Skipping%20Policies.html)

---

## Conftest / OPA

Conftest evaluates policies written in [Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) against the JSON output of `terraform show -json` (the plan summary). This enables plan-time checks — things Checkov cannot evaluate because they depend on computed values or cross-resource relationships.

Conftest runs only when a plan summary exists at `outputs/plan-summary-<example>.json`. Run `module.sh plan <example>` first.

### Writing a Rego policy

Place `.rego` files in `policies/conftest/`. Conftest uses the `deny` and `warn` rule conventions:

```rego
package main

# deny stops the pipeline; warn is advisory only.
deny[msg] {
    resource := input.resource_changes[_]
    resource.type == "time_static"
    not resource.change.after.triggers
    msg := sprintf("time_static.%s must define triggers", [resource.address])
}
```

`input` is the full `terraform show -json` object. Use `resource_changes[_]` to iterate proposed changes.

### References

- [Conftest documentation](https://www.conftest.dev)
- [OPA / Rego language reference](https://www.openpolicyagent.org/docs/latest/policy-language/)
- [Terraform plan JSON format](https://developer.hashicorp.com/terraform/internals/json-format)
- [Conftest with Terraform](https://www.conftest.dev/examples/)
