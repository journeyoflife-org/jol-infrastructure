# ADR-004: Network Segmentation (3-tier VPC Architecture)

## Status
Accepted

## Context
Workloads require network isolation to limit blast radius of security incidents.
GDPR and SOC 2 require logical network segmentation between tiers.

## Decision
Implement a 3-tier VPC architecture per environment:
- **Public tier**: ALB, NAT Gateways (internet-facing)
- **Private tier**: EKS nodes, application pods (no direct internet)
- **Database tier**: RDS, ElastiCache (isolated, no internet)

## CIDR Allocation
| Environment | VPC CIDR      |
|-------------|---------------|
| Production  | 10.0.0.0/16  |
| Staging     | 10.1.0.0/16  |
| Development | 10.2.0.0/16  |

## Consequences
- **Positive**: Clear trust boundaries, reduced attack surface
- **Positive**: Network ACLs provide defense-in-depth
- **Positive**: VPC Flow Logs for audit trail (SOC 2 CC7.2)
- **Negative**: NAT Gateway cost for private tier internet access

## Alternatives Considered
1. Single VPC with SGs only — rejected (insufficient isolation)
2. Transit Gateway mesh — rejected (premature for current scale)
3. VPC peering — rejected (limited to 125 peers, operational complexity)

## Compliance
- SOC 2 CC6.6: Logical network segmentation
- GDPR Art.25: Data protection by design — network isolation
- PCI DSS 1.3: Prohibit direct public access to cardholder data environment
