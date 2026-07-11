# Runbook: TLS Certificate Renewal

## Overview
cert-manager automatically renews Let's Encrypt certificates before expiry.
This runbook covers manual intervention when auto-renewal fails.

## Check Certificate Status
```bash
kubectl get certificates -A
kubectl get certificaterequests -A
kubectl describe certificate {name} -n {namespace}
```

## Manual Renewal
```bash
# Delete the existing certificate to trigger re-issuance
kubectl delete certificate {name} -n {namespace}

# Verify new certificate is issued
kubectl get certificate {name} -n {namespace} -w
```

## Troubleshooting
1. Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager`
2. Verify DNS propagation: `dig +short _acme-challenge.{domain}`
3. Check rate limits: Let's Encrypt allows 5 certs/domain/week
4. Verify ClusterIssuer status: `kubectl get clusterissuer letsencrypt-prod`

## Emergency: Self-Signed Certificate
```bash
# Only if Let's Encrypt is unavailable
kubectl apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {service}-selfsigned
  namespace: {namespace}
spec:
  secretName: {service}-tls
  duration: 24h
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  commonName: {domain}
YAML
```
