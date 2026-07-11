# ADR-003: Secrets Management (Vaultwarden + External Secrets Operator)

## Status
Accepted

## Context
Application secrets (DB credentials, API keys, TLS certs) must not reside in code or
environment variables committed to git. We need a centralized secrets manager that
integrates with Kubernetes without exposing secrets in manifests.

## Decision
Use Vaultwarden (self-hosted Bitwarden) as the secrets store, synced to Kubernetes
Secrets via External Secrets Operator (ESO).

## Consequences
- **Positive**: No secrets in git; ESO handles rotation automatically
- **Positive**: Self-hosted = no per-seat licensing costs
- **Positive**: Audit log of all secret access
- **Negative**: Requires Vaultwarden HA setup for production
- **Risk**: Vaultwarden availability is a single point of failure (mitigated by HA)

## Alternatives Considered
1. AWS Secrets Manager — rejected (cost at scale, vendor lock-in)
2. HashiCorp Vault — rejected (operational complexity for current scale)
3. Sealed Secrets — rejected (no rotation support)

## Compliance
- SOC 2 CC6.1: Secrets encrypted at rest and in transit
- GDPR Art.32: Encryption of personal data processing credentials
- ISO 27001 A.8.7: Automated secret rotation on defined schedule
