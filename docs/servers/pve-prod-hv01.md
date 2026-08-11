# pve-prod-hv01

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | pve-prod-hv01                              |
| **Role**           | hypervisor                                 |
| **Environment**    | prod                                       |
| **VLAN**           | 60 (Proxmox management)                  |
| **Static IP**      | 10.60.60.20                              |
| **OS**             | Proxmox VE 9.2 (Debian 13 Trixie)         |
| **Owner**          | jol-admin                                  |
| **Purpose**        | Hypervisor for AI service VMs (RAG, MCP, Hermes) |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | yes (PBS — HP P4500)                       |
| **Monitoring**     | yes (node-exporter, netdata)               |

## Role Description

Proxmox VE hypervisor hosting production AI service virtual machines.
Single-node cluster; no HA. Consumer-grade hardware with documented risk
acceptance (no ECC, no IPMI, single NIC/PSU).

## Hardware

| Component    | Specification                              |
|--------------|--------------------------------------------|
| Motherboard  | GIGABYTE GA-AX370-GAMING 5                |
| CPU          | AMD Ryzen 7 3700X (8C/16T, 4.4 GHz)       |
| RAM          | Corsair Vengeance LPX 64GB DDR4-2400 (non-ECC) |
| Storage      | 1TB NVMe SSD + 1TB HDD                    |
| NIC          | Dual onboard: nic0 + nic1 (GA-AX370-GAMING 5) |
| IPMI/BMC     | None                                       |

## Virtual Machines

| VMID | Hostname        | vCPU | RAM   | Disk   | IP          |
|------|-----------------|------|-------|--------|-------------|
| 100  | rag-prod-lt01   | 4    | 24 GB | 100 GB | 10.40.40.10 |
| 101  | mcp-prod-lt01   | 2    | 8 GB  | 50 GB  | 10.40.40.11 |
| 102  | her-prod-lt01   | 2    | 8 GB  | 50 GB  | 10.40.40.12 |

## Network

- vmbr0: 10.60.60.20/24 (VLAN 60, gateway 10.60.60.1, bridge-ports nic1)
- vmbr1: no host IP (bridge-ports nic0) — VMs use MikroTik 10.40.40.1 as gateway
- nic1 (MAC 1C:1B:0D:9F:4E:A8) → Gi1/0/5, switch VLAN 60 — management
- nic0 (MAC 1C:1B:0D:9F:4E:A6) → Gi1/0/6, switch VLAN 40 — VM traffic (RAG/MCP/Hermes)
- VMs directly on VLAN 40 (10.40.40.0/24), routed by MikroTik (no NAT)
- Web UI (8006) restricted to management VLANs

## SSH Policy

- Password authentication **disabled**
- Key-only access via centrally managed SSH keys
- Root login: prohibit-password (key-only)
- Allowed users: root, jol-admin
- Idle session timeout: 15 minutes
- fail2ban: 3 attempts = 24h ban

## Security Controls

- UFW: default deny incoming, allow 22/tcp, 8006/tcp (mgmt only)
- auditd: enabled for syscall auditing
- chrony: NTP synchronisation (SOC2 CC7.2)
- fail2ban: SSH brute-force protection

## Backup Policy

- VM backups via Proxmox Backup Server (HP P4500)
- Schedule: nightly 02:00 UTC
- Encryption: client-side (PBS)
- RPO: 24 h | RTO: 4 h

## Maintenance Notes

- Kernel updates require reboot — schedule with maintenance window
- PVE package updates via no-subscription repository
- All changes tracked via ticket and recorded in change log

## Risk Acceptance

| Risk | Mitigation |
|------|-----------|
| No ECC RAM | ZFS checksums + nightly backups |
| No IPMI/OOB | Physical access documented; netdata alerts |
| Dual NIC (nic0 spare) | nic1 active on VLAN 60; nic0 available for failover/iSCSI |
| Single PSU | UPS; documented acceptance |

## Change History

| Date       | Change | Evidence |
|------------|--------|----------|
| 2026-07-31 | vmbr0/vmbr1 migrated to nic1 (Gi1/0/5, VLAN 60) / nic0 (Gi1/0/6, VLAN 40) | n2048-config-2026-07-31.txt |
| 2026-08-08 | Network incident: vmbr1 had drifted to an isolated NAT bridge (`bridge-ports none`, hypervisor IP 10.40.40.1 squatting the gateway, iptables MASQUERADE to vmbr0) — contradicting the documented L2 design. Restored: `bridge-ports nic0`, NAT rule and host IP removed; rag/mcp/her reachable again from admin01 | `/etc/network/interfaces.bak-20260808`, n2048 session 2026-08-08 |
