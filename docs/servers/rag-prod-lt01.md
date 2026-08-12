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
| **Backup Enabled** | yes                                        |
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

- VM-level backup via PBS (nightly), RPO 24 h / RTO 4 h
- qemu-guest-agent installed for fs-consistent snapshots
- Nightly application-level Qdrant snapshot (cron, 03:30 UTC)

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
