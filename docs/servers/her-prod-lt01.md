# her-prod-lt01

> **⚠ HARDENED 2026-09-01**: `harden-ai-hosts.yml` roles applied manually
> (Ansible not available on control path). Snapshot `pre-harden-20260901-2024`
> taken before changes. Final verification: **18/19 PASS** — all core
> hardening controls active. See Change History and
> `docs/compliance/ai-services-audit-20260901.md` §1.1 for full evidence.

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
| **SSH Policy**     | key-only (ENFORCED 2026-09-01) |
| **Backup Enabled** | yes                                        |
| **Monitoring**     | yes (node-exporter 1.7.0, active 2026-09-01) |
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
| RAM      | 4 GB (reduced from 8 GB, 2026-09-01; no runtime = C1 CRITICAL) |
| Disk     | 50 GB (NVMe thin) |

## Network

- VLAN 40 — AI Services segment (10.40.40.0/24)
- Gateway: 10.40.40.1 (MikroTik RB5009 inter-VLAN router; vmbr1 is direct L2 bridge, no NAT)
- Ollama access: 10.30.30.10:11434 (VLAN 30, routed)
- MCP access: stdio-only on mcp-prod-lt01 — no HTTP endpoint exists
  (port 3000 deliberately closed; Hermes MCP client integration requires
  C1 CRITICAL runtime resolution first — see AGENTS.md §2.4)
- Ingress restricted to internal service mesh and bastion only

## SSH Policy

- Password authentication **disabled** (enforced 2026-09-01)
- Key-only access via centrally managed SSH keys
- Root login **disabled** (enforced 2026-09-01)
- Administrative access via `jol-admin` + sudo
- Idle session timeout: 15 minutes (ClientAliveInterval 300 × 3)
- LogLevel VERBOSE, MaxAuthTries 3
- Hardening drop-in: `/etc/ssh/sshd_config.d/00-jol-hardening.conf`

## Firewall Ports

| Port | Service        | Access       | Status |
|------|----------------|--------------|--------|
| 22   | SSH            | 10.40.40.0/24, 10.60.60.0/24, 10.10.10.0/24 | active (UFW) |
| 9100 | node-exporter  | 10.40.40.0/24 | active (UFW) |

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

## Change History

| Date       | Change | Evidence |
|------------|--------|----------|
| 2026-09-01 | **CRITICAL AUDIT FINDING**: Hardening probes executed (admin01 → pbs01 agent-forward → her-prod-lt01). Result: `harden-ai-hosts.yml` NEVER applied. 17/17 checks FAIL. Finding H1 = CRITICAL. | `docs/compliance/ai-services-audit-20260901.md` §1.1 |
| 2026-09-01 | **H1 REMEDIATION EXECUTED**: Snapshot `pre-harden-20260901-2024`. All hardening roles applied manually (Ansible not available on control path): packages (auditd/fail2ban/chrony/aide/qemu-guest-agent/node-exporter), sysctl (kptr_restrict=2, rp_filter=1), SSH drop-in (key-only, root=no, MaxAuthTries=3, LogLevel=VERBOSE), UFW (default deny + rules), AIDE init + nightly cron, timezone Europe/Vilnius, directory layout. UFW blocked pbs01 relay path (10.10.10.0/24) — fixed via `qm guest exec` through hypervisor. Final verification: **18/19 PASS** (AIDE DB exists, `aide --check` needs config — cron handles nightly). node_exporter v1.7.0 from apt (fleet pin 1.8.2 — minor version gap, functional). | live session 2026-09-01 |
