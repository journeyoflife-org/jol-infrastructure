# mcp-prod-lt01

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | mcp-prod-lt01                              |
| **Role**           | mcp                                        |
| **Environment**    | prod                                       |
| **VLAN**           | 40                                         |
| **Static IP**      | 10.40.40.11                                |
| **OS**             | Ubuntu 24.04 LTS (VM)                      |
| **Owner**          | jol-admin                                  |
| **Purpose**        | Model Context Protocol server, tool registry, agent integrations |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | yes                                        |
| **Monitoring**     | yes (node-exporter)                        |
| **VMID**           | 101                                        |
| **Hypervisor**     | pve-prod-hv01                              |

## Role Description

Model Context Protocol server providing tool registry, agent integrations,
and MCP endpoint services for the Hermes agent and RAG pipelines.

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
- Ingress restricted to internal service mesh and bastion only

## SSH Policy

- Password authentication **disabled**
- Key-only access via centrally managed SSH keys
- Root login disabled; administrative access via `jol-admin` + sudo
- Idle session timeout: 15 minutes

## Firewall Ports

| Port | Service        | Access       | Status |
|------|----------------|--------------|--------|
| 22   | SSH            | bastion only | UFW: allow from 10.40.40.0/24 and 10.60.60.0/24 |
| 3000 | MCP API        | internal     | not yet open — servers currently run MCP-over-stdio (no listener) |
| 9100 | node-exporter  | monitoring   | UFW: allow from 10.40.40.0/24 (exporter not yet installed) |

UFW: default deny incoming, allow outgoing, enabled at boot (2026-08-03).

## Backup Policy

- VM-level backup via PBS (nightly)
- RPO: 24 h | RTO: 4 h

## Monitoring Expectations

- Node-level metrics: CPU, memory, disk, network via node-exporter
- Alerting: host unreachable > 2 min, disk > 90 %
- Log shipping to centralised logging stack

## Deployment — jol-mcp-servers (manual, per repository strategy)

- App path: `/opt/jol-mcp-servers` (owned by service account `mcp-svc`, nologin)
- Bare git repo: `/opt/jol/git/jol-mcp-servers.git` with `post-receive` hook that
  checks out `main` into the app path, fixes ownership, and restarts services
- Sync procedure from workstation: `git push mcp-prod main`
  (remote `mcp-prod` in `/opt/jol/repos/jol-mcp-servers`, uses SSH ProxyJump alias)
- Python venv: `/opt/jol-mcp-servers/.venv` (uv, Python 3.12; VM has no internet —
  wheels live in `/opt/jol-mcp-servers/.wheels`, `uv` binary at `/usr/local/bin/uv`;
  dependency updates require offline wheel transfer)
- Pinned SDK: `mcp==1.29.0` (repo imports `mcp.server.fastmcp`, removed in mcp 2.x)
- systemd units: `jol-git-server`, `jol-jira-server`, `jol-compliance-server`,
  `jol-docs-server` (enabled at boot, stdio transport kept alive under systemd)
- Config: `/etc/jol-mcp/mcp.env` (`JOL_MCP_*` env vars);
  audit log dir `/var/log/jol-mcp` (`audit.jsonl` — wiring pending in jol-mcp-servers,
  `shared/audit/AuditLogger` exists but is not yet invoked by tools)
- No Jira/Bitrix credentials configured — external integrations unconfigured until
  secrets handling is decided

## Maintenance Notes

- Kernel patching during approved maintenance windows only
- Reboot required for kernel updates — schedule with AI team
- All changes tracked via ticket and recorded in change log
- MCP deployment config stays manual (no Ansible role) until extraction trigger
