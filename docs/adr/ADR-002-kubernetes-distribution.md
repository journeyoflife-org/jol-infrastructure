# ADR-002: Kubernetes Distribution (Amazon EKS)

## Status
Accepted

## Context
We need a managed Kubernetes platform that supports multi-tenant workloads,
integrates with AWS IAM, and meets SOC 2/GDPR compliance requirements.

## Decision
Use Amazon EKS (Elastic Kubernetes Service) as the container orchestration platform.

## Consequences
- **Positive**: Managed control plane, AWS IAM integration (IRSA), auto-patching
- **Positive**: Native VPC networking, Security Groups for Pods
- **Positive**: FIPS-compatible endpoints available for regulated workloads
- **Negative**: $0.10/hr control plane cost per cluster
- **Negative**: EKS lags 1-2 minor versions behind upstream Kubernetes

## Alternatives Considered
1. Self-managed Kubernetes (kubeadm) — rejected (operational burden)
2. Google GKE — rejected (multi-cloud complexity, team AWS expertise)
3. ECS — rejected (less flexible for complex workloads)

## Compliance
- SOC 2 CC6.1: IRSA for pod-level IAM, no shared credentials
- GDPR Art.25: Encryption in transit (TLS) and at rest (EBS KMS)
