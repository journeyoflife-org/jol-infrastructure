# Network Topology

## 3-Tier VPC Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    AWS Region: eu-central-1                  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  VPC: 10.0.0.0/16 (prod) / 10.1.x (stg) / 10.2.x (dev) │
│  │                                                      │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │  │
│  │  │  Public Tier │  │ Private Tier│  │  DB Tier    │ │  │
│  │  │  .1.0/24     │  │ .10.0/24    │  │ .20.0/24    │ │  │
│  │  │  .2.0/24     │  │ .11.0/24    │  │ .21.0/24    │ │  │
│  │  │  .3.0/24     │  │ .12.0/24    │  │ .22.0/24    │ │  │
│  │  │             │  │             │  │             │ │  │
│  │  │  ALB        │  │  EKS Nodes  │  │  RDS        │ │  │
│  │  │  NAT GW     │  │  App Pods   │  │  ElastiCache│ │  │
│  │  └──────┬──────┘  └──────┬──────┘  └─────────────┘ │  │
│  │         │                │                          │  │
│  │    Internet GW      NAT Gateway                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Traffic Flow
1. **Ingress**: Internet → ALB (public) → NetworkPolicy → App Pods (private)
2. **Egress**: App Pods → NAT Gateway → Internet (updates, external APIs)
3. **Internal**: App Pods → RDS/ElastiCache (DB tier, no internet)

## Network Controls
- **NACLs**: Subnet-level stateless filtering
- **Security Groups**: Instance-level stateful filtering
- **Network Policies**: Pod-level Kubernetes-native filtering
- **VPC Flow Logs**: All traffic logged to CloudWatch (SOC 2 CC7.2)
