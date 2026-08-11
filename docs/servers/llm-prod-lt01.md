# llm-prod-lt01

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | llm-prod-lt01                              |
| **Role**           | llm                                        |
| **Environment**    | prod                                       |
| **VLAN**           | 30                                         |
| **Static IP**      | 10.30.30.10                                |
| **OS**             | Ubuntu 24.04 LTS (bare-metal)              |
| **Owner**          | jol-admin                                  |
| **Purpose**        | GPU/LLM inference (Ollama) for the JOL platform |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | yes                                        |
| **Monitoring**     | yes (node-exporter)                        |
| **Switch Port**    | N2048 Gi1/0/4 (access VLAN 30)             |
| **Status**         | **Active** (commissioned 2026-08-08)       |

## Role Description

Ollama inference endpoint serving RAG generation and fine-tuning workloads
(`http://10.30.30.10:11434`). Only TCP 11434 is exposed to VLAN 40
(AI Services); all other ingress denied at host firewall and MikroTik
inter-VLAN firewall (see `docs/architecture/trust-boundaries.md`).
SOC 2 Type II / GDPR / ISO 27001 controls apply to the full host.

**Deployment runbook**: `docs/runbooks/llm-prod-lt01-deployment.md`
(end-to-end build/DR rebuild phases, verification gates, gap
remediation recommendations).

## Resources (2026-08 rebuild)

| Resource | Allocation                                  |
|----------|---------------------------------------------|
| CPU      | AMD Ryzen 9 3950X (16C/32T, up to 4.3 GHz)  |
| RAM      | 64 GB DDR4 — 2×32 GB Patriot 3600 C18 in A2/B2 (1 DPC, dual-channel, DOCP 3600 / FCLK 1800 1:1 — verified running 3600 MT/s 2026-08-08). Former 2×16 GB Corsair 3200 kit removed 2026-08-08 (mixed-kit policy: matched pair only) |
| Disk     | 1000 GB M.2 NVMe (ADATA LEGEND 860, root). LV `ubuntu-lv` extended 100 G → 914 G ext4 (2026-08-09; VG fully allocated, 0 free). Legacy 320 GB SATA HDD (ST9320423AS) removed 2026-08-08 — retained as sensitive media, wipe before reuse/storage |
| GPU      | none (headless; RX 5500 removed 2026-08-08 — 3950X has no iGPU, console-blind by design) |
| Inference | **CPU-only** (Ollama 0.32.6, 32 threads); no CUDA/ROCm stack by design |

### Ollama Runtime (commissioned 2026-08-08)

- Install: official script, version **0.32.6**, CPU-only (no GPU detected)
- Model: **`qwen3:30b`** (30B-A3B MoE, 18 GB Q4_K_M, 256K context, blob
  `ad815644918f`) — pulled from the registry and aliased via `ollama cp`
  to `mistral-7b-instruct` to match RAG's `OLLAMA_MODEL` (zero RAG-side
  change). Chosen as the best CPU-only fit for the 3950X: decode is
  memory-bandwidth-bound and the MoE activates only ~3B params per
  token — benchmarked **19.0 t/s** decode vs 10.0 t/s for Mistral-7B
  (same prompt/params, temperature 0).
- Rollback: `mistral:7b-instruct` (4.4 GB, blob `6577803aa9a0`) retained
  on-host; re-alias with `ollama cp mistral:7b-instruct mistral-7b-instruct`.
  Note: the bare `mistral-7b-instruct` registry tag no longer exists —
  the nightly model-store backup is the only restore source for it.
- Qwen3 caveat: it is a thinking model. `/api/chat` callers should pass
  `think: false` (or `/no_think`) for RAG-style latency; with thinking
  on, the first tokens are hidden reasoning and end-to-end latency grows.
- Drop-in `/etc/systemd/system/ollama.service.d/jol.conf`:
  `OLLAMA_HOST=0.0.0.0:11434`, `OLLAMA_MODELS=/var/lib/jol-ollama/models`
- Model store `/var/lib/jol-ollama/models` owned by `ollama` (member of
  `jol-ollama` group)

## Driver Policy (2026-08-08 decision)

- All device drivers are Ubuntu 24.04 GA-kernel (6.8) in-tree modules —
  no third-party/DKMS driver packages are installed or planned:
  - `igb` — Intel I211 Gigabit NIC (`enp5s0`, production)
  - `r8125` — Realtek RTL8125 2.5GbE (`enp4s0`, cold spare)
  - `nvme` — ADATA LEGEND 860 (root)
  - `amdgpu` — not loaded (no GPU present); reinstall RX 5500 only if
    BIOS/console access is ever required
  - `amd64-microcode` — CPU microcode (loaded, 0x8701035)
- Do not install Realtek DKMS tarballs or vendor NVMe drivers; kernel
  updates via `unattended-upgrades` are the driver update path.

## Storage Layout (audited 2026-08-09)

| Component | Size | Filesystem | Purpose |
|-----------|------|-----------|---------|
| `nvme0n1p1` | 1 G | vfat | EFI |
| `nvme0n1p2` | 2 G | ext4 | `/boot` |
| `nvme0n1p3` → `ubuntu-lv` | 914 G | **ext4** | `/` — OS, models, state |
| `/swap.img` | 8 G | swap file | within 8–16 G spec; `vm.swappiness=10` for SSD endurance (persistent, `/etc/sysctl.d/99-jol-vm.conf`). Hibernation deliberately not enabled (headless server; would need ≥64 G swap) |

Canonical directory structure:

- `/usr/local/bin/{ollama,node_exporter}` — binaries (installer layout,
  incl. `/usr/local/lib/ollama` runner libs)
- `/var/lib/jol-ollama/` (750, `jol-ollama:jol-ollama`) — `models/`
  (ollama-owned) + `logs -> /var/log/jol-ollama`
- `/var/backups/jol-ollama/` (750, `jol-ollama:jol-ollama`) — legacy
  snapshot staging dir (retired 2026-08-11 with the pbs01 migration;
  kept empty for now)
- `/etc/jol-ollama/` (750 root) — PBS backup credentials:
  `pbs-token` (API token secret, 600) + `pbs-encryption.key`
  (client-side encryption key, passphrase-less `--kdf none`, 600)
- `/opt/jol/repos/secrets/` (700, root) — layout skeleton only; **no
  secrets live on this host** (Vaultwarden on admin01)
- `/var/log/jol-ollama/` — app log dir (currently journald-only)

## Network

- VLAN 30 — GPU/LLM segment (10.30.30.0/24), gateway 10.30.30.1 (MikroTik
  RB5009 inter-VLAN routing)
- Switch: Dell N2048 Gi1/0/4, access VLAN 30
- NIC mapping (2026-08-08 install): `enp5s0` Intel I211 Gigabit, driver
  `igb` (MAC 24:4b:fe:55:b1:c4) — production, cabled to Gi1/0/4;
  `enp4s0` Realtek RTL8125 2.5GbE, driver `r8125`
  (MAC 24:4b:fe:55:b1:c5) — spare, unconfigured.
- Canonical netplan (single static file; NIC name to be discovered
  post-install and substituted):

```yaml
network:
  version: 2
  ethernets:
    enpXsY:                # replace with actual NIC name post-install
      dhcp4: no
      addresses:
        - 10.30.30.10/24
      routes:
        - to: default
          via: 10.30.30.1
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
```

- Install note: after installation, remove the cloud-init network config
  (`/etc/netplan/50-cloud-init.yaml`) so only the canonical static file is
  merged. The previous host carried a cloud-init file alongside the static
  one — a latent DHCP-override hazard.
- Port-security: Gi1/0/4 runs `maximum 1 / violation shutdown` with the old
  NIC's sticky MAC. The rebuild's new NIC MAC must be cleared/re-learned on
  the port **before** first link-up, or the port will violation-shutdown.

## SSH Policy

- Password authentication **disabled**, key-only
- Root login disabled; administrative access via `jol-admin` + sudo
- Hardening drop-in: `/etc/ssh/sshd_config.d/00-jol-hardening.conf`
  (Ansible role `ssh`)
- Idle session timeout: 15 minutes (ClientAliveInterval 300 × 3)
- LogLevel VERBOSE for audit trail

## Firewall Ports (UFW)

| Port  | Service       | Access                          | Status        |
|-------|---------------|---------------------------------|---------------|
| 22    | SSH           | 10.10.10.0/24, 10.60.60.0/24    | applied 2026-08-08 |
| 11434 | Ollama        | 10.40.40.0/24 only              | applied 2026-08-08 |
| 9100  | node-exporter | 10.10.10.0/24, 10.60.60.0/24    | applied 2026-08-08 |

UFW: default deny incoming, allow outgoing, enabled at boot.

## Observability

- node_exporter on 10.30.30.10:9100 (role `monitoring`)
- Ollama health: `curl http://10.30.30.10:11434/api/tags`
- Fleet Prometheus (admin01, container `jol-prometheus`,
  `prom/prometheus:v2.53.2`, port 9091) scrapes this host's
  node-exporter — target verified `up` 2026-08-08

## Backup Policy

- **PBS-native push to pbs01 (since 2026-08-11)**: root cron on this host
  (03:15) runs `/usr/local/sbin/backup-ollama-models.sh`
  (= `scripts/maintenance/backup-ollama-models.sh`) — stop-service
  snapshot → client-side **encrypted** push of the full model store
  (~22 GB; 35 s incremental / ~3.5 min initial at 112 MiB/s) →
  `jol-llm-backup@pbs!llm-token@10.10.10.30:pbs-store`, namespace
  `jol-llm`, group `host/llm-prod-lt01` → post-backup snapshot-count
  verification → client-side retention prune (keep-daily=7,
  keep-weekly=4); server-side GC + monthly verify jobs run on pbs01.
  ollama restart guaranteed on all exit paths. Logs:
  `/var/log/jol-ollama-backup.log` (+ `-cron.log`). TLS pinned by the
  pbs01 cert fingerprint; token/key live in `/etc/jol-ollama/` (600
  root), never in the script. Re-run manually after any model
  pull/alias change.
- Scope is **full store** (all blobs + manifests incl. `qwen3:30b`) —
  pbs01's 3.27 TB RAIDZ2 removed the capacity constraint that forced
  the 2026-08-09 selective archives on admin01. The Mistral rollback
  weights (registry tag `mistral-7b-instruct` removed upstream) are
  therefore also covered off-host.
- pbs01 identity: user `jol-llm-backup@pbs` + token `llm-token`,
  `DatastorePowerUser` on `/datastore/pbs-store` (backup + restore +
  prune of owned snapshots; token privs are intersected with the
  user's). nftables on pbs01 allows 8007/tcp from 10.30.30.10 only.
- **Restore** (drilled 2026-08-11 — full 22 GB restore: manifests
  diff identical + 18 GB blob SHA256 match): stop ollama, then
  `proxmox-backup-client restore host/llm-prod-lt01/<snapshot>
  jol-models.pxar /var/lib/jol-ollama/models --keyfile
  /etc/jol-ollama/pbs-encryption.key --repository ... --ns jol-llm
  --overwrite true --allow-existing-dirs true`, fix ownership
  (`chown -R ollama:ollama /var/lib/jol-ollama`), start ollama. See
  runbook Phase 5. If the encryption key is lost, re-pull per Path A.
- Superseded design (retired 2026-08-11): admin01-orchestrated
  selective tar.gz export to `admin01:~/backups/jol-llm/` — all
  archives deleted after the first verified PBS backup + restore
  drill; admin01 cron + script removed.
- RPO/RTO: model restore < 1 h from pbs01; full rebuild per this
  doc + Ansible (~4 h).

## Compliance Controls (host)

- Same baseline as AI service hosts: CIS Ubuntu 24.04 Level 1 subset (role
  `common`), auditd, fail2ban (sshd jail), unattended-upgrades, sysctl
  hardening — see `ansible/playbooks/harden-ai-hosts.yml` (play targets
  `ai_services, llm`; applied to this host 2026-08-08).

## Commissioning Checklist

1. Clear/re-learn Gi1/0/4 port-security sticky MAC (new NIC MAC).
2. Cable host to Gi1/0/4; confirm link Up and access VLAN 30.
3. Install Ubuntu 24.04 LTS on the M.2 NVMe; apply canonical netplan;
   remove cloud-init network config.
4. Run baseline hardening roles; apply UFW table above.
5. Verify: llm → `ping 10.30.30.1`; rag → `ping 10.30.30.10`;
   rag → `curl http://10.30.30.10:11434/api/tags`; RAG `/ready` shows
   ollama up.
6. Record final hardware (CPU/RAM/GPU models, NIC MAC) in this doc, the
   port table registry, and `inventory/prod/hosts.yml`.

## Change History

| Date       | Change | Evidence |
|------------|--------|----------|
| 2026-08-05 | Gi1/0/4 link Down after board/CPU swap; host unreachable | n2048 port table notes |
| 2026-08-07 | Investigation: carrier Up and static config correct, but host could not reach gateway 10.30.30.1 — wrong L2 segment; rag→llm path degraded (`From 192.168.88.1 ... Unreachable`) | /tmp console diagnostics |
| 2026-08-07 | Decision: full rebuild on new bare-metal (new CPU, 1000 GB M.2 NVMe, Ubuntu 24.04 LTS); old board decommissioned | this doc |
| 2026-08-08 | Ubuntu 24.04 LTS installed via Subiquity (LVM, no LUKS) on M.2 NVMe; static netplan on enp5s0; host pending Gi1/0/4 port-security remediation for L2 | installer session |
| 2026-08-08 | Incident resolved: llm cable moved Gi1/0/3→Gi1/0/4 (was on VLAN 20); Gi1/0/4 Up, MAC on VLAN 30, port-security re-armed, switch config saved; fleet SSH key installed; admin01 key-auth verified | n2048 session 2026-08-08 |
| 2026-08-08 | OS discrepancy found (booted old 22.04 install) → genuine 24.04.4 LTS reinstall on NVMe (kernel 6.8.0-137); hardware verified: Ryzen 9 3950X, 96 GB mixed DDR4, RX 5500 display-only; driver policy = in-tree only, CPU-only inference | live inspection 2026-08-08 |
| 2026-08-08 | Hardware finalised: RX 5500 and legacy HDD removed (headless, NVMe-only); Corsair 2×16 kit removed — 64 GB Patriot 2×32 @3600 DOCP in A2/B2; verified from admin01 (62Gi, NVMe-only, key-auth OK) | live inspection 2026-08-08 |
| 2026-08-08 | Commissioned: baseline hardening + UFW table applied; Ollama 0.32.6 CPU-only with jol.conf drop-in; node-exporter on :9100; model mistral-7b-instruct (Q4_K_M) pulled + aliased | live session 2026-08-08 |
| 2026-08-08 | Interim incident: SSH timeouts from admin01 despite healthy host — admin01 multi-homed routing sent prod traffic out its home DHCP NIC (SRC 192.168.88.249, correctly blocked by UFW). Fixed on admin01: `nmcli connection modify VLAN10-MGMT +ipv4.routes "10.0.0.0/8 10.10.10.1"`; emergency fallback `ssh -J root@10.60.60.20` | UFW BLOCK log forensics 2026-08-08 |
| 2026-08-08 | Gates GREEN: `/api/tags` from rag VM; RAG `/ready` qdrant/minio/ollama up; sample `/query` end-to-end OK (67 s CPU-only latency, empty corpus) | gate run 2026-08-08 |
| 2026-08-08 | DOCP pass: temporary RX 5500 + console installed, BIOS DOCP enabled — memory verified at 3600 MT/s (dmidecode, A2/B2); GPU removed again (headless). Re-gated: `/query` latency 67 s → 34 s (~2×) | dmidecode + gate run 2026-08-08 |
| 2026-08-08 | Residual risk closure (#26): model store exported to admin01 (6.3 GB); fleet Prometheus deployed on admin01:9091 scraping :9100 (target up); jol-admin password rotated; switch SNMP rw community removed + switch admin password rotated | live session 2026-08-08 |
| 2026-08-09 | Timezone aligned to fleet standard Europe/Vilnius (was UTC) | timedatectl 2026-08-09 |
| 2026-08-09 | File-structure audit: verified layout matches doc (binary `/usr/local/bin/ollama`, unit + `jol.conf` drop-in, state `/var/lib/jol-ollama` jol-ollama:jol-ollama 750, models ollama-owned, log dir present, UFW rules live in iptables); playbook targeting note corrected | live audit 2026-08-09 |
| 2026-08-09 | Storage build-out: `ubuntu-lv` 100 G → 914 G ext4 (online `lvextend`+`resize2fs`, VG now 0 free); swap confirmed 8 G (within 8–16 G spec); `vm.swappiness=10` + `vfs_cache_pressure=50` persisted for SSD endurance; `/var/backups/jol-ollama` staging dir created (750) | lvextend/df/sysctl 2026-08-09 |
| 2026-08-09 | Update/upgrade pass: OS fully patched (0 upgradable, kernel 6.8.0-137.137 running = installed, no reboot required); Ollama 0.32.6 = latest upstream; node_exporter 1.8.2 → 1.12.1 (SHA256-verified, Prometheus target back `up`); pin recorded in host_vars | apt audit + upgrade session 2026-08-09 |
| 2026-08-09 | Deployment re-verified GREEN from admin01 (Ollama 0.32.6 active+enabled after reboot, DOCP 3600, UFW table, RAG `/ready` ollama up); automated nightly model-store backup deployed (cron 03:15 admin01, `scripts/maintenance/backup-ollama-models.sh`), first test run OK: 4.0 GB archive, SHA256 verified, ollama auto-restarted | gate run + backup session 2026-08-09 |
| 2026-08-09 | Model migration Mistral → **qwen3:30b** (30B-A3B MoE, 18 GB): registry pull OK; benchmark decode 19.0 t/s vs Mistral 10.0 t/s (same prompt, t=0, 128 tokens); alias `mistral-7b-instruct` re-pointed to Qwen blob `ad815644918f` (RAG `OLLAMA_MODEL` unchanged); Mistral kept as rollback; RAG `/health` + `/ready` GREEN (qdrant/minio/ollama up); authenticated `/query` gate deferred to operator (JWT); model-store backup re-run; `ollama_version` + model pins added to host_vars | live session 2026-08-09 |
| 2026-08-09 | Incident: full-store backup (21 GB) filled admin01 `/home` (92 G, <1 MiB left) mid-transfer; truncated archive deleted, ollama confirmed active. Fix: backup scope made **selective** (manifests + non-re-pullable blobs only, ~4.5 GB) + destination free-space preflight + post-transfer size check; re-run verified (4.0 GB, SHA256 OK); retention 7 → 3 (steady-state ~12 GB fits /home); superseded 8.0 GB 2026-08-08 archive pruned (Mistral contents covered by 011910 + 023114); runbook Path B updated | backup log + live session 2026-08-09 |
| 2026-08-11 | Clean rebuild of model store on request: all archives (admin01 + server staging) deleted, store wiped, models re-installed directly on this host — `qwen3:30b` (blob `ad815644918f`), `mistral:7b-instruct` rollback (`6577803aa9a0`), alias `mistral-7b-instruct` re-created; inference smoke-tested | live session 2026-08-11 |
| 2026-08-11 | Backup migrated to fleet platform **pbs01**: `proxmox-backup-client` 3.4.7 installed (Debian bookworm pbs-client repo), identity `jol-llm-backup@pbs!llm-token` (DatastorePowerUser), namespace `jol-llm` created, nftables 8007/tcp from 10.30.30.10; nightly root cron 03:15 on this host; first encrypted backup OK (22 GB, 112 MiB/s); **restore drill passed** (manifests identical + 18 GB blob SHA256 match); admin01 backup role fully retired (cron + script + archives) | live session + `/var/log/jol-ollama-backup.log` 2026-08-11 |
