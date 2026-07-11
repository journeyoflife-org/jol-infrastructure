# Runbook: Service Scaling

## When to Scale
- CPU/Memory utilization consistently above 75%
- Response latency exceeding SLA thresholds
- Anticipated traffic spike (marketing campaign, holiday)

## Horizontal Pod Autoscaler (HPA)

### Check Current HPA Status
```bash
kubectl get hpa -n jol-{env}
kubectl describe hpa {service}-hpa -n jol-{env}
```

### Manual Scale (temporary)
```bash
# Scale deployment directly
kubectl scale deployment/{service} --replicas=5 -n jol-{env}

# Update HPA max replicas
kubectl patch hpa {service}-hpa -n jol-{env} -p '{"spec":{"maxReplicas":10}}'
```

## Node Group Scaling

### Check Node Group
```bash
aws eks describe-nodegroup \
  --cluster-name jol-{env}-cluster \
  --nodegroup-name jol-{env}-nodes
```

### Scale Node Group
```bash
aws eks update-nodegroup-config \
  --cluster-name jol-{env}-cluster \
  --nodegroup-name jol-{env}-nodes \
  --scaling-config desiredSize=5,maxSize=10,minSize=3
```

## Rollback
```bash
# Scale back down
kubectl scale deployment/{service} --replicas={original} -n jol-{env}

# Reset HPA
helm upgrade {service} helm/charts/{service} \
  -f helm/environments/{env}/values-{service}.yaml \
  -n jol-{env}
```
