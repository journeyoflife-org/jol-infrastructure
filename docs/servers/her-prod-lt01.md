# her-prod-lt01

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | her-prod-lt01                              |
| **Role**           | hermes                                     |
| **Environment**    | prod                                       |
| **VLAN**           | 40                                         |
| **Static IP**      | 10.40.40.12                                |
| **OS**             | Ubuntu 24.04 LTS (VM)                      |
| **Owner**          | jol-admin                                  |
| **Purpose**        | Hermes agent orchestration, workflows, automation |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | yes                                        |
| **Monitoring**     | yes (node-exporter)                        |
| **VMID**           | 102                                        |
| **Hypervisor**     | pve-prod-hv01                              |

## Role Description

Hermes Agent orchestration server running AI-powered infrastructure
automation: backup verification, CIS compliance scanning, P1 incident
triage, daily operational reporting, and Bitrix24 CRM integration.
All data residency confined to EU/EEA (GDPR Art.25).

## Resources

| Resource | Allocation |
|----------|-----------|
| vCPU     | 2         |
| RAM      | 8 GB      |
| Disk     | 50 GB (NVMe thin) |

## Network

- VLAN 40 — AI Services segment (10.40.40.0/24)
- Gateway: 10.40.40.1 (Proxmox NAT bridge)
- Ollama access: 10.30.30.10:11434 (VLAN 30, routed)
- MCP access: 10.40.40.11:3000 (same VLAN)
- Ingress restricted to internal service mesh and bastion only

## SSH Policy

- Password authentication **disabled**
- Key-only access via centrally managed SSH keys
- Root login disabled; administrative access via `jol-admin` + sudo
- Idle session timeout: 15 minutes

## Firewall Ports

| Port | Service        | Access       |
|------|----------------|--------------|
| 22   | SSH            | bastion only |
| 8080 | Hermes API     | internal     |
| 9100 | node-exporter  | monitoring   |

## Backup Policy

- VM-level backup via PBS (nightly)
- RPO: 24 h | RTO: 4 h

## Monitoring Expectations

- Node-level metrics: CPU, memory, disk, network via node-exporter
- Alerting: host unreachable > 2 min, disk > 90 %
- Log shipping to centralised logging stack

## Compliance Notes

- GDPR: All inference via local Ollama (EU-only, zero cross-border transfer)
- SOC2: Full audit trail of agent actions
- ISO 27001: Access control via key-only SSH + UFW

## Maintenance Notes

- Kernel patching during approved maintenance windows only
- Reboot required for kernel updates — schedule with AI team
- All changes tracked via ticket and recorded in change log
