# jol-app-pilot-lt01

> **Status**: SPEC — provisioning specification; VM does not exist yet.
> Provisioning blocked until: `data` ZFS pool created (with encryption) and
> ADR-004 amendment merged (see `docs/network/prox01-vmbr-layout.md`).

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | jol-app-pilot-lt01                         |
| **Role**           | application tier                            |
| **Environment**    | pilot                                       |
| **VLAN**           | 40                                          |
| **Static IP**      | 10.40.40.20                                 |
| **OS**             | Ubuntu 24.04 LTS (VM, FIPS-compatible kernel line) |
| **Owner**          | jol-admin                                   |
| **Purpose**        | JOL Church platform application tier — Lithuania pilot |
| **SSH Policy**     | key-only                                    |
| **Backup Enabled** | yes (PBS nightly)                           |
| **Monitoring**     | yes (node-exporter → jol-observ-pilot-lt01) |
| **VMID**           | 200                                         |
| **Hypervisor**     | prox01                                      |

## Role Description

Application tier of the JOL Pilot Lithuania stack: business logic and API
behind the ingress VM. Processes special-category data (GDPR Art. 9) —
full SOC 2 Type II / GDPR / ISO 27001 host controls apply. **Application
logic lives in the PRIMARY repos** (`jol-backend-platform` / `jol-core`);
this spec covers infrastructure only (AGENTS.md §1 rule 1).

## Resources (D1)

| Resource | Allocation |
|----------|-----------|
| vCPU     | 4 (cpu type `host`) |
| RAM      | 8 GB (ballooning allowed) |
| Disk     | 80 GB on `data` (raidz2, encrypted pool) — scsi, virtio-scsi-single, iothread |
| Machine  | q35, BIOS OVMF (UEFI) + EFI disk |
| Agent    | qemu-guest-agent enabled (fs-consistent PBS snapshots) |

Network: `vmbr0` tag **40**, virtio, static 10.40.40.20/24, gw 10.40.40.1
(Step 2: `docs/network/prox01-vmbr-layout.md` §2).

Cloud-init template: `ubuntu-24.04-lts-generic-amd64.qcow2` —
⚠ UNVERIFIED — manual check required: template not yet present on prox01;
download to `local` storage and verify SHA256 against Canonical's published
checksum BEFORE first boot. Templates are per-host — nothing is inherited
from pve-prod-hv01. Cloud-init user-data sets hostname + SSH key for
`jol-admin` ONLY — no secrets (D4).

## Disk Placement Justification (D2)

`data` (raidz2) over `rpool`: capacity headroom for application growth and
2-disk fault tolerance; all-SATA-SSD backing keeps latency acceptable for a
non-database workload. ZFS dataset properties: `compression=zstd`
(fleet convention, prox01 rpool), `atime=off`. Encryption at rest inherited
from the pool — **the `data` pool MUST be created with `encryption=on`
(aes-256-gcm)**; pool encryption cannot be retrofitted.

## Guest Hardening (D3) — mapped to `ansible/playbooks/harden-ai-hosts.yml`

> Inventory change required: add host to a `pilot` group and extend the
> playbook `hosts:` line (SOC 2 CC8.1 — reviewed, merged, then executed).
> Secret VALUES never in `inventory/prod/` (AGENTS.md §2.5).

- [ ] role `common` — CIS Ubuntu 24.04 L1 subset: sysctl (protected
      hardlinks/symlinks, rp_filter, kptr_restrict=2, tcp_syncookies,
      yama.ptrace_scope=1), unattended-upgrades + apticron
- [ ] role `time_sync` — chrony, internal NTP source (SOC 2 CC7.2)
- [ ] role `ssh` — drop-in `/etc/ssh/sshd_config.d/00-jol-hardening.conf`:
      `PermitRootLogin no`, `PasswordAuthentication no`,
      `AllowUsers jol-admin`, idle timeout 15 min, LogLevel VERBOSE
- [ ] role `base_firewall` — UFW default deny incoming; allow-list EXACTLY
      per `docs/security/jol-pilot-firewall-matrix.md` §2.1; `ufw limit 22/tcp`;
      `ufw logging on`
- [ ] role `monitoring` — node-exporter on 9100 (exposed to 10.60.60.0/24 only)
- [ ] role `backup_client` — PBS client config (hypervisor-level backup is
      the fleet default; guest client only if DB-style push is needed — NO
      for this VM)
- [ ] auditd immutable (`-e 2`): identity, sudoers, sshd, ufw, secrets watches
- [ ] AIDE baseline AFTER provisioning (Ubuntu workflow: `aideinit`, then
      move `/var/lib/aide/aide.db.new` → `/var/lib/aide/aide.db`); nightly
      04:15 UTC check
- [ ] fail2ban: sshd jail (banaction=ufw, 3 strikes / 1 h)

## Secret Delivery (D4) — AGENTS.md §0.1 zero tolerance

**NEVER in cloud-init user-data, NEVER in repo files, NEVER as CLI args.**

1. **Ansible Vault** for static secrets (DB credentials, JWT signing key):
   `ansible-vault encrypt_string --stdin-name 'jol_app_db_password'`,
   injected by playbook at deploy time.
2. **Vaultwarden** (fleet runtime secret manager,
   `docs/architecture/secret-flow.md`) for rotation-sensitive values;
   retrieved at deploy, never cached in plaintext. TLS material per
   `docs/runbooks/certificate-renewal.md`.
3. **On-guest model** (fleet precedent rag/mcp): env file
   `/etc/jol-app/app.env` — `0640 root:jol-app`, parent dir `0750`,
   world bits 0; service account `jol-app` (nologin); auditd watch
   `-w /etc/jol-app/ -p wa -k jol_secrets` (directory-level watch — covers
      app.env and any future secret files)

## Pre-Go-Live Audit Checklist (D5)

| Check | Command | Expected Output | Evidence File |
|-------|---------|-----------------|---------------|
| OS version | `cat /etc/os-release` | Ubuntu 24.04 LTS | `audit/<vm>-os-version.txt` |
| QGA running | `systemctl is-active qemu-guest-agent` | `active` | `audit/<vm>-qga.txt` |
| No root SSH | `grep -r PermitRootLogin /etc/ssh/sshd_config.d/` | `no` | `audit/<vm>-ssh.txt` |
| UFW active | `sudo ufw status verbose` | `Status: active`, default deny incoming | `audit/<vm>-ufw.txt` |
| Disk encryption | `zfs get encryption data` (on prox01) | `encryption on` | `audit/<vm>-crypto.txt` |
| No plaintext secrets | `sudo grep -ri "password\|secret" /etc/cloud/ /var/lib/cloud/instance/user-data.txt` | *(empty)* | `audit/<vm>-secrets.txt` |
| Secret perms | `sudo stat -c "%a %U:%G" /etc/jol-app/app.env` | `640 root:jol-app` | `audit/<vm>-secrets.txt` |
| auditd watch | `sudo auditctl -l \| grep jol_secrets` | watch on app.env | `audit/<vm>-auditd.txt` |
| AIDE | `sudo aide --check` | rc=0 | `audit/<vm>-aide.txt` |
| AIDE baseline hash | `sha256sum /var/lib/aide/aide.db` | `<hash>` recorded in evidence | `audit/<vm>-aide.txt` |
| Health gate | `curl -sf http://10.40.40.20:<app-port>/health` | HTTP 200 (⚠ UNVERIFIED — port from jol-backend-platform contract) | `audit/<vm>-health.txt` |

## Compliance Controls (host)

CIS Ubuntu 24.04 L1 subset (role `common`); auditd immutable; AIDE nightly;
fail2ban; unattended-upgrades; sysctl baseline — identical to the
rag-prod-lt01 host standard. GDPR: no prompt/content persistence
(Art. 5(1)(e)); connection-metadata logs only → jol-observ-pilot-lt01.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Provisioning spec created (Step 3) — VM not yet provisioned | this document |
| 2026-08-23 | Ratified-spec reconciliation: qcow2 template name, aideinit baseline procedure, QGA audit row | Step 3 ratified task spec |
| 2026-08-23 | Ratified-spec final: auditd secret watch widened to `/etc/jol-app/` directory; AIDE baseline-hash evidence row added | Step 3 ratified task spec (final) |
