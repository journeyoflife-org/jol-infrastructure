# Runbook: JOL Pilot Lithuania — Acceptance Gate (Go / No-Go)

> **Status**: TEMPLATE — executed once at pilot go-live; re-executed after
> any major change to the pilot estate.
> **Date**: 2026-08-23 (authored)
> **Compliance**: SOC 2 Type II CC7.1/CC7.2, GDPR Art. 32, ISO 27001:2022.
> **Verification rule (AGENTS.md §0.4)**: every gate is PASS only with
> captured command output. If a check cannot be executed (no SSH access,
> host absent), record `⚠ UNVERIFIED — manual check required` — an
> UNVERIFIED gate is a NO-GO unless formally risk-accepted in the CC8.1
> issue.
> **Evidence discipline**: all outputs captured via `tee` to the evidence
> files in §6 (scripts must log to stdout so tee captures them).
> **Inputs**: Step 1 topology/capacity, Step 2 vmbr + firewall matrix,
> Step 3 VM specs ×5, Step 4 backup plan + CC8.1 package.

## 0. Prerequisite Gate (from Steps 2–4) — ALL must be closed first

| # | Check | Verification | Expected |
|---|-------|--------------|----------|
| 0.1 | ADR-004 amendment merged (DMZ VLAN 45 / 10.45.45.0/24) | `git log --oneline docs/adr/ADR-004*` + file content | amendment present, approved |
| 0.2 | `data` pool exists, encrypted, ONLINE | `ssh root@10.60.60.10 'zpool status data; zfs get encryption data'` | `state: ONLINE`; `encryption` = `aes-256-gcm` (ZFS reports the algorithm, not "on") |
| 0.3 | Gi1/0/11 trunk + VLAN 45 live | N2048 `show interface gi1/0/11 switchport`; MikroTik SVI present | general mode, pvid 60, tagged 40+45 |
| 0.4 | Ubuntu 24.04 cloud template SHA256-verified on prox01 | `sha256sum` vs Canonical published checksum | match recorded in CC8.1 issue |
| 0.5 | Restore-test gate PASS (VM 201, +200) | `docs/compliance/evidence/restore-test-201-*.log` | PASS + cleanup evidenced |
| 0.6 | PBS nightly jobs ran successfully ≥1× | gate §1.3 below | all 5 VMIDs OK |
| 0.7 | DPIA actions #1–#2 closed; erasure register live | `docs/compliance/dpia-trigger-check.md` §3; `docs/compliance/erasure-log.md` | statuses OPEN→CLOSED |
| 0.8 | CC8.1 issue open with rollback plan + snapshot naming | GitHub issue | `[CC8.1] prox01 JOL Pilot…` present |

**Any 0.x FAIL or UNVERIFIED ⇒ NO-GO. Do not proceed to runtime gates.**

## 1. Host Health Gate (run on prox01)

| # | Check | Command | Expected Output | Evidence File |
|---|-------|---------|-----------------|---------------|
| 1.1 | All pools healthy | `zpool status -x` | `all pools are healthy` | `evidence/prox01-zpool.txt` |
| 1.2 | Data pool state + errors | `zpool status data` | `state: ONLINE`, `errors: No known data errors` | `evidence/prox01-vdev.txt` |
| 1.3 | PBS jobs success (last 24 h) | `pvesh get /cluster/tasks --typefilter vzdump --limit 12 --output-format yaml \| grep -E "upid\|status\|vmid"` | `status: OK` for VMIDs 200,201,202,203,204 | `evidence/prox01-pbs-jobs.txt` |
| 1.4 | RAM headroom per capacity baseline | `free -h` + Step 1 ratio re-check | allocation ≤ 80 % of (total − 20 GB reserve); ARC at configured cap | `evidence/prox01-ram.txt` |
| 1.5 | Hypervisor hardening intact | `sudo ufw status verbose; systemctl is-active fail2ban auditd chrony` | deny incoming; all active | `evidence/prox01-hardening.txt` |
| 1.6 | PVE version pinned | `pveversion` | `pve-manager/9.2.x…` (fleet pin, prox01.md) | `evidence/prox01-pve-version.txt` |

## 2. Per-VM Health Gate (VMIDs 200–204)

Common to all five:

| # | Check | Command | Expected Output | Evidence File |
|---|-------|---------|-----------------|---------------|
| 2.1 | VM running | `qm status <vmid>` | `status: running` | `evidence/vm<vmid>-status.txt` |
| 2.2 | Cloud-init complete | `qm guest exec <vmid> -- cloud-init status` | `status: done` (requires qga — Step 3) | `evidence/vm<vmid>-cloudinit.txt` |
| 2.3 | AIDE clean on guest | `qm guest exec <vmid> -- sudo aide --check` | rc=0 (Ubuntu 24.04 aide 0.18; if CLI differs, assert nightly run via journalctl) | `evidence/vm<vmid>-aide.txt` |
| 2.4 | Node exporter up | from 10.60.60.30/10.10.10.50: `curl -sf http://<vm-ip>:9100/metrics \| head -1` | `node_exporter_build_info…` | `evidence/vm<vmid>-metrics.txt` |

Service-specific health (per VM):

| VM | Check | Command (from authorized source) | Expected |
|----|-------|----------------------------------|----------|
| 200 app | Health endpoint | `curl -sf -w "%{http_code}" http://10.40.40.20:8080/health` | `200` (8080 is the spec default — ⚠ UNVERIFIED: confirm against the jol-backend-platform contract before execution) |
| 201 db | PostgreSQL ready | `qm guest exec 201 -- sudo -u postgres pg_isready -h 10.40.40.21` | `accepting connections` |
| 202 bitrix | Connector service + audit trail | `qm guest exec 202 -- systemctl is-active jol-bitrix; wc -l /var/log/jol-bitrix/audit.jsonl` | `active`; line count increasing after a test sync |
| 203 ingress | TLS 1.3 + redirect | `openssl s_client -tls1_3 -connect 10.45.45.10:443 </dev/null`; `curl -sI http://10.45.45.10` | handshake OK; `301 → https` |
| 204 observ | Ingest live | Loki/Prometheus query: UFW labels present from all 5 guests; scrape targets UP | entries present, 5/5 UP |

Evidence: `evidence/vm<vmid>-health.txt` per row.

## 3. Firewall Verification Gate (Step 2 matrix re-proven)

| # | Check | Command | Expected Output | Evidence File |
|---|-------|---------|-----------------|---------------|
| 3.1 | Default deny on every guest | per VM: `sudo ufw status verbose` | `Default: deny (incoming)` (policy line — NOT a numbered rule) | `evidence/fw-default-deny-<vmid>.txt` |
| 3.2 | No unexpected open ports | from admin01 / each authorized source: `nmap -p- --open <vm-ip>` | exactly the Step 2 §2 allow-list (22, 9100, + service ports) | `evidence/fw-nmap-<vmid>.txt` |
| 3.3 | DB isolation (negative) | from 10.40.40.22 and admin01: `nc -vz 10.40.40.21 5432` | REFUSED/timeout | `evidence/fw-neg-db.txt` |
| 3.4 | DMZ containment (negative) | with VM 203's **backend NIC detached** (net1 removed): `ping -c 3 10.40.40.20` and `nc -vz 10.40.40.21 5432` sourced from 10.45.45.10; additionally from a DMZ-side test host: `nc -vz 10.40.40.22 <connector-port>` | 100 % packet loss / REFUSED — the proxy's backend reachability exists ONLY via its own VLAN 40 NIC + MikroTik rule #1 (only .20's app port) | `evidence/fw-neg-dmz.txt` |
| 3.5 | DB egress block (negative) | `qm guest exec 201 -- curl -sf --max-time 5 https://example.com` | FAILS | `evidence/fw-neg-egress.txt` |
| 3.6 | VLAN 30 air-gap (negative) | from any pilot VM: `ping -c 3 10.30.30.10`; `nc -vz 10.30.30.10 22` | ICMP 100 % loss; TCP refused. Sole permitted exception if pilot LLM is enabled: 10.40.40.20 → 10.30.30.10:**11434** only (rag precedent); any other VLAN 30 reach is a FAIL | `evidence/fw-vlan30-airgap.txt` |
| 3.7 | MikroTik rule counters | MikroTik: print counters for Step 2 rules #1–#5 during synthetic transaction | counters moving on permitted flows only | `evidence/fw-mikrotik-counters.txt` |

## 4. Secret & Permission Gate

| # | Check | Command | Expected Output | Evidence File |
|---|-------|---------|-----------------|---------------|
| 4.1 | No committed secrets | `git secrets --scan && trufflehog git file://. --only-verified` (pre-commit toolchain, AGENTS.md §0.1) | no findings (word-grep on docs is NOT sufficient — docs legitimately discuss secrets) | `evidence/secret-repo-scan.txt` |
| 4.2 | Ansible Vault files encrypted | ⚠ currently NO vault files exist in this repo (verified 2026-08-23); when introduced: `head -1 <vault-file>` | `$ANSIBLE_VAULT;1.1;AES256` — re-run this check at introduction | `evidence/secret-vault-header.txt` |
| 4.3 | Guest secret-file perms | per VM: `stat -c "%a %U:%G" /etc/jol-*/..env` | `640 root:<svc>` (or 600 root:root), world bits 0 (Step 3 D4) | `evidence/secret-perms-<vmid>.txt` |
| 4.4 | Host key perms | per VM: `stat -c "%a %n" /etc/ssh/ssh_host_*_key` | `600` for ALL private host keys (ed25519/rsa/ecdsa) | `evidence/secret-key-perms-<vmid>.txt` |
| 4.5 | No world-readable env files | per VM: `find / -xdev -name "*.env" -perm /o+r 2>/dev/null \| wc -l` | `0` (mcp-prod-lt01 audit precedent) | `evidence/secret-env-scan-<vmid>.txt` |
| 4.6 | Cloud-init carried no secrets | per VM: `sudo grep -ri "password\|token\|key" /var/lib/cloud/instance/user-data.txt` | *(empty)* | `evidence/secret-cloudinit-<vmid>.txt` |
| 4.7 | auditd secret watches armed | per VM: `sudo grep jol_secrets /etc/audit/rules.d/*.rules; sudo auditctl -l \| grep jol_secrets` | watch rules present in both (immutable `-e 2` set) | `evidence/secret-auditd-<vmid>.txt` |
| 4.8 | PBS encryption key escrow | Vaultwarden: verify entry **`pbs01-pilot-encryption-key`** exists + an authorized restorer can retrieve it (read test, no key material logged) | entry present; retrieval OK — per `docs/runbooks/jol-pilot-backup-plan.md` §1 (Step 4 deliverable) | `evidence/secret-pbs-escrow.txt` |

## 5. Monitoring Reachability Gate

| # | Check | Command (from mgmt VLAN only) | Expected Output | Evidence File |
|---|-------|-------------------------------|-----------------|---------------|
| 5.1 | Observability stack up | `curl -sf http://10.60.60.30:<stack-port>/` (⚠ UNVERIFIED — port per chosen stack: Netdata 19999 / Prometheus 9090 / Grafana 3000; Alertmanager 9093 ONLY if included in the pinned stack) | UI/`-/healthy` responds | `evidence/mon-stack.txt` |
| 5.2 | All pilot targets scraped | Prometheus targets page / Netdata nodes | 6/6 UP (5 VMs + prox01) | `evidence/mon-targets.txt` |
| 5.3 | Log ingest from all guests | Loki query `{job="ufw"}` distinct hosts | 5 distinct pilot sources | `evidence/mon-ingest.txt` |
| 5.4 | Dashboard exposure check (negative) | from 10.40.40.20 and DMZ test host: `nc -vz 10.60.60.30 <stack-port>` | REFUSED (mgmt-VLANs only, Step 2 §2.5) | `evidence/mon-exposure-neg.txt` |

## 6. Compliance File Assembly (evidence package)

Final package: `docs/compliance/evidence/pilot-lt-golive-<YYYYMMDD>/`

```
pilot-lt-golive-<YYYYMMDD>/
├── 00-prereq/                  # §0 outputs (ADR refs, pool status, restore drill log)
├── 01-host/                    # §1 prox01-*
├── 02-vms/                     # §2 vm<vmid>-*
├── 03-fw/                      # §3 fw-*
├── 04-secrets/                 # §4 secret-*
├── 05-mon/                     # §5 mon-*
├── INDEX.md                    # manifest: gate → file → result map + descriptions
├── SHA256SUMS                  # generated LAST, immutable thereafter
└── signoff.md                  # GO/NO-GO decision block (below)
```

**Seal command** (run after all evidence is in place, before sign-off):

```bash
cd docs/compliance/evidence/pilot-lt-golive-<YYYYMMDD> && \
  find . -type f -not -name SHA256SUMS -exec sha256sum {} \; > SHA256SUMS
```

Rules:

- Every gate row names its file; every file appears in INDEX.md with its
  PASS/FAIL result — orphan evidence or unlisted gates are audit findings.
- `SHA256SUMS` is generated LAST and the directory is then treated as
  immutable (evidence integrity — ISO 27001 A.5.33).
- Retention: the package is compliance evidence — retained per the fleet
  retention register (do NOT purge with routine log rotation).
- Referenced from: the CC8.1 GitHub issue (closing comment), the
  CHANGELOG go-live row, and the DPIA evidence list.

## Gate Rule & Sign-off

- **GO** = §0 fully closed AND §1–§5 all PASS with captured output.
- **NO-GO** = any FAIL, or any UNVERIFIED without a documented,
  risk-accepted justification in the CC8.1 issue.
- GO ⇒ pilot may accept live personal data; CHANGELOG go-live row written
  citing this package. NO-GO ⇒ blockers documented, remediate, re-gate in
  48 h. Post-pilot: production sizing ADR + pbs02 HA planning.

Decision block (copied into `signoff.md`):

```markdown
## DECISION
- [ ] **GO** — §0 prerequisites closed AND §1–§5 all PASS with captured output.
- [ ] **NO-GO** — Blockers documented below. Re-evaluate in 48h.

**Infrastructure Architect:** _________________ Date: _________
**CISO / Compliance Lead:** _________________ Date: _________

**Blockers (if NO-GO):**
```

Both signatures are REQUIRED — infrastructure sign-off alone does not
authorise live personal data (GDPR accountability, Art. 5(2)).

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Acceptance gate authored (Step 5) — template until go-live execution | this document |
| 2026-08-23 | Ratified-spec reconciliation: `aes-256-gcm` expected value on 0.2; 1.6 pveversion pin check; 8080 health-port default (UNVERIFIED) on VM 200; 3.4 DMZ containment now requires backend NIC detached; 3.6 VLAN 30 air-gap negative test; 4.7 auditd secret-watch check | Step 5 ratified task spec |
| 2026-08-23 | Ratified-spec final: numbered evidence tree (00–05) + seal command; dual-signatory DECISION block (Architect + CISO/Compliance, 48h re-gate); 4.8 PBS escrow check linked to Step 4 backup plan | Step 5 ratified task spec (final) |
