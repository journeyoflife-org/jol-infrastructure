# ADR-004 Amendment — Pilot DMZ Segmentation (VLAN 45)

> **Amends**: `docs/adr/ADR-004-network-segmentation.md`
> **Status**: PROPOSED — pending approval and merge (Phase 0 deliverable;
> human approval gate — this document does not configure anything).
> **Date**: 2026-08-23
> **Drivers**: JOL Pilot Lithuania deployment on prox01 (Steps 1–5 design
> series); GDPR Art. 9/25/32, SOC 2 CC6.1/CC6.6, ISO 27001:2022 A.8.22,
> PCI-DSS scope separation.

## Context

ADR-004 established network segmentation as policy. Its body describes the
legacy AWS 3-tier model; the authoritative on-prem VLAN registry is
`docs/network/dell-n2048-port-table.md` §1 (AGENTS.md §2.5 records the
AWS text as legacy drift). The pilot needs a **public ingress edge** for
the Church platform, and two fleet facts constrain the design:

1. **VLAN 50 is the Marketplace segment** (market01.lt). Reusing it would
   merge the Church Platform and Marketplace audit surfaces — prohibited by
   AGENTS.md §0.2 tree segregation (a DPIA would be required for any such
   merge; none is sought).
2. **VLAN 30 is the air-gapped LLM segment** — no bridge or new flow may
   touch it; app→Ollama remains the single routed 40→30:11434 exception
   (rag-prod-lt01 precedent).

Public IP precedent: one dedicated public IP per Tier-1 tree ingress —
SNI sharing rejected (merged PCI scopes, blast radius; INC-2026-0814
history). The RB5009 is a documented Tier-1 SPOF (G6).

## Decision

Create **VLAN 45 — CHURCH-PILOT-DMZ, 10.45.45.0/24, gateway 10.45.45.1**
(MikroTik SVI), with the following binding rules:

1. **Single permitted cross-VLAN flow**: 10.45.45.10 (jol-ingress-pilot-lt01,
   DMZ NIC) → 10.40.40.20 (jol-app-pilot-lt01) on the application port
   (8080 default — ⚠ UNVERIFIED pending jol-backend-platform contract).
   MikroTik forward-chain permits ONLY this pair; all other 45-originated
   inter-VLAN traffic is DENY + log.
2. **Ingress VM dual-homing**: VM 203 carries net0 on tag 45 and net1 on
   tag 40 over prox01's single vlan-aware trunk (Gi1/0/11: general mode,
   pvid 60 native, tagged 40+45). No bridged L2 path between the NICs —
   proxy-pass only (Step 2 vmbr layout).
3. **Public addressing**: one dedicated public IP for the Church pilot
   ingress (dst-nat on RB5009 + DNS A-record). Marketplace keeps its own.
   No SNI sharing between trees.
4. **Switch changes**: N2048 `vlan 45 / name CHURCH-PILOT-DMZ`; Gi1/0/11
   access→general; Gi1/0/48 (RB5009 trunk) allowed-VLAN list extended
   with 45.
5. **Exclusions**: no VLAN 30 interaction (rule above); no VLAN 50 reuse.

## Conditions (must hold before implementation)

- [ ] N2048 port-security behaviour with multi-MAC general-mode port
      decided and recorded — ⚠ UNVERIFIED on firmware 6.7.1.24
- [ ] RB5009 cold-standby baseline confirmed (INC-2026-0814 remediation) —
      no new public service while the edge SPOF is unmitigated
- [ ] DPIA closed (`docs/compliance/dpia-trigger-check.md` §3) before live
      PII traverses the segment
- [ ] ADR-00y (monitoring flows + Loki push/pull) and ADR-00x (Bitrix
      egress) tracked decisions resolved before those flows are enabled

## Rollback

All changes are additive: remove VLAN 45 from Gi1/0/48 allowed list, revert
Gi1/0/11 to access/pvid 60 (saved pre-change config), delete MikroTik SVI +
dst-nat + forward rules (config export taken before change). No data path
depends on VLAN 45 until VM 203 exists.

## Compliance

- SOC 2 CC6.1 (logical access at the public edge), CC6.6 (boundary
  protection / segmentation)
- GDPR Art. 25 (data protection by design — isolation of Art. 9 processing),
  Art. 32 (security of processing)
- PCI-DSS 1.3 lineage (no direct public access to the data tier; DMZ
  containment proven by acceptance-gate negative tests 3.4/3.6)
- ISO 27001:2022 A.8.22 (segregation of networks)

## Alternatives Considered

1. Reuse VLAN 50 (Marketplace) — rejected: audit-surface merge violates
   AGENTS.md §0.2.
2. Direct public exposure on VLAN 40 — rejected: no DMZ containment;
   violates PCI-DSS 1.3 lineage and the Step 2 trust model.
3. New physical segment/switch — rejected: disproportionate for pilot scale;
   VLAN + L3 firewall achieves the same trust boundary.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Amendment drafted (Phase 0, execution series) — PROPOSED, not yet merged | Steps 1–5 design docs; `docs/compliance/evidence/execution/p0/` |
