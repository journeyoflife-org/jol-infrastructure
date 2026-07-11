# ADR-006: Monitoring Stack (Prometheus + Grafana + CloudWatch)

## Status
Accepted

## Context
We need comprehensive observability across infrastructure and application layers.
SOC 2 CC7.1 requires continuous monitoring of system operations.

## Decision
Use a hybrid monitoring stack:
- **Prometheus** (kube-prometheus-stack): Metrics collection and alerting
- **Grafana**: Dashboards and visualization
- **CloudWatch**: AWS-native metrics, logs, and alarms

## Consequences
- **Positive**: Prometheus is the Kubernetes-native standard
- **Positive**: CloudWatch provides AWS infrastructure visibility
- **Positive**: Grafana enables unified dashboards across both sources
- **Negative**: Two metric systems increase storage costs
- **Risk**: Alert fatigue mitigated by severity-based routing

## Alternatives Considered
1. Datadog — rejected (cost at scale)
2. CloudWatch only — rejected (insufficient K8s visibility)
3. Pure Prometheus — rejected (no AWS infra metrics)
