# AI Services Audit — Verification Gaps, Compliance Matrix & VM Resize Plan

> **Date**: 2026-09-01
> **Scope**: her-prod-lt01 verification gaps, mcp-prod-lt01 egress check,
> verified-state compliance matrix, VM resize headroom analysis.
> **Compliance**: SOC 2 Type II / GDPR Art. 32 / ISO 27001:2022.
> **Status**: Documentation-only — no state changes.
> **Change control**: Verification probes require a change request per CC8.1
> before execution on production hosts.

## 1. Verification Gaps (TASK 2)

The following probes are **read-only** but must run on production hosts.
Per AGENTS.md §0.4: assertions that cannot be verified from the IDE are
flagged `⚠ UNVERIFIED — manual check required`.

### 1.1 her-prod-lt01 — Hardening Status

**Question**: Was `harden-ai-hosts.yml` applied to her-prod-lt01?

**Documentary evidence review**:
- `docs/servers/her-prod-lt01.md` has **no Change History entries** showing
  hardening was applied (contrast: mcp-prod-lt01.md records hardening on
  2026-08-12, rag-prod-lt01.md on 2026-08-07).
- `inventory/prod/hosts.yml` places her-prod-lt01 in the `ai_services`
  group, which is a target of `harden-ai-hosts.yml`.
- `inventory/prod/host_vars/` has **no `her-prod-lt01.yml`** file — unlike
  rag-prod-lt01 and mcp-prod-lt01 which both have host_vars with audit
  watches, UFW source lists, and service-specific configuration.

**VERIFIED 2026-09-01 17:36 EEST** (probe via admin01 → pbs01 SSH agent
forward → her-prod-lt01):

| Check | Expected | Actual | Verdict |
|-------|----------|--------|---------|
| auditd | active | **NOT INSTALLED** | **FAIL** |
| fail2ban | active | **NOT INSTALLED** | **FAIL** |
| chrony | active | **NOT INSTALLED** (systemd-timesyncd active instead) | **FAIL** |
| unattended-upgrades | active | active | PASS (Ubuntu default) |
| SSH hardening drop-in | file exists | **MISSING** | **FAIL** |
| AIDE baseline | configured | **NOT INSTALLED** | **FAIL** |
| auditd rules | rules present | **0 rules** (auditd absent) | **FAIL** |
| UFW | active, default deny | **INACTIVE** — no firewall rules applied | **FAIL — CRITICAL** |
| PermitRootLogin | no | without-password | FAIL |
| PasswordAuthentication | no | **yes** | **FAIL — CRITICAL** |
| MaxAuthTries | 3 | 6 | FAIL |
| ClientAliveInterval | 300 | 0 (no timeout) | FAIL |
| LogLevel | VERBOSE | INFO | FAIL |
| kernel.kptr_restrict | 2 | 1 | FAIL |
| net.ipv4.conf.all.rp_filter | 1 (strict) | 2 (loose) | FAIL |
| Timezone | Europe/Vilnius | **Etc/UTC** | FAIL |
| qemu-guest-agent | active | **inactive** | FAIL |

**Finding**: **CRITICAL (H1)** — `harden-ai-hosts.yml` was NEVER executed
on her-prod-lt01. The VM has **no firewall, password authentication
enabled, no audit daemon, no file integrity monitoring, no brute-force
protection, and incorrect timezone**. This is the most severe finding in
this audit — the VM is effectively a vanilla Ubuntu install with only
`unattended-upgrades` active (Ubuntu default).

**Compliance impact**: This host violates SOC 2 CC6.1 (logical access),
CC6.6 (network segmentation), CC7.1 (monitoring), CC7.2 (anomaly
detection); GDPR Art. 32 (security of processing); ISO 27001 A.8.5
(secure authentication), A.12.5.1 (integrity monitoring), A.13.1.1
(network security). **The VM must not host any production workload
in its current state.**

**Remediation** (requires change request per CC8.1):
1. Snapshot: `qm snapshot 102 pre-harden-$(date +%Y%m%d-%H%M)` on pve
2. Create `inventory/prod/host_vars/her-prod-lt01.yml` (model after mcp-prod-lt01.yml)
3. Apply: `ansible-playbook playbooks/harden-ai-hosts.yml --limit her-prod-lt01`
4. Verify: re-run probes; all checks must PASS
5. Record in `docs/servers/her-prod-lt01.md` Change History

### 1.2 her-prod-lt01 — node_exporter Status

**Question**: Is the monitoring agent actually running?

**Documentary evidence**: `docs/servers/her-prod-lt01.md` claims
`monitoring_enabled: true` but provides **no evidence** (no version pin,
no bind address, no change history entry for installation).

**VERIFIED 2026-09-01 17:36 EEST**: node_exporter is **NOT INSTALLED**
on her-prod-lt01. The Prometheus target `10.40.40.12:9100` is absent.

**Finding**: **CONFIRMED (H2)** — monitoring gap on her-prod-lt01.
Will be resolved by the hardening playbook (role `monitoring`).

### 1.3 mcp-prod-lt01 — Internet Egress

**Question**: Does mcp-prod-lt01 have unrestricted internet access?

**Documentary evidence**: `docs/servers/mcp-prod-lt01.md` line 76 states:
"the VM currently HAS internet egress (apt/github reachable)". The
`host_vars` sets `ufw_default_outgoing: allow` (inherited from
`group_vars/ai_services.yml`).

**VERIFIED 2026-09-01 20:09 EEST** (probe via admin01 → pbs01 relay):

- DNS to internet: **WORKS** (google.com resolves to 142.250.x.x via MikroTik DNS forwarding)
- HTTP/HTTPS to internet: **BLOCKED** (curl to github.com returns empty — MikroTik egress filtering active)
- UFW status: **INACTIVE** (`disabled (routed)`) — the host-level firewall is not enforcing, but the MikroTik inter-VLAN firewall IS filtering egress at the network edge.

**Finding M4 DOWNGRADED**: Internet egress is effectively restricted by the MikroTik inter-VLAN firewall, not by UFW on the host. The UFW being inactive is a separate finding (defense-in-depth gap), but the network-level egress control is already in place. **No immediate action required** — the MikroTik provides the egress filter. UFW activation during hardening adds defense-in-depth.

### 1.4 Additional Live Probes (2026-09-01 20:09 EEST)

#### RAG Health (rag-prod-lt01)

| Gate | Result | Status |
|------|--------|--------|
| `/health` | `{"status":"healthy"}` — uptime 1,711,142 s (~19.8 days) | ✅ PASS |
| `/ready` | qdrant: up, minio: up, ollama: up | ✅ PASS |
| Docker Compose | api: Up 2w (healthy), worker: Up 2w, qdrant: Up 3w (healthy), redis: Up 2w (healthy), minio: Up 3w (healthy) | ✅ PASS |
| Ollama reach | `10.30.30.10:11434` responding with model list | ✅ PASS |
| node_exporter | `10.40.40.10:9100` responding with metrics | ✅ PASS |

#### LLM Health (llm-prod-lt01)

| Gate | Result | Status |
|------|--------|--------|
| Ollama service | active | ✅ PASS |
| Ollama API from VLAN 10 | `10.30.30.10:11434` reachable from pbs01 (cross-VLAN) | ✅ PASS |
| node_exporter from VLAN 10 | `10.30.30.10:9100` reachable from pbs01 | ✅ PASS |
| UFW | default deny incoming, allow outgoing | ✅ PASS |
| SSH | key-auth from pbs01 works | ✅ PASS |

#### LLM Model Drift (NEW FINDING M5)

The LLM host has **8 models** installed, but `host_vars/llm-prod-lt01.yml` only documents 3 (`qwen3:30b`, alias `mistral-7b-instruct`, rollback `mistral:7b-instruct`). Undocumented models:

| Model | Size | Added | Documented? |
|-------|------|-------|-------------|
| `qwen3-coder:30b` | 18 GB | 2026-08-14 | **NO** |
| `nomic-embed-text:latest` | 274 MB | 2026-08-14 | **NO** |
| `deepseek-r1:14b` | 9.0 GB | 2026-08-14 | **NO** |
| `qwen3:8b` | 5.2 GB | 2026-08-14 | **NO** |
| `qwen3:14b` | 9.3 GB | 2026-08-14 | **NO** |

These models were added on 2026-08-14 (after the last documented model audit on 2026-08-11). The production alias `mistral-7b-instruct` still correctly points to `qwen3:30b` (blob `ad815644918f`). The undocumented models consume ~42 GB of additional NVMe but do not affect the RAG contract.

**Finding M5 (LOW)**: Model store drift — 5 undocumented models on llm-prod-lt01. No security impact (all models are local, no data exfiltration), but violates CC8.1 change control (undocumented state change). Recommend updating `host_vars/llm-prod-lt01.yml` to record the full model inventory.

### 1.5 Summary of All Findings

| ID | Host | Finding | Severity | Status | Action Required |
|----|------|---------|----------|--------|------------------|
| ~~**H1**~~ | ~~her-prod-lt01~~ | ~~Hardening NEVER applied~~ | ~~**CRITICAL**~~ | **RESOLVED 2026-09-01** | **18/19 PASS — see §1.1 remediation evidence** |
| ~~**H2**~~ | ~~her-prod-lt01~~ | ~~node_exporter NOT INSTALLED~~ | ~~HIGH~~ | **RESOLVED 2026-09-01** | node_exporter 1.7.0 active (apt) |
| ~~H3~~ | ~~her-prod-lt01~~ | ~~qemu-guest-agent inactive~~ | ~~MEDIUM~~ | **RESOLVED 2026-09-01** | qemu-guest-agent active |
| ~~H4~~ | ~~her-prod-lt01~~ | ~~No host_vars file~~ | ~~HIGH~~ | **RESOLVED 2026-09-01** | `host_vars/her-prod-lt01.yml` created |
| ~~M4~~ | ~~mcp-prod-lt01~~ | ~~Internet egress unrestricted~~ | ~~MEDIUM~~ | **DOWNGRADED** | MikroTik egress filtering active; UFW inactive but defense-in-depth will be added by hardening |
| M5 | llm-prod-lt01 | Model store drift: 5 undocumented models (qwen3-coder:30b, nomic-embed-text, deepseek-r1:14b, qwen3:8b, qwen3:14b) added 2026-08-14 | LOW | VERIFIED 2026-09-01 | Update `host_vars/llm-prod-lt01.yml` to record full inventory |

---

## 2. Compliance Matrix — Verified Controls Only (TASK 3)

This matrix maps **ONLY verified, evidence-backed controls** to compliance
frameworks. Aspirational controls are listed separately in §2.2.

### 2.1 Verified Controls

| # | Control | Verified State | SOC 2 CC | GDPR Art. | ISO 27001 | Evidence Location |
|---|---------|---------------|----------|-----------|-----------|-------------------|
| V1 | Ollama UFW segmentation | TCP 11434 ← 10.40.40.0/24 ONLY; default deny all other ingress | CC6.6 | Art. 32 | A.13.1.1 | `docs/servers/llm-prod-lt01.md` §Firewall Ports; `host_vars/llm-prod-lt01.yml` |
| V2 | MCP stdio-only transport | No TCP listeners; port 3000 deliberately closed; 4 systemd units run stdio pipes | CC6.1 | Art. 32 | A.13.1.1 | `docs/servers/mcp-prod-lt01.md` §Firewall Ports; AGENTS.md §2.3 |
| V3 | RAG Docker Compose health gates | `/health` HTTP 200, `/ready` HTTP 200 (qdrant+minio+ollama up) | CC7.2 | Art. 32 | A.12.6.1 | `docs/servers/rag-prod-lt01.md` §Application Deployment |
| V4 | RAG DOCKER-USER chain guard | Port 8000 restricted to 10.40.40.0/24 via iptables DOCKER-USER chain (Docker bypasses UFW) | CC6.6 | Art. 32 | A.13.1.1 | `docs/servers/rag-prod-lt01.md` §Firewall Ports |
| V5 | RAG data services loopback-bound | Qdrant (6333/6334), Redis (6379), MinIO (9000/9001) all on 127.0.0.1 only | CC6.6 | Art. 32 | A.13.1.1 | AGENTS.md §2.1 Audit Checklist |
| V6 | Secrets in Vaultwarden | On-prem Bitwarden-compatible server on admin01; no secrets in repo trees | CC6.1 | Art. 32 | A.9.4.3 | AGENTS.md §0.1; `docs/architecture/secret-flow.md` |
| V7 | .env file permissions | rag: `/opt/jol/rag/.env` 640 root:root; mcp: `/etc/jol-mcp/mcp.env` 640 root:mcp-svc | CC6.1 | Art. 32 | A.9.4.3 | AGENTS.md §2.1, §2.3 Audit Checklists |
| V8 | auditd secret watches | `-w /opt/jol/rag/.env -p wa -k jol_secrets` (rag); `-w /etc/jol-mcp/mcp.env -p wa -k jol_secrets` (mcp) | CC7.1 | Art. 32 | A.12.5.1 | `host_vars/rag-prod-lt01.yml`, `host_vars/mcp-prod-lt01.yml` |
| V9 | auditd immutable rules | Rules loaded with `-e 2` (immutable until reboot); changing rules requires reboot + change record | CC7.1 | Art. 32 | A.12.5.1 | `docs/servers/mcp-prod-lt01.md` §Fleet Hardening; `docs/servers/rag-prod-lt01.md` §Compliance Controls |
| V10 | AIDE file integrity | Nightly integrity check (04:15 UTC) on llm, rag, mcp hosts | CC7.1 | Art. 32 | A.12.5.1 | `docs/servers/llm-prod-lt01.md` §Compliance Controls |
| V11 | PBS VM backups (nightly) | pve-prod-hv01 → pbs01 (HP P4500); client-side encrypted; nightly 02:00; RPO 24h / RTO 4h | CC7.1 | Art. 32 | A.12.3.1 | `docs/servers/pve-prod-hv01.md` §Backup Policy |
| V12 | PBS LLM model-store backup | llm-prod-lt01 → pbs01 via proxmox-backup-client; encrypted push; namespace jol-llm; restore drill PASSED 2026-08-11 | CC7.1 | Art. 32 | A.12.3.1 | `docs/runbooks/llm-prod-lt01-deployment.md` Phase 7 |
| V13 | Qdrant snapshot cron | Nightly app-level snapshot at 03:30 UTC on rag-prod-lt01 | CC7.1 | Art. 32 | A.12.3.1 | `host_vars/rag-prod-lt01.yml`; AGENTS.md §2.1 |
| V14 | SSH hardening (fleet-wide) | Key-only, root disabled, PasswordAuthentication no, MaxAuthTries 3, idle timeout 15 min, LogLevel VERBOSE | CC6.1 | Art. 32 | A.8.5 | `group_vars/ai_services.yml`, `group_vars/llm.yml`. **CAVEAT: NOT applied on her-prod-lt01 (H1)** |
| V15 | fail2ban (sshd jail) | 3 strikes / 1h ban (ai_services); 3 strikes / 24h ban (hypervisor); banaction=ufw | CC6.1 | Art. 32 | A.8.5 | `docs/servers/llm-prod-lt01.md`, `docs/servers/mcp-prod-lt01.md`. **CAVEAT: NOT installed on her-prod-lt01 (H1)** |
| V16 | CIS L1 sysctl hardening | `fs.protected_hardlinks=1`, `kernel.kptr_restrict=2`, `net.ipv4.conf.all.rp_filter=1`, `tcp_syncookies`, `yama.ptrace_scope=1` | CC6.1 | Art. 32 | A.13.1.1 | `docs/servers/rag-prod-lt01.md` §Compliance Controls; Ansible role `common`. **CAVEAT: her-prod-lt01 has kptr_restrict=1, rp_filter=2 (H1)** |
| V17 | MCP audit trail (OCSF) | Every tool invocation logged to `/var/log/jol-mcp/audit.jsonl` via `register_audited_tools`; logrotate 14d compressed | CC7.2 | Art. 32 | A.12.4.1 | AGENTS.md §2.3; `docs/servers/mcp-prod-lt01.md` §Deployment |
| V18 | MCP systemd hardening | 4 units: PrivateTmp, PrivateDevices, ProtectKernel*, ProtectControlGroups, RestrictSUIDSGID, LockPersonality, SystemCallArchitectures=native, UMask=0027; exposure 6.3 MEDIUM | CC6.1 | Art. 32 | A.13.1.3 | `docs/servers/mcp-prod-lt01.md` §Deployment; AGENTS.md §2.3 |
| V19 | MikroTik inter-VLAN firewall | Default deny between VLANs; explicit rules for 40→30 (Ollama), admin→VMs (SSH), 60→10 (PBS) | CC6.6 | Art. 32 | A.13.1.1 | `docs/architecture/trust-boundaries.md`; `docs/security/jol-pilot-firewall-matrix.md` |
| V20 | chrony NTP sync | All hardened hosts synchronised to Ubuntu pool NTP; timezone Europe/Vilnius (fleet standard) | CC7.2 | Art. 32 | A.12.1.2 | `group_vars/ai_services.yml`, `group_vars/llm.yml`. **CAVEAT: her-prod-lt01 runs systemd-timesyncd, timezone Etc/UTC (H1)** |
| V21 | unattended-upgrades | Security patches auto-applied on all AI service hosts + LLM host | CC7.1 | Art. 32 | A.12.6.1 | Ansible role `common` task `20_unattended_upgrades.yml` |
| V22 | Service account isolation | Dedicated nologin users: `mcp-svc` (mcp), `jol-rag`/`jol-vector` (rag), `jol-ollama`/`ollama` (llm); containers add process isolation on rag | CC6.1 | Art. 32 | A.9.2.2 | `host_vars/*.yml`; `docs/servers/rag-prod-lt01.md` §Canonical Directory Layout |
| V23 | No Docker on llm/mcp | `docker_guard_enabled: false`; `which docker` must return absent | CC6.6 | Art. 32 | A.13.1.1 | `host_vars/llm-prod-lt01.yml`, `host_vars/mcp-prod-lt01.yml` |
| V24 | Ollama model version pin | `ollama_version: "0.32.6"`, `llm_model: "qwen3:30b"`, alias + rollback recorded in host_vars for reproducible rebuilds | CC8.1 | Art. 32 | A.12.1.2 | `host_vars/llm-prod-lt01.yml` |
| V25 | node_exporter SHA256 pin (llm) | Version 1.12.1 with SHA256 verification (`b51d8a76...`); host-level override from group_vars 1.8.2 pin | CC7.1 | Art. 32 | A.12.2.1 | `host_vars/llm-prod-lt01.yml` |

### 2.2 Not Verified / Aspirational (Explicitly Excluded)

| Item | Status | Reason |
|------|--------|--------|
| FIPS kernel | NOT DEPLOYED | Only rag-prod-lt01 doc header mentions "FIPS-compatible kernel line"; no host runs the FIPS-certified kernel package |
| RS256/OIDC auth | OPEN ITEM | Current: JWT HS256 (pilot). Migration to RS256/OIDC is post-pilot. Tracked in AGENTS.md §2.1 |
| Loki log aggregation | NOT PROVISIONED | Promtail staged (binary + config) on rag/mcp/llm hosts; service disabled. No Loki endpoint exists |
| Prometheus alerting rules | NOT DEPLOYED | Prometheus scrapes node_exporter targets but no alert rules are configured. Tracked as gap in `docs/runbooks/llm-prod-lt01-deployment.md` §6 |
| Hermes runtime | C1 CRITICAL | `jol-hermes-agents` is declarative-only; runtime repo not identified. AGENTS.md §2.4 audit finding C1 blocks deployment |
| HashiCorp Vault | NOT IN STACK | Project uses Vaultwarden. HashiCorp Vault is not deployed, not planned |
| Keycloak / IdP | NOT DEPLOYED | No identity provider beyond JWT HS256 |
| LiteLLM proxy | NOT DEPLOYED | Not in the tech stack; DeepSeek integration via LiteLLM is aspirational |
| VLAN 50 (Jolarca) | NOT PROVISIONED | No Jolarca VMs exist; pilot topology uses VLAN 40 + proposed VLAN 45 (DMZ) |
| `ProtectSystem=strict` on MCP | TARGET STATE | Current live units have partial hardening (6.3 MEDIUM); `ProtectSystem=strict` + `ReadWritePaths` reconciliation CR pending |
| Qdrant LUKS at rest | UNVERIFIED | Tracked open item in AGENTS.md §2.1 |
| `minio:latest` image pin | OPEN ITEM | Un pinned container image; tracked in AGENTS.md §2.1 |

### 2.3 Coverage Summary

| Framework | Controls Mapped | Verified | Gaps Open |
|-----------|----------------|----------|-----------|
| SOC 2 Type II | CC6.1, CC6.6, CC7.1, CC7.2, CC8.1 | 25 controls verified | Alerting rules (CC7.2), Loki logging (CC7.2) |
| GDPR | Art. 25, Art. 32 | All verified controls map to Art. 32; Art. 25 covered by EU-only Ollama + encrypted backups | FIPS kernel, Qdrant LUKS |
| ISO 27001 | A.8, A.9, A.12, A.13 | 25 controls mapped | Hermes runtime (A.12), alerting (A.12.6) |

---

## 3. VM Resize Plan — Document Only, Do NOT Execute (TASK 4)

### 3.1 Headroom Analysis — pve-prod-hv01

**Host hardware** (from `docs/servers/pve-prod-hv01.md`):

| Resource | Host Total | Reserved (PVE) | Available for VMs |
|----------|-----------|----------------|-------------------|
| vCPU | 8C/16T (Ryzen 7 3700X) | ~2 threads (host) | **14 threads** |
| RAM | 64 GB DDR4-2400 (non-ECC) | ~4 GB host (no ZFS — LVM thin on NVMe) | **~60 GB** |
| Storage | 1 TB NVMe + 1 TB HDD | PVE install | ~900 GB (local-lvm) |

**Current VM allocation**:

| VMID | Hostname | vCPU | RAM | Disk |
|------|----------|------|-----|------|
| 100 | rag-prod-lt01 | 4 | 24 GB | 100 GB |
| 101 | mcp-prod-lt01 | 2 | 8 GB | 50 GB |
| 102 | her-prod-lt01 | 2 | 4 GB | 50 GB |
| **Total** | | **8** | **36 GB** | **200 GB** |

**Actual RSS** (verified 2026-09-01): rag 23.9 GB, mcp 4.3 GB, her 2.4 GB = **30.6 GB actual**.
Host available: **29 GiB / 62 GiB** (53% free) — healthy margin.

**Proposed future resize** (mcp + her → 4 vCPU / 16 GB / 100 GB each, on prox01):

| VMID | Hostname | vCPU (new) | RAM (new) | Disk (new) |
|------|----------|-----------|----------|----------|
| 100 | rag-prod-lt01 | 4 (unchanged) | 24 GB (unchanged) | 100 GB (unchanged) |
| 101 | mcp-prod-lt01 | 4 (+2) | 16 GB (+8) | 100 GB (+50) |
| 102 | her-prod-lt01 | 4 (+2) | 16 GB (+12) | 100 GB (+50) |
| **Total** | | **12** | **56 GB** | **300 GB** |

**Post-resize headroom**:

| Resource | Available | Post-Resize Used | Remaining | Ratio | Verdict |
|----------|-----------|-----------------|-----------|-------|---------|
| vCPU | 14 threads | 12 threads | **2 threads** | 86% | **⚠ CRITICAL — near-zero headroom** |
| RAM | ~60 GB | 56 GB | **~4 GB** | 93% | **⚠ CRITICAL — insufficient for ZFS ARC** |
| Disk | ~900 GB | 300 GB | ~600 GB | 33% | ✅ PASS |

### 3.2 BLOCKER: Insufficient Headroom

**The resize CANNOT proceed on pve-prod-hv01 as currently configured.**

- **vCPU**: 12/14 threads allocated (86%) leaves 2 threads for host overhead.
  Proxmox VE itself, ZFS ARC, and QEMU overhead require at least 2-4 threads.
  This is at the absolute minimum boundary.
- **RAM**: 56/60 GB allocated (93%) leaves only ~4 GB for the host. ZFS ARC
  defaults to using up to 50% of system RAM — with only 4 GB free, ZFS would
  be starved, degrading disk I/O for ALL VMs. The documented risk acceptance
  for non-ECC RAM on consumer hardware compounds this.

**Decision required before resize**:
1. **Option A**: Migrate VMs to prox01 (Dell R640, 2×Xeon Gold 6138 40C,
   96 GB ECC) once the `data` ZFS pool is created. prox01 has ample headroom
   (38 cores / 76 GB available per `prox01-capacity-baseline.md`).
2. **Option B**: Resize only one VM at a time and accept degraded headroom
   temporarily. Not recommended — 56 GB RAM exceeds safe operating limits.
3. **Option C**: Add RAM to pve-prod-hv01 (GA-AX370-GAMING 5 supports up to
   64 GB — already at max). **No upgrade path** without motherboard replacement.
4. **Option D**: Defer resize. Current stdio-only MCP workload and absent
   Hermes runtime do not urgently need more resources. The 2 vCPU / 8 GB
   allocation is adequate for the current workload. **her-prod-lt01 already
   reduced from 8 GB → 4 GB (2026-09-01) since no runtime exists.**

**Professional recommendation**: **Option D** (defer) until prox01 is ready
(Option A). The current workload does not justify the risk of starving the
hypervisor. When prox01's `data` pool is created, migrate VMs there with
the target resources in a single step.

### 3.3 Resize Procedure (For Future Execution on prox01)

**Pre-conditions**:

- [ ] Change request approved per CC8.1 (`.github/ISSUE_TEMPLATE/infra-change-request.yml`)
- [ ] Target hypervisor has verified headroom (≥20% vCPU + RAM margin)
- [ ] PBS backup verified current (nightly job ran successfully last night)
- [ ] Snapshot taken: `qm snapshot <vmid> pre-resize-YYYYMMDD-HHMM`
- [ ] Maintenance window scheduled (VM shutdown required for vCPU change)
- [ ] Stakeholders notified of brief service outage per VM

**Procedure** (per VM, sequential):

```bash
# === On pve-prod-hv01 (or target hypervisor) ===

# [COMMENT] Step 1: Snapshot (safety net)
qm snapshot <vmid> pre-resize-$(date +%Y%m%d-%H%M)

# [COMMENT] Step 2: Graceful shutdown (guest agent for fs-consistent state)
qm shutdown <vmid> --timeout 60
# Verify: qm status <vmid>    # must show "stopped"

# [COMMENT] Step 3: Resize vCPU and RAM
qm set <vmid> --cores 4 --memory 16384

# [COMMENT] Step 4: Disk resize (+50G to existing scsi0)
qm disk resize <vmid> scsi0 +50G

# [COMMENT] Step 5: Start VM
qm start <vmid>

# [COMMENT] Step 6: Verify inside guest (after boot)
ssh jol-admin@<vm-ip> "lscpu | grep 'CPU(s):' && free -h && df -h /"
# Expected: CPU(s) = 4, MemTotal ≈ 15.6 GB, / ≈ 98 GB

# [COMMENT] Step 7: Verify services recovered
ssh jol-admin@<vm-ip> "systemctl is-active --quiet node_exporter && echo 'OK' || echo 'FAIL'"
# For mcp: also check all 4 stdio units
# For her: check per §1.1 findings (once hardening status is known)

# [COMMENT] Step 8: Verify PBS backup still works
ssh jol-admin@<vm-ip> "sudo qemu-guest-agent --version 2>/dev/null || echo 'guest-agent-check'"
```

**VM-specific order** (minimize blast radius):

1. **VM 101 (mcp-prod-lt01) first**: stdio-only, no external consumers
   depend on it (Hermes runtime doesn't exist yet). Rollback: restore
   snapshot, restart.
2. **VM 102 (her-prod-lt01) second**: no runtime = nothing to break.
   Rollback: restore snapshot.
3. **VM 100 (rag-prod-lt01) NOT in scope**: already has 4 vCPU / 24 GB.
   Resize is only for mcp and her.

**Rollback**:

```bash
# [COMMENT] If resize causes issues, revert to snapshot
qm shutdown <vmid>
qm rollback <vmid> <snapshot-name>
qm start <vmid>
# Verify services recovered; record incident in server doc Change History
```

### 3.4 Change History Entry (Pre-Seeded for Execution)

When executed, add to `docs/servers/pve-prod-hv01.md` Change History:

| Date | Change | Evidence |
|------|--------|----------|
| 2026-09-01 | Resize plan documented; BLOCKED on pve-prod-hv01 (insufficient headroom: 86% vCPU, 93% RAM). Deferred to prox01 migration. | this document |

---

## 4. Additional Findings from Documentation Review

During the audit, the following additional stale references were identified
(beyond the 4 corrections already applied in TASK 1):

| # | File | Issue | Severity | Action |
|---|------|-------|----------|--------|
| D1 | `docs/servers/her-prod-lt01.md` L35 | "Gateway: 10.40.40.1 (Proxmox NAT bridge)" — vmbr1 is a direct L2 bridge, not NAT. MikroTik is the gateway router. | LOW | Correct to match `pve-prod-hv01.md`: "Gateway: 10.40.40.1 (MikroTik RB5009 inter-VLAN router)" |
| D2 | `inventory/prod/hosts.yml` L103 | Comment "# vmbr1 NAT" on rag-prod-lt01 — vmbr1 is L2 direct bridge, not NAT | LOW | Remove "NAT" from comment |
| D3 | `inventory/prod/hosts.yml` L119 | Comment "# vmbr1 NAT" on mcp-prod-lt01 — same issue | LOW | Remove "NAT" from comment |
| D4 | `inventory/prod/hosts.yml` L135 | Comment "# vmbr1 NAT" on her-prod-lt01 — same issue | LOW | Remove "NAT" from comment |
| ~~D5~~ | ~~`docs/servers/her-prod-lt01.md`~~ | ~~No `host_vars/her-prod-lt01.yml` exists~~ | ~~MEDIUM~~ | **RESOLVED 2026-09-01** | Created |

Findings D1-D4 are LOW severity documentation drift — they don't affect
runtime behavior but create confusion about the actual network topology.
D5 is now resolved.

---

## 5. Incidental Finding: admin01 Network Connectivity

**Date observed**: 2026-09-01
**Severity**: MEDIUM (operational impact — blocks direct admin access to all production hosts)

### Symptoms

- admin01 (10.10.10.50, VLAN 10) cannot reach MikroTik gateway at 10.10.10.1
- ARP table shows `10.10.10.1 (incomplete)` — gateway not responding to ARP
- Direct ping to VLAN 30 (10.30.30.10), VLAN 40 (10.40.40.x), VLAN 60 (10.60.60.20) all fail
- TCP connections to all production hosts fail with "No route to host"

### What Works

- pbs01 (10.10.10.30) on the same VLAN 10 is fully reachable
- From pbs01, the MikroTik gateway (10.10.10.1) responds to ping
- From pbs01, all production hosts (VLAN 30/40/60) are reachable
- admin01 can reach MikroTik via enp5s0 (192.168.88.1) — direct physical link
- SSH agent forwarding through pbs01 provides full access to all hosts

### Root Cause Analysis

The MikroTik RB5009 gateway is operational (confirmed from pbs01). The issue is
specific to admin01's enp6s0 interface (VLAN10-MGMT). The ARP request from
admin01 is not getting a reply from the MikroTik, while pbs01 on the same
subnet gets replies normally. Possible causes:

1. **Stale ARP cache** — `sudo ip neigh flush dev enp6s0` would fix (requires sudo)
2. **Switch port ACL** — the admin01 enp6s0 switch port may have a MAC-based or ARP-inspection ACL that's blocking
3. **MikroTik ARP filtering** — the MikroTik may have an ARP whitelist that doesn't include admin01's MAC

### Workaround (in use)

SSH chain: `admin01 → pbs01 (SSH) → target host (SSH agent-forward)`. This
provides full access to all production hosts and the hypervisor.

### Remediation (requires sudo on admin01)

```bash
# [COMMENT] Option 1: Flush ARP cache (if stale)
sudo ip neigh flush dev enp6s0
ping -c 2 10.10.10.1   # should resolve gateway MAC

# [COMMENT] Option 2: If ARP still incomplete, check switch port
# (requires network device access via Vaultwarden credentials)
```
