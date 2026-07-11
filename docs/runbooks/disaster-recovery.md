# Runbook: Disaster Recovery

## RTO/RPO Targets

| Environment | RTO | RPO | Strategy |
|-------------|-----|-----|----------|
| Production | 1 hour | 15 min | Multi-AZ + automated failover |
| Staging | 4 hours | 1 hour | Restore from backup |
| Development | 24 hours | 24 hours | Re-provision from Terraform |

## Recovery Procedures

### EKS Cluster Recovery
1. **Control plane**: Managed by AWS (auto-recovery)
2. **Node groups**: Auto-scaling replaces failed nodes
3. **State**: Terraform state in versioned S3 bucket

```bash
# If cluster is unrecoverable:
cd terraform/environments/prod
terraform plan  # Verify no drift
terraform apply # Re-create cluster
```

### Database Recovery
```bash
# RDS automated backups (point-in-time recovery)
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier jol-prod-db \
  --target-db-instance-identifier jol-prod-db-restored \
  --restore-time $(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
```

### State Recovery
```bash
# S3 versioning — restore previous state
aws s3api list-object-versions \
  --bucket jol-terraform-state-prod \
  --prefix terraform.tfstate

# Download specific version
aws s3api get-object \
  --bucket jol-terraform-state-prod \
  --key terraform.tfstate \
  --version-id VERSION_ID \
  restored-state.tfstate
```

## Verification
After any DR event:
1. Verify all pods are running: `kubectl get pods -A`
2. Run health checks on all services
3. Verify database connectivity
4. Check monitoring dashboards
5. Confirm backup schedules are active
