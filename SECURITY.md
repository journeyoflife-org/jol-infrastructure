# Security Policy

## Supported Versions

This repository manages infrastructure-as-code for the Journey of Life platform.
Security fixes are applied to the current main branch and deployed immediately.

## Reporting a Vulnerability

### Severity Levels & Response Times

| Severity | Response Time | Resolution Target |
|----------|--------------|-------------------|
| **P1 — Critical** | 4 hours | 24 hours |
| **P2 — High** | 24 hours | 7 days |
| **P3 — Medium** | 72 hours | 30 days |

### How to Report

1. **Email**: security@journeyoflife.org
2. **GitHub**: Open a private security advisory via GitHub Security tab
3. **Emergency**: Contact the on-call SRE via PagerDuty

### What to Include
- Description of the vulnerability
- Affected component (terraform, kubernetes, helm, scripts)
- Steps to reproduce
- Potential impact assessment
- Suggested fix (if available)

## GDPR Data Breach Notification

Per GDPR Article 33:
- **72 hours** from awareness to notify the supervisory authority
- Notification must include: nature of breach, categories of data affected, likely consequences, remediation measures
- Contact the Data Protection Officer (DPO) immediately upon discovering any personal data exposure

## Security Controls

### Infrastructure
- All Terraform state encrypted at rest (SSE-KMS)
- EKS secrets encrypted via KMS
- VPC network segmentation (3-tier architecture)
- Network policies enforce default-deny

### Access Control
- IRSA (IAM Roles for Service Accounts) — no static credentials
- `automountServiceAccountToken: false` on all service accounts
- No `cluster-admin` bindings (enforced by OPA Gatekeeper)
- Pre-commit hooks prevent secret commits (TruffleHog)

### Compliance
- SOC 2 Type II — change management, monitoring, access controls
- GDPR — data protection by design and by default (Art.25)
- ISO 27001 — cryptographic key management (A.8.7)

### Continuous Security
- **TruffleHog**: Secret scanning on every commit
- **Checkov**: Infrastructure policy validation (CIS, NIST, SOC 2)
- **tfsec**: Terraform security analysis
- **OPA**: Custom policy enforcement (no cluster-admin, resource limits)
- **Qodana**: Code quality analysis (CRITICAL = pipeline fail)

## Bug Bounty

We do not currently operate a public bug bounty program.
Security researchers who discover vulnerabilities are encouraged to report them via the channels above.
