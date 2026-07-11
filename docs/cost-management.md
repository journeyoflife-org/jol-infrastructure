# Cost Management

## Overview
All infrastructure costs are tracked per environment and service.
Cost reviews are conducted monthly and during quarterly compliance audits.

## Cost Monitoring Tools
- **AWS Cost Explorer** — monthly spend analysis by service/tag
- **Infracost** — PR-level cost estimates for Terraform changes
- **Kubecost** — Kubernetes cluster cost allocation

## Budget Alerts
CloudWatch budgets configured per environment:

| Environment | Monthly Budget | Alert Threshold |
|-------------|---------------|----------------|
| dev | $500 | 80%, 100% |
| staging | $1,500 | 80%, 100% |
| prod | $5,000 | 70%, 90%, 100% |

## Cost Optimization Strategies
1. **Right-sizing**: Review instance types quarterly via Compute Optimizer
2. **Reserved Instances**: Convert on-demand to RI for stable workloads
3. **Spot Instances**: Use for non-critical batch workloads (analytics)
4. **Auto-scaling**: Scale down during off-hours for dev/staging
5. **S3 Lifecycle**: Transition old data to Intelligent-Tiering

## Tagging Strategy
All resources must include:
- `Project`: jol
- `Environment`: dev/staging/prod
- `ManagedBy`: terraform
- `CostCenter`: (team-specific)
