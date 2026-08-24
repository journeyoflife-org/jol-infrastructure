# jol-db-pilot-lt01

> **Status**: SPEC — provisioning specification; VM does not exist yet.
> Provisioning blocked until: `data` ZFS pool created (with encryption) and
> ADR-004 amendment merged (see `docs/network/prox01-vmbr-layout.md`).

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | jol-db-pilot-lt01                          |
| **Role**           | database tier                               |
| **Environment**    | pilot                                       |
| **VLAN**           | 40                                          |
| **Static IP**      | 10.40.40.21                                 |
| **OS**             | Ubuntu 24.04 LTS (VM, FIPS-compatible kernel line) |
| **Owner**          | jol-admin                                   |
| **Purpose**        | PostgreSQL — crown-jewel data tier (GDPR Art. 9 data; PCI-DSS scope if donations in pilot) |
| **SSH Policy**     | key-only                                    |
| **Backup Enabled** | yes (PBS nightly + WAL archiving ⚠ decide) |
| **Monitoring**     | yes (node-exporter → jol-observ-pilot-lt01) |
| **VMID**           | 201                                         |
| **Hypervisor**     | prox01                                      |

## Role Description

Primary datastore of the JOL Pilot Lithuania: parishioner PII and
religious-affiliation data (GDPR Art. 9 special category). Isolation,
encrypted at rest, and zero internet egress are non-negotiable design
constraints (GDPR Art. 32; PCI-DSS scope containment if donations enter
scope). SOC 2 Type II / ISO 27001 controls apply to the full guest.

## Resources (D1)

| Resource | Allocation |
|----------|-----------|
| vCPU     | 4 (cpu type `host`) |
| RAM      | 16 GB — **ballooning DISABLED** (`balloon: 0`): DB working set must not be reclaimed under host pressure |
| Disk     | 120 GB on `data` (raidz2, encrypted pool) — scsi, virtio-scsi-single, iothread, `volblocksize=16K` |
| Machine  | q35, BIOS OVMF (UEFI) + EFI disk |
| Agent    | qemu-guest-agent enabled |

Network: `vmbr0` tag **40**, virtio, static 10.40.40.21/24, gw 10.40.40.1.

Cloud-init template: `ubuntu-24.04-lts-generic-amd64.qcow2` —
⚠ UNVERIFIED — manual check required: upload + SHA256-verify on prox01
before first boot; user-data carries hostname + `jol-admin` SSH key only.

## Disk Placement Justification (D2)

`data` (raidz2) over `rpool`: `rpool` usable capacity is ~430 GiB and
carries the host — the DB must not compete with it. raidz2 provides 2-disk
fault tolerance on the most critical guest, and the all-SSD vdev keeps IOPS
adequate for pilot scale. ZFS tuning for PostgreSQL:

- **`volblocksize=16K`** set at volume creation (immutable afterwards) —
  aligns with PostgreSQL 8 KB pages × multi-page writes and reduces
  write amplification on raidz2.
- `compression=zstd` (fleet convention; transparent to PG, net I/O win).
- Pool **MUST be created with `encryption=on` (aes-256-gcm)** — encryption
  cannot be retrofitted; this guest is the primary beneficiary.
- `sync` left at default (ZIL on the SSD vdev); PBS fs-consistent snapshots
  via qemu-guest-agent, plus PostgreSQL-level backup (pg_basebackup/WAL —
  ⚠ decide in Step 4 DR plan).

## Guest Hardening (D3) — mapped to `ansible/playbooks/harden-ai-hosts.yml`

> Inventory: add to `pilot` group; extend playbook `hosts:` line via
> reviewed change (SOC 2 CC8.1). No secret values in `inventory/prod/`.

- [ ] role `common` — CIS Ubuntu 24.04 L1 subset; unattended-upgrades +
      apticron (kernel patching in maintenance windows only — DB reboot
      coordination required)
- [ ] role `time_sync` — chrony, internal NTP (timestamp integrity for
      audit + WAL)
- [ ] role `ssh` — `PermitRootLogin no`, `PasswordAuthentication no`,
      `AllowUsers jol-admin`, idle timeout, LogLevel VERBOSE
- [ ] role `base_firewall` — UFW per `jol-pilot-firewall-matrix.md` §2.2:
      **5432/tcp from 10.40.40.20 ONLY**; SSH from 10.10.10.0/24 +
      10.60.60.0/24 (limited); **default deny outgoing** except internal
      DNS/NTP; `ufw logging on`
- [ ] role `monitoring` — node-exporter on 9100 → 10.60.60.0/24 only
- [ ] role `backup_client` — only if guest-side PBS push is chosen
      (fleet default is hypervisor-level; see Step 4)
- [ ] auditd immutable (`-e 2`): identity, sudoers, sshd, ufw, + watch
      `/etc/postgresql/` config and secret files (`-k jol_secrets`)
- [ ] AIDE baseline post-provisioning (`aideinit`, then move
      `/var/lib/aide/aide.db.new` → `/var/lib/aide/aide.db`); nightly 04:15 UTC
- [ ] fail2ban: sshd jail

### PostgreSQL-specific controls (beyond the Ansible baseline)

- [ ] PostgreSQL 16 (Ubuntu 24.04 default line — ⚠ confirm exact minor
      version at provisioning and record here)
- [ ] `listen_addresses = '10.40.40.21,127.0.0.1'`
- [ ] `pg_hba.conf`: single entry `host all jol_app 10.40.40.20/32 scram-sha-256`
      + local peer for `postgres`; nothing else
- [ ] `ssl = on` with internal CA certificate (per `certificate-renewal.md`)
- [ ] Dedicated least-privilege role `jol_app` (no SUPERUSER); separate
      role for migrations
- [ ] `log_connections = on`, `log_disconnections = on`,
      `log_statement = 'ddl'` (connection metadata, never row data —
      Art. 5(1)(e))

### Tenant Isolation Model (schema-per-tenant) — ratified 2026-08-24

> Ratified per `jol-hub/docs/decisions/ADR-001-schema-per-tenant-isolation.md`
> (cross-repo Tier-0 ADR). Supersedes the earlier "separate database per
> website" formulation. SOC 2 CC8.1 change record: this spec-delta row in
> Change History below.

- [ ] One cluster hosts **one schema per tenant** (naming `t_<tenant_id>`);
      NO database-per-site — single cluster to harden, patch, and back up
- [ ] **Row-Level Security** enabled + `FORCE`d on every tenant-scoped table
      (second independent isolation layer over the schema boundary)
- [ ] `jol_app` resolves the tenant schema per request from the
      tenant-resolution chain (subdomain → tenant → schema); `search_path`
      pinned to resolved tenant schema + platform schema; **no cross-schema
      grants**
- [ ] Migration role separate from the runtime role; migrations fan out
      across all tenant schemas (tooling owned by `jol-hub`)
- [ ] Per-tenant erasure boundary: `deleted_at` logical deletion + scheduled
      purge (see Compliance Controls); schema EXPORT/DROP tooling for
      Art. 15/17/20 requests

## Secret Delivery (D4) — AGENTS.md §0.1 zero tolerance

**NEVER in cloud-init user-data, NEVER in repo files, NEVER as CLI args.**

1. **Ansible Vault** for the bootstrap superuser + `jol_app` passwords:
   `ansible-vault encrypt_string --stdin-name 'jol_db_admin_password'`;
   applied by playbook via `ALTER ROLE`, never echoed to shell history.
2. **Vaultwarden** holds the live credentials for rotation per
   `docs/runbooks/secret-rotation.md`; rotation record mandatory.
3. **On-guest model**: `/etc/jol-db/db.env` — `0640 root:postgres-group`
   (group read needed only if a service loads it via EnvironmentFile;
   otherwise `0600 root:root`), world bits 0; auditd watch
   `-w /etc/jol-db/ -p wa -k jol_secrets`. No credentials in
   `.pgpass` with world-visible perms; if used: `0600 postgres:postgres`.

## Pre-Go-Live Audit Checklist (D5)

| Check | Command | Expected Output | Evidence File |
|-------|---------|-----------------|---------------|
| OS version | `cat /etc/os-release` | Ubuntu 24.04 LTS | `audit/<vm>-os-version.txt` |
| QGA running | `systemctl is-active qemu-guest-agent` | `active` | `audit/<vm>-qga.txt` |
| No root SSH | `grep -r PermitRootLogin /etc/ssh/sshd_config.d/` | `no` | `audit/<vm>-ssh.txt` |
| UFW active | `sudo ufw status verbose` | `Status: active`, deny incoming default; deny outgoing default | `audit/<vm>-ufw.txt` |
| DB bind | `ss -tlnp \| grep 5432` | bound to 10.40.40.21 + 127.0.0.1 only | `audit/<vm>-bind.txt` |
| Negative test | `psql` from 10.40.40.22 and admin01 | connection REFUSED | `audit/<vm>-neg.txt` |
| Disk encryption | `zfs get encryption data` (on prox01) | `encryption on` | `audit/<vm>-crypto.txt` |
| volblocksize | `zfs get volblocksize data/vm-201-disk-0` (on prox01) | `16K` | `audit/<vm>-crypto.txt` |
| No plaintext secrets | `sudo grep -ri "password\|secret" /etc/cloud/ /var/lib/cloud/instance/user-data.txt` | *(empty)* | `audit/<vm>-secrets.txt` |
| Secret perms | `sudo stat -c "%a %U:%G" /etc/jol-db/db.env` | `640 root:postgres` (or 600 root:root) | `audit/<vm>-secrets.txt` |
| PG TLS | `openssl s_client -connect 10.40.40.21:5432 -starttls postgres` | certificate chain valid; additionally `psql sslmode=require` from app VM succeeds, non-TLS refused | `audit/<vm>-tls.txt` |
| pg_hba restrictive | `grep -v "^#" /etc/postgresql/16/main/pg_hba.conf \| grep -v "^$"` | only the `10.40.40.20/32` host entry + local peer | `audit/vm201-pghba.txt` |
| Tenant schemas | `psql -Atc "select nspname from pg_namespace where nspname not like 'pg\_%' and nspname <> 'information_schema'"` | `public` (+ `t_*` tenant schemas once onboarded); nothing else | `audit/vm201-schemas.txt` |
| RLS enforced | `psql -Atc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname like 't\_%' and c.relkind='r' and (not c.relrowsecurity or not c.relforcerowsecurity)"` | `0` | `audit/vm201-rls.txt` |
| AIDE | `sudo aide --check` | rc=0 | `audit/<vm>-aide.txt` |
| AIDE baseline hash | `sha256sum /var/lib/aide/aide.db` | `<hash>` recorded in evidence | `audit/<vm>-aide.txt` |
| No WAN egress | `curl -sf --max-time 5 https://example.com` from guest | FAILS (expected) | `audit/<vm>-egress.txt` |

## Compliance Controls (host)

Same baseline as jol-app-pilot-lt01 (CIS L1 subset, auditd immutable,
AIDE, fail2ban, unattended-upgrades). Additional drivers: GDPR Art. 9/32
(data-tier isolation + encryption at rest), Art. 17 erasure support —
implemented as `deleted_at` logical deletion + scheduled hard-purge with
backup restore-replay per `docs/compliance/erasure-log.md` (verify the
endpoint chain at app layer), PCI-DSS scoping decision tracked in
`docs/compliance/dpia-trigger-check.md` §4.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Provisioning spec created (Step 3) — VM not yet provisioned | this document |
| 2026-08-23 | Ratified-spec reconciliation: qcow2 template name, aideinit procedure, QGA audit row, `log_disconnections=on`, `openssl -starttls postgres` TLS check | Step 3 ratified task spec |
| 2026-08-23 | Ratified-spec final: `pg_hba.conf` restrictive audit row + AIDE baseline-hash evidence row added | Step 3 ratified task spec (final) |
| 2026-08-24 | Spec delta: schema-per-tenant + RLS tenant isolation model ratified (supersedes "separate database per website"); Tenant Isolation Model controls + 2 D5 audit rows added | `jol-hub/docs/decisions/ADR-001-schema-per-tenant-isolation.md` |
