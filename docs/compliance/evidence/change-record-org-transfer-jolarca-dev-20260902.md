# Change Record — GitHub Org Transfer: `jolarca*` → `jolarca-dev`

**Change ID**: JOL-ORGTRANSFER-20260902-01
**Status**: EXECUTED
**Effective date**: 2026-09-02
**Authority**: SOC 2 CC8.1 change control; ISO 27001:2022 A.8.13 (segregation of processing facilities)
**Scope**: GitHub organization transfer of 5 marketplace-tree repositories

## Summary

All 5 `jolarca*` repositories were transferred from the ministry organization
(`journeyoflife-org`) to a separate commercial organization (`jolarca-dev`).
This enforces Tier-1 audit segregation at the source-control layer: the
ministry org contains only church-platform repos (GDPR Art. 9, donation
PCI-DSS), while the commercial org contains marketplace repos (KYC/AML,
VAT OSS, commercial PCI-DSS, Stripe keys).

## Rationale

1. **Audit narrative**: If JOL is ever audited (canonical or civil), the
   `journeyoflife-org` repos must prove they are not operating a for-profit
   SaaS. Commingled repos = commingled liability.
2. **Secret isolation**: `jolarca-dev` can have commercial CI/CD secrets
   (Stripe, AWS commercial accounts) without exposing JOL's donation
   processor keys.
3. **ISO 27001 A.8.13**: The two-tree segregation control (already enforced
   at the filesystem and OS-identity layers) now extends to the source-control
   layer.

## Repositories Transferred

| Repository | From | To | Redirect chain |
|---|---|---|---|
| `jolarca` | `journeyoflife-org/jolarca` | `jolarca-dev/jolarca` | ✅ verified |
| `jolarca-infrastructure` | `journeyoflife-org/jolarca-infrastructure` | `jolarca-dev/jolarca-infrastructure` | ✅ verified |
| `jolarca-compliance` | `journeyoflife-org/jolarca-compliance` | `jolarca-dev/jolarca-compliance` | ✅ verified |
| `jolarca-legal` | `journeyoflife-org/jolarca-legal` | `jolarca-dev/jolarca-legal` | ✅ verified |
| `jolarca-data` | `journeyoflife-org/jolarca-data` | `jolarca-dev/jolarca-data` | ✅ verified |

## Pre-Transfer State (captured 2026-09-02)

| Repository | Visibility | Branch protection | Webhooks | Actions secrets | Topics |
|---|---|---|---|---|---|
| `jolarca` | public | present | 0 | 0 | catholic, gdpr, journey-of-life, liturgy, marketplace |
| `jolarca-infrastructure` | public | present | 0 | 1 | journey-of-life, marketplace |
| `jolarca-compliance` | public | present | 0 | 0 | journey-of-life, marketplace |
| `jolarca-legal` | public | present | 0 | 0 | journey-of-life, marketplace |
| `jolarca-data` | private | N/A (free org limit) | 0 | 0 | journey-of-life, marketplace |

## Post-Transfer Verification

- All 5 repos confirmed live in `jolarca-dev` via GitHub API
- Redirect chain (old org): `journeyoflife-org/jolarca*` → `jolarca-dev/jolarca*` ✅
- Redirect chain (frozen names): `journeyoflife-org/jol-m-*` → `jolarca-dev/jolarca*` ✅ (2-hop)
- Branch protection preserved on 4/5 public repos
- `jolarca-data` is private on free org plan (branch protection API requires Pro or public)

## Impact on Living Documents

| Document | Change |
|---|---|
| `AGENTS.md` §0.2 | Org transfer note added |
| `docs/compliance/rename-registry-jolm-to-jolarca.md` | Canonical map updated to `jolarca-dev`; frozen-names section updated; change history row added |
| `CHANGELOG.md` | Entry added |

## Frozen Names Status

The frozen `jol-m-*` names remain in `journeyoflife-org` as redirect pointers
only. The 2-hop redirect chain is:
```
journeyoflife-org/jol-m-marketplace → journeyoflife-org/jolarca → jolarca-dev/jolarca
```
GitHub preserves redirects on both rename and org transfer. The chain is
functional but relies on GitHub's redirect goodwill — no code or CI should
depend on the old URLs.

## Rollback

GitHub org transfers are reversible: each repo can be transferred back to
`journeyoflife-org` via the same API. Redirects from `jol-m-*` names would
continue to work (they resolve to whatever org the `jolarca*` repos land in).

## Compliance

- **ISO 27001 A.8.13**: Segregation of processing facilities extended to source-control org layer
- **SOC 2 CC8.1**: Change documented with evidence, rollback, and verification
- **GDPR Art. 5(1)(f)**: Integrity of marketplace scope preserved — no cross-tree data flow created
- **PCI-DSS**: Commercial payment secrets (future Stripe keys) now scoped to a separate org from donation processor keys
