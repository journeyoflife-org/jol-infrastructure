# jol-infrastructure

Infrastructure and DevOps configurations for **Journey of Life** — a production-grade,
compliance-ready infrastructure platform built on AWS, EKS, and Helm.

## Overview

This repository defines the complete infrastructure-as-code for the JOL platform:

- **Terraform** — AWS resources: VPC, EKS, IAM, storage, monitoring
- **Kubernetes** — Cluster configuration, RBAC, network policies, pod security
- **Helm** — Application deployment charts for all microservices
- **Policies** — OPA, Checkov, tfsec rules for compliance enforcement
- **CI/CD** — GitHub Actions workflows with SOC 2 change management controls
- **LLM host** — `llm/`: Ansible/systemd/Caddy stack for the air-gapped bare-metal LLM platform (llm-prod-lt01); see `llm/README.md`

## Architecture

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Dev VPC   │    │ Staging VPC │    │  Prod VPC   │
│ 10.2.0.0/16 │    │ 10.1.0.0/16 │    │ 10.0.0.0/16 │
│     EKS     │    │     EKS     │    │     EKS     │
└─────────────┘    └─────────────┘    └─────────────┘
```

Each environment uses a 3-tier VPC (public/private/database) with full network segmentation.

## Quick Start

```bash
# 1. Setup repository (git signing, pre-commit, tool check)
./scripts/bootstrap/01-setup-repo.sh

# 2. Verify required tools
make check-tools

# 3. Bootstrap Terraform state (ONE-TIME)
./scripts/bootstrap/02-bootstrap-state.sh

# 4. Plan infrastructure for dev
make plan-dev

# 5. Bootstrap EKS cluster
./scripts/bootstrap/03-bootstrap-cluster.sh dev
```

## Repository Structure

```
jol-infrastructure/
├── .github/           # CI/CD workflows, CODEOWNERS, templates
├── terraform/         # IaC: bootstrap, modules, environments
├── kubernetes/        # K8s: base configs, overlays, RBAC, policies
├── helm/              # Helm charts + environment values
├── policies/          # OPA, Checkov, tfsec policy-as-code
├── scripts/           # Bootstrap, maintenance, audit, utilities
├── llm/               # Bare-metal LLM host: Ansible, systemd, Caddy, monitoring
└── docs/              # ADRs, architecture, runbooks, dev setup
```

## Compliance

| Framework | Controls Implemented |
|-----------|---------------------|
| **SOC 2 Type II** | CC6.1, CC6.6, CC7.1, CC7.2, CC8.1 |
| **GDPR** | Art.25, Art.32, Art.33 |
| **ISO 27001** | A.8.4, A.8.7, A.12.1.2 |

## Development

```bash
# Run all validation (format, lint, OPA, checkov, tfsec)
make validate

# Run security scans
make scan

# Plan for specific environment
make plan-staging
make plan-prod
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development workflow.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting, GDPR breach procedures,
and security control details.

**P1 response: 4 hours** | **GDPR notification: 72 hours**

## Documentation

- [Architecture Decision Records](docs/adr/)
- [Network Topology](docs/architecture/network-topology.md)
- [Secret Flow](docs/architecture/secret-flow.md)
- [Runbooks](docs/runbooks/)
- [Tool Versions](docs/dev-setup/tool-versions.md)

## License

See [LICENSE](LICENSE).
