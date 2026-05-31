# Run all:       terraform test
# Run this file: terraform test -filter=tests/unit.tftest.hcl

mock_provider "time" {
  mock_resource "time_static" {
    defaults = {
      id      = "2026-05-30T00:00:00Z"
      rfc3339 = "2026-05-30T00:00:00Z"
      unix    = 1748563200
    }
  }
}

run "defaults_produce_empty_triggers" {
  command = apply

  assert {
    condition     = length(time_static.this.triggers) == 0
    error_message = "Expected empty triggers map when none are provided."
  }
}

run "custom_triggers_are_passed_through" {
  command = apply

  variables {
    triggers = { version = "1.0.0" }
  }

  assert {
    condition     = time_static.this.triggers == tomap({ version = "1.0.0" })
    error_message = "Triggers were not passed through correctly."
  }

  assert {
    condition     = output.rfc3339 == "2026-05-30T00:00:00Z"
    error_message = "rfc3339 output did not match mock value."
  }

  assert {
    condition     = output.unix == 1748563200
    error_message = "unix output did not match mock value."
  }
}

run "explicit_rfc3339_pin_is_used" {
  command = plan

  variables {
    rfc3339 = "2025-01-01T00:00:00Z"
  }

  assert {
    condition     = time_static.this.rfc3339 == "2025-01-01T00:00:00Z"
    error_message = "Pinned rfc3339 value was not used."
  }
}
