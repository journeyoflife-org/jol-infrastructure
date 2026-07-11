# Terraform Bootstrap

One-time bootstrap module that creates the foundational resources required for Terraform remote state management.

## What This Creates

| Resource | Purpose |
|----------|---------|
| S3 Bucket (×3) | Remote state storage per environment (dev/staging/prod) |
| KMS Key (×3) | Encryption at rest for state files |
| DynamoDB Table (×3) | State locking to prevent concurrent modifications |

## Prerequisites

- AWS CLI configured with admin credentials
- Terraform >= 1.9.0

## Usage

```bash
# 1. Initialize
cd terraform/bootstrap
terraform init

# 2. Plan
terraform plan

# 3. Apply (ONE-TIME only)
terraform apply

# 4. Copy the backend config snippets from outputs into each environment's backend.tf
terraform output backend_config_snippet
```

> **IMPORTANT:** This module uses local state. Run it ONCE, then all subsequent
> Terraform operations use the S3 remote backend created here.

## Security Controls

- **Encryption at rest**: S3 SSE-KMS with dedicated KMS keys
- **Versioning**: Enabled for state recovery (SOC 2 CC8.1)
- **Public access**: Fully blocked
- **Key rotation**: Automatic annual rotation (ISO 27001 A.8.7)
- **Lifecycle**: Old state versions retained 90 days for audit trail
