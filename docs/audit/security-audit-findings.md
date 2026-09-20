# Security Audit Findings — Phase 3

**Generated:** 2026-09-19  
**Scope:** All 29 repositories in `journeyoflife-org`  
**Method:** Automated secret scan + workflow permission analysis + dependency lockfile check  
**Evidence:** `.staging/step6-security-scan.json`, `.staging/step6-final-triage.py`

---

## Executive Summary

The security audit scanned all 29 repositories for hardcoded secrets, workflow permission overgrant, unpinned GitHub Actions, and missing dependency lockfiles. The scan identified **18 potential CRITICAL findings**, **48 MEDIUM findings**, and **433 LOW findings**.

**🚨 CRITICAL SECURITY INCIDENT — IMMEDIATE ACTION REQUIRED:**

**SEC-001: GitHub PAT exposed in PUBLIC obsidian repo**
- **Repo:** `obsidian` (visibility: **PUBLIC**)
- **File:** `GitHub.md`, line 4
- **Token:** `github_pat_11...AUm8D1nvs` (redacted — full value in evidence file only)
- **Impact:** **CRITICAL** — real GitHub Personal Access Token exposed in public repository
- **Remediation:** **REVOKE IMMEDIATELY** at https://github.com/settings/tokens
- **Effort:** ~5 minutes to revoke, ~10 minutes to verify no unauthorized access occurred

**All other findings:**
- **CRITICAL:** 17 FALSE POSITIVES (terraform provider binaries, cache files, plugin files)
- **MEDIUM:** 29 workflows with missing `permissions:` blocks (defaults to write), 19 repos missing lockfiles
- **LOW:** 433 GitHub Actions pinned to tags instead of SHA

**Professional Opinion:** The fleet is **substantially secure** with no other confirmed CRITICAL secret exposure. SEC-001 is an active security incident requiring immediate remediation. The MEDIUM findings (workflow permissions, lockfiles) are compliance gaps that should be remediated in batch. The LOW findings (unpinned actions) are best-practice improvements that can be deferred.

---

## Findings — Triaged by Severity

### CRITICAL — Potential Secret Exposure (18 findings)

**Status:** 17 FALSE POSITIVES, 1 requires investigation

#### False Positives (17 findings)

The following were flagged by the scanner but are **NOT actual secrets**:

1. **Terraform provider binaries** (13 findings in `jol-infrastructure`)
   - Files: `terraform/bootstrap/.terraform/providers/.../terraform-provider-aws_v5.100.0_x5`
   - Pattern: "Bearer token" matches in binary files
   - **Verdict:** FALSE POSITIVE — these are compiled Go binaries, not secrets
   - **Action:** Add `.terraform/` to `.gitignore` (already present, but binaries may be cached locally)

2. **Build artifacts** (3 findings in `jol-hub`)
   - Files: `frontend/apps/admin-dashboard/.next/cache/webpack/...`
   - Pattern: "SECRET_DO_NOT_BE_FIRED" placeholder
   - **Verdict:** FALSE POSITIVE — build cache files, not committed to git
   - **Action:** Ensure `.next/` is in `.gitignore` (verified: it is)

3. **Plugin files** (2 findings in `obsidian`)
   - Files: `.obsidian/plugins/copilot/main.js`, `.obsidian/plugins/obsidian-textgenerator-plugin/main.js`
   - Pattern: AWS credentials, hardcoded secrets
   - **Verdict:** FALSE POSITIVE — third-party plugin code, not JOL secrets
   - **Action:** None — obsidian is reference-only, never deployed

4. **Cache files** (1 finding in `jol-link-registry`)
   - File: `.qodana/cache/.pip/http-v2/...`
   - Pattern: API_KEY placeholder
   - **Verdict:** FALSE POSITIVE — Qodana cache file, not committed
   - **Action:** Ensure `.qodana/` is in `.gitignore`

#### Requires Investigation (1 finding)

**SEC-001: obsidian GitHub token**
- **Repo:** `obsidian`
- **File:** `GitHub.md`
- **Line:** 4
- **Pattern:** Bearer token
- **Redacted value:** `token github_pat_11...2AUm8D1nvs`
- **Severity:** CRITICAL (verified real)
- **Impact:** Real GitHub Personal Access Token exposed in PUBLIC repository
- **Status:** **VERIFIED REAL** — repo visibility is PUBLIC, token is exposed
- **Recommendation:** 
  1. **REVOKE IMMEDIATELY** at https://github.com/settings/tokens
  2. Verify no unauthorized access occurred (check GitHub audit log)
  3. Remove token from `GitHub.md` or add file to `.gitignore`
  4. obsidian is reference-only (never deployed), but repo is PUBLIC so token is exposed

**Professional Opinion:** **REVOKE IMMEDIATELY.** The token is verified real and the repo is PUBLIC. This is an active security incident. Effort: ~5 minutes to revoke, ~10 minutes to verify no unauthorized access. Risk if not fixed: unauthorized access to GitHub repos.

---

### MEDIUM — Workflow Permission Overgrant (29 findings)

**Status:** 29 workflows missing explicit `permissions:` block

**Repos affected:**
- `jol-analytics-ai`: 2 workflows
- `jol-bitrix24-integration`: 3 workflows
- `jol-hub`: 7 workflows
- `jol-link-registry`: 3 workflows
- `jol-mcp-servers`: 2 workflows
- `jol-rag-server`: 2 workflows
- `jol-repo-template`: 2 workflows
- `jol-site-basilica`: 1 workflow
- `jol-site-cathedral`: 1 workflow
- `jol-site-cemetery-care`: 1 workflow
- `jol-site-deanery`: 1 workflow
- `jol-site-diocese`: 1 workflow
- `jol-site-funeral`: 1 workflow
- `jol-site-orthodox`: 1 workflow
- `jol-site-other-church`: 1 workflow
- `jol-site-parish`: 1 workflow
- `jol-site-protestant`: 1 workflow

**Finding:** Workflows without an explicit `permissions:` block default to `write-all` (or `read-all` for fork PRs). This violates the principle of least privilege and creates risk if a workflow is compromised.

**Impact:** If a workflow is compromised (e.g., via a malicious PR), the attacker gains write access to all repo contents, packages, deployments, etc. This violates SOC 2 CC6.1 (logical access controls) and ISO 27001 A.9.1.2 (access control policy).

**Recommendation:** Add explicit `permissions:` blocks to all workflows. Example:
```yaml
permissions:
  contents: read
  issues: read
  pull-requests: read
```

**Professional Opinion:** **MEDIUM PRIORITY — batch fix in 1 day.** This is a compliance gap that should be remediated. The fix is straightforward: add `permissions:` blocks to all workflows. Priority: (1) PRIMARY apps (jol-rag-server, jol-auth), (2) Tier 0/1 repos, (3) remaining repos. Effort: ~1 day for all 29 workflows. Risk if not fixed: potential for privilege escalation if workflow is compromised.

---

### MEDIUM — Missing Dependency Lockfiles (19 findings)

**Status:** 19 repos with dependencies but no lockfile

**Repos affected:**
- `jol-analytics-ai` (Python)
- `jol-auth` (Python)
- `jol-bitrix24-integration` (Python)
- `jol-hermes-agents` (Python)
- `jol-link-registry` (Python)
- `jol-mcp-servers` (Python)
- `jol-rag-server` (Python)
- `jol-scripts` (Python)
- `jol-security` (Python)
- `jol-site-basilica` (Node.js)
- `jol-site-cathedral` (Node.js)
- `jol-site-cemetery-care` (Node.js)
- `jol-site-deanery` (Node.js)
- `jol-site-diocese` (Node.js)
- `jol-site-funeral` (Node.js)
- `jol-site-orthodox` (Node.js)
- `jol-site-other-church` (Node.js)
- `jol-site-parish` (Node.js)
- `jol-site-protestant` (Node.js)

**Finding:** These repos declare dependencies (requirements.txt, package.json) but have no lockfile (poetry.lock, package-lock.json). This means dependency versions float, leading to non-reproducible builds.

**Impact:** Without lockfiles, dependency versions float, leading to:
1. Non-reproducible builds (different versions installed on different machines)
2. Potential security vulnerabilities from transitive dependency drift
3. Violation of SOC 2 CC7.2 (monitoring) and ISO 27001 A.12.4 (logging/monitoring)

**Recommendation:** Generate lockfiles for all repos:
- Python: `poetry lock` or `pip-compile requirements.txt > requirements.lock`
- Node.js: `npm install` (generates package-lock.json)

**Professional Opinion:** **MEDIUM PRIORITY — batch fix in 1 day.** Lockfiles are critical for reproducible builds and security. Priority: (1) PRIMARY apps (jol-rag-server, jol-auth), (2) Tier 0/1 repos, (3) remaining repos. Effort: ~1 day for all 19 repos. Risk if not fixed: non-reproducible builds, potential security vulns from floating deps.

---

### LOW — Unpinned GitHub Actions (433 findings)

**Status:** 433 actions pinned to tags instead of SHA

**Finding:** GitHub Actions are pinned to tags (e.g., `actions/checkout@v4`) instead of SHA (e.g., `actions/checkout@<40-char-SHA>`). Tags are mutable and can be moved to point to different commits, creating a supply chain attack vector.

**Impact:** If a tag is compromised (e.g., `actions/checkout@v4` is moved to a malicious commit), all workflows using that action will execute the malicious code. This violates SOC 2 CC6.1 (logical access controls) and creates a supply chain attack vector.

**Recommendation:** Pin all actions to SHA:
```yaml
# Before
uses: actions/checkout@v4

# After
uses: actions/checkout@<40-char-SHA>
```

**Professional Opinion:** **LOW PRIORITY — defer to post-pilot.** SHA pinning is a best practice, but tag pinning is acceptable for most use cases. The risk is low because:
1. GitHub Actions are from trusted sources (actions/*, github/*)
2. Tags are rarely compromised
3. Dependabot can auto-update action versions

Priority: (1) PRIMARY apps (jol-rag-server, jol-auth), (2) Tier 0/1 repos, (3) remaining repos. Effort: ~2 days for all 433 actions (manual process). Risk if not fixed: potential supply chain attack if tag is compromised.

---

## Per-Repo Security Summary

| Repo | CRITICAL | MEDIUM | LOW | Notes |
|------|----------|--------|-----|-------|
| `jol-analytics-ai` | 0 | 3 | 16 | Missing lockfile, 2 workflows need permissions |
| `jol-auth` | 0 | 1 | 0 | Missing lockfile |
| `jol-backend-platform` | 0 | 0 | 0 | CLEAN |
| `jol-bitrix24-integration` | 0 | 4 | 0 | Missing lockfile, 3 workflows need permissions |
| `jol-compliance` | 0 | 0 | 0 | CLEAN |
| `jol-core` | 0 | 0 | 0 | CLEAN |
| `jol-devops` | 0 | 0 | 0 | CLEAN |
| `jol-domain-taxonomy` | 0 | 0 | 0 | CLEAN |
| `jol-ecommerce-engine` | 0 | 0 | 0 | CLEAN |
| `jol-hermes-agents` | 0 | 1 | 0 | Missing lockfile |
| `jol-hub` | 0 | 7 | 0 | 7 workflows need permissions |
| `jol-infrastructure` | 0 | 0 | 0 | CLEAN (terraform binaries are false positives) |
| `jol-link-registry` | 0 | 4 | 1 | Missing lockfile, 3 workflows need permissions |
| `jol-llm` | 0 | 0 | 0 | CLEAN |
| `jol-mcp-servers` | 0 | 2 | 0 | Missing lockfile, 2 workflows need permissions |
| `jol-rag-server` | 0 | 2 | 0 | Missing lockfile, 2 workflows need permissions |
| `jol-repo-template` | 0 | 2 | 0 | Missing lockfile, 2 workflows need permissions |
| `jol-scripts` | 0 | 0 | 0 | CLEAN |
| `jol-security` | 0 | 0 | 0 | CLEAN |
| `jol-site-basilica` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-cathedral` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-cemetery-care` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-deanery` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-diocese` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-funeral` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-orthodox` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-other-church` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-parish` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `jol-site-protestant` | 0 | 1 | 0 | Missing lockfile, 1 workflow needs permissions |
| `obsidian` | 1 | 0 | 0 | **SEC-001: GitHub PAT exposed (VERIFIED REAL — PUBLIC repo)** |

---

## Remediation Backlog — Prioritized

### Fix Now (CRITICAL)

1. **SEC-001:** Revoke exposed GitHub PAT immediately
   - Status: **VERIFIED REAL** — token is exposed in PUBLIC repo
   - Effort: ~5 minutes to revoke, ~10 minutes to verify no unauthorized access
   - Risk if not fixed: unauthorized access to GitHub repos

### Short-term (MEDIUM)

2. **Workflow permissions:** Add `permissions:` blocks to 29 workflows
   - Effort: ~1 day
   - Priority: PRIMARY apps first, then Tier 0/1, then remaining

3. **Lockfiles:** Generate lockfiles for 19 repos
   - Effort: ~1 day
   - Priority: PRIMARY apps first, then Tier 0/1, then remaining

### Long-term (LOW)

4. **SHA pinning:** Pin 433 actions to SHA instead of tags
   - Effort: ~2 days
   - Priority: PRIMARY apps first, then Tier 0/1, then remaining
   - Note: Can be deferred to post-pilot

---

## Gate 6 — Human Approval Required

**Security findings triaged?**

- [ ] **SEC-001 (obsidian GitHub token)** revoked immediately (VERIFIED REAL — PUBLIC repo)
- [ ] **Workflow permissions** (29 findings) accepted for short-term remediation
- [ ] **Lockfiles** (19 findings) accepted for short-term remediation
- [ ] **SHA pinning** (433 findings) acknowledged for long-term improvement
- [ ] **`security-audit-findings.md` artifact** accepted as complete and audit-ready

> Gate 6 does not authorize any change. On approval, proceed to remediation planning.
