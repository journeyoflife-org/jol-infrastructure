# Change Record — Marketplace Tree Rename `jol-m-*` → `jolarca*`

**Record ID**: JOL-RENAME-20260831-01 (file GitHub Issue from this record on org tooling access)
**Template**: `.github/ISSUE_TEMPLATE/infra-change-request.yml` fields below
**Date opened**: 2026-08-31
**Compliance**: SOC 2 CC8.1 · ISO 27001:2022 A.8.32 · GDPR Art. 5(1)(f)

## Risk level

**Medium** — naming-only migration; no data-path, credential, or runtime-service
change. Elevated from Low because it touches the marketplace tree segregation
boundary (ISO 27001 A.8.13), OS identity namespace, and five GitHub repos with
redirect semantics.

## Blast radius

- GitHub org `journeyoflife-org`: 5 repositories renamed (jol-m-marketplace → jolarca;
  jol-m-{infrastructure,compliance,legal,data} → jolarca-{…})
- Host asset tree: `/opt/jol-m` → `/opt/jolarca`; groups `jolm`/`jolm-dev` → `jolarca`/`jolarca-dev`;
  user `jolm-app` → `jolarca-app` (UID/GIDs preserved)
- `jol-infrastructure` living docs/scripts: AGENTS.md §0.2, adr-003-amendment (PROPOSED draft),
  git-fleet-sync.sh, provision-jolm-tree.sh (renamed)
- External: domain registration jolarca.{com,eu,org,net} (irreversible purchase)
- **NOT in scope**: church tree `/opt/jol` (untouched), SOPS key material (none generated),
  any production VM (rag/llm/mcp unaffected)

## Rollback plan

| Phase | Rollback |
|---|---|
| P2 GitHub renames | Rename back in org UI; old redirect restored; re-point local remotes |
| P3 in-repo content | `git revert` of the rename commits per repo |
| P4 local remotes | `git remote set-url` back to legacy URLs (redirect still resolves) |
| P5 host tree/identities | `mv /opt/jolarca /opt/jol-m`; `groupmod -n` and `usermod -l` reversed; safe.directory restored — fully reversible in <5 min |
| P6 jol-infrastructure PR | Revert PR/merge |
| P1 domains | Irreversible — compensating control: pre-purchase availability check + brand sign-off recorded here |

## Change series (one record, gated phases)

- P0 governance: issue + baseline evidence (`rename-jolarca-baseline-20260831.txt`) + rename registry
  (`docs/compliance/rename-registry-jolm-to-jolarca.md`) + evidence-immutability correction
- P1 domain registration (external, EU-domiciled registrar)
- P2 GitHub renames (marketplace anchor first) + metadata/description update
- P3 scripted in-repo content migration (longest-match-first; dated evidence excluded)
- P4 local remote re-point + fetch proof
- P5 host tree + OS identity rename (maintenance window, backup/snapshot first)
- P6 jol-infrastructure reconciliation PR
- P7 certification sweep: fleet grep, git-fleet-sync report, AIDE check→explain→rebuild

## Evidence references

- Baseline: `docs/compliance/evidence/rename-jolarca-baseline-20260831.txt`
- Registry: `docs/compliance/rename-registry-jolm-to-jolarca.md`
- Plan: Jolarca Rename Migration plan (session plan file, 2026-08-31)

## Status

OPENED 2026-08-31 — execution results:

| Phase | Result |
|---|---|
| P0 governance | ✅ DONE — baseline, registry, evidence-immutability correction (ISO-A832 reverted) |
| P1 domains | ✅ DONE 2026-08-31 (operator) + VERIFIED — `jolarca.com` registered at Hostinger (RDAP: registration 2026-08-31, expiry 2028-08-31, `clientTransferProhibited`, registrant data not publicly disclosed → GDPR-consistent); parked on Hostinger DNS (`orbit/horizon.dns-parking.com`, A 2.57.91.91, www CNAME→apex) — no platform targets wired, per plan; defensive TLDs `jolarca.eu/.org/.net/.lt/.de` probed AVAILABLE (no NS delegation) — registration decision pending operator |
| P2 GitHub renames | ✅ DONE 2026-08-31 — 5/5 renamed via API (anchor first), metadata + description/topics set, authenticated redirect verified, name collisions pre-checked zero |
| P3 content migration | ✅ DONE — 363 files replaced across 5 repos (longest-match-first); 2 sealed audit artifacts excluded (immutability); caches untracked; special surfaces (CI/Terraform/pyproject) verified new-name |
| P4 remotes | ✅ DONE — 5/5 re-pointed, zero extra deploy remotes, fetch PASS 5/5 |
| P5 host tree | ⏸ DEFERRED TO WINDOW — `scripts/maintenance/migrate-jolm-tree-to-jolarca.sh` prepared (DRY_RUN + SNAPSHOT_OK gates, V1 segregation re-proof built in); root/snapshot required |
| P6 jol-infrastructure | ✅ DONE — AGENTS.md §0.2, adr-003-amendment (age-jolarca), git-fleet-sync.sh, provision-jolarca-tree.sh, CHANGELOG row; shellcheck clean (new scripts), bash -n 4/4 PASS |
| P7 certification | ✅ SWEEP PASS — residuals = dated evidence + governance docs only; fleet-sync graceful on pending tree |

**Tracked follow-ups (never silent):**
1. ~~P1 domain registration~~ ✅ DONE — `jolarca.com` verified 2026-08-31 (RDAP evidence above); defensive TLDs `.eu/.org/.net` (+ optionally `.lt/.de` for EU/Lithuania mission footprint) remain unregistered — operator decision owed
2. P5 host migration window (snapshot → DRY_RUN → apply → V1 re-proof)
3. Terraform `github-org` module: `terraform state mv` for the 5 renamed
   `github_repository.repos["<old>"]` instances (+ branch-protection /
   vulnerability-alerts for_each keys) BEFORE next `terraform apply` —
   otherwise plan proposes destroy/recreate of renamed repos.
   **Script prepared**: `scripts/maintenance/terraform-state-rename-jolarca.sh`
   (copy to jolarca-infrastructure/scripts/, run from terraform/environments/production)
4. Branch/PR + push of the 5 marketplace repos' rename diffs and this
   repo's reconciliation (operator commits per branch-protection policy)
5. AIDE check→explain→rebuild on the host after P5 (sudo required)
6. `provision-jolarca-tree.sh` DRY_RUN=1 operator gate (sudo required)
7. Vaultwarden: review any items referencing `/opt/jol-m` paths (⚠ UNVERIFIED)

Rollback: NOT USED.
