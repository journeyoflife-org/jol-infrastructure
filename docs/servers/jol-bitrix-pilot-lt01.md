# jol-bitrix-pilot-lt01

> **Status**: SPEC — provisioning specification; VM does not exist yet.
> Provisioning blocked until: `data` ZFS pool created (with encryption) and
> ADR-004 amendment merged (see `docs/network/prox01-vmbr-layout.md`).

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | jol-bitrix-pilot-lt01                      |
| **Role**           | third-party integration connector           |
| **Environment**    | pilot                                       |
| **VLAN**           | 40                                          |
| **Static IP**      | 10.40.40.22                                 |
| **OS**             | Ubuntu 24.04 LTS (VM, FIPS-compatible kernel line) |
| **Owner**          | jol-admin                                   |
| **Purpose**        | Bitrix24 SaaS integration connector (sync/webhooks) — Bitrix24 itself is NOT hosted here |
| **SSH Policy**     | key-only                                    |
| **Backup Enabled** | yes (PBS nightly)                           |
| **Monitoring**     | yes (node-exporter → jol-observ-pilot-lt01) |
| **VMID**           | 202                                         |
| **Hypervisor**     | prox01                                      |

## Role Description

Egress-facing connector for the Bitrix24 SaaS CRM (fleet Tier 3 asset
`jol-bitrix24-integration`). This is the pilot's **highest egress-risk
guest**: it holds external API credentials and initiates outbound calls.
Isolation exists so a connector compromise cannot pivot to the data tier.
DPIA dependency: Art. 28 DPA + data-residency confirmation for the Bitrix24
portal are prerequisites (`docs/compliance/dpia-trigger-check.md` §3 #2).

## Resources (D1)

| Resource | Allocation |
|----------|-----------|
| vCPU     | 2 (cpu type `host`) |
| RAM      | 4 GB (ballooning allowed) |
| Disk     | 60 GB on `data` (raidz2, encrypted pool) — scsi, virtio-scsi-single, iothread |
| Machine  | q35, BIOS OVMF (UEFI) + EFI disk |
| Agent    | qemu-guest-agent enabled |

Network: `vmbr0` tag **40**, virtio, static 10.40.40.22/24, gw 10.40.40.1.

Cloud-init template: `ubuntu-24.04-lts-generic-amd64.qcow2` —
⚠ UNVERIFIED — manual check required: upload + SHA256-verify on prox01;
user-data carries hostname + `jol-admin` SSH key only.

## Disk Placement Justification (D2)

`data` (raidz2): consistent with the other VLAN 40 pilot guests; the
connector is stateless (queue state only), so capacity needs are minimal —
placement is driven by pool encryption and fleet consistency rather than
performance. `compression=zstd`, `atime=off`.

## Guest Hardening (D3) — mapped to `ansible/playbooks/harden-ai-hosts.yml`

> Inventory: add to `pilot` group; extend playbook `hosts:` line via
> reviewed change (SOC 2 CC8.1). No secret values in `inventory/prod/`.

- [ ] role `common` — CIS Ubuntu 24.04 L1 subset; unattended-upgrades + apticron
- [ ] role `time_sync` — chrony, internal NTP (audit timestamp integrity)
- [ ] role `ssh` — `PermitRootLogin no`, `PasswordAuthentication no`,
      `AllowUsers jol-admin`, idle timeout, LogLevel VERBOSE
- [ ] role `base_firewall` — UFW per `jol-pilot-firewall-matrix.md` §2.3:
      inbound only from 10.40.40.20 (connector port ⚠ UNVERIFIED — from
      jol-bitrix24-integration contract) + mgmt SSH (limited) + 9100 to
      10.60.60.0/24; **outbound: Bitrix24 FQDN allowlist :443 only** +
      DNS/NTP; explicit DENY toward 10.40.40.21 (DB)
- [ ] role `monitoring` — node-exporter on 9100 → 10.60.60.0/24 only
- [ ] role `backup_client` — not required (stateless; hypervisor-level PBS)
- [ ] auditd immutable (`-e 2`): identity, sudoers, sshd, ufw, secrets
- [ ] AIDE baseline post-provisioning (`aideinit`, then move
      `/var/lib/aide/aide.db.new` → `/var/lib/aide/aide.db`); nightly 04:15 UTC
- [ ] fail2ban: sshd jail

### Connector-specific controls

- [ ] Every outbound API call audit-logged (fleet `audit.jsonl` pattern —
      timestamp, caller, tool/endpoint, outcome; schema precedent:
      jol-mcp-servers AuditEvent)
- [ ] Webhook receivers (if Bitrix24 pushes events) authenticate signed
      payloads; unsigned/unknown sources logged + dropped
- [ ] Egress allowlist enforced at BOTH layers: guest UFW and MikroTik
      srcnat rule scoped to 10.40.40.22 (Step 2 rule #4)
- [ ] Field minimisation: connector transfers only the fields declared in
      the DPIA mapping (Art. 5(1)(c)) — Art. 9 fields require an explicit
      mapping decision (DPIA trigger check §2 criterion 6)

## Secret Delivery (D4) — AGENTS.md §0.1 zero tolerance

**NEVER in cloud-init user-data, NEVER in repo files, NEVER as CLI args.**

1. **Vaultwarden** is the primary store for Bitrix24 API tokens (external
   SaaS credentials = highest rotation sensitivity): retrieved at deploy /
   rotation windows per `docs/runbooks/secret-rotation.md`; never cached in
   plaintext on disk beyond the runtime env file.
2. **Ansible Vault** only for deploy-time plumbing (no Bitrix credentials
   in the repo, even encrypted, if Vaultwarden retrieval is available —
   keep the external credential surface in ONE system).
3. **On-guest model**: `/etc/jol-bitrix/bitrix.env` — `0640
   root:jol-bitrix` (service `EnvironmentFile` needs group read — mcp.env
   precedent), world bits 0; service account `jol-bitrix` (nologin, NOT in
   sudo group); auditd watch `-w /etc/jol-bitrix/ -p wa -k
   jol_secrets` (directory-level watch — covers bitrix.env and any future
   secret files). Token rotation: revoke-old-issue-new, never reuse;
   **90-day rotation cadence**, executed per
   `docs/runbooks/secret-rotation.md` with a rotation record.

## Pre-Go-Live Audit Checklist (D5)

| Check | Command | Expected Output | Evidence File |
|-------|---------|-----------------|---------------|
| OS version | `cat /etc/os-release` | Ubuntu 24.04 LTS | `audit/<vm>-os-version.txt` |
| QGA running | `systemctl is-active qemu-guest-agent` | `active` | `audit/<vm>-qga.txt` |
| No root SSH | `grep -r PermitRootLogin /etc/ssh/sshd_config.d/` | `no` | `audit/<vm>-ssh.txt` |
| UFW active | `sudo ufw status verbose` | `Status: active`, default deny incoming | `audit/<vm>-ufw.txt` |
| DB reach denied | `nc -vz 10.40.40.21 5432` from guest | REFUSED/timed out | `audit/<vm>-neg.txt` |
| Egress allowlist | `curl -sf --max-time 5 https://<non-allowlisted-host>` | FAILS (expected) | `audit/<vm>-egress.txt` |
| Bitrix API reach | `curl -sf https://<portal-fqdn>/rest/` (allowlisted) | 200/401 (reachable) | `audit/<vm>-egress.txt` |
| Disk encryption | `zfs get encryption data` (on prox01) | `encryption on` | `audit/<vm>-crypto.txt` |
| No plaintext secrets | `sudo grep -ri "password\|secret\|token" /etc/cloud/ /var/lib/cloud/instance/user-data.txt` | *(empty)* | `audit/<vm>-secrets.txt` |
| Secret perms | `sudo stat -c "%a %U:%G" /etc/jol-bitrix/bitrix.env` | `640 root:jol-bitrix` | `audit/<vm>-secrets.txt` |
| auditd watch | `sudo auditctl -l \| grep jol_secrets` | watch on bitrix.env | `audit/<vm>-auditd.txt` |
| World-readable env | `find / -name "*.env" -perm /o+r 2>/dev/null \| wc -l` | 0 | `audit/<vm>-secrets.txt` |
| AIDE | `sudo aide --check` | rc=0 | `audit/<vm>-aide.txt` |
| AIDE baseline hash | `sha256sum /var/lib/aide/aide.db` | `<hash>` recorded in evidence | `audit/<vm>-aide.txt` |

## Compliance Controls (host)

Same baseline as jol-app-pilot-lt01. Additional drivers: third-party
blast-radius containment (ISO 27001 A.5.19 supplier security), GDPR Art. 28
processor flow, egress audit trail (SOC 2 CC6.6).

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Provisioning spec created (Step 3) — VM not yet provisioned | this document |
| 2026-08-23 | Ratified-spec reconciliation: qcow2 template name, aideinit procedure, QGA audit row, 90-day Bitrix token rotation cadence | Step 3 ratified task spec |
| 2026-08-23 | Ratified-spec final: auditd secret watch widened to `/etc/jol-bitrix/` directory; AIDE baseline-hash evidence row added | Step 3 ratified task spec (final) |
