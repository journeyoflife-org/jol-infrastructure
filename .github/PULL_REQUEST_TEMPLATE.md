## 🏗️ Infrastructure Pull Request

> **All infrastructure changes are subject to SOC 2 CC8.1 change management controls.**

---

### 📋 Change Summary

<!-- Describe the infrastructure change in 2-3 sentences -->

### 🎯 Change Type

- [ ] Terraform (cloud resources)
- [ ] Kubernetes (cluster config)
- [ ] Helm (application deployment)
- [ ] Policy (OPA/Checkov/tfsec)
- [ ] CI/CD (GitHub Actions)
- [ ] Other

### 🌍 Target Environment(s)

- [ ] dev
- [ ] staging
- [ ] prod

### ⚠️ Risk Assessment

**Risk Level:** Low / Medium / High / Critical

**Blast Radius:**
<!-- Describe what systems/services are affected -->

### 📝 Detailed Description

<!-- Provide a detailed description of the change -->

### 🔙 Rollback Plan

<!-- Describe how to revert this change if it fails -->

1.
2.
3.

### 🎫 Ticket Reference

- **Jira/Linear:** `JOL-XXXX`
- **RFC/ADR:** <!-- link if applicable -->

### ✅ Pre-Merge Checklist

- [ ] `terraform fmt` and `terraform validate` pass
- [ ] `checkov` scan passes with no new critical findings
- [ ] `tfsec` scan passes
- [ ] OPA policy tests pass
- [ ] No secrets committed (TruffleHog clean)
- [ ] Cost impact assessed (if applicable)
- [ ] GDPR data impact assessed (if applicable)
- [ ] Rollback plan documented
- [ ] CHANGELOG.md updated (for production changes)

### 📊 Cost Impact

<!-- Estimated monthly cost change (use Infracost output if available) -->

| Before | After | Delta |
|--------|-------|-------|
| $      | $     | $     |

---

> 📌 **Production applies are manual only** — use the `Production Apply` workflow with proper approval.
