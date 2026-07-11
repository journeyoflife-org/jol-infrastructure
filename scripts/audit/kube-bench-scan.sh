#!/usr/bin/env bash
# =============================================================================
# CIS Kubernetes Benchmark Scan
# Runs kube-bench to assess cluster security posture
# =============================================================================
set -euo pipefail

ENV="${1:-dev}"

echo "🔍 Running CIS Kubernetes Benchmark scan for ${ENV}..."

# Ensure kubeconfig is set
aws eks update-kubeconfig --name "jol-${ENV}-cluster" --region eu-central-1

# Run kube-bench as a Job
kubectl apply -f - << YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-$(date +%s)
  namespace: default
spec:
  template:
    spec:
      hostPID: true
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:latest
          command: ["kube-bench", "run", "--benchmark", "eks-1.2.0"]
          volumeMounts:
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
      restartPolicy: Never
  backoffLimit: 0
YAML

echo "⏳ Waiting for kube-bench job to complete..."
kubectl wait --for=condition=complete job/kube-bench --timeout=300s

echo ""
echo "✅ Scan complete. View results with:"
echo "   kubectl logs job/kube-bench"
