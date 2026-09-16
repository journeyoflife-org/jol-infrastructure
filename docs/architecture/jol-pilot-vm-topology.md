# JOL Pilot Lithuania — VM Topology on prox01 (Dell R640)

> **Status**: DRAFT — pending capacity confirmation (see
> `docs/servers/prox01-capacity-baseline.md`) and the ADR-004 amendment for
> the new DMZ VLAN.
> **Date**: 2026-08-23
> **Compliance**: SOC 2 Type II / GDPR (EU 2016/679, incl. Art. 9 and
> Art. 32) / ISO 27001:2022. PCI-DSS scoping applies **if donations are
> processed in the pilot** (see D2).
> **Ground truth**: `docs/servers/prox01.md`,
> `docs/servers/pve-prod-hv01.md` (naming convention, VM table format),
> `docs/architecture/network-topology.md` (VLAN plan), AGENTS.md §0–§1.

## D2. Verdict on the 3-VM Proposal

**Verdict: UNDER-PROVISIONED** — as a compliance-bound pilot architecture,
not as raw compute.

The proposed three tiers (JOL app / DB / Bitrix) are each **correct and
necessary**, and the DB-as-own-VM decision is endorsed without reservation.
But the proposal omits two tiers that the compliance frame makes
non-negotiable:

1. **No ingress/security edge.** TLS termination, WAF (ModSecurity-class),
   and request logging must live outside the application VM. Co-locating the
   public edge with the app tier means a web-layer compromise is immediately
   a data-tier compromise — a direct GDPR Art. 32 failure ("appropriate
   technical measures … isolation") and an ISO 27001 A.8.22 (segregation of
   networks) gap.
2. **No observability/evidence tier.** SOC 2 CC7.2 requires monitoring and
   log evidence; Art. 30/Art. 33 require demonstrable records. Logs shipped
   off-guest to a dedicated collector survive a full app-VM compromise and
   give the audit trail a host the auditor can point at.

Additional compliance drivers for keeping the DB isolated:

- **GDPR Art. 32**: the platform processes special-category data
  (religious affiliation, Art. 9). Isolation, per-guest UFW default-deny,
  and independent backup/encryption of the DB guest are the baseline
  demonstration of "security of processing".
- **PCI-DSS scoping**: if donations are in pilot scope, the DB VM becomes
  (or sits adjacent to) the CDE. Isolating it now keeps the PCI scope
  contained to one guest + its flows; co-locating would scope the entire
  application tier into PCI-DSS.
- **Third-party blast radius**: the Bitrix24 connector talks to an external
  SaaS API — it is the highest egress-risk guest and must not share a
  kernel or filesystem with the data tier.

## D3. Recommended Topology

VMID range **200–204 reserved for the pilot** — fleet numbering continues
from `pve-prod-hv01.md` (VMIDs 100–102), and VMIDs must be unique across
the planned prox01–prox03 cluster. Naming follows the fleet convention
`{service}-{env}-lt01` with `env=pilot`.

| VMID | Hostname | vCPU | RAM | Disk (Pool) | VLAN / IP | Purpose | Compliance Driver |
|------|----------|------|-----|-------------|-----------|---------|-------------------|
| 200 | `jol-app-pilot-lt01` | 4 | 8 GB | 80 GB (data, raidz2) | 40 / 10.40.40.20 (static) | JOL application tier | Art. 32 app/data isolation |
| 201 | `jol-db-pilot-lt01` | 4 | 16 GB | 120 GB (data, raidz2) | 40 / 10.40.40.21 (static); DB ports UFW-restricted to 10.40.40.20 | PostgreSQL | GDPR Art. 9 + Art. 32; PCI-DSS scope containment |
| 202 | `jol-bitrix-pilot-lt01` | 2 | 4 GB | 60 GB (data, raidz2) | 40 / 10.40.40.22 (static) | Bitrix24 **integration connector** (Bitrix24 itself is SaaS) | Third-party blast-radius isolation; egress auditing |
| 203 | `jol-ingress-pilot-lt01` | 2 | 4 GB | 40 GB (rpool) | 45 (proposed DMZ) / 10.45.45.10 + 40 (backend) / 10.40.40.23 (static, dual-homed) — VLAN 45 gated on the ADR-004 amendment; NOT VLAN 30 (air-gapped LLM segment) | Traefik/Nginx + ModSecurity, TLS 1.3 termination, access logging | SOC 2 CC6.1 (logical access), CC7.2 (logging) |
| 204 | `jol-observ-pilot-lt01` | 2 | 6 GB | 100 GB (data, raidz2) | 60 / 10.60.60.30 (static; .10=prox01, .20=hv01 — next free) | Netdata / Prometheus / Loki — fleet evidence collector | SOC 2 CC7.2 evidence generation; ISO 27001 A.8.16 monitoring |

**IP allocations verified against** `docs/architecture/network-topology.md`
(VLAN 40 in use: .10/.11/.12 → .20–.22 free) and
`docs/servers/pve-prod-hv01.md` / `docs/servers/prox01.md` (VLAN 60 in use:
.10/.20 → .30 free).

### Corrections applied to the draft proposal

| Draft | Corrected | Reason |
|-------|-----------|--------|
| Ingress on "VLAN 30+40 / 10.60.30.x + 10.60.40.x" | New DMZ VLAN (ADR-004 amendment) + VLAN 40 backend | VLAN 30 is the air-gapped LLM segment (AGENTS.md §2.2 — egress blocked by design); the drafted IPs match no fleet subnet; new public-facing segments require an ADR-004 amendment |
| DB disk on `rpool` | `data` (raidz2) | `rpool` usable ≈ 430 GiB and carries the host; raidz2 gives 2-disk fault tolerance on the most critical guest |
| "DHCP→static" | Static IPs, pre-assigned above | Fleet convention is static addressing throughout (`network-topology.md`) |
| "Bitrix" VM hosting Bitrix | Integration connector for Bitrix24 SaaS | Bitrix24 is a cloud CRM; fleet Tier 3 asset is `jol-bitrix24-integration` |
| Observability IP unspecified | 10.60.60.30 | Verified next-free in VLAN 60 |

## D5. Security/Compliance Rationale (per VM)

**200 — jol-app-pilot-lt01.** The application tier handles session state and
business logic but must never share a kernel, filesystem, or failure domain
with the database: a full app compromise (RCE via a web vulnerability) must
still meet a firewall-enforced boundary before reaching data. A VM (not an
LXC) is chosen because Art. 9 special-category data demands the strongest
available isolation for the guests adjacent to it, and KVM gives an
auditable, snapshot/backup-able unit per SOC 2 CC8.1 change evidence.
Cross-repo dependencies (AGENTS.md §1): upstream `jol-core` (domain models),
`jol-auth` (identity / JWT contract), `jol-backend-platform` (application
logic + health-endpoint port contract); downstream `jol-hub` + `jol-site-*`
spokes (UI — formerly `jol-frontend-platform`, retired 2026-09-11) and
`jol-analytics-ai` (anonymized telemetry only). Runtime secrets
(app.env, DB credentials, signing keys) arrive via Ansible Vault — the app
repo itself ships no secrets.

**201 — jol-db-pilot-lt01.** The data tier is the pilot's crown-jewel guest:
parishioner PII and religious-affiliation data (GDPR Art. 9), and
potentially donation records (PCI-DSS). Its own VM allows independent
hardening (DB ports bound/filtered to the app VM only), independent PBS
backup with its own RPO, and keeps PCI scoping — if invoked — contained to a
single guest rather than the whole application stack. 16 GB RAM supports
PostgreSQL shared_buffers sizing without contention.
Cross-repo dependencies: schema and migrations are owned by
`jol-backend-platform` / `jol-core` (this repo never contains application
logic — AGENTS.md §1 rule 1); credentials flow exclusively via Ansible
Vault at deploy time; no repo — including this one — stores DB values.
Consumers reach the data tier only through VM 200; there is no direct
downstream repo dependency on the DB host.

**202 — jol-bitrix-pilot-lt01.** The Bitrix24 connector is the pilot's
highest egress-risk component: it holds API credentials for an external SaaS
and initiates outbound calls. Isolation is mandated by GDPR Art. 32
(security of processing — third-party processor flows must be segmented) and
ISO 27001 A.5.19 (supplier relationships): credential theft or
supply-chain compromise of the connector cannot pivot to the data tier;
egress from this guest is restricted by UFW to the Bitrix24 API endpoints
only, and all calls are audit-logged (fleet audit.jsonl pattern). An LXC
would be defensible here (stateless connector), but consistency with the
pilot's VM-only backup/snapshot workflow wins for a 5-guest estate.
Cross-repo dependencies: code and sync contract come from
`jol-bitrix24-integration` (fleet Tier 3); Bitrix24 API tokens live in
**Vaultwarden** (never in that repo, never here) and are rotated per
`docs/runbooks/secret-rotation.md`; the egress FQDN allowlist is a runtime
dependency on the same repo's declared endpoint list. DPIA/DPA status is
tracked in `docs/compliance/dpia-trigger-check.md`.

**203 — jol-ingress-pilot-lt01.** The public edge terminates TLS 1.3, runs
WAF rules, and is the only guest exposed toward the untrusted side. Keeping
it a separate guest means DDoS, WAF bypass attempts, and web-layer exploits
are contained before reaching any data-bearing host; its access logs are the
SOC 2 CC6.1/CC7.2 evidence for who reached what and when. It must sit in a
dedicated DMZ VLAN — the amendment to ADR-004 is a blocking prerequisite.
Cross-repo dependencies: upstream port/health contract from
`jol-backend-platform` (the only permitted backend); TLS certificates via
the fleet workflow in `docs/runbooks/certificate-renewal.md` with private
keys stored in Vaultwarden; WAF rule maintenance falls under
`jol-infrastructure` / `jol-security` policy scope.

**204 — jol-observ-pilot-lt01.** Evidence generation is itself a compliance
control: metrics (Netdata/Prometheus) and logs (Loki) collected into a
dedicated guest survive the compromise or loss of any monitored guest, and
give SOC 2 / ISO 27001 audits a single, identifiable evidence host. Placing
it on VLAN 60 matches the fleet pattern (node-exporter/metrics are exposed
to management VLANs only — see `pve-prod-hv01.md` Security Controls).
Cross-repo dependencies: scrape/exporter configuration is templated by the
`jol-infrastructure` Ansible `monitoring` role; collected evidence feeds
the SOC 2 evidence workflow (`scripts/audit/collect-soc2-evidence.sh`) and
the compliance tree (`jol-compliance`); the stack itself has no application
repo dependency, which is deliberate — the evidence host must not depend on
the systems it observes.

## Verification (sources cited)

- [x] `docs/servers/prox01.md` — storage layout (rpool ~430 GiB, data raidz2
      ~7.3 TiB planned), host status, network table
- [x] `docs/servers/pve-prod-hv01.md` — naming convention, VM table format,
      VMID sequence (100–102), hardening baseline
- [x] `docs/architecture/network-topology.md` — VLAN 40/60 IP usage for
      free-address verification
- [x] AGENTS.md §0.4 — verification rule: all unconfirmed items carry
      `⚠ UNVERIFIED — manual check required`

## End Matter

- **Open Risks**: host CPU/RAM unverified (capacity verdict is
  scenario-based — see capacity baseline §3); DMZ VLAN undefined until
  ADR-004 amendment; `data` raidz2 pool not yet created — blocking for
  VMIDs 200–202, 204; RB5009 single-point-of-failure (documented risk G6)
  applies to any pilot ingress path.
- **Tracked Items**: (1) confirm whether a `jol-bastion-pilot-lt01` is
  needed or the existing admin01 → MikroTik inter-VLAN routing covers pilot
  admin access; (2) ADR-004 amendment for the pilot DMZ segment; (3) record
  `env=pilot` as an approved naming-convention value (fleet currently uses
  `prod` only); (4) PCI-DSS scoping decision if donations enter pilot scope.
- **Next Step**: Step 2 — network segmentation and trust boundaries, taking
  this topology as input (per-VM UFW matrix, vmbr layout on prox01, ADR
  requirements for each cross-VLAN flow).

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Initial pilot topology (DRAFT) — 5-VM recommendation with corrections to 3-VM draft | this document; `docs/servers/prox01-capacity-baseline.md` |
| 2026-08-23 | Reconciliation pass: ingress row updated to proposed VLAN 45 (10.45.45.10) + backend 10.40.40.23 per Step 2 vmbr layout and ratified Step 1 task spec; ADR-004 gate unchanged | `docs/network/prox01-vmbr-layout.md` §2 |
| 2026-08-23 | D5 completed per ratified task spec: cross-repo dependency dimension added to all five VM rationales (AGENTS.md §1 ecosystem map) | AGENTS.md §1 |
| 2026-09-11 | VM 200 downstream UI dependency corrected to `jol-hub` + `jol-site-*` spokes following the `jol-frontend-platform` retirement | `docs/compliance/evidence/change-record-retire-jol-frontend-platform-20260911.md` |
