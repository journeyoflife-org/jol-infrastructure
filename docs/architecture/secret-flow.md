# Secret Flow Architecture

## Vaultwarden → External Secrets Operator → Kubernetes Secret

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Vaultwarden  │────▶│ External Secrets  │────▶│  Kubernetes     │
│  (self-hosted)│ API │ Operator (ESO)   │ sync │ Secret          │
└──────────────┘     └──────────────────┘     └────────┬────────┘
                                                       │
                                                       ▼
                                                ┌─────────────────┐
                                                │  Application Pod │
                                                │  (env/mount)     │
                                                └─────────────────┘
```

## Flow Steps
1. Secrets are stored in Vaultwarden organized by `{env}/{service}/{key}`
2. `ClusterSecretStore` defines the Vaultwarden connection (webhook provider)
3. `ExternalSecret` resources in each namespace request specific secrets
4. ESO polls Vaultwarden on `refreshInterval` (default: 1h)
5. ESO creates/updates native Kubernetes `Secret` objects
6. Pods mount secrets via `envFrom` or `volumeMounts`

## Security Controls
- Vaultwarden API token stored in Kubernetes Secret (bootstrapped manually)
- IRSA role for ESO limits AWS access to secret retrieval only
- Network Policy restricts ESO pod egress to Vaultwarden + K8s API only
- All secrets encrypted at rest (KMS) and in transit (TLS)
- Audit log: Vaultwarden records all access events

## Secret Rotation
1. Update secret value in Vaultwarden
2. ESO detects change on next refresh cycle
3. Kubernetes Secret is updated
4. Application detects change via file watch or restart
5. Old secret value invalidated at the service level
