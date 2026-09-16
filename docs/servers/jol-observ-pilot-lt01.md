# jol-observ-pilot-lt01

> **Status**: SPEC — provisioning specification; VM does not exist yet.
> Provisioning blocked until: `data` ZFS pool created (with encryption);
> DMZ VLAN not required by this VM (VLAN 60 only).

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | jol-observ-pilot-lt01                      |
| **Role**           | observability / compliance evidence collector |
| **Environment**    | pilot                                       |
| **VLAN**           | 60 (Proxmox management)                     |
| **Static IP**      | 10.60.60.30                                 |
| **OS**             | Ubuntu 24.04 LTS (VM, FIPS-compatible kernel line) |
| **Owner**          | jol-admin                                   |
| **Purpose**        | Netdata / Prometheus / Loki — metrics + centralised logs for the pilot fleet; SOC 2 / ISO 27001 evidence host |
| **SSH Policy**     | key-only                                    |
| **Backup Enabled** | yes (PBS nightly)                           |
| **Monitoring**     | self (Netdata local) + prox01 node-exporter |
| **VMID**           | 204                                         |
| **Hypervisor**     | prox01                                      |

## Role Description

Dedicated evidence tier: collects metrics (node-exporter scrapes) and logs
(UFW logs from all pilot guests, ingress access/WAF logs via Loki) from a
host OUTSIDE the guests it observes — compromise of any monitored guest
does not destroy its own evidence. Management-facing only: never exposed
to the public side. IP 10.60.60.30 verified next-free in VLAN 60
(10.60.60.10=prox01, .20=hv01 — `docs/servers/prox01.md`,
`docs/servers/pve-prod-hv01.md`).

## Resources (D1)

| Resource | Allocation |
|----------|-----------|
| vCPU     | 2 (cpu type `host`) |
| RAM      | 6 GB (ballooning allowed) |
| Disk     | 100 GB on `data` (raidz2, encrypted pool) — scsi, virtio-scsi-single, iothread |
| Machine  | q35, BIOS OVMF (UEFI) + EFI disk |
| Agent    | qemu-guest-agent enabled |

Network: `vmbr0` **native/untagged** (VLAN 60), virtio, static
10.60.60.30/24, gw 10.60.60.1.

Cloud-init template: `ubuntu-24.04-lts-generic-amd64.qcow2` —
⚠ UNVERIFIED — manual check required: upload + SHA256-verify on prox01;
user-data carries hostname + `jol-admin` SSH key only.

## Disk Placement Justification (D2)

`data` (raidz2): log/metric retention is the pilot's largest *capacity*
consumer among the support tiers, and retention must survive disk loss —
raidz2's 2-disk fault tolerance protects the evidence chain (SOC 2 CC7.2).
`compression=zstd` (logs compress well; material retention win),
`atime=off`. Pool MUST be created with `encryption=on` (aes-256-gcm) —
log metadata is still processing data under GDPR (IP addresses appear in
access logs → Art. 4(1) personal data).

## Guest Hardening (D3) — mapped to `ansible/playbooks/harden-ai-hosts.yml`

> Inventory: add to `pilot` group; extend playbook `hosts:` line via
> reviewed change (SOC 2 CC8.1). No secret values in `inventory/prod/`.

- [ ] role `common` — CIS Ubuntu 24.04 L1 subset; unattended-upgrades + apticron
- [ ] role `time_sync` — chrony, internal NTP — **this host is the
      timestamp authority for evidence correlation; drift = unusable audit
      trail** (SOC 2 CC7.2)
- [ ] role `ssh` — `PermitRootLogin no`, `PasswordAuthentication no`,
      `AllowUsers jol-admin`, idle timeout, LogLevel VERBOSE
- [ ] role `base_firewall` — UFW per `jol-pilot-firewall-matrix.md` §2.5:
      dashboards/query ports from 10.60.60.0/24 + 10.10.10.0/24 ONLY;
      Loki push (3100/tcp) from 10.40.40.0/24 + 10.45.45.0/24; SSH from
      mgmt sources (limited); **no internet egress** except DNS/NTP;
      `ufw logging on`
- [ ] role `monitoring` — node-exporter on 9100 (self-scrape + fleet view)
- [ ] role `backup_client` — not required (hypervisor-level PBS); evidence
      retention beyond backup RPO is application-level (see retention below)
- [ ] auditd immutable (`-e 2`): identity, sudoers, sshd, ufw, secrets +
      watch on retention/ingest configs (`-k jol_secrets` if secret-bearing)
- [ ] AIDE baseline post-provisioning (`aideinit`, then move
      `/var/lib/aide/aide.db.new` → `/var/lib/aide/aide.db`); nightly 04:15 UTC
- [ ] fail2ban: sshd jail

### Evidence-tier controls

- [ ] Stack pinned at provisioning (⚠ decide: Netdata + Prometheus + Loki
      versions) — no `latest` tags anywhere (fleet pin discipline, AGENTS.md
      §2.2/§2.4 precedent)
- [ ] Retention policy: metrics ≥ 90 d, logs ≥ 180 d (⚠ align with the
      compliance retention register before go-live; GDPR Art. 5(1)(e)
      storage limitation applies — logs hold IPs = personal data)
- [ ] Log ingestion accepts **connection metadata only**; no request
      bodies, no prompt/completion content (fleet 0-day prompt-retention
      principle extends here)
- [ ] Dashboards (Netdata 19999 / Prometheus 9090 / Grafana 3000 — per
      chosen stack) bind to the mgmt-facing NIC only; no public exposure
- [ ] Alerting: scrape-failure + ingest-failure alerts (an evidence host
      silently going blind is itself an incident — CC7.2)

## Secret Delivery (D4) — AGENTS.md §0.1 zero tolerance

**NEVER in cloud-init user-data, NEVER in repo files, NEVER as CLI args.**

1. **Ansible Vault** for static config secrets (Loki basic-auth if enabled,
   Grafana admin bootstrap password): `ansible-vault encrypt_string
   --stdin-name 'jol_observ_admin_password'`, injected at deploy.
2. **Vaultwarden** for any rotated credentials; bootstrap admin password is
   rotated out of Vaultwarden-managed state immediately after first login.
3. **On-guest model**: `/etc/jol-observ/observ.env` — `0640
   root:jol-observ` if a service loads it via EnvironmentFile, else `0600
   root:root`; world bits 0; service account `jol-observ` (nologin);
   auditd watch `-w /etc/jol-observ/ -p wa -k jol_secrets`.

## Pre-Go-Live Audit Checklist (D5)

| Check | Command | Expected Output | Evidence File |
|-------|---------|-----------------|---------------|
| OS version | `cat /etc/os-release` | Ubuntu 24.04 LTS | `audit/<vm>-os-version.txt` |
| QGA running | `systemctl is-active qemu-guest-agent` | `active` | `audit/<vm>-qga.txt` |
| No root SSH | `grep -r PermitRootLogin /etc/ssh/sshd_config.d/` | `no` | `audit/<vm>-ssh.txt` |
| UFW active | `sudo ufw status verbose` | `Status: active`, default deny incoming | `audit/<vm>-ufw.txt` |
| Dashboards mgmt-only | `ss -tlnp \| grep -E "19999\|9090\|3000"` | bound; reachable only from 10.60.60.0/24 + 10.10.10.0/24 (negative test from 10.40.40.20 → REFUSED) | `audit/<vm>-bind.txt` |
| Ingest from guests | Loki query: UFW label present from all 5 pilot guests | entries present | `audit/<vm>-ingest.txt` |
| Disk encryption | `zfs get encryption data` (on prox01) | `encryption on` | `audit/<vm>-crypto.txt` |
| No plaintext secrets | `sudo grep -ri "password\|secret" /etc/cloud/ /var/lib/cloud/instance/user-data.txt` | *(empty)* | `audit/<vm>-secrets.txt` |
| Secret perms | `sudo stat -c "%a %U:%G" /etc/jol-observ/observ.env` | `640 root:jol-observ` (or 600 root:root) | `audit/<vm>-secrets.txt` |
| No WAN egress | `curl -sf --max-time 5 https://example.com` from guest | FAILS (expected) | `audit/<vm>-egress.txt` |
| NTP accuracy | `chronyc tracking` | offset < 10 ms vs internal source | `audit/<vm>-ntp.txt` |
| AIDE | `sudo aide --check` | rc=0 | `audit/<vm>-aide.txt` |
| AIDE baseline hash | `sha256sum /var/lib/aide/aide.db` | `<hash>` recorded in evidence | `audit/<vm>-aide.txt` |

## Compliance Controls (host)

Same baseline as jol-app-pilot-lt01. This guest IS the compliance control
for CC7.2: its availability, timestamp accuracy, and its own integrity
(AIDE + no egress) are audited as evidence-of-the-evidence.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Provisioning spec created (Step 3) — VM not yet provisioned | this document |
| 2026-08-23 | Ratified-spec reconciliation: qcow2 template name, aideinit procedure, QGA audit row | Step 3 ratified task spec |
| 2026-08-23 | Ratified-spec final: AIDE baseline-hash evidence row added | Step 3 ratified task spec (final) |
