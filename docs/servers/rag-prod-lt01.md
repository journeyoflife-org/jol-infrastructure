# rag-prod-lt01

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | rag-prod-lt01                              |
| **Role**           | rag                                        |
| **Environment**    | prod                                       |
| **VLAN**           | 40                                         |
| **Static IP**      | 10.40.40.10                                |
| **OS**             | Ubuntu 24.04 LTS (VM, FIPS-compatible kernel line) |
| **Owner**          | jol-admin                                  |
| **Purpose**        | RAG services, vector databases, document indexing, embeddings |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | **yes (re-verified 2026-11-01)** — nightly `vzdump` on pve-prod-hv01 → pbs01 ns `jol-hv01`; VMID 100 newest snapshot `2026-11-01T00:00:01Z` (10 consecutive OK local nights) |
| **Monitoring**     | yes (node-exporter)                        |
| **VMID**           | 100                                        |
| **Hypervisor**     | pve-prod-hv01                              |

## Role Description

Retrieval-Augmented Generation stack serving the JOL platform: FastAPI
RAG API, ingestion worker, Qdrant vector store, Redis queue, MinIO object
storage (SSE via KMS key). Handles sensitive organisational documents —
SOC 2 Type II / GDPR / ISO 27001 controls apply to the full host.

## Resources

| Resource | Allocation |
|----------|-----------|
| vCPU     | 4         |
| RAM      | 24 GB     |
| Disk     | 100 GB (local-lvm, thin) |

## Network

- VLAN 40 — AI Services segment (10.40.40.0/24), vmbr1 direct L2 bridge
  (nic0 → Gi1/0/6) — no NAT (restored 2026-08-08)
- Gateway: 10.40.40.1 (MikroTik RB5009 inter-VLAN routing)
- Ollama access: 10.30.30.10:11434 (VLAN 30, routed)
- Admin access: direct from admin01 (VLAN 10, routed); ProxyJump via
  pve-prod-hv01 remains available as fallback

## SSH Policy

- Password authentication **disabled**, key-only
- Root login disabled; administrative access via `jol-admin` + sudo
- Drop-in hardening: `/etc/ssh/sshd_config.d/00-jol-hardening.conf`
  (Ansible role `ssh`; first-match-wins override of cloud-init defaults)
- Idle session timeout: 15 minutes (ClientAliveInterval 300 × 3)
- LogLevel VERBOSE for audit trail

## Firewall Ports (UFW + DOCKER-USER guard)

| Port | Service        | Access       | Status |
|------|----------------|--------------|--------|
| 22   | SSH            | 10.40.40.0/24, 10.60.60.0/24 | active |
| 80/443 | reverse proxy | 10.40.40.0/24 | open (proxy not yet deployed) |
| 8000 | RAG API (Docker-published) | 10.40.40.0/24 via DOCKER-USER chain | active |
| 9100 | node-exporter  | 10.40.40.0/24 | active |

UFW: default deny incoming, allow outgoing, enabled at boot.
Docker bypasses UFW for published ports; `jol-docker-firewall.service`
enforces source restriction on port 8000 in the DOCKER-USER chain.

## Application Deployment — jol-rag-server (PRIMARY repo)

- Live deployment: Docker Compose stack at `/opt/jol/rag` (since 2026-08-03)
- Source repo: `journeyoflife-org/jol-rag-server` (reference clone read-only
  at `/opt/jol/repos/jol-rag-server`)
- Services: `jol-rag-api` (8000), `jol-rag-worker`, `jol-rag-qdrant`
  (127.0.0.1:6333/6334), `jol-rag-redis` (127.0.0.1:6379), `jol-rag-minio`
  (127.0.0.1:9000/9001) — data services loopback-bound only
- Secrets: `/opt/jol/rag/.env` (root:root 0640), injected from Vault —
  never committed; audit-watched via auditd (`jol_secrets` key)
- Containers run read-only rootfs, no-new-privileges, with memory/CPU limits
- Health gate: `/health` and `/ready` must return HTTP 200 after any change

## Canonical Directory Layout

```
/opt/jol/repos
├── jol-rag-server/          # application repo (read-only reference)
├── jol-infrastructure/      # bootstrap playbooks (read-only after bootstrap)
└── secrets/                 # Ansible Vault encrypted secrets (root:root, 700)
/var/lib/jol-rag/
├── vector-db -> /var/lib/qdrant   # live qdrant storage (uid 1000)
├── uploads   -> /data/raw_docs    # ingestion corpus (ro)
└── logs      -> /var/log/jol-rag  # application logs
```

Service accounts (host-level, nologin): `jol-rag`, `jol-vector`,
`jol-ollama` (reserved — inference runs on llm-prod-lt01). Process-level
isolation is provided by the container runtime.

## Observability

- node_exporter on 10.40.40.10:9100 (dedicated user, systemd-sandboxed)
- Promtail **staged** (binary + config at `/etc/promtail/config.yml`);
  enable once Loki endpoint exists (`promtail_enabled=true`)
- Filebeat SIEM profile available in compose (`--profile siem`)

## Backup Policy

**Working baseline (verified 2026-10-31T20:36Z — read-only probes in
`docs/compliance/evidence/hv01-backup-baseline-20261031.txt`)**

- Off-host VM backup **IS in force**: hypervisor job `hv01-nightly-pbs`
  (`schedule 02:00` Europe/Vilnius, `vmid 100,101,102`, `mode snapshot`, `compress zstd`,
  `prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6`, `repeat-missed 1`) →
  datastore `pbs01` (`pvesm status` → active), namespace `jol-hv01`.
- **10** consecutive scheduled OK runs, local nights 2026-10-23 → **2026-11-01** (re-measured
  2026-11-01T15:21Z from the hypervisor's own task epochs: the Nov 1 run is
  `2026-11-01T00:00:01Z`, status `OK`; one task per night covers all three VMIDs).
- Newest VMID 100 group `2026-11-01T00:00:01Z` — 15.3 h old at probe time ⇒ **RPO 24 h met**
  (8 groups held, `encrypted` fingerprint present, `verification.state=ok`).
- Client-side encryption on every group; the key is escrowed off-host (`/etc/pve/priv/storage/pbs01.enc`).
- **Restore drill PASSED for THIS VMID on 2026-10-31T21:58Z** — `qmrestore` of
  `pbs01:backup/vm/100/2026-10-31T00:00:07Z` (today's *scheduled* backup, not a hand-made dump) to
  scratch VMID 199: 107,374,182,400 bytes in 137.8 s at 743 MB/s (66 % zeroes ⇒ dedup + decryption
  with the stored key both proven), `net0` removed **before** the first boot (the image still carries
  10.40.40.10 while this VM is live), guest agent responsive after **80 s**, `get-fsinfo` answered,
  production `/health` still 200 throughout, then `qm destroy 199 --purge` with
  `vm199_lv_count=0`. End-to-end 4 min 48 s ⇒ the RTO 4 h claim for this asset is measured, not
  asserted. The earlier 2026-10-22 drill restored **vm/102** and proved the shared key, not this
  group. Evidence: `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` §9a, issue #131.
- qemu-guest-agent installed for fs-consistent snapshots (used by `mode snapshot`).
- Nightly application-level Qdrant snapshot (cron, 03:30 UTC) — on-VM only, NOT a substitute
  for the VM backup (it shares the NVMe device).
- **Still open**: the 3-2-1 "one off-site" leg — pbs01 has **no remote sync target**
  (`proxmox-backup-manager remote list` → empty, verified 2026-10-31), so a site-loss event
  still takes the hypervisor and its backup custodian together.

RPO: 24 h (met) | RTO: 4 h (measured 4 min 48 s for this VMID's restore path, 2026-10-31)

**History**: on 2026-10-21 this page claimed a nightly PBS backup that did not exist (no
datastore registered on the hypervisor, and the only `jobs.cfg` section was rejected by the
scheduler parser). The finding was recorded the same day and closed on 2026-10-22 by
`docs/runbooks/hv01-storage-backup-reconfiguration.md`; see Change History.

## Compliance Controls (host)

- CIS Ubuntu 24.04 Level 1 subset via Ansible role `common`
- auditd rules (immutable, `-e 2`): identity, sudoers, sshd, ufw, secrets —
  changing audit rules requires reboot + change record
- AIDE baseline with nightly integrity check (04:15 UTC)
- fail2ban (sshd jail, banaction=ufw, 3 strikes / 1 h ban)
- unattended-upgrades for security patches
- sysctl: protected hardlinks/symlinks, rp_filter, kptr_restrict=2,
  tcp_syncookies, yama.ptrace_scope=1

## Change History

| Date       | Change | Evidence |
|------------|--------|----------|
| 2026-08-03 | Initial RAG stack deployment (Docker Compose) | /opt/jol/rag mtimes |
| 2026-08-07 | Snapshot `pre-rag-deploy-20260807-1959` before baseline hardening | qm listsnapshot 100 |
| 2026-08-07 | Host baseline hardening (harden-ai-hosts.yml, roles v1) | /tmp/harden-rag-run*.log |
| 2026-08-07 | HOTFIX (jol-rag-server): qdrant-client forces HTTPS when api_key set — pinned `https=False` when internal TLS disabled; rebuilt rag-api/rag-worker | /tmp/provision-rag-hotfix.log, /tmp/rag-rebuild.log |
| 2026-08-07 | HOTFIX (jol-rag-server): read_only rootfs broke model cache (`/app/.cache` RO) — `HF_HOME`/`SENTENCE_TRANSFORMERS_HOME` → tmpfs `/tmp/hf` | /tmp/provision-rag-hotfix2.log |
| 2026-08-08 | Network incident resolved: Gi1/0/6 was on VLAN 50 (re-set to 40) AND vmbr1 had drifted to an isolated NAT bridge (`bridge-ports none`, hypervisor squatting 10.40.40.1); restored to documented L2 bridge with nic0, NAT rule and host IP removed. Reachable again: 10.40.40.10/11/12 answer from admin01 | n2048 session 2026-08-08; pve `/etc/network/interfaces.bak-20260808` |
| 2026-08-08 | Ollama dependency restored: llm-prod-lt01 commissioned (Ollama 0.32.6 CPU-only, model mistral-7b-instruct). Gates: `/ready` qdrant/minio/ollama all up; sample `/query` end-to-end OK (67 s CPU-only latency, empty corpus) | gate run 2026-08-08 |
| 2026-10-22 | **Off-host backup for VMID 100 went live** (runbook `docs/runbooks/hv01-storage-backup-reconfiguration.md`): pbs01 datastore registered on the hypervisor, ns `jol-hv01` created, first manual `vzdump` OK (107 GB group), API-created job `hv01-nightly-pbs` | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §17 |
| 2026-10-31 | **Backup baseline re-verified read-only; this page's "Backup Enabled: NO (2026-10-21)" corrected to YES.** 9 consecutive scheduled OK nightlies; newest group `2026-10-31T00:00:07Z` (RPO 24 h met); `hv01-archive-to-pbs.sh` evidence push live since 2026-10-25; prune/verify jobs present; GC still unscheduled and no off-site remote. The AGENTS.md §2.1 gate "≥ 7 consecutive OK runs before retiring the 2026-08-12 manual dump" is now satisfied (9 of 7) — the file was **not** deleted (separate change record required) | `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` |
| 2026-10-31 21:58Z | **VMID 100 restore drill PASSED** (issue #131) — `vm/100/2026-10-31T00:00:07Z` → scratch VMID 199 with `net0` removed before boot, agent up in 80 s, destroyed clean (`lvs` residue 0), 4 min 48 s end-to-end, production `/health` 200 throughout. This is the second half of the runbook §4 forward-only rule (the 2026-10-22 drill restored vm/102 only); the manual 2026-08-12 dump was left in place — its retirement is its own record | `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` §9a |
| 2026-11-01 16:11Z | **Offline filesystem check of THIS VMID's restored image — first time any backup of VMID 100 was opened without booting it** (issue #137, runbook §6): `vm/100/2026-11-01T00:00:01Z` → scratch VMID 199 (107 GB in 138.2 s @741 MB/s, 66 % zeroes), `losetup -f --show -P`, `e2fsck -fn` / `fsck.vfat -n`, never `-y`. `/` (p1, ext4) **rc=4** = 37 orphan-list inodes + one zero-dtime + negative block/inode bitmaps, superblock `state: clean`, **0** severe markers; `/boot` (p16) **rc=0 clean**; **ESP (p15, vfat) rc=1 — FAT dirty bit set** ("was not properly unmounted") + boot-sector vs backup difference at offset 65, accepted as non-severe because the restored copies boot and because clearing it would be a repair. `net0` never existed here (deleted before any inspection), teardown verified by post-state (`lv_count=0 loop_count=0`, pool 5.94 % → 5.94 %, VMs 100/101/102 running). Relevance to this guest: the Qdrant/MinIO corpora on `/` are GDPR Art. 9 data, so "the restored filesystem is structurally sound" is now a measured claim rather than an inference from a successful boot. Recorded residual: the ESP dirty bit is present in EVERY nightly image of this VM, not cleaned by design | evidence §12; host `/var/log/jol-hv01/offline-fsck-20261101-180639.log` (= 16:06:39Z, file names are host-local) |

## Maintenance Notes

- Kernel patching during approved maintenance windows only
- Reboot required for kernel updates — schedule with AI team
- Health gate after every change: `/health`, `/ready`, sample RAG query
- 2026-08-07 gate result: `/health` 200 PASS; `/ready` 200 (qdrant up, minio
  up, ollama down — LLM host llm-prod-lt01 unreachable, external outage);
  `/query` pipeline verified through embedding + retrieval, generation fails
  on Ollama connection only
- 2026-08-08 gate result: `/ready` 200 (qdrant up, minio up, ollama up);
  sample `/query` end-to-end PASS — 67 s latency pre-DOCP, re-gated at
  34 s after DOCP 3600 applied on the LLM host
- All changes tracked via ticket and recorded in change log
