# Security Audit Findings — Phase 6

**Generated:** 2026-09-19  
**Scope:** All 31 repositories in `/opt/jol/repos`  
**Method:** Automated security scan (`scripts/audit/phase6-security-audit.py`)  
**Evidence:** `.staging/phase6-security/phase6-security.json`, `.staging/phase6-security/phase6-summary.txt`

---

## Executive Summary

The security audit identified **382 hardcoded secrets** (309 CRITICAL, 73 HIGH) and **80 unpinned GitHub Actions** across 31 repositories. The majority of secrets are in test files, build artifacts, and documentation (knowledge base), but several are in production scripts and require immediate remediation.

**Headline findings:**
- **309 CRITICAL-severity secrets** — AWS access keys, private keys, tokens in test files and build artifacts
- **73 HIGH-severity secrets** — passwords, tokens in scripts and configs
- **80 MEDIUM-severity workflow issues** — unpinned GitHub Actions (tag-based vs. SHA pinning)
- **3 repos with SOPS configured** — jol-hub, jol-infrastructure, 10 site spokes (shared config)

**CRITICAL:** The `obsidian` knowledge base contains 196 secrets (mostly in documentation/examples), and `jol-hub` contains 129 secrets (mostly in test files and build artifacts). These require immediate verification to determine if they are real secrets or test fixtures.

---

## Findings — Triaged (Fix-Now vs. Backlog)

### 🔴 FIX-NOW (CRITICAL — Immediate Remediation Required)

#### S1: `jol-auth` has passwords in bootstrap scripts

**Repo:** `jol-auth` (Tier 0 — Contracts)  
**Severity:** CRITICAL  
**Finding:** Bootstrap scripts (`scripts/bootstrap-jol-auth.sh`, `scripts/fix-and-run.sh`) contain hardcoded passwords (lines 181, 212, 69).  
**Impact:** Potential credential exposure in version control. If these are real passwords, they must be rotated immediately.  
**Evidence:** `scripts/bootstrap-jol-auth.sh:181`, `scripts/bootstrap-jol-auth.sh:212`, `scripts/fix-and-run.sh:69`  
**Recommendation:** 
1. Verify if passwords are real or placeholders
2. If real: rotate immediately, move to Ansible Vault or environment variables
3. Add `.env` and `*.secret` to `.gitignore`
4. Add pre-commit hook to detect secrets

**Professional Opinion:** **VERIFY IMMEDIATELY.** Bootstrap scripts should never contain hardcoded passwords. Use environment variables or Ansible Vault. If these are real passwords, this is a CRITICAL security violation.

---

#### S2: `jol-hub` has 129 secrets in test files and build artifacts

**Repo:** `jol-hub` (Tier 0 — Contracts)  
**Severity:** CRITICAL  
**Finding:** 129 secrets detected, mostly AWS access keys in test files (`frontend/packages/observability/src/__tests__/observability.test.ts`) and build artifacts (`frontend/packages/testing/dist/`).  
**Impact:** If these are real AWS keys, they are exposed in version control. Build artifacts should not be committed.  
**Evidence:** `frontend/packages/observability/src/__tests__/observability.test.ts:63`, `frontend/packages/testing/dist/index.mjs:3226`  
**Recommendation:**
1. Verify if AWS keys are real or test fixtures
2. If real: rotate immediately, use environment variables or AWS IAM roles
3. Add `dist/` and `build/` to `.gitignore`
4. Add pre-commit hook to detect AWS keys

**Professional Opinion:** **VERIFY IMMEDIATELY.** Test files should use mock credentials, not real AWS keys. Build artifacts should never be committed. This is likely a combination of test fixtures and committed build artifacts (both are bad practices).

---

#### S3: `obsidian` knowledge base has 196 secrets

**Repo:** `obsidian` (Knowledge Base — Reference Only)  
**Severity:** HIGH  
**Finding:** 196 secrets detected, mostly in documentation (`01-Governance/Secure-Workstation/...`) and plugin files (`.obsidian/plugins/obsidian-textgenerator-plugin/main.js`).  
**Impact:** Documentation may contain example passwords/keys. Plugin files may contain hardcoded tokens.  
**Evidence:** `01-Governance/Secure-Workstation/Secure-Development-Workstation-Configuration-Specification.md:462`, `.obsidian/plugins/obsidian-textgenerator-plugin/main.js:608`  
**Recommendation:**
1. Verify if secrets are examples or real
2. If examples: add clear "[EXAMPLE]" markers
3. If real: rotate immediately
4. Consider excluding `obsidian` from security scans (it's a knowledge base, not deployable code)

**Professional Opinion:** **LOW RISK — but verify.** The `obsidian` repo is a knowledge base (reference only, never deployable). Most secrets are likely examples in documentation. However, the plugin JS file containing AWS keys is concerning. Verify and document as examples.

---

### 🟡 BACKLOG (HIGH/MEDIUM — Schedule for Remediation)

#### S4: 10 site spokes have 4 secrets each

**Repos:** All 10 `jol-site-*` spokes  
**Severity:** HIGH  
**Finding:** Each spoke has 4 secrets, likely from shared templates.  
**Impact:** If these are real secrets, they are exposed in 10 repos.  
**Evidence:** Pattern consistent across all spokes  
**Recommendation:**
1. Verify if secrets are real or template placeholders
2. If real: rotate immediately, move to environment variables
3. Update spoke templates to exclude secrets
4. Add pre-commit hooks to all spokes

**Professional Opinion:** **VERIFY AS BATCH.** The spokes are likely using shared templates with placeholder secrets. Verify one spoke, then apply fix to all.

---

#### S5: 80 unpinned GitHub Actions across all repos

**Repos:** All 31 repos  
**Severity:** MEDIUM  
**Finding:** All workflows use tag-based references (`v4`, `v7`, `main`) instead of SHA pinning.  
**Impact:** Tag-based references are mutable — a compromised tag could inject malicious code. SHA pinning prevents this.  
**Evidence:** 80 workflow files with unpinned actions  
**Recommendation:**
1. Pin all actions to SHA (e.g., `actions/checkout@<sha>`)
2. Use Dependabot to keep actions updated
3. Prioritize CRITICAL/HIGH tier repos first

**Professional Opinion:** **MEDIUM PRIORITY — batch fix in 1-2 days.** SHA pinning is a security best practice, but tag-based references are not immediately exploitable. Schedule as a batch remediation after CRITICAL secrets are resolved.

---

#### S6: `jol-link-registry` has 5 secrets

**Repo:** `jol-link-registry` (Tier 3 — Integrations)  
**Severity:** HIGH  
**Finding:** 5 secrets detected.  
**Impact:** Potential credential exposure.  
**Evidence:** Scan results  
**Recommendation:** Verify and rotate if real.

---

#### S7: `jol-rag-server` has 2 secrets

**Repo:** `jol-rag-server` (Tier 1 — PRIMARY APPLICATION)  
**Severity:** HIGH  
**Finding:** 2 secrets detected.  
**Impact:** PRIMARY app handling GDPR Art.9 data — credential exposure is CRITICAL.  
**Evidence:** Scan results  
**Recommendation:** Verify immediately, rotate if real.

---

#### S8: `jol-mcp-servers` has 1 secret

**Repo:** `jol-mcp-servers` (Tier 2 — AI Estate)  
**Severity:** HIGH  
**Finding:** 1 secret detected.  
**Impact:** Potential credential exposure.  
**Evidence:** Scan results  
**Recommendation:** Verify and rotate if real.

---

#### S9: `jol-security` has 2 secrets

**Repo:** `jol-security` (Tier 4 — Infra/Gov)  
**Severity:** HIGH  
**Finding:** 2 secrets detected.  
**Impact:** Security repo should not contain secrets.  
**Evidence:** Scan results  
**Recommendation:** Verify and rotate if real.

---

#### S10: `jol-repo-template` has 1 secret

**Repo:** `jol-repo-template` (Tier 4 — Infra/Gov)  
**Severity:** MEDIUM  
**Finding:** 1 secret detected (likely template placeholder).  
**Impact:** Template should not contain real secrets.  
**Evidence:** Scan results  
**Recommendation:** Verify it's a placeholder, update template if needed.

---

### 🟢 INFO (Low Risk — Document and Monitor)

#### S11: SOPS configuration status

**Repos:** `jol-hub`, `jol-infrastructure`, 10 `jol-site-*` spokes  
**Status:** SOPS configured (`.sops.yaml` present)  
**Impact:** Positive — these repos have encryption-at-rest for secrets.  
**Recommendation:** Continue using SOPS for all secret management.

---

## Remediation Priority

### Immediate (This Week)

1. **S1:** Verify `jol-auth` bootstrap script passwords — rotate if real
2. **S2:** Verify `jol-hub` AWS keys — rotate if real, remove build artifacts from git
3. **S3:** Verify `obsidian` secrets — document as examples
4. **S7:** Verify `jol-rag-server` secrets — rotate if real (PRIMARY app)

### Short-term (Next 2 Weeks)

5. **S4:** Verify 10 site spokes secrets — batch fix
6. **S6, S8, S9:** Verify remaining repo secrets
7. **S10:** Verify `jol-repo-template` placeholder

### Medium-term (Next Month)

8. **S5:** Pin all 80 GitHub Actions to SHA (batch fix)

---

## Secret Types Breakdown

| Secret Type | Count | Severity | Examples |
|-------------|-------|----------|----------|
| AWS_ACCESS_KEY | 210 | CRITICAL | `AKIA...` patterns in test files, build artifacts |
| PRIVATE_KEY_BLOCK | 99 | CRITICAL | `-----BEGIN PRIVATE KEY-----` in various files |
| TOKEN | 33 | HIGH | `TOKEN = ...` in scripts, configs |
| PASSWORD | 29 | HIGH | `PASSWORD = ...` in scripts, docs |
| API_KEY | 11 | HIGH | `API_KEY = ...` in configs |

---

## Workflow Security Issues

| Issue Type | Count | Severity | Description |
|------------|-------|----------|-------------|
| UNPINNED_ACTION | 80 | MEDIUM | Actions use tag-based refs (`v4`, `main`) instead of SHA pinning |

---

## Professional Opinions

### Overall Assessment

**Opinion:** The security posture is **WEAK but not CRITICAL** (yet). The majority of "secrets" are likely test fixtures, examples, or build artifacts, not real credentials. However, the bootstrap scripts in `jol-auth` and the PRIMARY app (`jol-rag-server`) require immediate verification.

### Key Risks

1. **Credential exposure in version control** — if any secrets are real, they must be rotated immediately
2. **Build artifacts committed** — `jol-hub` has `dist/` directories committed, which is a bad practice
3. **Unpinned actions** — tag-based references are mutable, creating supply chain risk

### Recommendations

1. **Immediate:** Verify S1, S2, S3, S7 (CRITICAL secrets in key repos)
2. **Short-term:** Add pre-commit hooks to all repos to detect secrets
3. **Medium-term:** Pin all actions to SHA, remove build artifacts from git
4. **Long-term:** Implement SOPS for all repos, establish secret rotation policy

---

## Verification Commands

To verify the findings, run:

```bash
# Check jol-auth bootstrap scripts
grep -n "PASSWORD" /opt/jol/repos/jol-auth/scripts/bootstrap-jol-auth.sh

# Check jol-hub test files
grep -n "AWS_ACCESS_KEY" /opt/jol/repos/jol-hub/frontend/packages/observability/src/__tests__/observability.test.ts

# Check obsidian documentation
grep -n "password" /opt/jol/repos/obsidian/01-Governance/Secure-Workstation/Secure-Development-Workstation-Configuration-Specification.md | head -5

# Check unpinned actions
grep -r "uses:.*@v[0-9]" /opt/jol/repos/jol-hub/.github/workflows/ | head -5
```

---

## Gate 6 Status

**Security findings triaged?** ⏳ AWAITING HUMAN REVIEW

- [ ] **S1–S3** (CRITICAL secrets) — verify and remediate immediately
- [ ] **S4–S10** (HIGH/MEDIUM secrets) — verify and schedule remediation
- [ ] **S5** (unpinned actions) — schedule SHA pinning batch fix
- [ ] **S11** (SOPS status) — acknowledge as positive control

> Gate 6 does not authorize any change. On approval, proceed to immediate remediation of CRITICAL findings.

---

**Audit completed by:** Principal Platform Architect  
**Date:** 2026-09-19  
**Status:** ⏳ AWAITING HUMAN REVIEW
