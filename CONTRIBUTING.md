# Contributing to jol-infrastructure

## Getting Started

1. Clone the repository
2. Run the bootstrap script: `./scripts/bootstrap/01-setup-repo.sh`
3. Verify tools: `./scripts/utils/check-tools.sh`
4. Install pre-commit hooks: `pre-commit install`

## Development Workflow

### 1. Create a Feature Branch
```bash
git checkout -b feature/JOL-XXX-description
```

### 2. Make Changes
- Terraform: `terraform/` — infrastructure modules and environments
- Kubernetes: `kubernetes/` — cluster configuration and policies
- Helm: `helm/` — application deployment charts
- Policies: `policies/` — OPA, Checkov, tfsec rules

### 3. Validate Locally
```bash
make validate    # Format + lint + OPA + checkov + tfsec
make scan        # Security scanning
```

### 4. Submit Pull Request
- Use the PR template (auto-populated)
- Ensure all CI checks pass
- Request review from CODEOWNERS

### 5. Merge
- Squash merge to keep history clean
- Production applies via manual `workflow_dispatch` only

## Code Standards

### Terraform
- Run `terraform fmt` before committing
- All resources must have `tags`
- No hardcoded secrets (use variables + ESO)
- Follow module pattern: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`

### Kubernetes
- All pods must have resource limits
- `automountServiceAccountToken: false` on all service accounts
- Network policies required for all namespaces
- Pod Security Standards labels on all namespaces

### Helm
- All charts must include: Deployment, Service, Ingress, HPA, NetworkPolicy templates
- Environment values override chart defaults
- Use `_helpers.tpl` for common labels

### Shell Scripts
- Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- Use `set -euo pipefail` in all scripts
- Shellcheck must pass with no warnings

## Security

- **Never** commit secrets, credentials, or API keys
- Pre-commit hooks scan for secrets via TruffleHog
- All infrastructure changes reviewed by CODEOWNERS
- Production changes require approval + manual trigger

## Documentation

- Architecture decisions: `docs/adr/`
- Runbooks: `docs/runbooks/`
- See [docs/](docs/) for full documentation index
