# Trust Boundaries

## Trust Zones

| Zone | Trust Level | Contents | Access Control |
|------|------------|----------|----------------|
| Internet | Untrusted | End users, external services | ALB + WAF |
| Public (DMZ) | Semi-trusted | ALB, NAT Gateway | Security Groups |
| Private (App) | Trusted | EKS nodes, application pods | IRSA + NetworkPolicy |
| Database | Highly Trusted | RDS, ElastiCache | VPC isolation + IAM auth |
| Management | Restricted | AWS Console, SSM | MFA + IAM policies |

## Data Flows

```
User (untrusted)
  │
  ▼ HTTPS (TLS 1.3)
ALB (public tier)
  │
  ▼ mTLS / HTTP2
EKS Pod (private tier)
  │
  ├──▶ RDS (DB tier) — IAM auth + TLS
  ├──▶ ElastiCache (DB tier) — AUTH token + TLS
  ├──▶ S3 — IRSA + VPC endpoint
  └──▶ External APIs — NAT Gateway + TLS
```

## GDPR Art.25 — Data Protection by Design
- Personal data encrypted at rest (KMS) and in transit (TLS 1.3)
- Database tier has no internet access — data exfiltration blocked
- Network policies enforce pod-to-pod communication rules
- VPC Flow Logs provide audit trail of all network access

## SOC 2 Trust Services Criteria
- CC6.1: Logical access — IRSA, RBAC, NetworkPolicy
- CC6.6: Network segmentation — 3-tier VPC + NACLs + SGs
- CC7.2: Monitoring — VPC Flow Logs, CloudWatch, Prometheus
