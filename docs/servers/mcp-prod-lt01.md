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
| 9100 | node-exporter  | monitoring   | UFW: allow from 10.40.40.0/24 (node_exporter 1.8.2 installed 2026-08-12, bound to 10.40.40.11) |

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
- Python venv: `/opt/jol-mcp-servers/.venv` (uv, Python 3.12; wheels mirrored
  in `/opt/jol-mcp-servers/.wheels`, `uv` binary at `/usr/local/bin/uv`).
  Note (2026-08-12): the VM currently HAS internet egress (apt/github reachable),
  but the offline-wheel pattern is retained as the documented dependency path
- Pinned SDK: `mcp==1.29.0` (repo imports `mcp.server.fastmcp`, removed in mcp 2.x)
- systemd units: `jol-git-server`, `jol-jira-server`, `jol-compliance-server`,
  `jol-docs-server` (enabled at boot, stdio transport kept alive under systemd)
- Hardening drop-in on all 4 units:
  `/etc/systemd/system/jol-*-server.service.d/10-jol-hardening.conf`
  (PrivateTmp, PrivateDevices, ProtectKernel*, ProtectControlGroups,
  RestrictSUIDSGID, LockPersonality, SystemCallArchitectures=native, UMask=0027)
- Config: `/etc/jol-mcp/mcp.env` (`JOL_MCP_*` env vars, auditd-watched);
  audit log LIVE at `/var/log/jol-mcp/audit.jsonl` (OCSF JSON Lines via
  `shared/audit/integration.register_audited_tools` — every tool invocation
  logged; dir `mcp-svc:mcp-svc` 0750; rotated by `/etc/logrotate.d/jol-mcp`,
  daily, 14× compressed)
- No Jira/Bitrix credentials configured — external integrations unconfigured until
  secrets handling is decided
- Deployment/reconcile procedure: `docs/runbooks/mcp-prod-lt01-deployment.md`

## Fleet Hardening (applied 2026-08-12 via `harden-ai-hosts.yml`)

- CIS Ubuntu 24.04 Level 1 subset via Ansible role `common`
- auditd rules (immutable, `-e 2`): identity, sudoers, sshd, ufw, secrets incl.
  `-w /etc/jol-mcp/mcp.env -p wa -k jol_secrets` — changing audit rules
  requires reboot + change record
- AIDE baseline with nightly integrity check (04:15 UTC)
- fail2ban (sshd jail, banaction=ufw, 3 strikes / 1 h ban)
- chrony time sync; unattended-upgrades for security patches
- node_exporter 1.8.2 (sandboxed fleet-standard unit, binds 10.40.40.11:9100)

## Change History

| Date       | Change | Evidence |
|------------|--------|----------|
| 2026-08-03 | Initial MCP deployment (4 stdio units, post-receive deploy) | unit mtimes |
| 2026-08-12 | Change request #29; snapshot `pre-mcp-fix-20260812-2213` before reconcile | GitHub issue #29; qm listsnapshot 101 |
| 2026-08-12 | First-time fleet hardening (harden-ai-hosts.yml --limit mcp-prod-lt01): auditd/AIDE/fail2ban/chrony/node_exporter/qemu-guest-agent; host_vars added | /tmp/harden-mcp-run{,2,3,4}-*.log |
| 2026-08-12 | Audit runtime fix: `/var/log/jol-mcp` perms (mcp-svc 0750), logrotate (14d), units restarted; smoke test 4/4 PASS, audit.jsonl live | /tmp/mcp_smoke.py run 2026-08-12 |
| 2026-08-12 | systemd hardening drop-ins on all 4 MCP units, rolling restart; exposure 6.3 MEDIUM | systemd-analyze security |
| 2026-08-18 | **M3 remediation** (P2 gate finding 2026-08-17): snapshot `pre-m3-fix-20260818-0014`; `/etc/jol-mcp/mcp.env` backed up (`.bak.20260818-0014`, 640 root:mcp-svc preserved) + `JOL_MCP_GIT_REPO_ROOT=/opt/jol/repos` added; inspectable work-tree clone provisioned at `/opt/jol/repos/jol-mcp-servers` (from `/opt/jol/git/jol-mcp-servers.git`, HEAD c226602, owned `mcp-svc:mcp-svc` — git safe.directory requires owner == invoking user); `jol-git-server` restarted; end-to-end MCP `tools/call git_status` → "Working tree clean" + audit.jsonl `Success`; re-gate 14/14 PASS (guest-exec-mcp-prod-lt01-20260818 log, jol-compliance audit-evidence) | qm guest exec session 2026-08-18 |

## Maintenance Notes

- Kernel patching during approved maintenance windows only
- Reboot required for kernel updates — schedule with AI team
- All changes tracked via ticket and recorded in change log
- MCP deployment config stays manual (no Ansible role) until extraction trigger
