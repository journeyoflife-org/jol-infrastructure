# ADR-001: Terraform State Backend (S3 + DynamoDB)

## Status
Accepted

## Context
We need a reliable, secure, and team-collaborative backend for Terraform state storage.
State files contain sensitive data (resource IDs, configurations) and must be encrypted at rest.

## Decision
Use AWS S3 with DynamoDB locking as the Terraform state backend.

- **S3**: State storage with versioning, SSE-KMS encryption, public access blocked
- **DynamoDB**: State locking to prevent concurrent modifications
- **KMS**: Customer-managed keys for encryption at rest

## Consequences
- **Positive**: Native AWS integration, cost-effective, supports team collaboration
- **Positive**: Versioned state enables rollback (SOC 2 CC8.1)
- **Negative**: Requires initial bootstrap step (one-time)
- **Risk**: State file corruption mitigated by versioning + DynamoDB locks

## Alternatives Considered
1. Terraform Cloud — rejected (cost, vendor lock-in)
2. Git-based state — rejected (no locking, security concerns)
3. Consul — rejected (operational complexity)

## Compliance
- SOC 2 CC6.1: Encryption at rest via KMS
- SOC 2 CC8.1: Versioned state for change audit trail
- ISO 27001 A.8.7: Automatic key rotation
