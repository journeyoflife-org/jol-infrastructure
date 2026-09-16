# Change Record — Retirement: `jol-frontend-platform`

**Change ID**: JOL-RETIRE-20260911-01
**Status**: EXECUTED
**Effective date**: 2026-09-11
**Authority**: SOC 2 CC8.1 change control
**Scope**: Delete local working copy `/opt/jol/repos/jol-frontend-platform`; retain the
GitHub repository in its already-archived state; correct living documents that
assert the repo is a live Tier-1 application.

## Summary

`jol-frontend-platform` was a 2026-02-04 scaffold that was never developed. It
contained exactly three tracked files (`.gitignore`, `LICENSE`, `README.md`).
The frontend estate has since been re-platformed onto the hub-and-spoke model —
`jol-hub` (Tier-0 monorepo) plus twelve `jol-site-*` spokes. The local working
copy is removed. **No object is lost**: the repository's entire object database
(14 objects) was extracted, restore-verified outside the source, and proven
byte-identical before deletion (see *Preserved Evidence* and
*Object Coverage Proof*).

## Pre-Delete State (captured 2026-09-11)

| Attribute | Value |
|---|---|
| Local path | `/opt/jol/repos/jol-frontend-platform` |
| Size / tracked files | 292 KB / 3 files |
| Total files incl. `.git` internals | 43 |
| `main` | `0ab71a5` "Initial commit" — in sync with `origin/main` |
| Local-only branch | `security/sops-enablement` → `24c4e13` (absent from every remote) |
| Local-only unreachable object | `610c8d31` — dangling commit, on **no** ref, **no** remote |
| Untracked / ignored files | none (`git status --ignored` empty) |
| Stash | none |
| Submodules / other worktrees / LFS objects | none |
| GitHub `full_name` | `JourneyOfLife/jol-frontend-platform` |
| Owner type | **User** (personal account) — the `journeyoflife-org` path in the git remote is a login-redirect alias only |
| Visibility / archived | public / **already `archived: true`** |
| `createdAt` / `pushedAt` | 2026-02-04T14:05:27Z / 2026-02-04T14:05:28Z (never updated after creation) |
| Remote refs | `refs/heads/main` only |
| diskUsage / forks / watchers / stars | 2 KB / 0 / 0 / 0 |
| Open or closed issues / PRs | 0 / 0 |

## Why the folder delete was not safe to run blind

Two Gate 8 objects existed **nowhere but this working copy**:

| Object | Ref state | Content |
|---|---|---|
| `24c4e13` (2026-08-27 01:05:05 +0300) | tip of local branch `security/sops-enablement`; never pushed | `.sops.yaml` + `secrets/encrypted/README.md` |
| `610c8d31` (2026-08-27 00:58:09 +0300) | **dangling** — on no branch, absent from reflog, invisible to `--branches` bundles | the same two files, an earlier attempt superseded 7 minutes later |

Both are **Gate 8 authorized fleet enablement** artifacts under
`journeyoflife-org/jol-infrastructure#36`. A plain `rm -rf` would have destroyed
them with no recovery path.

The difference between the two is only the three `# pragma: allowlist secret`
markers added to the `age:` lines in `.sops.yaml` (blob `00b9425` → `95fe742`);
`secrets/encrypted/README.md` is byte-identical in both (`e7cbb90`). The
dangling commit is therefore *redundant in content* but was preserved anyway —
its authorship metadata and its status as the first Gate-8 attempt on this repo
are the property being retained, not its bytes.

> **Detection note**: `610c8d31` surfaced **only** because `git fsck --lost-found`
> was run as a pre-delete gate. `git status`, `git log --all`, branch listings,
> reflogs, and a naive `git bundle --branches` all report a clean, fully-captured
> repository while hiding it. Any future retirement script that skips `fsck`
> will silently destroy unreachable work.

Fleet comparison of the Gate-8 commit at the time of this change:

| Pushed to `origin/security/sops-enablement` | **Local-only (evidence gap)** |
|---|---|
| `jol-auth`, `jol-core`, `jol-ecommerce-engine`, `jol-llm`, `jol-repo-template`, `jol-scripts`, `jol-security`, `jol-analytics-ai`, `jol-bitrix24-integration`, `jol-compliance`, `jol-devops`, `jol-domain-taxonomy`, `jol-hermes-agents`, `jol-link-registry`, `jol-rag-server` | `jol-frontend-platform` (`24c4e13`), `jol-backend-platform` (`8502c4a`) |

`jol-mcp-servers` carries **no** Gate-8 commit at all. Both residual gaps are
tracked in *Follow-Up Actions*.

## Preserved Evidence

Artifacts in `docs/compliance/evidence/retirement-jol-frontend-platform-20260911/`
(56 KB total):

| File | Purpose |
|---|---|
| `gate8-sops-enablement.bundle` | **Authoritative restore artifact.** Complete-history bundle carrying all three refs: `refs/heads/main`, `refs/heads/security/sops-enablement`, `refs/heads/evidence-tmp/gate8-superseded` |
| `gate8-superseded-attempt.bundle` | Redundant single-ref bundle of the dangling attempt (belt-and-braces; `--branches` already covers it) |
| `0001-sec-sops-enable-SOPS-recipient-encrypted-secrets-roo.patch` | `format-patch` of `24c4e13` — reviewable without git plumbing |
| `0002-security-enable-SOPS-Church-opt-jol-tree-recipient-s.patch` | `format-patch` of `610c8d31` |
| `source-commit.txt` / `source-tree.txt` | Recorded identity + blob SHAs of `24c4e13` |
| `dangling-commit.txt` / `dangling-tree.txt` | Recorded identity + blob SHAs of `610c8d31`, with superseded status |
| `source-odb-inventory.txt` | **Every object** in the source ODB (`type size oid`) — 14 objects: 6 blobs, 3 commits, 5 trees |
| `verification-object-coverage.txt` | Raw log of the restore-verification run |
| `execution-log-retire.txt` | Log of the guarded removal itself (all three gates + post-conditions) |
| `verify-recovery.sh` | **Re-runnable proof** that this evidence still reconstructs the repo (`exit 0` == intact) |
| `SHA256SUMS.txt` | Fixity over all artifacts above |

No private key material is stored. The only secret-shaped value present is the
**public** age recipient `age17ne7fvag6gxedsgs4yzpefqe5t8uefp4ldezrc7ajfqyjad79g5qsv0rn2`
(ADR-003 amendment, Gate 7 published recipient).

## Restore Procedure

> **Executed and confirmed working 2026-09-11** (after deletion) — see
> *Restore Drill* below. Do not "simplify" the `checkout -b ... origin/...`
> forms: cloning a multi-ref bundle materialises **only HEAD** as a local
> branch, so `git checkout security/sops-enablement` fails with *unknown
> revision*.

```bash
cd docs/compliance/evidence/retirement-jol-frontend-platform-20260911
bash verify-recovery.sh                        # exit 0 == evidence intact
sha256sum -c SHA256SUMS.txt                    # fixity
git clone gate8-sops-enablement.bundle /opt/jol/repos/jol-frontend-platform
cd /opt/jol/repos/jol-frontend-platform
git checkout -b security/sops-enablement origin/security/sops-enablement  # 24c4e13
git checkout -b gate8-superseded  origin/evidence-tmp/gate8-superseded    # 610c8d31
# then, if it becomes a live repo again:
git remote set-url origin https://github.com/journeyoflife-org/jol-frontend-platform.git
```

Patch-form alternative for `main` cloned from GitHub: `git apply 0001-*.patch`
(or `0002-*.patch`).

### Restore Drill (post-deletion, 2026-09-11)

Performed into a scratch directory with the source already gone:

| Check | Result |
|---|---|
| `main` | `0ab71a5540985ed347cee78b470ee49c3c7e5445` ✓ — worktree `.gitignore`, `LICENSE`, `README.md`, **no** `.sops.yaml` (correct for `main`) |
| `security/sops-enablement` | `24c4e1304f396fac81bd2786933c16acd771ed64` ✓ — adds `.sops.yaml` + `secrets/encrypted/README.md` |
| `gate8-superseded` | `610c8d31cdbac30d0fc064133d4a356ddcc923e6` ✓ |
| `.sops.yaml` content | Header + `creation_rules` restored verbatim |
| Superseded-vs-final diff | Only the three `# pragma: allowlist secret` markers, as recorded |

## Verification Performed (2026-09-11)

Re-runnable as `bash verify-recovery.sh` in this directory (exit 0 == evidence
intact). Raw output retained as `verification-object-coverage.txt`. Each bundle
was cloned into a fresh temporary directory that does **not** reference the
source repository, then:

1. `git bundle verify` → *"The bundle records a complete history"*, all 3 refs listed.
2. Restored commit `24c4e1304f396fac81bd2786933c16acd771ed64` resolves and `cat-file -e` succeeds in the isolated clone — SHA-1 identity preserved across the round trip.
3. Restored `git ls-tree -r 24c4e13` diff-identical to `source-tree.txt`.
4. Restored `git ls-tree -r 610c8d31` diff-identical to `dangling-tree.txt`; `.sops.yaml` blob returns as `00b9425` (the pre-pragma variant).
5. `.sops.yaml` age recipient recovered verbatim — 3 occurrences in each variant.
6. `0001-*.patch` passes `git apply --check` against `main` (`0ab71a5`).
7. **Set difference** `source ODB objects − union(bundle-clone objects)` = **empty** → `MISSING_COUNT=0`, full object coverage.
8. For all 14 objects, `git cat-file <type> <oid>` piped to SHA-256 is **identical** between source and restored clone → `ALL_OBJECTS_BYTE_IDENTICAL_AFTER_RESTORE`.
9. `sha256sum -c SHA256SUMS.txt` → 10/10 `OK`.

Only after all nine checks passed was the working copy deleted.

### Two failed attempts recorded (not silently patched)

- **Attempt 1** aborted (`RC=128`): a stray quote broke a `diff <(...) <(...)`
  block; fail-fast prevented any partial artifact from being written.
- **Attempt 2** aborted (`RC=128`): bundling the dangling commit with
  `610c8d31 --not main` and then `update-ref`-ing a ref *at* an unreachable
  object produced an **unborn ref**, so the bundle claimed "complete history"
  while restoring an **empty repository**. Caught by the round-trip clone test —
  `bundle verify` alone would have passed it as good evidence. The broken
  `gate8-superseded-attempt-dangling.bundle` was deleted and replaced with a
  real branch-based bundle.

**Lesson**: `git bundle verify` attests to *self-consistency*, not to *content
presence*. Only cloning the bundle into isolation and asserting object identity
proves preservation.

## GitHub Repository Decision

**Retained, not deleted.** The repo was already `archived: true`, public, 2 KB,
with zero forks, watchers, issues, and pull requests. Archiving already delivers
retirement semantics (read-only, closed to contribution) while preserving
`0ab71a5`, the audit trail of the repo's existence, and any inbound redirect.
A hard `gh repo delete` on this **user-owned** (not org-owned) repo would be
irreversible — GitHub's restore window applies to organization repositories —
and buys nothing.

Because the repo is archived, GitHub rejects pushes to it; rescuing `24c4e13`
onto the remote would have required unarchiving a repo being retired. The
bundle route was chosen instead.

## Impact on Living Documents

| Document | Change |
|---|---|
| `AGENTS.md` §1 ecosystem map | `jol-frontend-platform` removed from Tier 1 (Primary Apps); frontend-home note added pointing to `jol-hub` + `jol-site-*` |
| `AGENTS.md` §2.1 Cross-Repo Dependencies | rag-server downstream UI consumer repointed to `jol-hub` + `jol-site-*` spokes |
| `docs/architecture/jol-pilot-vm-topology.md` | VM 200 downstream dependency corrected; Change History row added |
| `docs/compliance/evidence/retirement-jol-frontend-platform-20260911/` | Added (2 bundles, 2 patches, 4 identity files, ODB inventory, verification log, fixity) |
| `CHANGELOG.md` | Entry added |

## Governance Finding — Personal-Account Custody

The repository's true owner is the **personal** account `JourneyOfLife`, while
the rest of the church-tier fleet is addressed as `journeyoflife-org`. Any
retired asset left on a personal account sits outside org ownership, org
audit-export, and offboarding. This is a custody defect independent of this
change, raised rather than silently resolved.

## Rollback

| Layer | Restore step |
|---|---|
| Working copy | `git clone gate8-sops-enablement.bundle /opt/jol/repos/jol-frontend-platform` — returns all three refs at exact SHAs |
| GitHub repo | Untouched by this change; no action needed |
| Documents | `git revert` the docs commit on branch `docs/db-pilot-tenant-isolation-delta` (base `62b1b60`) |

No Proxmox snapshot applies — this change touches no VM or host.

## Follow-Up Actions

1. **`jol-backend-platform` Gate-8 gap** — commit `8502c4a` is local-only, the
   same defect as this one. Push (after unarchiving if applicable) or bundle it
   under a separate change record. Owner: SOPS custody.
2. **`jol-mcp-servers` Gate-8 absence** — no SOPS enablement commit exists;
   confirm whether the repo is in the 28-repo Gate-8 scope or explicitly exempt.
3. **Personal-account custody** — decide whether archived `JourneyOfLife`-owned
   tombstones should be transferred into the org for audit-export coverage.
4. **Gate 8 evidence completeness** — issue #36 should record that church-tree
   Gate-8 enablement is *not* uniformly pushed to remotes.
5. **Retirement tooling gate** — add `git fsck --unreachable --dangling` plus an
   isolated clone-and-compare round trip to any repo-deletion runbook; a
   bundle/`rm -rf` workflow without them loses unreachable work.

## Compliance

- **SOC 2 CC8.1**: Change documented with pre-state, evidence, verification, rollback, and residual findings; failed attempts disclosed.
- **SOC 2 CC7.2**: Detection of the Gate-8 push gap recorded rather than suppressed by deletion.
- **ADR-003 (SOPS/age)**: Gate-8 creation-rules artifacts preserved; public recipient only, no private key material.
- **ISO 27001 A.8.13 / A.5.10**: Tier-1 map corrected so the audit surface no longer asserts a nonexistent primary application.
- **GDPR Art. 5(1)(c) data minimisation**: Dead scaffold removed from the church tree; no personal data was present in the deleted content.
- **ISO 27001 A.5.22 / A.8.10 (information deletion)**: deletion verified against a retained inventory rather than assumed complete.
