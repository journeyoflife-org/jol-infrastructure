# Runbook: Secret Rotation

## Overview
Procedure for rotating application secrets (database credentials, API keys, TLS certs).

**ISO 27001 A.8.7**: Cryptographic keys rotated on defined schedule.
**SOC 2 CC6.1**: Logical access credentials rotated periodically.

## Prerequisites
- Access to Vaultwarden admin console
- `kubectl` access to target cluster
- Application health dashboard access

## Procedure

### 1. Generate New Credentials
```bash
# In Vaultwarden:
# Navigate to: {env}/{service}/database
# Generate new password (min 32 chars, alphanumeric + special)
# Save — do NOT close the old entry yet
```

### 2. Wait for ESO Sync
```bash
# Check ExternalSecret status
kubectl get externalsecret -n jol-{env} -o yaml
# Wait for lastSyncTime to update (max 1 hour)

# Force sync if needed:
kubectl annotate externalsecret {name} -n jol-{env} force-sync=$(date +%s) --overwrite
```

### 3. Verify Application Health
```bash
kubectl get pods -n jol-{env} -l app={service}
kubectl logs -n jol-{env} -l app={service} --tail=50
```

### 4. Restart Deployment (if app doesn't auto-detect)
```bash
kubectl rollout restart deployment/{service} -n jol-{env}
kubectl rollout status deployment/{service} -n jol-{env}
```

### 5. Remove Old Credentials
Wait 24 hours, then delete the old entry from Vaultwarden.

## Rollback
If the new secret causes failures:
1. Revert to old secret value in Vaultwarden
2. Force ESO sync
3. Restart deployment

## Documentation
Log rotation in `CHANGELOG.md` with ticket reference.
