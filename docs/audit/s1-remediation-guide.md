# S1 Remediation Guide — jol-auth Database Password Rotation

**Date:** 2026-09-19  
**Status:** 🔴 CRITICAL — IMMEDIATE ACTION REQUIRED  
**Severity:** HIGH — Real database passwords in version control  
**Commit:** `e0c8b2e` (vault.yml added to jol-auth)

---

## Problem Statement

Database passwords are hardcoded in `jol-auth` bootstrap scripts:
- `scripts/bootstrap-jol-auth.sh` (lines 175, 212)
- `scripts/fix-and-run.sh` (line 69)

**Impact:**
- Violates AGENTS.md §0.1 (secret management)
- Violates SOC 2 CC6.1, ISO 27001 A.9.2, GDPR Art. 32
- Potential data breach if repo is compromised

---

## Remediation Steps

### Step 1: Rotate Database Passwords

**On the production database server:**

```bash
# Generate new passwords
openssl rand -base64 32  # Save as NEW_LT_PASSWORD
openssl rand -base64 32  # Save as NEW_IDENTITY_PASSWORD

# Connect to PostgreSQL as superuser
sudo -u postgres psql

# Rotate jol_lt_platform_prod password
ALTER USER jol_lt_app_user WITH PASSWORD 'NEW_LT_PASSWORD';

# Rotate jol_identity password
ALTER USER jol_identity_user WITH PASSWORD 'NEW_IDENTITY_PASSWORD';

\q
```

### Step 2: Update and Encrypt Vault

**In the jol-auth repo:**

```bash
cd /opt/jol/repos/jol-auth

# Edit the vault file with new passwords from Step 1
vim ansible/group_vars/jol_auth/vault.yml

# Encrypt the vault file
ansible-vault encrypt ansible/group_vars/jol_auth/vault.yml

# Commit the encrypted vault
git add ansible/group_vars/jol_auth/vault.yml
git commit -m "security: Encrypt vault with rotated database credentials"
```

### Step 3: Update Bootstrap Scripts

Replace hardcoded passwords with environment variables loaded from Vault:

```bash
# Create wrapper script
cat > scripts/run-with-vault.sh << 'WRAPPER'
#!/bin/bash
export JOL_LT_DB_PASSWORD=$(ansible-vault view ansible/group_vars/jol_auth/vault.yml | grep vault_jol_lt_db_password | cut -d'"' -f2)
export JOL_IDENTITY_DB_PASSWORD=$(ansible-vault view ansible/group_vars/jol_auth/vault.yml | grep vault_jol_identity_db_password | cut -d'"' -f2)
exec ./scripts/bootstrap-jol-auth.sh "$@"
WRAPPER
chmod +x scripts/run-with-vault.sh

# Update bootstrap-jol-auth.sh to use ${JOL_LT_DB_PASSWORD} and ${JOL_IDENTITY_DB_PASSWORD}
# Update fix-and-run.sh to use ${JOL_IDENTITY_DB_PASSWORD}
```

### Step 4: Verify Remediation

```bash
# 1. No hardcoded passwords in scripts
grep -r "OLD_PASSWORD" /opt/jol/repos/jol-auth/scripts/
# Expected: NO RESULTS

# 2. Vault file is encrypted
head -1 /opt/jol/repos/jol-auth/ansible/group_vars/jol_auth/vault.yml
# Expected: $ANSIBLE_VAULT;1.1;AES256

# 3. Pre-commit hook works
echo "test_password = 'hardcoded_secret'" > test.txt
git add test.txt
git commit -m "test"  # Should FAIL
rm test.txt
```

---

## Verification Commands

```bash
# Verify no hardcoded passwords remain
grep -r "JOL_LT_User_2026\|JOL_Identity_2026" /opt/jol/repos/jol-auth/scripts/
# Expected: NO RESULTS

# Verify vault is encrypted
head -1 /opt/jol/repos/jol-auth/ansible/group_vars/jol_auth/vault.yml
# Expected: $ANSIBLE_VAULT;1.1;AES256

# Verify database connectivity with new passwords
PGPASSWORD='NEW_LT_PASSWORD' psql -h localhost -U jol_lt_app_user -d jol_lt_platform_prod -c "SELECT 1;"
PGPASSWORD='NEW_IDENTITY_PASSWORD' psql -h localhost -U jol_identity_user -d jol_identity -c "SELECT 1;"
# Both should return: 1 row
```

---

## Compliance Impact

| Framework | Requirement | Before | After |
|-----------|-------------|--------|-------|
| **SOC 2** | CC6.1 (logical access) | 🔴 FAIL | ✅ PASS |
| **ISO 27001** | A.9.2 (user access) | 🔴 FAIL | ✅ PASS |
| **GDPR** | Art. 32 (security) | 🔴 FAIL | ✅ PASS |

---

## Rollback Plan

If remediation fails:

1. Restore scripts from git: `git checkout HEAD~1 scripts/`
2. Restore database passwords (if already rotated)
3. Remove vault file: `rm -rf ansible/`

---

## Sign-off

- [ ] Database passwords rotated
- [ ] Vault file updated and encrypted
- [ ] Bootstrap scripts updated
- [ ] Verification commands pass
- [ ] Compliance impact documented

**Remediated by:** _________________  
**Date:** _________________  
**Reviewed by:** _________________  
**Date:** _________________

---

**Status:** 🔴 PENDING — Requires production database access  
**Effort:** 4-8 hours  
**Owner:** Platform Architect
