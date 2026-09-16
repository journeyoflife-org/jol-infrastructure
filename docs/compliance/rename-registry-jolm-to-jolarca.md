# Rename Registry — `jol-m-*` → `jolarca*`

**Status**: ACTIVE
**Effective date**: 2026-08-31
**Authority**: umbrella change record `docs/compliance/evidence/change-record-rename-jolm-to-jolarca-20260831.md` (SOC 2 CC8.1 change series, phases P0–P7 of the Jolarca Rename Migration plan)
**Compliance**: ISO 27001:2022 A.8.32 (change management lineage), A.5.9 (asset inventory), SOC 2 CC8.1

## Purpose and Resolution Rule

This registry is the canonical mapping between the legacy marketplace-tree
naming and the `jolarca*` brand naming. It exists because **dated compliance
and evidence documents are immutable**: records authored before the effective
date retain the names in force at their date and are NEVER rewritten. When a
dated document references an old name, **this registry resolves it** to the
current name. Only living documents (drafts, AGENTS.md, scripts, runbooks)
are updated in place.

## Canonical Map

| Old identifier | New identifier | Kind |
|---|---|---|
| `jol-m-marketplace` | `jolarca` | GitHub repository (`jolarca-dev`) |
| `jol-m-infrastructure` | `jolarca-infrastructure` | GitHub repository (`jolarca-dev`) |
| `jol-m-compliance` | `jolarca-compliance` | GitHub repository (`jolarca-dev`) |
| `jol-m-legal` | `jolarca-legal` | GitHub repository (`jolarca-dev`) |
| `jol-m-data` | `jolarca-data` | GitHub repository (`jolarca-dev`) |
| `/opt/jol-m` | `/opt/jolarca` | host asset tree (marketplace scope root) |
| `jolm` (GID 984) | `jolarca` (GID 984) | OS group — GID preserved |
| `jolm-dev` (GID 983) | `jolarca-dev` (GID 983) | OS group — GID preserved |
| `jolm-app` (UID 997) | `jolarca-app` (UID 997) | OS service user — UID preserved |
| `age-jolm` | `age-jolarca` | SOPS age identity (adr-003-amendment; not yet generated) |
| `/var/log/jolm-provision` | `/var/log/jolarca-provision` | provisioning change log (new runs) |

## Segregation Statement (unchanged by this rename)

The rename changes NAMES ONLY. The two-tree segregation control is unaffected:

- Church Platform tree `/opt/jol` — GDPR Art. 9 + PCI-DSS donations scope
- Marketplace tree `/opt/jolarca` (ex `/opt/jol-m`) — PCI-DSS payments + KYC/AML + VAT OSS scope

The trees remain distinct audit surfaces with distinct SOPS age identities
(`age-jol` / `age-jolarca`), distinct OS groups, and distinct DPIAs. No
cross-tree recipient, shared credential, or merged backup scope is created by
this rename (AGENTS.md §0.2; ISO 27001 A.8.13).

## Frozen Names

The old repository names are FROZEN after GitHub rename: they must never be
re-created in `journeyoflife-org`, because GitHub's old→new URL redirect
breaks permanently if the old name is reused. The 2026-09-02 org transfer
moved the `jolarca*` repos to `jolarca-dev`; the frozen `jol-m-*` names
remain in `journeyoflife-org` as redirect pointers only (2-hop chain:
`journeyoflife-org/jol-m-*` → `journeyoflife-org/jolarca*` →
`jolarca-dev/jolarca*`).

## Dated Documents Retaining Legacy Names (non-exhaustive, resolved here)

- `docs/compliance/evidence/ISO-A832-remediation-pair-20260814.md` — references
  `jol-m-compliance` (as-of 2026-08-14) → resolves to `jolarca-compliance`
- Documents dated before 2026-08-31 in any fleet repo that reference
  `jol-m-*` or `/opt/jol-m` → resolve per the canonical map above

## Brand Assets (ISO 27001 A.5.9 inventory)

| Asset | State | Verified |
|---|---|---|
| `jolarca.com` | Registered at Hostinger; parked (`*.dns-parking.com`); transfer lock ON; expiry 2028-08-31; registrant data undisclosed (GDPR-consistent) | RDAP + DNS probes 2026-08-31 |
| `jolarca.eu` / `.org` / `.net` (defensive) | UNREGISTERED — probed available 2026-08-31; operator decision owed | dig NS probes 2026-08-31 |
| DNS targets | NONE wired — no platform/ACME endpoints until the marketplace hosting ADR exists | dig A/CNAME probes 2026-08-31 |

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-31 | Registry created as part of Phase 0 of the Jolarca Rename Migration | baseline evidence file `rename-jolarca-baseline-20260831.txt` |
| 2026-08-31 | P1 verified: `jolarca.com` registered + parked; brand-assets inventory section added | RDAP events (reg 2026-08-31, clientTransferProhibited), dig NS/A/SOA |
| 2026-09-02 | Org transfer: all 5 `jolarca*` repos moved from `journeyoflife-org` to `jolarca-dev` (separate GitHub org for marketplace/commercial tree segregation per ISO 27001 A.8.13). Redirect chains verified intact. | CC8.1 change record `change-record-org-transfer-jolarca-dev-20260902.md` |
