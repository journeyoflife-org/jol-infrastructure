# Checkov Policies

Checkov scans Terraform, Kubernetes, and Helm configurations against
CIS, NIST, SOC 2, and custom policy packs.

## Configuration
See `.checkov.yaml` for active rules and skip-list.

## Running Locally
```bash
checkov -d ../../terraform/ --config-file .checkov.yaml
checkov -d ../../kubernetes/ --config-file .checkov.yaml
```

## Adding Skip Rules
All skipped checks must be documented with:
1. Check ID
2. Business justification
3. Compensating control
4. Expiry date for re-evaluation
