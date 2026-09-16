# Design — Organization `.github` Repository Configuration

**Date:** 2026-09-12
**Target:** `journeyoflife-org/.github` (exists, PUBLIC, default branch `main`) + local clone `/opt/jol/repos/.github`
**Author:** Principal Platform Architect (Qoder agent)
**Status:** Approved by owner (scope, approach A, design parts 1–2) — pending owner review of this document
**Change class:** GitHub organization governance files. No host, VM, network, or data-plane change.

---

## 1. Verified starting state

All facts below were read from the live org and local fleet during design, not assumed.

| Fact | Evidence |
|---|---|
| `journeyoflife-org/.github` already exists | `gh repo view` → PUBLIC, `main`, description "Organization default community health files (SECURITY.md, CODE_OF_CONDUCT.md)" |
| Its only content is a 4-line stub `README.md` | `git/trees/main?recursive=1` → single path `README.md` |
| Local clone absent | `ls: cannot access '/opt/jol/repos/.github': No such file or directory` |
| Token identity / scopes | account `JourneyOfLife`; scopes `gist, read:org, repo, workflow` — **no `admin:org`** |
| Permission on `.github` | `viewerPermission: ADMIN`, `viewerCanAdminister: true` |
| Org size / plan | 29 repos, all PUBLIC, plan `free` |
| Teams | `backend`, `data`, `devops`, `frontend`, `security` (all `closed`) |
| **Org has exactly one member** | `orgs/journeyoflife-org/members` → `JourneyOfLife` only |
| **`IterVitae` is not a member** | `orgs/.../members/IterVitae` → 404 |
| Team membership | `teams/security/members` → `JourneyOfLife`; `teams/devops/members` → `JourneyOfLife` |
| `SECURITY.md` missing in | `jol-compliance`, `jol-domain-taxonomy` (and `.github` itself). **Corrected after execution:** `jol-hub` was originally listed here in error — it has its own `.github/SECURITY.md`, the location GitHub checks *first*; the probe queried only the repository root |
| `.github` security policy flag | `isSecurityPolicyEnabled: false` |
| `CODE_OF_CONDUCT.md` present in | `jol-core`, `jol-security` only; the `jol-core` copy is a pasted scaffold fragment (begins `---`, `### ✅ 2. \`CODE_OF_CONDUCT.md\``) and cites `github.com/JourneyOfLife` |
| `SUPPORT.md` present in | nowhere in the fleet |
| `.github` labels | GitHub's 9 defaults only; **`needs-triage` absent**, yet `jol-infrastructure/.github/ISSUE_TEMPLATE/bug_report.md` requests it |
| `.github` feature flags | `hasIssuesEnabled: false`, discussions/wiki/projects off |
| Fleet protection model | `jol-infrastructure` ruleset id `18809087` `protect-main`: deletion, non_fast_forward, required_linear_history, required_signatures, pull_request (`required_approving_review_count: 0`, `require_code_owner_review: true`, `require_extra_approval_for_unattributed_changes: true`, `dismiss_stale_reviews_on_push: true`, `require_last_push_approval: false`, `required_review_thread_resolution: true`, `allowed_merge_methods: ["squash"]`), required_status_checks (11 contexts), code_scanning, code_quality, update; `bypass_actors: [{actor_id: 5, RepositoryRole, always}]` |
| `.github` rulesets | none |
| Local commit signing | `commit.gpgsign=true`, key `609F7926A8254CDB`, last commit `%G?` = `G` |
| Fleet remote convention | SSH 23 / HTTPS 7; default branch `main` in all repos |
| `jol-infrastructure` tree state | 61 modified/untracked paths on branch `docs/db-pilot-tenant-isolation-delta` (unrelated in-flight work) |
| Legacy branch protection | `branches/main/protection` → null; rulesets are the mechanism in use |

### Platform semantics confirmed against GitHub docs

Source: <https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file>

1. The `.github` default repo **must be public**. It is.
2. Defaults apply **only** to repos that do not define their own file of that type.
3. Precedence inside any repository, including the defaults repo: `.github` folder → repo root → `docs` folder.
4. Supported default file types: `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, discussion category forms, `FUNDING.yml`, issue + PR templates and `config.yml`, `SECURITY.md`, `SUPPORT.md`.
   - **Correction applied during design:** `CONTRIBUTING.md` *does* cascade (initially assumed otherwise).
5. `FUNDING.yml` must be in the `.github` folder; issue templates and `config.yml` must be in `.github/ISSUE_TEMPLATE`. All other supported files may sit at root.
6. **A license file cannot be defaulted** — per-repo only.
7. `CODEOWNERS` is **not** a supported default file → a `CODEOWNERS` in `.github` governs only the `.github` repo.
8. If a repo defines *any* valid templates or template config in its own `.github/ISSUE_TEMPLATE`, **none** of the default folder's contents are used for it.
9. If an issue template sets a label, that label must exist in the `.github` repo **and** in every repo where the template is used.

---

## 2. Scope

**In scope:** one repository (`journeyoflife-org/.github`) — its local clone, its content, and its branch protection. Plus two write-actions outside that repo that create no file changes to governed code: a CC8.1 change-control **issue** opened in `journeyoflife-org/jol-infrastructure` (issues are disabled on `.github`), and this design document. The document was originally to be left uncommitted because `jol-infrastructure` carries 61 unrelated dirty paths on branch `docs/db-pilot-tenant-isolation-delta`; the owner instead directed that it be committed there as a single isolated file, which keeps the surrounding work unstaged.

**Explicitly out of scope (owner decision: "Org defaults only, no sweep"):** the other 28 repositories receive no file edits, no setting changes, and no template rewrites.

**Out of scope by tooling constraint:** organization-wide rulesets and org membership administration — `gh api orgs/journeyoflife-org/rulesets` returned *"This API operation needs the `admin:org` scope"*. Both are human UI actions; see §7.

### Direct consequence the owner accepted

Because per-repo files always win, an org-level `SECURITY.md` is **inert for the ~25 repos that carry their own**. It becomes effective for exactly `jol-compliance`, `jol-domain-taxonomy` and `.github` — **two** fleet repos, not three (see the §1 correction). `CODE_OF_CONDUCT.md` becomes effective for 27 of 29 repos; `SUPPORT.md` for all 29.

---

## 3. Approach

**A — Fleet-parity mirror with enforcement deferred to a tracked prerequisite.** Populate all defaults now and land them in one signed bootstrap push while `main` is still unprotected; apply the ruleset immediately afterwards; record the missing second reviewer identity as an explicit prerequisite rather than implying a control that cannot fire.

Rejected alternatives:

- **B — four-eyes enforced before content** (review count 1, no bypass): highest integrity, but content cannot land until a human issues an org invitation and a second identity approves. The two repos with no security policy keep that gap, and the change cannot be completed by the agent.
- **C — content now, protection later:** leaves the org-wide `SECURITY.md` and templates editable with no review trail. Incompatible with the approved scope, which included protection.

Also rejected on the fleet-sync question (owner decision): patching `scripts/maintenance/git-fleet-sync.sh` to see dot-directories. See §8.

---

## 4. File layout

Paths relative to `/opt/jol/repos/.github`. The repository is itself named `.github`, so the mandated inner `.github/` folder produces `/.github/.github/…`. This is not a mistake: GitHub searches the `.github` folder **first** and requires `FUNDING.yml` and `ISSUE_TEMPLATE/` to be there.

```
README.md                                  repo README: explains fallback semantics + manual-sync caveat
profile/README.md                          ORG PROFILE PAGE (renders at github.com/journeyoflife-org)
SECURITY.md                                cascading default
CODE_OF_CONDUCT.md                         cascading default
SUPPORT.md                                 cascading default
CONTRIBUTING.md                            cascading default
LICENSE                                    Apache-2.0; per-repo only, does not cascade
CHANGELOG.md                               CC8.1 evidence record for this repo
.github/FUNDING.yml                        cascading default (folder placement required)
.github/ISSUE_TEMPLATE/bug_report.yml      YAML form
.github/ISSUE_TEMPLATE/feature_request.yml YAML form
.github/ISSUE_TEMPLATE/config.yml          blank_issues_enabled: false + contact_links
.github/PULL_REQUEST_TEMPLATE.md           cascading default
.github/CODEOWNERS                         governs this repo only
.gitignore                                 minimal: .DS_Store, .idea/, .venv/, .env*
```

Notes:

- Root placement for the four cascading `.md` defaults (`SECURITY`, `CODE_OF_CONDUCT`, `SUPPORT`, `CONTRIBUTING`) matches GitHub's precedence list and is what the community-profile UI links to. `README.md`, `profile/README.md`, `LICENSE` and `CHANGELOG.md` are root-level for ordinary reasons and cascade nothing.
- Existing stub `README.md` is replaced; its prior content is preserved in Git history.
- `CHANGELOG.md` is created in this repo (it has none) so the change record travels with the governed artifact.

---

## 5. Content policy per file

### 5.1 `SECURITY.md`

Keeps the fleet SLA table and compliance anchors, drops the false controls.

- Supported versions: current `main`, deployed immediately.
- Reporting channels: `security@journeyoflife.org`; GitHub **private security advisory**; explicit "do not open a public issue".
- SLA: P1 critical 4 h response / 24 h resolution; P2 high 24 h / 7 d; P3 medium 72 h / 30 d.
- Required report content: description, affected repo/component, reproduction steps, impact, suggested fix.
- GDPR: Art. 33 72-hour supervisory-authority notification; Art. 9 special-category (religious affiliation) handling stated explicitly; PCI-DSS noted for donation-handling code.
- Scope: `journeyoflife-org` repositories only. The `jolarca-dev` organization is a **separate** governance surface (ISO 27001 A.8.13 segregation) and is named, not described.
- Bug bounty: none; researchers directed to the channels above.

**Control claims must match reality.** The org file therefore lists: on-prem hosting on Proxmox VE + bare metal, Ansible-driven provisioning, secrets in Ansible Vault / Proxmox cloud-init / Vaultwarden, UFW default-deny with VLAN 30 (LLM) / 40 (AI services) / 60 (management) boundaries, TruffleHog + git-secrets pre-commit, signed-commit rulesets, encrypted Proxmox Backup Server snapshots, AIDE integrity.

**Forbidden content:** `SSE-KMS`, `EKS`, `IRSA`, `VPC`, `cluster-admin`, `PagerDuty`, on-call escalation mechanics, hostnames, IP addresses, VLAN IDs *paired with* service/port mappings, serial-console or iDRAC access detail. The AWS/EKS/IRSA/VPC/PagerDuty claims in `jol-infrastructure/SECURITY.md` are stale — that file is a tracked follow-up (§8), not a source to copy.

### 5.2 `CODE_OF_CONDUCT.md`

Clean single-document code of conduct: pledge, standards, scope, enforcement and reporting to `security@journeyoflife.org`, attribution to Contributor Covenant 2.1 with an explicit note that it is adapted for faith-based institutional contexts. Correct org handle `github.com/journeyoflife-org` throughout. No scaffold fragment headers, no editing marks.

### 5.3 `SUPPORT.md`

Support is issue-based and internal-first: open an issue in the owning repository using the provided forms; security matters via §5.1 channels; general project questions via contact link. **No invented addresses** — `security@journeyoflife.org` is the only evidence-backed address, plus the existing `https://journeyoflife.org/donate` URL. Explicit statement that no SLA is offered to third parties.

### 5.4 `CONTRIBUTING.md`

Contribution contract for the fleet: branch naming (`feature/JOL-XXX-description`), pre-commit hooks (`git-secrets --scan`, `trufflehog`, `bandit`), **squash-merge only**, signed commits required, PR template completion, and the standing rule that a production change requires a GitHub issue with a rollback plan. Never passing credentials as CLI arguments. Points at per-repo `CONTRIBUTING.md` as authoritative when present.

### 5.5 `profile/README.md`

Org profile page copy: mission (Roman Catholic digital mission platform, ~400,000 sites across 27 EU member states), compliance baseline (GDPR Art. 9, PCI-DSS, SOC 2 Type II, ISO 27001:2022), the Tier 0–4 repository map, and where to find each family. Public-safe summaries only — names of repos and tiers, never infrastructure detail.

### 5.6 `.github/ISSUE_TEMPLATE/*`

- **YAML forms only.** Mixing markdown and YAML templates in one folder causes the markdown ones to be ignored; the org defaults must not encode that trap.
- Forms: `bug_report.yml`, `feature_request.yml`, each with structured `input`/`textarea`/`dropdown` fields including a repo selector (the defaults are shared by 29 repos, so "which repository" is a required field).
- **No `labels:` key anywhere.** GitHub requires every label referenced by a template to exist in each repo where the template is used, and `needs-triage`-class labels are not guaranteed to exist fleet-wide (`jol-infrastructure` already references one that is absent from `.github`); omitting the key removes that silent-failure class entirely.
- `config.yml`: `blank_issues_enabled: false`, `contact_links` to the org profile page and the donation page. **No contact link inviting vulnerability reports** — that path must remain a private advisory.

### 5.7 `.github/PULL_REQUEST_TEMPLATE.md`

Generalized from `jol-infrastructure`'s version: change summary, change type, target environment, risk level and blast radius, **rollback plan (mandatory)**, ticket reference, pre-merge checklist. Repo-specific lines (`terraform fmt`, `checkov`, Infracost tables) are removed since the defaults serve non-Terraform repos.

### 5.8 `.github/CODEOWNERS`

```
*   @journeyoflife-org/security @journeyoflife-org/devops
```

Both teams currently contain only `JourneyOfLife`, so this encodes the intended two-person rule (per the fleet CODEOWNERS convention for security-sensitive paths) without yet delivering separation — see §7.

### 5.9 `.github/FUNDING.yml` and `LICENSE`

`FUNDING.yml` mirrors the existing fleet file: `github: [journeyoflife-org]`, `custom: ['https://journeyoflife.org/donate']`. `LICENSE` is the Apache-2.0 text, consistent with `jol-infrastructure`.

---

## 6. Protection

### 6.1 Ruleset `protect-main` on `.github`

Mirror of `jol-infrastructure` id `18809087` with CI-dependent rules removed.

| Rule | Value | Reason |
|---|---|---|
| `deletion` | on | main cannot be deleted |
| `non_fast_forward` | on | no force-push rewriting history |
| `required_linear_history` | on | fleet parity |
| `required_signatures` | on | workstation already signs (`%G?` = `G`) |
| `update` | on | branch must be up to date before merge |
| `pull_request` | count `0`, `require_code_owner_review: true`, `require_extra_approval_for_unattributed_changes: true`, `dismiss_stale_reviews_on_push: true`, `require_last_push_approval: false`, `required_review_thread_resolution: true`, `allowed_merge_methods: ["squash"]` | fleet parity |
| `required_status_checks` | **omitted** | the 11 contexts come from `infra-validate.yml` / `terraform-plan.yml`, which do not exist in this repo; requiring them would make every PR unmergeable |
| `code_scanning`, `code_quality` | **omitted** | no code, no analyzers |
| `bypass_actors` | `[{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]` | parity with fleet |
| `conditions.ref_name.include` | `["~DEFAULT_BRANCH", "refs/heads/main"]` | |

`bypass_actors` is retained for fleet parity only. **Policy: admin bypass is not an approved merge path** (ratified project decision: dual-account four-eyes supersedes owner-admin bypass; bypasses collapse the review gate and create unreviewable audit trails).

### 6.2 Sequencing — order prevents lockout

1. Preflight: `ssh -T git@github.com` succeeds for `JourneyOfLife`; re-confirm `viewerPermission: ADMIN`; confirm no ruleset exists.
2. Open the CC8.1 change-control issue in `journeyoflife-org/jol-infrastructure` with the `infra-change-request.yml` template (issues are disabled on `.github`).
3. `git clone git@github.com:journeyoflife-org/.github.git /opt/jol/repos/.github`.
4. Author all §4 files; one **signed** commit; push directly to `main` — the bootstrap exception, possible only because step 5 has not run yet.
5. Create the ruleset. From this point `main` accepts changes only via PR.
6. Run §6.3 gates; capture output into the issue.
7. `CHANGELOG.md` entry + evidence reference; no Proxmox snapshot (no VM touched).

### 6.3 Verification gates — nothing declared working without output

| Gate | Command | Pass condition |
|---|---|---|
| Ruleset active & correct | `gh api repos/journeyoflife-org/.github/rulesets` | `protect-main`, `enforcement=active`, rules match §6.1 exactly |
| Fallback resolves — gap repo 1 | `gh repo view journeyoflife-org/jol-compliance --json isSecurityPolicyEnabled,securityPolicyUrl` | `isSecurityPolicyEnabled: true`, URL host is `github.com/journeyoflife-org/.github` |
| Fallback resolves — gap repo 2 | same for `jol-domain-taxonomy` | as above |
| Cascade proof (CoC / PR template) | `gh api repos/journeyoflife-org/<repo>/community/profile --jq .files.code_of_conduct_file.html_url` | points into `journeyoflife-org/.github` for a repo without its own, and into the repo itself for a repo that has one (local-wins control) |
| Direct push refused | `git push origin main` after ruleset | rejected **only if the actor lacks bypass — see note below** |
| Delete/force refused | `git push --delete origin main` | rejected **only if the actor lacks bypass — see note below** |
| Signature real | `git log -1 --pretty='%G?'` | `G` |
| Public-exposure leak scan | `grep -rEi '10\.(10|30|40|60)\.|iDRAC|prox[0-9]|pve-prod|pagerduty|CHANGE_ME' .` and `git-secrets --scan` / `trufflehog filesystem .` | **zero** findings |
| Org profile renders | WebFetch `https://github.com/journeyoflife-org` | profile text present |
| YAML templates parse | `python -c "import yaml,sys,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/ISSUE_TEMPLATE/*.yml')]"` | no exception |
| Issue-template labels absent | `grep -rn 'labels:' .github/ISSUE_TEMPLATE/` | zero hits |

**Bypass reality — self-caught during spec review.** Because `bypass_actors` grants the `admin` repository role `bypass_mode: "always"` (mirrored from the fleet), the only existing identity, `JourneyOfLife`, can push to `main` regardless of the ruleset. The two rows above therefore **cannot** be executed as pass/fail gates by that identity, and claiming they passed would be false. Enforcement of those rules becomes testable only after §7 completes. What is verifiable now:

- `gh api repos/journeyoflife-org/.github/rulesets/<id> --jq '{enforcement,rules:.rules[].type,bypass_actors}'` — configuration assertion.
- `gh api repos/journeyoflife-org/.github --jq .current_user_can_bypass` — records explicitly that the sole identity bypasses, so the deficit is on the evidence record rather than hidden.
- A scratch PR (closed unmerged) observing whether GitHub reports the code-owner requirement as satisfied by the sole team member. This is the open question behind §7 and its outcome is recorded either way.

Any gate that cannot be executed is reported `⚠ UNVERIFIED — manual check required`, never assumed.

**Instrument warnings — found while executing these gates.** Two plausible-looking probes are incapable of measuring what they appear to measure, and produced a false reading that had to be withdrawn:

- `community/profile` has **no `security_policy` key at all** (its keys are `content_reports_enabled`, `description`, `documentation`, `files`, `health_percentage`, `updated_at`). Querying it returns NULL even for a repository with its own `SECURITY.md`, so it fails silently as a gate. Use the GraphQL `isSecurityPolicyEnabled` / `securityPolicyUrl` fields instead.
- `Repository.issueTemplates` (GraphQL) reports **zero forms for repositories with definitely-live folder forms** — it returned `0` for `.github` and for `jol-hub`, while surfacing only legacy single-file `.md` templates elsewhere. Likewise `files.issue_template` returns no URL for *any* repository. Neither can confirm or deny issue-form inheritance; that gate requires an authenticated browser on `/<repo>/issues/new/choose`, which redirects anonymous requests to `/login`.

A nil result from these fields means "instrument blind", not "feature absent".

### 6.4 Rollback

- Content: `git revert <bootstrap-commit>` — a single commit, so the revert is exact. **This re-opens the two `SECURITY.md` gaps and is safety-reducing**; rollback must be described as such.
- Ruleset: `gh api -X DELETE repos/journeyoflife-org/.github/rulesets/<id>` returns the repo to unprotected, matching the pre-change state.
- Local: delete `/opt/jol/repos/.github` (clone only; no local-only work of record).
- Nothing in this change touches hosts, backups, network policy, or secrets, so there is no data-plane rollback.

---

## 7. Prerequisite blocking substantive review

The ruleset's code-owner requirement has **no eligible second approver today**: `IterVitae` is not an org member and both owning teams contain only `JourneyOfLife`.

Required human action, not automatable with this token:

1. Invite `IterVitae` to `journeyoflife-org` (organization → People → Invite); requires `admin:org`/owner UI access.
2. Add it to `security` and `devops` teams.
3. Confirm acceptance, then re-run the gates and record a probe PR showing a code-owner review from a non-author identity.

Until then the control is **declarative only** and this document, the issue, and `CHANGELOG.md` must say so. Recorded risk: single-owner org with a self-approvable code-owner gate.

---

## 8. Tracked follow-ups (not in this change)

1. Activate four-eyes review (§7).
2. `jol-core/CODE_OF_CONDUCT.md`: pasted scaffold fragment with the wrong org handle — replace with a per-repo copy or delete to inherit the default.
3. `jol-infrastructure/.github/ISSUE_TEMPLATE` mixes markdown and YAML (markdown silently ignored) and `bug_report.md` requests a non-existent `needs-triage` label.
4. ~25 per-repo `SECURITY.md` files still assert AWS/EKS/IRSA/VPC/PagerDuty controls on a 100 % on-prem platform; org default is inert for them.
5. `scripts/maintenance/git-fleet-sync.sh` iterates `"$root"/*/`, and bash globs skip dot-directories, so `.github` is invisible to the audited fleet pass; **`.github` is synced manually (`git pull`) until that glob is fixed.**
6. Optionally enable issues on `.github` if owner-direct intake is wanted; private advisories are the current path.

---

## 9. Compliance mapping

| Control | How this change serves it |
|---|---|
| SOC 2 CC8.1 | Issue + rollback plan + single signed commit + CHANGELOG evidence entry |
| ISO 27001 A.8.13 (segregation) | `jolarca-dev` named as a separate surface; never merged into this policy file |
| GDPR Art. 33 / Art. 9 | Public, uniform vulnerability + breach-reporting path across all repos |
| GDPR Art. 5(1)(f) | Leak scan gate before publishing into a public org repo |
| N/A by design | AIDE rebuild, Proxmox snapshot, PBS restore — no host or VM state touched |

---

## 10. Execution outcome (2026-09-12)

Implemented as designed. Change record: `journeyoflife-org/jol-infrastructure` **issue #54**, evidence comment `issuecomment-5641502405`.

| Item | Result |
|---|---|
| Local clone | `/opt/jol/repos/.github` — real directory, own `.git`, remote `origin` over SSH, clean worktree |
| Content commit | `888b217`, signed (`%G?` = `G`), 15 files; remote `main` commit *and* tree sha match local (`7883570`) |
| Ruleset | `protect-main` id **22978013**, `enforcement=active` |
| Enforcement proven real | scratch PR #1 rejected — *"the base branch policy prohibits the merge"*; closed unmerged, probe branch deleted |
| Cascades confirmed | CoC + PR template resolve into `.github` for `jol-compliance`, `jol-domain-taxonomy`, `jol-infrastructure`; `jol-hub` / `jol-infrastructure` keep their own PR templates (local-wins control holds) |
| Org profile | renders at `github.com/journeyoflife-org` |
| `config.yml` | accepted server-side — all four `contact_links` live |
| Secret scan | **substituted**, not passed — `trufflehog` and `git-secrets` are absent from this host; a pattern scan was used and is recorded as weaker than the specified gate |
| Issue-form inheritance | **⚠ UNVERIFIED — manual check required** (see instrument warnings in §6.3) |
| Direct-push / force-push refusal | **not tested, deliberately** — the sole identity holds an always-bypass, so the test could not fail for it, and a branch-deletion probe risked destroying `main` |

Two owner decisions taken at completion:

1. The inaccurate `jol-hub` sentence in the published `.github/CHANGELOG.md` **stays and is superseded by the next legitimately-reviewed change**; no admin bypass is used to correct it. This follows the ratified position that dual-account four-eyes supersedes owner-admin bypass — a documentation fix is not worth establishing bypass as a merge precedent on the repository holding the org's security policy.
2. This spec is committed to `docs/db-pilot-tenant-isolation-delta` as an isolated file, leaving the branch's other 61 paths untouched.

Still standing from §8: fleet sync cannot see `.github` (dot-directory glob), `jol-core`'s malformed CoC wins over the default for that repo, and the ~25 stale per-repo `SECURITY.md` files remain inert against the org default.
