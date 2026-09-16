# Runbook: jol-mcp-servers Deployment — mcp-prod-lt01 (MCP stdio servers)

> **Scope**: Proxmox VM 101 `mcp-prod-lt01` (10.40.40.11/24, VLAN 40) —
> the four jol-mcp-servers stdio units (git/jira/compliance/docs) plus fleet
> baseline hardening. Deployment config stays manual (no Ansible app role)
> until the extraction trigger is met; host hardening and monitoring ARE
> Ansible-managed.
> **Compliance**: SOC 2 Type II / GDPR (EU 2016/679) / ISO 27001:2022.
> **No credentials in this document** — use the secrets manager
> (Vaultwarden on admin01; see `docs/architecture/secret-flow.md`).
> **Reference docs**: `docs/servers/mcp-prod-lt01.md` (as-run record),
> `docs/runbooks/incident-response.md`, `docs/architecture/trust-boundaries.md`.
> **Change control**: production changes require a change request via
> `.github/ISSUE_TEMPLATE/infra-change-request.yml` (SOC 2 CC8.1).

## When to Use

- Fresh deployment or DR rebuild of the MCP server suite on VM 101.
- Reconciliation after drift (missing audit dir, stale units, missing hardening).
- Reference procedure for `git push mcp-prod main` deploys and rollbacks.

## Asset Summary

| Item | Value |
|------|-------|
| Host | mcp-prod-lt01 — 10.40.40.11/24 (VLAN 40 AI Services, VMID 101 on pve-prod-hv01) |
| OS | Ubuntu 24.04 LTS VM, 2 vCPU / 8 GB / 50 GB NVMe thin |
| App path | `/opt/jol-mcp-servers` (owner `mcp-svc`, nologin; venv `.venv`, wheels `.wheels`, uv at `/usr/local/bin/uv`) |
| Bare repo | `/opt/jol/git/jol-mcp-servers.git` with `post-receive` auto-deploy hook |
| Units | `jol-git-server`, `jol-jira-server`, `jol-compliance-server`, `jol-docs-server` (stdio, no network listeners) |
| SDK pin | `mcp==1.29.0` (`mcp.server.fastmcp` import — do not upgrade past 1.x) |
| Config | `/etc/jol-mcp/mcp.env` (auditd watch `-p wa -k jol_secrets`), audit JSONL at `/var/log/jol-mcp/audit.jsonl` |
| Admin access | `jol-admin` + sudo, SSH key-only via ProxyJump (`ssh mcp-prod-lt01`) |

### Host Firewall (UFW — default deny incoming, allow outgoing)

| Port | Service       | Allowed sources |
|------|---------------|-----------------|
| 22   | SSH           | 10.40.40.0/24, 10.60.60.0/24 |
| 9100 | node-exporter | 10.40.40.0/24 |

No other ports must be open — in particular **no port 3000 / SSE listener**;
the MCP transport is stdio by design.

---

## Phase 0 — Change control & pre-flight

1. **Change request**: file via `.github/ISSUE_TEMPLATE/infra-change-request.yml`;
   record all work in the server doc Change History and `CHANGELOG.md`.
2. **Snapshot (blocking gate)** on pve-prod-hv01:
   ```bash
   qm snapshot 101 pre-mcp-fix-$(date +%Y%m%d-%H%M) \
     --description "Pre MCP reconcile-and-fix"
   qm listsnapshot 101          # gate: snapshot must be listed
   ```
3. Capture baseline evidence on the VM: `dpkg -l`, `systemctl list-units`,
   `ufw status verbose`, `free -h`, `df -h` to `/tmp/pre-mcp-fix-*.txt`.
4. Verify deployed revision: `git -C /opt/jol-mcp-servers rev-parse HEAD`
   must equal `origin/main` of jol-mcp-servers.

---

## Phase 1 — Host hardening + monitoring (Ansible)

1. Maintain `inventory/prod/host_vars/mcp-prod-lt01.yml`
   (`jol_audit_secret_files: [/etc/jol-mcp/mcp.env]`,
   `node_exporter_bind_address: 10.40.40.11`, `promtail_enabled: false`,
   `docker_guard_enabled: false`, `backup_enabled: false`).
2. Run:
   ```bash
   cd ansible/
   ansible-playbook playbooks/harden-ai-hosts.yml --limit mcp-prod-lt01
   ```
   Roles: `common` (CIS L1 subset, auditd immutable `-e 2`, AIDE, fail2ban,
   unattended-upgrades), `time_sync`, `ssh`, `base_firewall`, `monitoring`
   (node_exporter 1.8.2, SHA-256 pinned download), `backup_client`
   (qemu-guest-agent for fs-consistent snapshots).
3. Known friction: `get_url` for exporter/promtail tarballs may fail with
   "Remote end closed connection" — pre-stage the file with `curl` on the
   host, verify the role-pinned SHA-256, re-run the playbook.
4. If audit rules show `auditctl -l` empty after the run: `sudo augenrules --load`.

### Exit criteria

- Idempotent green run (failed=0); `systemctl is-active node_exporter`;
  `curl -sf http://10.40.40.11:9100/metrics` returns metrics; audit rules
  loaded incl. the `mcp.env` watch.

---

## Phase 2 — Audit runtime (config-only)

1. Backup env: `cp /etc/jol-mcp/mcp.env /etc/jol-mcp/mcp.env.bak.$(date +%Y%m%d-%H%M)`.
2. Log dir: `mkdir -p /var/log/jol-mcp && chown mcp-svc:mcp-svc /var/log/jol-mcp
   && chmod 0750 /var/log/jol-mcp` — servers run as `mcp-svc`; a root-owned
   dir silently breaks audit writes (FileHandler falls back to stderr).
3. Ensure `JOL_MCP_AUDIT_LOG_PATH=/var/log/jol-mcp/audit.jsonl` in `mcp.env`
   (matches `shared/config/settings.py` default).
4. `/etc/logrotate.d/jol-mcp` (root:root 0644): daily, rotate 14, compress,
   delaycompress, missingok, notifempty, `copytruncate` (append-mode JSONL,
   servers hold no reopen signal), `create 0640 mcp-svc mcp-svc`.
5. Restart the four units; verify `logrotate -d /etc/logrotate.d/jol-mcp` clean.

---

## Phase 3 — Smoke test and audit verification

1. Per server, over stdio JSON-RPC: `initialize` → `notifications/initialized`
   → `tools/list` → one read-only `tools/call`
   (`git_status`, `doc_search`, `gdpr_checklist`, `issue_search`). Jira/docs
   tools return `Error: ... not configured` without credentials — that is
   expected and still produces an audit entry (outcome `Failure`, severity
   `Warning`).
2. Verify `/var/log/jol-mcp/audit.jsonl` gains one OCSF entry per call
   (timestamp, caller, tool.server/name/parameters, outcome, security blocks;
   secret-looking parameters redacted).
3. Invariant: `ss -tlnp` shows NO new listeners (stdio-only; only 22, 25,
   9100 + loopback DNS).
4. If audit entries are missing: inspect `shared/audit/audit_logger.py` /
   `integration.py`; code fixes go through jol-mcp-servers (branch, `uv run
   pytest`, PR to main) then Phase deploy below.

---

## Phase 4 — Systemd hardening drop-ins

1. Back up unit files (`/root/backups/systemd-units-<ts>/`), then drop-in
   `/etc/systemd/system/jol-{git,jira,compliance,docs}-server.service.d/10-jol-hardening.conf`:
   ```ini
   [Service]
   PrivateTmp=true
   PrivateDevices=true
   ProtectKernelTunables=true
   ProtectKernelModules=true
   ProtectKernelLogs=true
   ProtectControlGroups=true
   RestrictSUIDSGID=true
   LockPersonality=true
   SystemCallArchitectures=native
   UMask=0027
   ```
2. `systemctl daemon-reload`, then **rolling** restart: one unit at a time,
   verify `is-active` before the next.
3. Gate: 4/4 active, no restart loops in journal,
   `systemd-analyze security jol-git-server` exposure not degraded.

---

## Phase 5 — Documentation and evidence

1. Update `docs/servers/mcp-prod-lt01.md` (Change History rows + evidence refs).
2. Append the `CHANGELOG.md` row (SOC 2 CC8.1).
3. Refresh the AIDE baseline on the VM (`aideinit`/`aide --update` per fleet
   convention) — otherwise the nightly 04:15 check alerts.
4. Collect evidence: pre/post `ufw status verbose`, smoke-test transcript,
   redacted `audit.jsonl` sample, `qm listsnapshot 101`.

---

## Deploy workflow (day-2)

```bash
# workstation: /opt/jol/repos/jol-mcp-servers on branch main
git push mcp-prod main
```

The `post-receive` hook on VM 101 checks out `main` to `/opt/jol-mcp-servers`,
fixes ownership (`mcp-svc`), and restarts all four units. Dependency changes:
add wheels to `.wheels` in the repo first (offline-wheel pattern is the
documented path even though egress currently exists).

## Rollback

1. Unit-level: `git push mcp-prod main` with the previous good revision, or
   restore from `/root/backups/systemd-units-<ts>/`.
2. Whole-VM: `qm rollback 101 <snapshot-name>` on pve-prod-hv01, then verify
   Phase 3 gates.
3. Incident handling: `docs/runbooks/incident-response.md`.
