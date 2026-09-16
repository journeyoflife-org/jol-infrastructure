# JOL Pilot Lithuania — Firewall Matrix (Default Deny)

> **Status**: DRAFT — IP plan from Step 1
> (`docs/architecture/jol-pilot-vm-topology.md`); DMZ subnet pending ADR-004
> amendment (placeholder `10.45.45.0/24`).
> **Date**: 2026-08-23
> **Compliance**: SOC 2 Type II (CC6.1 logical access, CC6.6 boundary
> protection, CC7.2 logging) / GDPR Art. 32 / ISO 27001:2022 A.8.20, A.8.22.
> **⚠️ NO CREDENTIALS in this document.**

## 0. Enforcement layers (defence in depth)

1. **L2/L3 segment edge — MikroTik RB5009 inter-VLAN firewall**: every
   cross-VLAN flow must be explicitly permitted; default deny between VLANs.
2. **Guest edge — UFW**: default deny incoming on every pilot VM; inbound
   allow-list per §2 below; rate-limited SSH; logging on.
3. **Service bind — application layer**: data services bind to specific
   interfaces (DB listens for the app VM IP only where supported), matching
   the fleet loopback-bind pattern for internal services.

Corrections vs. the Step-2 task draft: the draft's subnets `10.60.30.0/24` /
`10.60.40.0/24` do not exist in the fleet VLAN scheme
(`docs/network/dell-n2048-port-table.md` §1 — scheme is `10.<vlan>.<vlan>.0/24`);
the DB allow rule "from 10.60.40.0/24" was also over-broad — least privilege
restricts 5432/tcp to the single app-VM address.

## 1. Common baseline (every pilot VM)

```bash
ufw default deny incoming
ufw default allow outgoing          # refined per-VM below via route/dest policy
ufw limit 22/tcp                    # rate limit SSH (fleet standard)
ufw logging on                      # CC7.2 evidence; shipped to jol-observ-pilot-lt01
ufw enable
```

Management SSH sources follow the fleet convention (see UFW baselines in
AGENTS.md §2.1–§2.3): **10.10.10.0/24 (admin01) + 10.60.60.0/24 (mgmt)**.
Every guest additionally runs fail2ban, chrony, auditd (hv01 baseline).

## 2. Per-VM rules

### 2.1 VM 200 — jol-app-pilot-lt01 (10.40.40.20)

| Dir | Rule | Justification |
|-----|------|---------------|
| IN | ALLOW 10.40.40.23 → 8000/tcp (or app port ⚠ UNVERIFIED — confirm from jol-backend-platform contract) | Traffic only via ingress VM, never direct from DMZ |
| IN | ALLOW 10.10.10.0/24, 10.60.60.0/24 → 22/tcp (limited) | Fleet admin SSH pattern |
| IN | ALLOW 10.60.60.0/24 → 9100/tcp | node-exporter scrape by observ VM (mgmt-VLAN-only exposure, fleet pattern) |
| OUT | ALLOW → 10.40.40.21:5432/tcp | PostgreSQL (only DB flow) |
| OUT | ALLOW → 10.30.30.10:11434/tcp | Ollama — **only if pilot uses on-prem LLM** (precedent: rag-prod-lt01); otherwise omit (air-gap stays clean) |
| OUT | ALLOW → 10.45.45.0/24? **No.** App never initiates toward DMZ | — |
| OUT | ALLOW → internal resolver :53, NTP :123, apt mirrors via proxy | Baseline ops |
| DENY | all other inbound (default) | Art. 32 isolation |

### 2.2 VM 201 — jol-db-pilot-lt01 (10.40.40.21) — crown jewel

```bash
# Inbound — least privilege, single consumer
ufw allow from 10.40.40.20 to any port 5432 proto tcp   # app VM ONLY, not the /24
ufw allow from 10.10.10.0/24 to any port 22 proto tcp limit
ufw allow from 10.60.60.0/24 to any port 22 proto tcp limit
ufw allow from 10.60.60.0/24 to any port 9100 proto tcp
# Outbound — NO internet egress for the data tier
ufw default allow outgoing    # replace with: deny outgoing, allow only NTP + internal resolver
ufw enable
```

| Dir | Rule | Justification |
|-----|------|---------------|
| IN | ALLOW 10.40.40.20 → 5432/tcp | PostgreSQL from app tier only (GDPR Art. 9/32, PCI-DSS scope containment) |
| IN | ALLOW mgmt sources → 22/tcp (limited) | Admin |
| IN | ALLOW 10.60.60.0/24 → 9100/tcp | Metrics |
| OUT | DENY internet egress entirely; ALLOW NTP + internal DNS only | DB tier with no WAN path = exfiltration blocked (trust-boundaries.md Art. 25 pattern) |
| OUT | ALLOW → pbs01 10.10.10.30:8007/tcp **if** guest-side PBS client is used (⚠ decision: hypervisor-level backup is the fleet default — then no rule needed) | Encrypted backup stream |

Additionally: `postgresql.conf listen_addresses = '10.40.40.21,127.0.0.1'`
and `pg_hba.conf` restricted to 10.40.40.20/32 — firewall alone is not the
only control layer.

### 2.3 VM 202 — jol-bitrix-pilot-lt01 (10.40.40.22)

| Dir | Rule | Justification |
|-----|------|---------------|
| IN | ALLOW 10.40.40.20 → connector port (⚠ UNVERIFIED — from jol-bitrix24-integration contract) | App-initiated sync only; the connector never receives DMZ traffic |
| IN | ALLOW mgmt sources → 22/tcp (limited); 10.60.60.0/24 → 9100/tcp | Fleet baseline |
| OUT | ALLOW → Bitrix24 API endpoints :443/tcp — ⚠ UNVERIFIED — manual check required: exact tenant FQDN allowlist from jol-bitrix24-integration (e.g., `<portal>.bitrix24.*`); MikroTik NAT rule scoped to this source IP only | Highest egress-risk guest: SaaS credentials live here — egress allowlist is the blast-radius control |
| OUT | DENY all other internet; ALLOW DNS/NTP | No general browsing/updates path |
| DENY | any flow toward 10.40.40.21 (DB) | Connector must never touch the data tier directly |

### 2.4 VM 203 — jol-ingress-pilot-lt01 (dual-homed)

NICs: external = DMZ 10.45.45.10 (proposed), backend = VLAN 40 10.40.40.23.
IP forwarding between the two NICs is a controlled proxy pass, not routing —
the proxy listens on the DMZ side and originates new connections to the
backend (no bridged L2 path).

| Dir | Rule | Justification |
|-----|------|---------------|
| IN (DMZ NIC) | ALLOW 0.0.0.0/0 → 443/tcp (TLS 1.3 only), 80/tcp → 301 to 443 | Public entry point — WAF-terminated |
| IN (DMZ NIC) | ALLOW mgmt sources → 22/tcp (limited) | Admin |
| IN (backend NIC) | DENY all inbound except established/related | DMZ compromise must not pivot laterally |
| OUT (backend NIC) | ALLOW → 10.40.40.20:<app-port>/tcp | Only upstream = the app VM |
| OUT | DENY direct internet from backend NIC; DMZ NIC egress = OCSP/updates only (⚠ decide and record) | Containment |
| LOG | access + WAF logs → shipped to 10.60.60.30 (Loki) | CC6.1/CC7.2 evidence of who reached what |

### 2.5 VM 204 — jol-observ-pilot-lt01 (10.60.60.30)

| Dir | Rule | Justification |
|-----|------|---------------|
| IN | ALLOW 10.60.60.0/24, 10.10.10.0/24 → dashboard/query ports (⚠ UNVERIFIED — per stack choice: Netdata 19999 / Prometheus 9090 / Grafana 3000) from mgmt VLANs only | Evidence is management-facing, never public |
| IN | ALLOW mgmt sources → 22/tcp (limited) | Admin |
| IN | ALLOW 10.40.40.0/24 + 10.45.45.0/24 → Loki push port (3100/tcp) if guests push logs | Centralised logging sink |
| OUT | ALLOW → 10.40.40.20-23:9100/tcp, 10.60.60.10:9100/tcp | node-exporter scrapes (pull model — matches fleet exporter pattern) |
| OUT | DENY internet egress (NTP/DNS only) | The evidence host must itself be exfiltration-resistant |

### 2.6 Hypervisor prox01 (10.60.60.10) — inherits fleet baseline

Unchanged from `docs/servers/prox01.md` Security Controls: default deny,
22/tcp + 8006/tcp from management VLANs only, fail2ban, auditd, chrony.
No pilot traffic transits the hypervisor IP.

## 3. MikroTik inter-VLAN rules (RB5009 — L3 edge)

| # | Flow | Action | Driver |
|---|------|--------|--------|
| 1 | 10.45.45.0/24 → 10.40.40.20:<app-port>/tcp | ALLOW (only this pair) | DMZ→app via ingress; **ADR-004 amendment governs** |
| 2 | 10.45.45.0/24 → any other 10.40.40.x | DENY | No lateral movement from DMZ |
| 3 | 10.40.40.20 → 10.30.30.10:11434/tcp | ALLOW if pilot uses LLM (existing rule class — rag precedent); else DENY | Air-gap hygiene |
| 4 | 10.40.40.22 → Bitrix24 FQDN allowlist :443 | ALLOW (srcnat scoped to .22) | Egress allowlist |
| 5 | 10.40.40.21 → WAN | DENY | DB has no internet (Art. 25/32) |
| 6 | 10.10.10.50 → pilot VMs :22 | ALLOW | Admin routing precedent (trust-boundaries.md) |
| 7 | anything → 10.60.60.0/24 except 10.10.10.0/24 | DENY | Mgmt segment protection |
| default | all inter-VLAN | DENY + log | CC6.6 |

### 3.1 Cross-VLAN flow matrix & ADR flags (D3)

Per AGENTS.md §1 rule 3, every trust-boundary crossing is flagged. "NO" never
means undocumented — it means covered by an existing or in-flight ADR named
in the justification.

| Source | Destination | Port | VLAN Path | ADR Required? | Justification |
|--------|-------------|------|-----------|---------------|---------------|
| jol-app (10.40.40.20) | jol-db (10.40.40.21) | 5432/tcp | Intra-VLAN 40 | NO | Same segment; least privilege enforced by UFW /32 + pg_hba (matrix §2.2) |
| jol-ingress (10.45.45.10) | jol-app (10.40.40.20) | app port (⚠ UNVERIFIED — jol-backend-platform contract) | 45→40 routed | NO — covered by ADR-004 amendment | Reverse-proxy function; the amendment defines VLAN 45 and MikroTik rule #1 permits ONLY this pair |
| jol-app (10.40.40.20) | Ollama (10.30.30.10) | 11434/tcp | 40→30 routed | NO — existing ADR-004 rule class | rag-prod-lt01 precedent; conditional on pilot enabling LLM; no other VLAN 30 flow exists |
| jol-bitrix (10.40.40.22) | Internet (Bitrix24 FQDNs) | 443/tcp | 40→WAN | **YES — ADR-00x (tracked)** | Allowlisted SaaS egress carrying Art. 9-adjacent sync data; generic 40→WAN masquerade precedent exists but this path gets its own decision |
| jol-observ (10.60.60.30) | pilot guests | 9100/tcp (19999 if Netdata peers) | 60→40/45 (pull) | **YES — ADR-00y (tracked)** | Cross-VLAN monitoring flow; fleet scrape precedent exists (mgmt→guest exporter exposure) but the pilot instantiation is ratified explicitly in ADR-00y, which consolidates dual-homing + monitoring flows + the push-vs-pull decision |
| pilot guests (40/45) | Loki (10.60.60.30:3100) | 3100/tcp | 40/45→60 (push) | **YES — ADR-00y (tracked)** | Inverts fleet direction (guest→mgmt); decide push vs pull before enabling |
| admin01 (10.10.10.50) | pilot guests | 22/tcp | 10→40/60 routed | NO — fleet precedent | trust-boundaries.md admin access pattern |
| prox01 (10.60.60.10) | pbs01 (10.10.10.30) | 8007/tcp | 60→10 routed | NO — fleet precedent | Encrypted backup stream, hv01 precedent; D6 may move to VLAN 85 |
| Any | VLAN 30 (except 40→:11434 above) | Any | Blocked | N/A | Air-gapped by design (AGENTS.md §2.2) |
| Any (except 10.10.10.0/24) | 10.60.60.0/24 | Any | DENY | N/A | Management segment protection (rule #7) |
| DMZ (45) | Any except 10.40.40.20 | Any | DENY | N/A | No lateral movement from DMZ (rule #2) |

## 4. Logging & evidence (CC7.2)

- `ufw logging on` on every guest; logs forwarded to jol-observ-pilot-lt01
  (Loki) — the evidence host is OUTSIDE the guests it observes.
- MikroTik rule hits logged for rules #1–#5.
- Retention: align with the fleet retention policy; pilot logs contain no
  prompt/content data, only connection metadata (GDPR Art. 5(1)(e) minimisation).

## 5. Verification checklist

- [ ] Per VM: `sudo ufw status verbose` shows `default deny incoming` + exactly the allow-list above
- [ ] Negative tests: DB port 5432 refused from 10.40.40.22 and from admin01; DMZ NIC cannot reach 10.40.40.21
- [ ] MikroTik rule counters moving for flows #1–#4 during a synthetic transaction
- [ ] Loki receiving UFW logs from all 5 guests
- [ ] This matrix re-verified after any IP/VLAN change (matrix drift is an audit finding)

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Initial default-deny firewall matrix (DRAFT) for pilot VMs 200–204 | this document; Step 1 topology |
| 2026-08-23 | Ratified-spec reconciliation: added cross-VLAN flow matrix with per-flow ADR flags (§3.1); ADR-00x/ADR-00y tracked | Step 2 ratified task spec |
| 2026-08-23 | Ratified-spec iteration: monitoring pull-scrape flow (60→40/45) upgraded from fleet-precedent NO to explicit **YES — ADR-00y** per ratified Step 2 spec | Step 2 ratified task spec (final) |
