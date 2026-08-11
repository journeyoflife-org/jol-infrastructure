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

## On-Prem Proxmox Infrastructure (VLAN-Segmented)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Dell N2048 Switch — VLAN-segmented (MikroTik RB5009 inter-VLAN router) │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  pve-prod-hv01 (10.60.60.20) — VLAN 60: Proxmox Hypervisors      │  │
│  │  Gi1/0/5 → nic1 (vmbr0, 10.60.60.20/24, gw 10.60.60.1)          │  │
│  │  Gi1/0/6 → nic0 (vmbr1, VLAN 40 — VM traffic, no host IP)        │  │
│  │                                                                   │  │
│  │  vmbr1 → VLAN 40: AI Services (direct L2, MikroTik routes)       │  │
│  │    │                                                              │  │
│  │    ├── 10.40.40.10  rag-prod-lt01  (VMID 100, 4C/24G/100G)      │  │
│  │    ├── 10.40.40.11  mcp-prod-lt01  (VMID 101, 2C/8G/50G)        │  │
│  │    └── 10.40.40.12  her-prod-lt01  (VMID 102, 2C/8G/50G)        │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  llm-prod-lt01 (10.30.30.10) — VLAN 30: GPU/LLM Segment         │  │
│  │    Ollama inference endpoint: 10.30.30.10:11434                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  HP P4500 (10.10.10.30) — VLAN 10: Management / PBS             │  │
│  │    Nightly encrypted VM backups, RPO 24h / RTO 4h                 │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### VLAN 40 Traffic Flow
1. **VM → Ollama**: 10.40.40.0/24 → 10.30.30.10:11434 (routed via MikroTik inter-VLAN)
2. **VM → Internet**: 10.40.40.0/24 → MikroTik 10.40.40.1 → WAN (masquerade)
3. **Admin → VMs**: Workstation → 10.40.40.x:22 direct (routed via MikroTik, no ProxyJump needed)
4. **Backups**: Proxmox → PBS (HP P4500) via routed VLANs (encrypted)

### On-Prem Network Controls
- **MikroTik RB5009**: Inter-VLAN routing + firewall (srcnat masquerade to WAN)
- **nftables (PBS)**: Default deny incoming; allow SSH/API from management VLANs
- **fail2ban**: SSH brute-force protection on hypervisor and PBS
- **Isolation**: VLAN 40 VMs have no direct Layer 2 exposure to management LAN
- **Direct routing**: Admin → VMs via MikroTik inter-VLAN (no ProxyJump required)

---

## Network Controls (AWS)
- **NACLs**: Subnet-level stateless filtering
- **Security Groups**: Instance-level stateful filtering
- **Network Policies**: Pod-level Kubernetes-native filtering
- **VPC Flow Logs**: All traffic logged to CloudWatch (SOC 2 CC7.2)
