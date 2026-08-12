# Runbook: jol-llm Deployment — llm-prod-lt01 (CPU-only Ollama inference)

> **Scope**: bare-metal llm-prod-lt01 (Ryzen 9 3950X, 64 GB DDR4, 1 TB M.2
> NVMe) at 10.30.30.10/24, VLAN 30 — Ollama inference backend for the
> jol-llm/RAG stack on rag-prod-lt01.
> **Compliance**: SOC 2 Type II / GDPR (EU 2016/679) / ISO 27001:2022.
> **No credentials in this document** — use the secrets manager
> (Vaultwarden on admin01; see `docs/architecture/secret-flow.md`).
> **Reference docs**: `docs/servers/llm-prod-lt01.md` (as-run record),
> `docs/architecture/trust-boundaries.md`, `docs/network/dell-n2048-port-table.md`.
> **Change control**: production changes require a change request via
> `.github/ISSUE_TEMPLATE/infra-change-request.yml` (SOC 2 CC8.1).

## When to Use

- Fresh deployment of the jol-llm inference backend on new hardware.
- DR rebuild of llm-prod-lt01 (target RTO ~4 h per this runbook + Ansible).
- Host re-provisioning after board/CPU/storage replacement.

## Asset Summary

| Item | Value |
|------|-------|
| Host | llm-prod-lt01 — 10.30.30.10/24 (VLAN 30, gateway 10.30.30.1) |
| Hardware | AMD Ryzen 9 3950X (16C/32T), 64 GB DDR4 (2×32 GB Patriot 3600 C18, A2/B2, DOCP 3600), 1000 GB M.2 NVMe (ADATA LEGEND 860) |
| GPU | none — headless by design (3950X has no iGPU; console-blind) |
| Inference | CPU-only (Ollama 0.32.6, 32 threads); no CUDA/ROCm stack |
| OS | Ubuntu 24.04 LTS (bare-metal, GA kernel 6.8, in-tree drivers only) |
| Switch port | Dell N2048 Gi1/0/4 — access VLAN 30, port-security `maximum 1 / violation shutdown` |
| NIC mapping | `enp5s0` Intel I211 (`igb`) — production; `enp4s0` Realtek RTL8125 2.5GbE (`r8125`) — cold spare, unconfigured |
| Service accounts | `jol-ollama` (state owner), `ollama` (runtime; member of `jol-ollama`) |
| Admin access | `jol-admin` + sudo, SSH key-only, from VLAN 10/60 |

### Host Firewall (UFW — default deny incoming, allow outgoing)

| Port  | Service       | Allowed sources            |
|-------|---------------|----------------------------|
| 22    | SSH           | 10.10.10.0/24, 10.60.60.0/24 |
| 11434 | Ollama API    | 10.40.40.0/24 only (AI Services) |
| 9100  | node-exporter | 10.10.10.0/24, 10.60.60.0/24 |

Inter-VLAN enforcement also applies at the MikroTik RB5009 (see
`docs/architecture/trust-boundaries.md`).

---

## Phase 0 — Change control & pre-flight

1. **Change request**: file via `.github/ISSUE_TEMPLATE/infra-change-request.yml`;
   record all work in the server doc change log regardless.
2. **Port-security hazard (blocking)**: Gi1/0/4 carries a sticky MAC with
   `maximum 1 / violation shutdown`. A new NIC MAC **must be cleared/re-learned
   on the port before first link-up**, or the port will violation-shutdown.
   See Phase 1.
3. **Model restore source**: `qwen3:30b` is re-pullable from the registry,
   but the Mistral rollback weights are not (the bare `mistral-7b-instruct`
   tag was removed upstream) and neither is the alias/manifest layout. If
   replacing a live host, export its model store first (Phase 7 procedure).
   On a clean rebuild, restore from pbs01 (namespace `jol-llm`, group
   `host/llm-prod-lt01` — full store incl. the `mistral-7b-instruct`
   alias; client-side encryption key from the password manager).
4. Reachability checks from admin01 (10.10.10.50) where applicable:
   ```bash
   ping -c 3 10.30.30.1                     # VLAN 30 gateway (MikroTik)
   ```
5. **Media note**: any removed disk (e.g. the legacy 320 GB HDD) is
   sensitive media — wipe per sanitization policy before reuse or disposal.

---

## Phase 1 — L2: switch port and cabling

1. Clear/re-learn the sticky MAC on Gi1/0/4 (via `scripts/network/n2048-cli.py`
   or switch CLI), keeping the port in access VLAN 30.
2. Cable the host's production NIC (`enp5s0`) to Gi1/0/4.
3. Verify link Up, MAC learned on VLAN 30, then re-arm port-security with the
   new sticky MAC and save the switch config.

### Exit criteria

- Gi1/0/4 Up, single MAC learned, port-security re-armed, config saved.

---

## Phase 2 — OS baseline (Ubuntu 24.04 LTS)

1. Install Ubuntu 24.04 LTS via Subiquity onto the M.2 NVMe: LVM profile,
   **no LUKS** (risk acceptance recorded in the server doc), hostname
   `llm-prod-lt01`, static network per Subiquity field mapping.
2. Post-install, apply the canonical static netplan (single file; substitute
   the actual NIC name — production NIC is `enp5s0` on the current build):

   ```yaml
   network:
     version: 2
     ethernets:
       enp5s0:
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

3. **Remove `/etc/netplan/50-cloud-init.yaml`** — a cloud-init file alongside
   the static one is a latent DHCP-override hazard (observed on the previous
   host). Only the canonical static file must remain.
4. Extend `ubuntu-lv` to the full VG (Subiquity defaults to 100 G):
   ```bash
   sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
   sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
   ```
5. Swap: keep the 8 G `/swap.img` (within 8–16 G spec); persist SSD-endurance
   tuning in `/etc/sysctl.d/99-jol-vm.conf`:
   `vm.swappiness=10`, `vfs_cache_pressure=50`. Hibernation is deliberately
   not enabled (headless server).
6. Full update pass: `apt update && apt full-upgrade`; confirm running kernel
   equals installed kernel; timezone fleet standard `Europe/Vilnius`
   (`timedatectl set-timezone Europe/Vilnius`).

### Exit criteria

- `ip -br a` shows 10.30.30.10/24 on `enp5s0`; default route via 10.30.30.1.
- `ping 10.30.30.1` succeeds; `df -h /` reflects the full LV; no
  cloud-init netplan file remains.

---

## Phase 3 — Hardware verification

1. **DOCP**: enable DOCP in BIOS so the matched 2×32 GB kit runs at
   3600 MT/s (FCLK 1800, 1:1). Memory bandwidth directly bounds token
   throughput — DOCP cut sample `/query` latency from 67 s to 34 s (~2×).
   Console access requires temporarily installing a GPU (3950X has no iGPU);
   remove it again afterward to restore the headless baseline.
   Verify with `sudo dmidecode -t memory` (speed 3600 MT/s, A2/B2 populated).
2. **Memory policy**: matched pair only (2×32 GB in A2/B2, 1 DPC,
   dual-channel). Never mix kits; JEDEC fallback (2133 MT/s) halves
   effective inference throughput.
3. **Driver policy**: Ubuntu 24.04 GA-kernel in-tree modules only —
   `igb`, `r8125`, `nvme`, `amd64-microcode`. No DKMS/vendor driver
   packages; kernel updates via `unattended-upgrades` are the driver
   update path.
4. Record final hardware (CPU/RAM/NIC MACs) in `docs/servers/llm-prod-lt01.md`
   and `inventory/prod/hosts.yml`.

### Exit criteria

- `dmidecode` confirms 3600 MT/s; `lscpu` shows 16C/32T; NVMe-only disk
  layout; no GPU present.

---

## Phase 4 — Baseline hardening (Ansible)

1. Install the fleet SSH key for `jol-admin`; verify key-auth from admin01.
   (`jol-admin` requires its NOPASSWD sudoers drop-in.)
2. Run the baseline hardening play:
   ```bash
   cd ansible/
   ansible-playbook playbooks/harden-ai-hosts.yml --limit llm
   ```
   Roles applied: `common` (CIS Ubuntu 24.04 L1 subset, auditd, fail2ban,
   unattended-upgrades, sysctl), `time_sync` (chrony), `ssh`
   (key-only drop-in `00-jol-hardening.conf`, LogLevel VERBOSE, 15-min idle
   timeout), `base_firewall` (UFW table above, driven by
   `inventory/prod/host_vars/llm-prod-lt01.yml`), `monitoring`
   (node-exporter). `backup_client` is skipped — bare-metal decision
   (`backup_client_enabled: false` in `group_vars/llm.yml`).
3. Verify UFW: `sudo ufw status verbose` matches the port table; rules live
   in iptables.

### Exit criteria

- Playbook idempotent green run; `ufw status` matches the table; SSH
  password auth disabled; fail2ban sshd jail active.

---

## Phase 5 — Ollama runtime (jol-llm backend)

1. Install Ollama (official script; pin **0.32.6** — record the version in
   the server doc). CPU-only: no GPU detected, no CUDA/ROCm stack.
2. Create the state layout:
   - group `jol-ollama`; user `ollama` is a member of it
   - `/var/lib/jol-ollama` — 750, `jol-ollama:jol-ollama`
   - `/var/lib/jol-ollama/models` — owned by `ollama`
   - `/var/lib/jol-ollama/logs -> /var/log/jol-ollama` (app log dir)
   - `/var/backups/jol-ollama` — 750 (local snapshot staging, Phase 7)
3. Systemd drop-in `/etc/systemd/system/ollama.service.d/jol.conf`:
   ```ini
   [Service]
   Environment="OLLAMA_HOST=0.0.0.0:11434"
   Environment="OLLAMA_MODELS=/var/lib/jol-ollama/models"
   ```
   Then `systemctl daemon-reload && systemctl restart ollama`.
4. **Model install — Path B (preferred): restore from pbs01.**
   Requires `proxmox-backup-client` + credentials from the password
   manager (`/etc/jol-ollama/pbs-token`, `pbs-encryption.key`) — see
   Phase 7. Full store restore (~22 GB, drilled 2026-08-11):
   ```bash
   sudo systemctl stop ollama
   sudo env PBS_PASSWORD_FILE=/etc/jol-ollama/pbs-token \
     PBS_FINGERPRINT=4b:93:a9:7e:0b:9a:89:ee:1a:9f:64:2c:40:e1:8f:3a:4a:91:92:d4:29:ed:f5:a6:1b:1d:b3:26:e6:4c:54:92 \
     PBS_ENCRYPTION_PASSWORD="" \
     proxmox-backup-client restore \
     host/llm-prod-lt01/<snapshot> jol-models.pxar /var/lib/jol-ollama/models \
     --keyfile /etc/jol-ollama/pbs-encryption.key \
     --overwrite true --allow-existing-dirs true \
     --repository "jol-llm-backup@pbs!llm-token@10.10.10.30:pbs-store" \
     --ns jol-llm
   sudo chown -R ollama:ollama /var/lib/jol-ollama
   sudo systemctl start ollama
   ```
   The restore covers the **full store**: all manifests and blobs,
   `qwen3:30b`, the Mistral rollback weights, and the
   `mistral-7b-instruct` alias — no follow-up pull needed. If the
   encryption key is lost, fall back to Path A.
5. **Model install — Path A (only if no export exists)**: pull
   `qwen3:30b` (18 GB Q4_K_M, 30B-A3B MoE, 256K context — the CPU-optimal
   choice for the 3950X; decode is bandwidth-bound and the MoE activates
   only ~3B params/token: measured 19.0 t/s vs 10.0 t/s for Mistral-7B)
   and alias it to match RAG's `OLLAMA_MODEL`:
   ```bash
   ollama pull qwen3:30b
   ollama cp qwen3:30b mistral-7b-instruct
   ```
   Optionally keep `mistral:7b-instruct` (4.4 GB) installed as rollback:
   `ollama cp mistral:7b-instruct mistral-7b-instruct` reverts. Note: the
   bare `mistral-7b-instruct` registry tag no longer exists — the alias
   name is RAG's contract and the export is the authoritative source.
   Qwen3 is a thinking model: `/api/chat` consumers should set
   `think: false` for RAG-style latency.
6. Verify locally: `curl http://127.0.0.1:11434/api/tags` lists the model.

### Exit criteria

- `ollama.service` active; `/api/tags` on 10.30.30.10:11434 returns the
  model; state dir ownership/modes per layout above.

---

## Phase 6 — Observability

1. node_exporter bound to 10.30.30.10:9100. Pin **1.12.1** with SHA256
   verification (values recorded in `inventory/prod/host_vars/llm-prod-lt01.yml`:
   `node_exporter_version: "1.12.1"`, `node_exporter_sha256: b51d8a76...`).
2. Fleet Prometheus (`jol-prometheus`, `prom/prometheus:v2.53.2`, admin01,
   port 9091) scrapes this host's node-exporter — confirm target state `up`.
3. Promtail: staged only (`promtail_enabled: false` in host_vars) until a
   Loki endpoint exists; journald is the current log path for Ollama.
4. Ollama health probe for dashboards/monitoring:
   `curl http://10.30.30.10:11434/api/tags`.

### Exit criteria

- Prometheus target for 10.30.30.10:9100 is `up`; node_exporter version
  matches the pin.

---

## Phase 7 — Backup

Bare-metal decision: no PBS guest-agent backup (`backup_client_enabled: false`).
OS state is reproducible from netplan + `harden-ai-hosts.yml`; the
irreplaceable asset is the model store.

**Design (live since 2026-08-11)**: PBS-native push from the LLM host to
the fleet backup platform pbs01 — same push model pve-prod-hv01 uses for
VM backups. Supersedes the retired admin01 tar.gz flow (2026-08-09..11).

1. Client: `proxmox-backup-client` 3.4.7 from
   `deb http://download.proxmox.com/debian/pbs-client bookworm main`
   (key: `https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg`).
   Note: the client repo is **Debian bookworm** even on Ubuntu 24.04 —
   there is no `ubuntu/` publication.
2. Identity: PBS user `jol-llm-backup@pbs` + API token `llm-token`,
   role `DatastorePowerUser` on `/datastore/pbs-store` granted to **both**
   the user and the token (PBS intersects token privileges with the
   parent user's). Namespace `jol-llm` under datastore `pbs-store`.
   Credentials on the LLM host (600 root, outside the repo):
   `/etc/jol-ollama/pbs-token`, `/etc/jol-ollama/pbs-encryption.key`
   (passphrase-less key, `--kdf none`; key ID `74:f6:4f:c5:a3:75:69:f4`).
   TLS pinned via pbs01 server-cert fingerprint (see `docs/servers/pbs01.md`
   — rotate together with a pbs01 cert renewal).
3. **Automated nightly backup**: root cron on llm-prod-lt01, 03:15, runs
   `/usr/local/sbin/backup-ollama-models.sh`
   (source: `scripts/maintenance/backup-ollama-models.sh`). It stops
   ollama, pushes the **full** model store (~22 GB) as encrypted pxar
   (`jol-models.pxar`, group `host/llm-prod-lt01`, namespace `jol-llm`),
   verifies a new snapshot landed, prunes retention, and restarts ollama
   (guaranteed via trap even on failure). Log:
   `/var/log/jol-ollama-backup.log` (+ cron wrapper log). Full run ≈3 min;
   incremental runs ≈35 s (PBS chunk dedup). Brief Ollama outage during
   the window — RAG `/ready` shows ollama down meanwhile.
4. **Retention**: keep-daily=7, keep-weekly=4 (client-side prune after
   each backup; server-side GC reclaims freed chunks).
5. **Policy**: after any manual model pull/alias change, run the script
   once by hand so the newest weights are backed up immediately.
6. RPO/RTO: model restore < 1 h from pbs01 (drilled 2026-08-11: full
   22 GB restore, manifests diff + blob SHA256 identical); full rebuild
   per this runbook + Ansible (~4 h). Restore steps are Phase 5 step 4.

### Exit criteria

- Snapshot visible on pbs01 (`namespace jol-llm` → `host/llm-prod-lt01`);
  nightly root cron entry installed on llm-prod-lt01; a restore drill has
  been performed and checksums verified (Phase 5 step 4).

---

## Phase 8 — Verification gates (service acceptance)

| # | Gate | Command / check | Expected |
|---|------|-----------------|----------|
| 1 | L3 from host | `ping -c 3 10.30.30.1` on llm | replies |
| 2 | Ollama API from AI segment | from rag-prod-lt01: `curl http://10.30.30.10:11434/api/tags` | model listed |
| 3 | RAG readiness | RAG `/ready` | HTTP 200 — qdrant up, minio up, **ollama up** |
| 4 | End-to-end | sample RAG `/query` (JWT-authenticated) | HTTP 200, latency ≤ 40 s (34 s measured with Mistral-7B post-DOCP; ~2× decode speed expected with qwen3:30b) |
| 5 | Monitoring | Prometheus target | `up` |
| 6 | Firewall | UFW BLOCK log review | no unexpected inbound |

All gates must be GREEN before the change is closed; record results in the
server doc change log.

---

## Gap Remediation & Professional Recommendations

Prioritized findings from the as-run state (2026-08-09 audit):

1. **Timezone drift (remediated 2026-08-09)** — both
   `inventory/prod/group_vars/llm.yml` and `group_vars/ai_services.yml`
   now set `jol_timezone: "Europe/Vilnius"`, matching the fleet standard
   and the hosts, so Ansible runs can no longer re-drift any host to UTC.
2. **Model-store backup automation** — RESOLVED 2026-08-09 (admin01 tar.gz),
   **REPLACED 2026-08-11** by PBS-native push to pbs01: nightly root cron
   on llm-prod-lt01 runs `scripts/maintenance/backup-ollama-models.sh`
   (client-side encrypted pxar push, snapshot verification, retention
   keep-daily=7/keep-weekly=4; restore drill passed 2026-08-11). See Phase 7.
3. **Ollama version pin in inventory** — RESOLVED 2026-08-09:
   `inventory/prod/host_vars/llm-prod-lt01.yml` now pins
   `ollama_version: "0.32.6"` plus `llm_model: "qwen3:30b"`,
   `llm_model_alias` and `llm_model_rollback`, consistent with the
   node_exporter pin, so rebuilds are reproducible from inventory.
4. **Alerting gap** — Prometheus scrapes the host but no alert rules cover
   it. Add minimal rules on the admin01 Prometheus: node-exporter target
   down, `ollama.service` unit inactive (node_exporter systemd collector),
   disk > 85 % on `/`.
5. **Promtail/Loki** — stays staged (`promtail_enabled: false`) until a Loki
   endpoint is provisioned. Intentional; no action.
6. **Media sanitization** — the removed legacy 320 GB HDD is retained as
   sensitive media; track its wipe per sanitization policy before reuse or
   disposal.
7. **Inventory reconciliation** — `inventory/prod/hosts.yml` declares
   `backup_enabled: true` for the host while `group_vars/llm.yml` sets
   `backup_enabled: false` (deliberate bare-metal decision; OS state is
   reproducible, model store covered by the offline export). Keep the
   distinction documented to avoid audit confusion.

---

## Rollback / DR

- **Model-only failure**: stop ollama, restore the newest snapshot from
  pbs01 (Phase 5 step 4), start ollama, re-run gates 2–4. RTO < 1 h.
- **Host loss**: rebuild from Phase 1 onward; model restore from pbs01
  (PBS credentials must be recovered from Vaultwarden/pbs01 records —
  without `/etc/jol-ollama/pbs-token` + `pbs-encryption.key` the store
  is unreadable); target RTO ~4 h. The RAG stack degrades gracefully — `/ready` reports
  ollama down while embedding/retrieval keep working (observed 2026-08-07).
- **Risk acceptance**: single NVMe, no LUKS at rest. Confidentiality
  relies on host firewall + VLAN segmentation and the "no secrets on this
  host" policy (Vaultwarden lives on admin01). Model weights are
  organisational data — revisit LUKS if data-classification requirements
  change.

---

## Change History (as-run seeding)

| Date       | Event |
|------------|-------|
| 2026-08-08 | Bare-metal rebuild commissioned: Ubuntu 24.04 LTS, hardening + UFW, Ollama 0.32.6 CPU-only, mistral-7b-instruct, gates GREEN |
| 2026-08-08 | DOCP 3600 enabled — `/query` latency 67 s → 34 s; model store exported to admin01 (6.3 GB); residual risks from issue #26 closed |
| 2026-08-09 | Timezone aligned to Europe/Vilnius; file-structure audit passed; `ubuntu-lv` extended to 914 G; OS patched; node_exporter 1.12.1 pinned |
| 2026-08-09 | This deployment runbook created from the as-run record |
| 2026-08-09 | Full deployment re-verified GREEN from admin01 (gates 1–3, 5–6); automated nightly model-store backup deployed and test-run OK (`scripts/maintenance/backup-ollama-models.sh`, cron 03:15 on admin01) |
| 2026-08-09 | Model migration Mistral-7B → qwen3:30b (30B-A3B MoE): registry pull, decode benchmark 19.0 vs 10.0 t/s, alias `mistral-7b-instruct` re-pointed (RAG unchanged), Mistral retained as rollback, RAG readiness gates GREEN, fresh model-store export, inventory pins added (`ollama_version`, `llm_model*`) |
| 2026-08-11 | Backup migrated admin01 tar.gz → pbs01 (PBS-native): `proxmox-backup-client` 3.4.7 on the LLM host, dedicated user/token + namespace `jol-llm`, client-side encryption, nightly root cron 03:15, retention 7d/4w, full-store restore drill PASSED (22 GB, SHA256-verified); admin01 storage role retired (archives + cron removed) |
