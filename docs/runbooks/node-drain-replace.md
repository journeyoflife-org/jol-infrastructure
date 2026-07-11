# Runbook: Node Drain & Replace

## When to Use
- Node is unhealthy (NotReady, high disk pressure)
- OS patching required
- Instance type change needed

## Procedure

### 1. Identify the Node
```bash
kubectl get nodes -l environment=prod
kubectl describe node {node-name}
```

### 2. Cordon (prevent new scheduling)
```bash
kubectl cordon {node-name}
```

### 3. Drain (evict pods gracefully)
```bash
kubectl drain {node-name} \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60 \
  --timeout=300s
```

### 4. Terminate the Instance
```bash
# Via AWS Console or CLI
aws ec2 terminate-instances --instance-ids {instance-id}

# EKS node group will auto-replace the node
```

### 5. Verify Replacement
```bash
# Wait for new node to join (2-5 minutes)
kubectl get nodes -l environment=prod
kubectl get pods -A -o wide | grep {new-node}
```

### 6. Uncordon (if node was kept)
```bash
kubectl uncordon {node-name}
```

## Rollback
If new node doesn't join:
1. Check node group desired count
2. Manually increase ASG desired capacity
3. Investigate bootstrap logs via SSM
