# jol-ingress-pilot-lt01

> **Status**: SPEC — provisioning specification; VM does not exist yet.
> Provisioning **blocked on the ADR-004 amendment** (DMZ VLAN 45 /
> 10.45.45.0/24 must be approved and created on N2048 + MikroTik first —
> see `docs/network/prox01-vmbr-layout.md` §3).

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | jol-ingress-pilot-lt01                     |
| **Role**           | public ingress / security edge              |
| **Environment**    | pilot                                       |
| **VLAN**           | 45 (DMZ, proposed — pending ADR) + 40 (backend) |
| **Static IP**      | 10.45.45.10 (DMZ NIC) / 10.40.40.23 (backend NIC) |
| **OS**             | Ubuntu 24.04 LTS (VM, FIPS-compatible kernel line) |
| **Owner**          | jol-admin                                   |
| **Purpose**        | TLS 1.3 termination, WAF (ModSecurity), access logging — the ONLY public entry point of the pilot |
| **SSH Policy**     | key-only                                    |
| **Backup Enabled** | yes (PBS nightly)                           |
| **Monitoring**     | yes (node-exporter → jol-observ-pilot-lt01) |
| **VMID**           | 203                                         |
| **Hypervisor**     | prox01                                      |

## Role Description

Dual-homed reverse proxy (Traefik or Nginx — ⚠ decide and record) forming
the trust boundary between the untrusted side and VLAN 40. Terminates TLS
1.3, applies WAF rules, and produces the CC6.1/CC7.2 access evidence. The
proxy **originates new connections** to the backend — no bridged L2 path,
no IP forwarding between NICs.

## Resources (D1)

| Resource | Allocation |
|----------|-----------|
| vCPU     | 2 (cpu type `host`) |
| RAM      | 4 GB (ballooning allowed) |
| Disk     | 40 GB on **`rpool`** (ZFS mirror) — scsi, virtio-scsi-single, iothread |
| Machine  | q35, BIOS OVMF (UEFI) + EFI disk |
| Agent    | qemu-guest-agent enabled |

Network — **two NICs**, both on `vmbr0` with VLAN tags (Step 2 layout §2):

| NIC | vmbr | Tag | IP | Gateway |
|-----|------|-----|----|---------|
| net0 (external) | vmbr0 | 45 (DMZ) | 10.45.45.10/24 | 10.45.45.1 |
| net1 (backend)  | vmbr0 | 40 | 10.40.40.23/24 | none (no default route on this NIC) |

Cloud-init template: `ubuntu-24.04-lts-generic-amd64.qcow2` —
⚠ UNVERIFIED — manual check required: upload + SHA256-verify on prox01;
user-data carries hostname + `jol-admin` SSH key only.

## Disk Placement Justification (D2)

`rpool` (mirror) deliberately: the ingress guest is small, stateless, and
latency-sensitive at boot/restart; the 2-disk mirror gives fast, simple
resilience without consuming the large data pool. Capacity need is minimal
(40 GB incl. logs — access logs rotate to the observ VM).

**Residual risk (documented, accepted-by-design pending review)**: `rpool`
was created by the PVE installer WITHOUT encryption and cannot be
retrofitted. Compensating controls: (1) PBS backups are client-side
encrypted; (2) this guest holds NO personal data at rest — access logs
contain connection metadata only and must be **redaction-configured**
(no query strings, no auth headers in logs); (3) WAF/proxy config and TLS
**private keys** on this disk are the sensitive items — private keys live
only in the runtime secret file (0640, auditd-watched, see D4) and are
regenerable from the CA. If the review rejects this residual risk,
alternative: place the disk on `data` (encrypted) instead — cost is minor.

## Guest Hardening (D3) — mapped to `ansible/playbooks/harden-ai-hosts.yml`

> Inventory: add to `pilot` group; extend playbook `hosts:` line via
> reviewed change (SOC 2 CC8.1). No secret values in `inventory/prod/`.

- [ ] role `common` — CIS Ubuntu 24.04 L1 subset; unattended-upgrades + apticron
- [ ] role `time_sync` — chrony, internal NTP (log timestamps are evidence —
      SOC 2 CC7.2)
- [ ] role `ssh` — `PermitRootLogin no`, `PasswordAuthentication no`,
      `AllowUsers jol-admin`, idle timeout, LogLevel VERBOSE
- [ ] role `base_firewall` — UFW per `jol-pilot-firewall-matrix.md` §2.4:
      DMZ NIC: 443/tcp (TLS 1.3 only) + 80/tcp→301 from any, SSH from mgmt
      sources (limited); backend NIC: deny inbound except
      established/related; outbound backend NIC → 10.40.40.20:<app-port>
      only; `ufw logging on`
- [ ] role `monitoring` — node-exporter on 9100 → 10.60.60.0/24 only
- [ ] role `backup_client` — not required (hypervisor-level PBS)
- [ ] auditd immutable (`-e 2`): identity, sudoers, sshd, ufw, secrets +
      watch on TLS key material (`-k jol_secrets`)
- [ ] AIDE baseline post-provisioning (`aideinit`, then move
      `/var/lib/aide/aide.db.new` → `/var/lib/aide/aide.db`); nightly 04:15
      UTC (WAF rule files are AIDE-covered — rule changes are auditable
      diffs)
- [ ] fail2ban: sshd jail **+ HTTP(S) jails** (waf/abuse patterns;
      banaction=ufw)

### Edge-specific controls

- [ ] TLS: **1.3 only**, strong cipher suite, HSTS, OCSP stapling;
      certificates per `docs/runbooks/certificate-renewal.md`
- [ ] WAF: ModSecurity (or proxy-native equivalent) in blocking mode after
      a soak period in detection-only; rule updates change-controlled
- [ ] Access logs → Loki (jol-observ-pilot-lt01) with redaction config;
      local retention ≤ 7 days
- [ ] No direct DMZ→backend route: verify `ip route` shows no forwarding
      path; `net.ipv4.ip_forward=0` enforced by role `common` sysctl

## Secret Delivery (D4) — AGENTS.md §0.1 zero tolerance

**NEVER in cloud-init user-data, NEVER in repo files, NEVER as CLI args.**

1. **TLS private keys**: issued via the fleet certificate workflow
   (`docs/runbooks/certificate-renewal.md`); keys stored in Vaultwarden,
   deployed by Ansible at provisioning/renewal — never generated or stored
   on the admin workstation.
2. **Ansible Vault** for any upstream shared secrets (e.g., backend API
   tokens the proxy forwards) — injected at deploy time.
3. **On-guest model**: `/etc/jol-ingress/` — dir `0750 root:jol-ingress`;
   TLS key file `0640 root:jol-ingress`, world bits 0; service account
   `jol-ingress` (nologin); auditd watch `-w /etc/jol-ingress/ -p wa -k
   jol_secrets`.

## Pre-Go-Live Audit Checklist (D5)

| Check | Command | Expected Output | Evidence File |
|-------|---------|-----------------|---------------|
| OS version | `cat /etc/os-release` | Ubuntu 24.04 LTS | `audit/<vm>-os-version.txt` |
| QGA running | `systemctl is-active qemu-guest-agent` | `active` | `audit/<vm>-qga.txt` |
| No root SSH | `grep -r PermitRootLogin /etc/ssh/sshd_config.d/` | `no` | `audit/<vm>-ssh.txt` |
| UFW active | `sudo ufw status verbose` | `Status: active`, default deny incoming | `audit/<vm>-ufw.txt` |
| TLS 1.3 only | `openssl s_client -tls1_2 -connect 10.45.45.10:443` | handshake FAILS (expected) | `audit/<vm>-tls.txt` |
| TLS 1.3 works | `openssl s_client -tls1_3 -connect 10.45.45.10:443` | handshake OK | `audit/<vm>-tls.txt` |
| No forwarding | `sysctl net.ipv4.ip_forward` | `= 0` | `audit/<vm>-route.txt` |
| Backend pivot denied | from DMZ-side test host: `nc -vz 10.40.40.21 5432` | REFUSED | `audit/<vm>-neg.txt` |
| Disk encryption | `zfs get encryption rpool` (on prox01) | `off` — documented residual risk (§D2) | `audit/<vm>-crypto.txt` |
| No plaintext secrets | `sudo grep -ri "password\|secret\|key" /etc/cloud/ /var/lib/cloud/instance/user-data.txt` | *(empty)* | `audit/<vm>-secrets.txt` |
| TLS key perms | `sudo stat -c "%a %U:%G" /etc/jol-ingress/tls/privkey.pem` | `640 root:jol-ingress` | `audit/<vm>-secrets.txt` |
| Log redaction | sample access log line | no query strings / auth headers | `audit/<vm>-logs.txt` |
| AIDE | `sudo aide --check` | rc=0 | `audit/<vm>-aide.txt` |
| AIDE baseline hash | `sha256sum /var/lib/aide/aide.db` | `<hash>` recorded in evidence | `audit/<vm>-aide.txt` |

## Compliance Controls (host)

Same baseline as jol-app-pilot-lt01 + fail2ban HTTP jails. Drivers: SOC 2
CC6.1 (logical access at the edge), CC6.6 (boundary protection), CC7.2
(access evidence); ISO 27001 A.8.22 (segregation of networks) — this guest
is the implementation of the DMZ boundary defined by the ADR-004 amendment.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Provisioning spec created (Step 3) — VM not yet provisioned | this document |
| 2026-08-23 | Ratified-spec reconciliation: qcow2 template name, aideinit procedure, QGA audit row | Step 3 ratified task spec |
| 2026-08-23 | Ratified-spec final: AIDE baseline-hash evidence row added | Step 3 ratified task spec (final) |
