# Internal CA & Certificate Generation

Keys and certs for this directory are **generated, never committed**
(see `.gitignore`). This README is the normative procedure; the script
implementation is `scripts/security/generate-mtls-certs.sh`.

## One-time CA creation (offline CA host)

```bash
sudo scripts/security/generate-mtls-certs.sh --init-ca
```

Produces:

| File | Purpose | Lifetime |
|---|---|---|
| `ca.key` | CA private key — offline, encrypted at rest, vault passphrase | 5 years |
| `ca.crt` | CA certificate — distributed to server + clients | 5 years |
| `index.txt`, `serial` | CA bookkeeping for revocation | ongoing |

## Server leaf (llm-prod-lt01)

```bash
sudo scripts/security/generate-mtls-certs.sh --leaf llm-prod-lt01 \
    --san "DNS:llm.jol.internal,IP:10.40.10.21"
```

Install per `docs/04-operations/runbooks/certificate-rotation.md`.

## Client certificates

```bash
sudo scripts/security/generate-mtls-certs.sh --client team-x
```

CN = team identifier; hand out `.crt` + `.key` over the secure channel
only; record issuance in the access-control matrix.

## Revocation

```bash
sudo scripts/security/generate-mtls-certs.sh --revoke team-x.crt
# regenerates ca.crl → deploy to /etc/caddy/tls/ca.crl → reload caddy
```

## Security rules

- `ca.key` never leaves the offline CA host except for disaster recovery
  (which is itself an incident).
- Leaf keys: 0600 root, group caddy (0640).
- All generation events are logged to the audit trail by the script.
