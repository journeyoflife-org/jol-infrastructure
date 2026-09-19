# Pre-Change State Record

**Generated:** 2026-09-18  
**Purpose:** Snapshot of every local repository's state BEFORE any remediation begins

---

## Summary

- **Total repos in org:** 29
- **Total local clones:** 29 (all present at `/opt/jol/repos/`)
- **Repos with uncommitted changes:** 9
- **Repos on non-default branch:** 11 (10 site spokes + jol-compliance)
- **Repos with unpushed commits:** 1 (`jol-devops`)
- **Repos fully clean on `main`:** 9

## Detailed Pre-Change State

| # | Repository | Branch | Dirty | Unpushed | Last Commit |
|---|-----------|--------|-------|----------|-------------|
| 1 | `jol-analytics-ai` | `main` | 6 files | 0 | `6d4d7aa chore: add dependabot ignore rules` |
| 2 | `jol-auth` | `main` | 31 files | 0 | `a08ab1b docs(contributing): codify Qodana quality gates` |
| 3 | `jol-bitrix24-integration` | `main` | 0 | 0 | `3420da0 fix: add explicit __init__ methods` |
| 4 | `jol-compliance` | `feature/initial-setup` | 7 files | unknown | `929b220 feat(compliance): add GDPR DSR tracker` |
| 5 | `jol-core` | `main` | 2 files | 0 | `2ef41dd refactor: rename repository` |
| 6 | `jol-devops` | `main` | 0 | 1 commit | `d089cef feat(maintenance): add workstation disk layout fix` |
| 7 | `jol-domain-taxonomy` | `main` | 0 | 0 | `1aa7bfd Initial commit` |
| 8 | `jol-ecommerce-engine` | `main` | 0 | 0 | `8bb1088 docs(release): allow tag-name reuse` |
| 9 | `jol-hermes-agents` | `main` | 16 files | 0 | `dc79827 fix(ci): grant CodeQL job actions:read` |
| 10 | `jol-hub` | `main` | 0 | 0 | `de7d3256 fix: resolve 4 remaining CI failures (#127)` |
| 11 | `jol-infrastructure` | `main` | 6 files | 0 | `1679068 chore(deps): ignore hashicorp/aws 6.x` |
| 12 | `jol-link-registry` | `main` | 13 files | 0 | `5c94ec5 chore: bump github/codeql-action from v3 to v4` |
| 13 | `jol-llm` | `main` | 32 files | 0 | `d37c331 fix(docs): replace broken relative links` |
| 14 | `jol-mcp-servers` | `main` | 0 | 0 | `f278e5d ci(qodana): switch to workflow_dispatch` |
| 15 | `jol-rag-server` | `main` | 0 | 0 | `9702701 docs(deployments): close /query end-to-end closure` |
| 16 | `jol-repo-template` | `main` | 1 file | 0 | `edd9bbe feat: initial enterprise repository template` |
| 17 | `jol-scripts` | `main` | 0 | 0 | `ee742d6 fix(ci): use space-separated args format` |
| 18 | `jol-security` | `main` | 0 | 0 | `27e4773 Initial commit: SOC 2 / GDPR / ISO 27001` |
| 19 | `jol-site-basilica` | `feature/stage0-gate-remediation` | 2 files | no upstream | `40093bc docs: add final engagement sign-off` |
| 20 | `jol-site-cathedral` | `feature/stage0-gate-remediation` | 7 files | no upstream | `8193a44 feat(frontend): implement page package 04` |
| 21 | `jol-site-cemetery-care` | `feature/stage0-gate-remediation` | 7 files | no upstream | `d20a7a8 feat(frontend): implement page package 12` |
| 22 | `jol-site-deanery` | `feature/stage0-gate-remediation` | 7 files | no upstream | `07c7e8e feat(frontend): implement page package 06` |
| 23 | `jol-site-diocese` | `feature/stage0-gate-remediation` | 7 files | no upstream | `cc9390d feat(frontend): implement page package 05` |
| 24 | `jol-site-funeral` | `feature/stage0-gate-remediation` | 7 files | no upstream | `557aba4 feat(frontend): implement page package 11` |
| 25 | `jol-site-orthodox` | `feature/stage0-gate-remediation` | 7 files | no upstream | `b2abe65 feat(frontend): implement page package 09` |
| 26 | `jol-site-other-church` | `feature/stage0-gate-remediation` | 7 files | no upstream | `9165d23 feat(frontend): implement page package 10` |
| 27 | `jol-site-parish` | `feature/stage0-gate-remediation` | 7 files | no upstream | `64d1da6 feat(frontend): implement page package 07` |
| 28 | `jol-site-protestant` | `feature/stage0-gate-remediation` | 7 files | no upstream | `4d2b767 feat(frontend): implement page package 08` |
| 29 | `.github` | `main` | — | — | Org defaults repo (community health files) |

## Preservation Rules Applied

1. **No uncommitted changes will be discarded** — all dirty trees will be inspected and their owner/intent determined before any remediation
2. **Feature branches will not be force-reset** — the 10 site spokes on `feature/stage0-gate-remediation` represent prior remediation work
3. **Unpushed commits will be preserved** — `jol-devops` has 1 unpushed commit that must not be lost
4. **No `git stash` or `git reset --hard` without explicit authorization**
