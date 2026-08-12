# Trust Boundaries

## Trust Zones

### Cloud (AWS)

| Zone | Trust Level | Contents | Access Control |
|------|------------|----------|----------------|
| Internet | Untrusted | End users, external services | ALB + WAF |
| Public (DMZ) | Semi-trusted | ALB, NAT Gateway | Security Groups |
| Private (App) | Trusted | EKS nodes, application pods | IRSA + NetworkPolicy |
| Database | Highly Trusted | RDS, ElastiCache | VPC isolation + IAM auth |
| Management | Restricted | AWS Console, SSM | MFA + IAM policies |

### On-Prem (Proxmox)

| Zone | Trust Level | Contents | Access Control |
|------|------------|----------|----------------|
| VLAN 10 — Management (10.10.10.0/24) | Semi-trusted | PBS, admin workstation | nftables + fail2ban + key-only SSH |
| VLAN 40 — AI Services (10.40.40.0/24) | Trusted | rag-prod-lt01, mcp-prod-lt01, her-prod-lt01 | MikroTik inter-VLAN firewall + UFW |
| VLAN 30 — GPU/LLM (10.30.30.0/24) | Trusted | llm-prod-lt01 (Ollama) | Firewall: only :11434 exposed to VLAN 40 |
| Hypervisor (pve-prod-hv01) | Highly Trusted | Proxmox VE 9.2, VM lifecycle | Root key-only SSH, auditd, UFW 8006 restricted to /24 |

## Data Flows

### Cloud
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

### On-Prem
```
Admin workstation (10.10.10.50, VLAN 10)
  │
  ├──▶ SSH key-only → pve-prod-hv01 (10.60.60.20)
  ├──▶ SSH key-only → pbs01 (10.10.10.30)
  └──▶ SSH key-only → VLAN 40 VMs (10.40.40.10-12, routed via MikroTik)

VLAN 40 VMs (10.40.40.10-12)
  │
  ├──▶ Ollama (10.30.30.10:11434) — routed, firewall-restricted
  ├──▶ MCP API (10.40.40.11:3000) — intra-VLAN
  └──▶ Internet — masquerade via MikroTik WAN

pve-prod-hv01 (10.60.60.20)
  └──▶ PBS / HP P4500 (10.10.10.30:8007) — encrypted backup stream

llm-prod-lt01 (10.30.30.10, bare-metal, VLAN 30)
  └──▶ PBS / HP P4500 (10.10.10.30:8007) — encrypted model-store backup
      stream (proxmox-backup-client push, namespace jol-llm,
      token-scoped identity; 8007/tcp allowed for this host only, 2026-08-11)
```

## GDPR Art.25 — Data Protection by Design

### Cloud
- Personal data encrypted at rest (KMS) and in transit (TLS 1.3)
- Database tier has no internet access — data exfiltration blocked
- Network policies enforce pod-to-pod communication rules
- VPC Flow Logs provide audit trail of all network access

### On-Prem
- All AI inference via local Ollama — zero cross-border data transfer (EU-only)
- VM backups encrypted client-side (PBS encryption key, stored outside repo)
- llm-prod-lt01 model-store backups encrypted client-side and pushed to
  pbs01 under a dedicated least-privilege token (2026-08-11)
- VLAN 40 access controlled via MikroTik inter-VLAN firewall rules
- SSH key-only access; no password authentication anywhere
- auditd on hypervisor and PBS for full syscall-level audit trail

## SOC 2 Trust Services Criteria
- CC6.1: Logical access — IRSA, RBAC, NetworkPolicy (cloud); key-only SSH, sudo, AllowUsers (on-prem)
- CC6.6: Network segmentation — 3-tier VPC + NACLs + SGs (cloud); VLAN segmentation + MikroTik firewall + nftables (on-prem)
- CC7.2: Monitoring — VPC Flow Logs, CloudWatch, Prometheus (cloud); auditd, chrony NTP, node-exporter (on-prem)

## ISO 27001 Controls (On-Prem)
- A.8.2 (Privileged access): Root SSH key-only (prohibit-password), AllowUsers restricted
- A.8.5 (Secure authentication): Key-only SSH, fail2ban, MaxAuthTries 3
- A.8.20 (Network security): VLAN segmentation, MikroTik firewall, nftables/UFW
- A.8.13 (Information backup): PBS nightly encrypted backups (VMs from
  pve-prod-hv01; model store from llm-prod-lt01), RPO 24h / RTO 4h
