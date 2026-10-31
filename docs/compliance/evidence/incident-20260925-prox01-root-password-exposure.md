# Security Incident: prox01 Root Password Exposed in Plain Text

| Field | Value |
|-------|-------|
| **Incident ID** | INC-20260925-PWD-EXPOSURE |
| **Date** | 2026-09-25 |
| **Severity** | **CRITICAL** — root credential exposure on production hypervisor |
| **Classification** | Secret management violation (AGENTS.md §0.1 zero-tolerance) |
| **Status** | OPEN — immediate rotation required |

## 1. Summary

During the VM 205 (`tfstate-prod-01`) creation session, the **prox01 root password** was shared in plain text in an agent conversation. This violates AGENTS.md §0.1 (secret management — zero tolerance) and SOC 2 CC6.1 (logical access controls).

**Exposed credential**: prox01 root password (shared in chat)

**Impact**: 
- Password is in conversation history (potentially logged/stored)
- Anyone with access to this conversation can compromise prox01
- prox01 is a **production hypervisor** hosting AI service VMs (RAG, MCP, Hermes) and pilot VMs
- Full root access = complete control over all VMs, ZFS storage, network config

## 2. Root cause

Operator shared the password in plain text in chat instead of using approved secret injection methods:
- Vaultwarden (runtime injection)
- Encrypted variable files (Ansible Vault / SOPS)
- Interactive prompt at deploy time

## 3. Immediate remediation (MUST complete within 1 hour)

### Step 1: Rotate the prox01 root password NOW

```bash
# SSH to prox01 with the compromised password
ssh root@10.60.60.10

# Change the password immediately
passwd

# Generate a strong new password:
openssl rand -base64 24

# Enter the new password when prompted
# Confirm the new password
```

### Step 2: Store the new password securely

- Store the new password in **Vaultwarden ONLY**
- Location: `JOL Infrastructure / prox01 / root`
- **NEVER** share it in chat, email, tickets, or documentation

### Step 3: Verify no other systems reused the password

Check if the exposed password was reused on:
- pve-prod-hv01 (hypervisor)
- pbs01 (backup server)
- llm-prod-lt01 (LLM inference)
- Any AI service VMs (rag, mcp, her)
- Any pilot VMs

If reused, rotate those passwords too.

### Step 4: Audit access logs

```bash
# On prox01, check recent SSH access
last | head -20
cat /var/log/auth.log | grep "Accepted password" | tail -20

# Check for suspicious activity
journalctl -u ssh --since "2026-09-25" | grep -i "accepted\|failed"
```

### Step 5: Document the rotation

Update the CHANGELOG.md with the rotation:

```markdown
| 2026-09-25T... | @JourneyOfLife | prox01 root password rotated per INC-20260925-PWD-EXPOSURE. New password stored in Vaultwarden (JOL Infrastructure / prox01 / root). Verified no reuse on other systems. Access logs audited — no suspicious activity detected. | prod (security) | INC-20260925-PWD-EXPOSURE |
```

## 4. Compensating controls

- **Password rotation**: eliminates the exposed credential
- **Access log audit**: detects any unauthorized access during the exposure window
- **Vaultwarden storage**: prevents future plain-text exposure

## 5. Preventive measures (implement within 1 week)

### 5.1 Update operator runbooks

Add explicit warnings to all runbooks:

```markdown
⚠ **SECURITY**: NEVER share passwords in chat, email, or tickets.
Use Vaultwarden for runtime injection or encrypted variable files.
See AGENTS.md §0.1 for secret management policy.
```

### 5.2 Add pre-flight checks to provisioning scripts

Update `prox01-create-vm205-tfstate.sh` and similar scripts to check for and reject plain-text credentials:

```bash
# Check if password was passed as argument (reject)
if [ $# -gt 0 ]; then
    echo "ERROR: Do not pass passwords as command-line arguments (shell history exposure)"
    echo "Use interactive prompt or Vaultwarden injection"
    exit 1
fi
```

### 5.3 Train operator on secret injection methods

Document approved methods:
1. **Vaultwarden**: `run-with-vault.sh` pattern (see `docs/architecture/secret-flow.md`)
2. **Ansible Vault**: encrypted variable files for batch operations
3. **SOPS**: encrypted config files with age key
4. **Interactive prompt**: `read -s -p "Password: " PASSWORD` for one-time use

### 5.4 Add secret detection to CI

Ensure pre-commit hooks detect plain-text credentials:
- `detect-secrets` hook (already configured)
- `trufflehog` scan (already configured)
- `git-secrets` patterns for common password formats

## 6. Compliance impact

- **SOC 2 CC6.1**: Logical access controls compromised (root credential exposed)
- **SOC 2 CC7.2**: Monitoring and detection required (access log audit)
- **GDPR Art. 32**: Security of processing — credential exposure could lead to unauthorized access to special-category data (religious affiliation, Art. 9)
- **ISO 27001 A.9.2**: User access provisioning — credential management failure
- **AGENTS.md §0.1**: Zero-tolerance secret management violation

## 7. Lessons learned

1. **Never share credentials in plain text** — even in "private" conversations
2. **Use approved secret injection methods** — Vaultwarden, Ansible Vault, SOPS
3. **Rotate immediately upon exposure** — don't wait, don't rationalize
4. **Document incidents** — transparency enables improvement
5. **Train continuously** — secret management is a habit, not a one-time lesson

## 8. Verification gates

- [ ] prox01 root password rotated
- [ ] New password stored in Vaultwarden
- [ ] No other systems reused the exposed password
- [ ] Access logs audited (no suspicious activity)
- [ ] CHANGELOG updated with rotation record
- [ ] Operator runbooks updated with security warnings
- [ ] Preventive measures implemented (within 1 week)

## 9. Rollback

Not applicable — password rotation is irreversible. If the new password is lost, use the prox01 console (physical or IPMI if available) to reset.

## 10. References

- AGENTS.md §0.1 — Secret Management (Zero Tolerance)
- AGENTS.md §0.3 — Change Control (SOC 2 CC8.1)
- `docs/architecture/secret-flow.md` — approved secret injection methods
- `docs/runbooks/secret-rotation.md` — password rotation procedure
- CHANGELOG.md — incident + rotation records
