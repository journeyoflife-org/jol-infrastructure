# Tool Version Matrix

Pinned versions for all infrastructure tooling. Update quarterly during maintenance window.

| Tool | Version | Purpose | Install |
|------|---------|---------|---------|
| Terraform | 1.9.x | Infrastructure as Code | `brew install terraform` |
| kubectl | 1.30.x | Kubernetes CLI | `brew install kubectl` |
| Helm | 3.15.x | Package manager | `brew install helm` |
| AWS CLI | 2.17.x | AWS management | `brew install awscli` |
| pre-commit | 3.7.x | Git hooks | `pip install pre-commit` |
| checkov | 3.2.x | Terraform policy | `pip install checkov` |
| tfsec | 1.28.x | Terraform security | `brew install tfsec` |
| OPA | 0.67.x | Policy engine | `brew install opa` |
| kube-bench | 0.7.x | CIS benchmark | `brew install kube-bench` |
| trivy | 0.54.x | Vulnerability scanner | `brew install trivy` |
| syft | 1.8.x | SBOM generator | `brew install syft` |
| jq | 1.7.x | JSON processor | `brew install jq` |
| yq | 4.44.x | YAML processor | `brew install yq` |
| Qodana | 2024.1.x | Code quality | JetBrains plugin |

## Verification
```bash
./scripts/utils/check-tools.sh
```
