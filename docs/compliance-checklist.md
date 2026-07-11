# Compliance Checklist

Quick-reference checklist for infrastructure changes against compliance frameworks.

## SOC 2 Type II

| Control | Requirement | Verification |
|---------|------------|--------------|
| CC6.1 | Logical access controls | IRSA, RBAC, NetworkPolicy, no static credentials |
| CC6.6 | Network segmentation | 3-tier VPC, NACLs, Security Groups, NetworkPolicy |
| CC7.1 | System monitoring | CloudWatch, Prometheus, VPC Flow Logs |
| CC7.2 | Anomaly detection | CloudWatch Alarms, alerting rules |
| CC8.1 | Change management | PR review, CI validation, manual prod apply, CHANGELOG |

## GDPR

| Article | Requirement | Verification |
|---------|------------|--------------|
| Art.25 | Data protection by design | Encryption at rest/transit, network isolation |
| Art.32 | Security of processing | KMS encryption, TLS 1.3, access controls |
| Art.33 | Breach notification | 72h incident response procedure, DPO notification |

## ISO 27001

| Control | Requirement | Verification |
|---------|------------|--------------|
| A.8.4 | Access to source code | CODEOWNERS, RBAC, branch protection |
| A.8.7 | Key management | KMS auto-rotation, secret rotation schedule |
| A.12.1.2 | Change management | GitOps workflow, peer review, approval gates |

## Pre-Merge Validation (automated)

- [ ] TruffleHog — no secrets detected
- [ ] Checkov — no policy violations
- [ ] tfsec — no security findings above MEDIUM
- [ ] OPA — all custom policies pass
- [ ] Qodana — no CRITICAL issues
