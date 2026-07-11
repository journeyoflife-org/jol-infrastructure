# tfsec Policies

tfsec performs static analysis of Terraform code for security issues.

## Configuration
See `config.yaml` for severity thresholds and exclusions.

## Running Locally
```bash
tfsec ../../terraform/ --config-file config.yaml
```

## Severity Levels
- **CRITICAL**: Must fix before merge (pipeline fails)
- **HIGH**: Must fix before merge (pipeline warns)
- **MEDIUM**: Should fix, documented exception allowed
- **LOW**: Best effort, informational

## Ignored Checks
See `../../.tfsec/ignored-checks.yml` for all overrides.
Each override must include a business justification and expiry date.
