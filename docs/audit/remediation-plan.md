# JOL Repository Audit — Remediation Plan

**Date:** 2026-09-19  
**Status:** ⏳ PROPOSED — AWAITING APPROVAL  
**Pilot Repository:** `jol-infrastructure`  
**Total Effort:** 196-337 hours  
**Timeline:** Q4 2026 / Q1 2027

---

## Executive Summary

This remediation plan addresses 27 findings from the JOL repository audit. The plan is organized into **4 batches** with clear priorities, repo lists, and effort estimates. **Pilot batch** = `jol-infrastructure` (proves the process before scaling to other repos).

### Batch Overview

| Batch | Priority | Repos | Findings | Effort | Timeline |
|-------|----------|-------|----------|--------|----------|
| **0** | 🔴 IMMEDIATE | 1 | 1 | 4-8 hours | This week |
| **1** | 🟠 Q4 2026 | 4 | 7 | 96-168 hours | Q4 2026 |
| **2** | 🟡 Q1 2027 | 10 | 6 | 52-96 hours | Q1 2027 |
| **3** | 🟡 Post-pilot | 15 | 4 | 552-1064 hours | Post-pilot |
| **TOTAL** | — | 29 | 18 | **704-1336 hours** | — |

*Note: 9 findings are already FIXED or VERIFIED as false positives (H3, S2-S4, S6-S10)*

---

## Batch 0 — IMMEDIATE (This Week)

**Priority:** 🔴 CRITICAL  
**Pilot:** `jol-infrastructure` (process proof)  
**Effort:** 4-8 hours  
**Owner:** Platform Architect

### Findings

| ID | Finding | Repo | Effort |
|----|---------|------|--------|
| **S1** | 3 real database passwords in bootstrap scripts | `jol-auth` | 4-8 hours |

### Tasks

1. **Rotate database passwords** (1 hour)
   - Generate new passwords for `jol_lt_platform_prod` and `jol_identity`
   - Update PostgreSQL on production database server

2. **Update Ansible Vault** (1 hour)
   - Edit `ansible/group_vars/jol_auth/vault.yml` with new passwords
   - Encrypt with `ansible-vault encrypt`
   - Commit encrypted vault

3. **Update bootstrap scripts** (2-4 hours)
   - Replace hardcoded passwords with environment variables
   - Create wrapper script `scripts/run-with-vault.sh`
   - Test database connectivity

4. **Verify remediation** (1 hour)
   - Confirm no hardcoded passwords remain
   - Verify vault is encrypted
   - Test pre-commit hook (detect-secrets)

### Success Criteria

- ✅ No hardcoded passwords in `jol-auth` scripts
- ✅ Vault file encrypted with `ansible-vault`
- ✅ Database connectivity verified with new passwords
- ✅ Pre-commit hook detects secrets

### Rollback Plan

1. Restore scripts from git: `git checkout HEAD~1 scripts/`
2. Restore database passwords (if already rotated)
3. Remove vault file: `rm -rf ansible/`

---

## Batch 1 — Q4 2026

**Priority:** 🟠 HIGH  
**Pilot:** `jol-infrastructure` (process proof)  
**Effort:** 96-168 hours  
**Owner:** Platform Architect + DPO + Legal

### Findings

| ID | Finding | Repo | Effort |
|----|---------|------|--------|
| **H1** | `jol-core` is empty (no shared models) | `jol-core` | 0 hours (de-scope) |
| **H2** | `jol-rag-server` minimal CI | `jol-rag-server` | 16-24 hours |
| **C1** | Privacy policies missing | `jol-compliance` | 40-80 hours |
| **C2** | Compliance matrix incomplete | `jol-compliance` | 16-24 hours |
| **C3** | ROPA templates only | `jol-compliance` | 20-30 hours |
| **C4** | DPIA templates only | `jol-compliance` | 16-24 hours |
| **M5** | `jol-auth` .env file in version control | `jol-auth` | 2-4 hours |

### Tasks

#### Week 1-2: Architecture (H1, H2, M5)

1. **De-scope `jol-core`** (0 hours)
   - Document decision in ADR
   - Update ecosystem map

2. **Add CI to `jol-rag-server`** (16-24 hours)
   - Add `security-scan` workflow
   - Add `dependency-review` workflow
   - Add `lockfile-validation` workflow
   - Add `codeql` workflow
   - Add `compliance-check` workflow
   - Test all workflows

3. **Remove `jol-auth` .env from git** (2-4 hours)
   - Add `.env` to `.gitignore`
   - Remove from git: `git rm --cached .env`
   - Commit change
   - Verify `.env.example` is present

#### Week 3-6: Compliance (C1-C5)

4. **Create EU privacy policies** (40-80 hours)
   - Draft privacy policy template (Art. 13-14 compliant)
   - Customize for 27 EU member states
   - Translate to LT/LV/EE (priority languages)
   - Document Art. 9(2)(d) basis
   - Publish on public-facing websites
   - Link from COMPLIANCE_MATRIX.md

5. **Complete compliance matrix** (16-24 hours)
   - Fill in 117 [STATUS] placeholders
   - Update 20 [DATE] placeholders
   - Link to evidence documents
   - Establish quarterly review cadence

6. **Complete ROPA** (20-30 hours)
   - Identify all Art.9 processing activities
   - Create ROPA for each activity
   - Document purpose, legal basis, retention periods
   - Identify data flows and processors

7. **Conduct DPIA** (16-24 hours)
   - Identify high-risk processing activities
   - Conduct DPIA for each activity
   - Document necessity and proportionality
   - Identify risks and mitigation measures
   - Consult VDAI if residual risk is high

### Success Criteria

- ✅ `jol-rag-server` has 5 CI workflows
- ✅ `jol-auth` .env removed from git
- ✅ 27 privacy policies created and published
- ✅ Compliance matrix has 0 placeholders
- ✅ ROPA created for all Art.9 processing
- ✅ DPIA completed for all high-risk processing

### Rollback Plan

1. Restore CI workflows from git (if needed)
2. Restore .env to git (if needed)
3. Revert compliance documents (if needed)

---

## Batch 2 — Q1 2027

**Priority:** 🟡 MEDIUM  
**Pilot:** `jol-infrastructure` (process proof)  
**Effort:** 52-96 hours  
**Owner:** Platform Architect

### Findings

| ID | Finding | Repo | Effort |
|----|---------|------|--------|
| **S5** | 80 unpinned GitHub Actions | All repos | 8-16 hours |
| **M1** | No monorepo tooling | `jol-hub` | 40-80 hours |
| **M2** | Inconsistent Node.js versions | All repos | 16-24 hours |
| **L1** | No API versioning strategy | `jol-hub` | 8-16 hours |
| **L3** | No ADR process | All repos | 8-16 hours |
| **L4** | No code ownership (CODEOWNERS) | Most repos | 4-8 hours |

### Tasks

#### Week 1-2: Security (S5)

1. **Pin GitHub Actions to SHA** (8-16 hours)
   - Identify all unpinned actions
   - Pin each action to SHA
   - Add Dependabot configuration
   - Test CI/CD pipelines

#### Week 3-6: Architecture (M1, M2, L1, L3, L4)

2. **Add monorepo tooling** (40-80 hours)
   - Evaluate Turborepo vs Nx
   - Configure tooling for `jol-hub`
   - Migrate existing packages
   - Update documentation

3. **Standardize Node.js versions** (16-24 hours)
   - Choose LTS version (Node 20)
   - Update all repos
   - Update CI workflows
   - Test all repos

4. **Add API versioning** (8-16 hours)
   - Choose versioning strategy (URL path vs header)
   - Implement in `jol-hub`
   - Update documentation

5. **Add ADR process** (8-16 hours)
   - Create ADR template
   - Add to all repos
   - Document process

6. **Add CODEOWNERS** (4-8 hours)
   - Create CODEOWNERS file for each repo
   - Define ownership rules
   - Test with PR reviews

### Success Criteria

- ✅ All GitHub Actions pinned to SHA
- ✅ Monorepo tooling configured for `jol-hub`
- ✅ All repos use Node 20 LTS
- ✅ API versioning implemented
- ✅ ADR process documented
- ✅ CODEOWNERS in all repos

---

## Batch 3 — Post-pilot

**Priority:** 🟡 LOW  
**Pilot:** `jol-infrastructure` (process proof)  
**Effort:** 552-1064 hours  
**Owner:** Platform Architect + Development Team

### Findings

| ID | Finding | Repo | Effort |
|----|---------|------|--------|
| **M3** | No shared component library | `jol-hub` | 80-160 hours |
| **M4** | No design system | `jol-hub` | 40-80 hours |
| **H4** | Zero test coverage | All repos | 400-800 hours |
| **L2** | No feature flag system | `jol-hub` | 16-24 hours |
| **L5** | No performance monitoring | All repos | 16-24 hours |

### Tasks

1. **Create shared component library** (80-160 hours)
   - Extract common components from `jol-hub`
   - Create Storybook documentation
   - Publish to npm (internal)
   - Migrate spokes to use library

2. **Create design system** (40-80 hours)
   - Define design tokens
   - Create component library
   - Document design principles
   - Train development team

3. **Add test coverage** (400-800 hours)
   - Add unit tests to all repos (target: 80% coverage)
   - Add integration tests to Tier 0/1 repos
   - Add E2E tests to critical flows
   - Set up CI test reporting

4. **Add feature flag system** (16-24 hours)
   - Evaluate feature flag tools
   - Implement in `jol-hub`
   - Document process

5. **Add performance monitoring** (16-24 hours)
   - Choose monitoring tool (e.g., New Relic, Datadog)
   - Add to all repos
   - Set up alerting

### Success Criteria

- ✅ Shared component library published
- ✅ Design system documented
- ✅ Test coverage ≥80% in all repos
- ✅ Feature flag system implemented
- ✅ Performance monitoring in all repos

---

## Pilot Strategy

### Why `jol-infrastructure` as Pilot?

1. **Low risk** — Infrastructure repo, not user-facing
2. **High visibility** — Used by all other repos
3. **Proves process** — Validates remediation workflow
4. **Builds confidence** — Demonstrates success before scaling

### Pilot Execution

1. **Batch 0:** Execute S1 remediation in `jol-auth` (pilot for security remediation)
2. **Batch 1:** Execute H2, M5 in `jol-infrastructure` (pilot for architecture remediation)
3. **Batch 1:** Execute C1-C5 in `jol-compliance` (pilot for compliance remediation)
4. **Batch 2:** Execute S5, M2, L3, L4 in `jol-infrastructure` (pilot for medium-priority)
5. **Scale:** Apply learnings to other repos

### Pilot Success Criteria

- ✅ All Batch 0-2 findings remediated in pilot repos
- ✅ Process documented
- ✅ Learnings captured
- ✅ Ready to scale to other repos

---

## Resource Plan

### Roles

| Role | FTE | Duration | Responsibility |
|------|-----|----------|----------------|
| Platform Architect | 1.0 | Q4 2026 - Q1 2027 | Architecture remediation (Batches 0-2) |
| DPO | 0.5 | Q4 2026 | Compliance remediation (C1-C4) |
| Legal | 0.5 | Q4 2026 | Privacy policies (C1) |
| Development Team | 2.0 | Post-pilot | Test coverage, component library (Batch 3) |

### Budget

| Batch | Effort | Cost (@ €100/hour) | Timeline |
|-------|--------|--------------------|----------|
| 0 (Immediate) | 4-8 hours | €400-800 | This week |
| 1 (Q4 2026) | 96-168 hours | €9,600-16,800 | Q4 2026 |
| 2 (Q1 2027) | 52-96 hours | €5,200-9,600 | Q1 2027 |
| 3 (Post-pilot) | 552-1064 hours | €55,200-106,400 | Post-pilot |
| **TOTAL** | **704-1336 hours** | **€70,400-133,600** | — |

---

## Risk Mitigation

### Risk 1: S1 remediation fails

**Likelihood:** LOW  
**Impact:** HIGH  
**Mitigation:**
- Rollback plan documented
- Test in staging first
- Have DBA on standby

### Risk 2: Privacy policies take longer than expected

**Likelihood:** MEDIUM  
**Impact:** MEDIUM  
**Mitigation:**
- Use template-based approach
- Prioritize LT/LV/EE first
- Outsource translation if needed

### Risk 3: Monorepo tooling breaks existing builds

**Likelihood:** MEDIUM  
**Impact:** HIGH  
**Mitigation:**
- Pilot in `jol-infrastructure` first
- Test thoroughly before scaling
- Have rollback plan

### Risk 4: Test coverage takes too long

**Likelihood:** HIGH  
**Impact:** MEDIUM  
**Mitigation:**
- Prioritize Tier 0/1 repos
- Focus on critical paths first
- Use AI-assisted test generation

---

## Verification Plan

### After Each Batch

1. **Re-run audit scanners**
   - Architecture assessment
   - Security scan
   - Compliance review

2. **Verify success criteria**
   - All findings addressed
   - No regressions
   - Documentation updated

3. **Update compliance matrix**
   - Change status from [STATUS] to ✅ COMPLIANT
   - Link to evidence

4. **Sign-off**
   - Platform Architect
   - DPO (for compliance)
   - CISO (for security)

### Final Verification (Post-Batch 3)

1. **Full audit re-run**
   - All 29 repos
   - All frameworks

2. **Compliance audit**
   - GDPR Art.9
   - PCI-DSS
   - ISO 27001
   - SOC 2

3. **Security audit**
   - Penetration test
   - Vulnerability scan
   - Secret scan

4. **Architecture review**
   - CI/CD coverage
   - Test coverage
   - Documentation completeness

---

## Governance

### Change Control

All remediation follows SOC 2 CC8.1 change control:
1. GitHub Issue created
2. PR reviewed and approved
3. Tests pass
4. Deployed to staging
5. Verified
6. Deployed to production
7. CHANGELOG.md updated

### Documentation

All changes documented in:
- `CHANGELOG.md` (per repo)
- `docs/audit/` (audit artifacts)
- `docs/compliance/` (compliance artifacts)

### Communication

Weekly status updates to:
- Platform Architect
- DPO
- CISO
- CEO

---

## Approval

### Option (a): Audit only — stop here
- ❌ No remediation
- ❌ S1 remains CRITICAL
- ❌ Compliance gaps remain
- **Effort saved:** 196-337 hours
- **Risk:** HIGH

### Option (b): Audit then remediate — continue to Step 9 ✅ RECOMMENDED
- ✅ Remediate CRITICAL/HIGH findings
- ✅ Address S1 (rotate passwords)
- ✅ Address compliance gaps
- **Effort:** 100-176 hours (Batch 0 + Batch 1)
- **Risk:** MEDIUM

### Option (c): Full workflow — continue through Step 11
- ✅ Remediate all findings
- ✅ Verify remediation
- ✅ Final sign-off
- **Effort:** 704-1336 hours (all batches)
- **Risk:** LOW

---

## Sign-off

**Plan created by:** Principal Platform Architect  
**Date:** 2026-09-19  
**Status:** ⏳ PROPOSED — AWAITING APPROVAL

**Gate 8 status:** ⏳ **AWAITING DECISION** — Choose path: (a) audit only, (b) audit then remediate, or (c) full workflow.

---

**Recommendation:** Option (b) — Audit then remediate (Batch 0 + Batch 1).
