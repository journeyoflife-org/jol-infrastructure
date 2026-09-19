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
| Qoder plugin | 2026.917.73315602 | Agentic AI coding assistant (auto-update disabled; full IDE matrix below) | JetBrains plugin |

## Workstation IDE and agent-runtime matrix

The Qoder plugin and the binaries it self-installs are pinned here because the
agent receives repository context and, for Terraform work, sits upstream of
`plan`/`apply`. Automatic plugin updates are disabled in Qoder Settings — but an
IDE upgrade re-resolves the whole plugin set and can replace a build without
touching that setting. That is how the pin in the table above went stale
undetected: finding **QD-1**, observed 2026-09-17T14:28–14:30Z when both IDEs
moved to 2026.2.2 and the plugin moved to 2026.917.73315602. Verified on the
workstation 2026-09-17 by file inspection.

| Component | Pinned version | Identifier / evidence |
|-----------|----------------|-----------------------|
| PyCharm (back-end track) | 2026.2.2 | build `PY-262.10315.174` |
| WebStorm (front-end track) | 2026.2.2 | build `WS-262.10315.144` |
| Qoder plugin — PyCharm | 2026.917.73315602 | `~/.local/share/JetBrains/PyCharm2026.2/qoder-jetbrains/lib/instrumented-qoder-product-2026.917.73315602.jar` |
| Qoder plugin — WebStorm | 2026.917.73315602 | same jar name under `WebStorm2026.2/` — both IDEs share one `~/.qoder` state root, so a version skew between them would be a hidden config fork |
| security-scan plugin | 0.8.1 | `security-scan@qoder-bundler`. **Enablement switch is OFF** while its layer toggles read true — finding QD-6 in [qoder-setup.md](qoder-setup.md); do not cite it as an operating control until gate G2 closes |
| qodersec binary | 0.8.0 | `~/.qodersec/bin/qodersec-version.json`, channel `global`, written 2026-09-05T17:59:48Z |
| qodercli binary | 1.0.45 | `~/.qodersec/bin/qodercli-version.json`, channel `global` |
| terraform MCP plugin | 0.1.0 | `terraform@qoder-marketplace` |
| terraform MCP image | `hashicorp/terraform-mcp-server:1.0.0` @ `sha256:5ded3710465158bd671ff86ed58842076ec34017ed3bfb8116c158723a3b0399` | digest read from the local store 2026-09-17 (`docker image inspect --format '{{.RepoDigests}}'`). ⚠ QD-7 stays open: the vendor manifest at `~/.qoder/plugins/cache/qoder-marketplace/terraform/0.1.0/.qoder-plugin/mcp.json` still *launches* by mutable tag, so the digest above is a witness record, not an enforcement point. Enforce only by overriding the server in Qoder Settings → MCP with the `@sha256:` reference |
| context7 / playwright / chrome-devtools-mcp plugins | 1.0.0 / 1.0.0 / 1.2.0 | front-end track; each needs a reachable browser or network, so expect them to fail closed on an air-gapped host |
| Node.js | 20.20.2 | `/usr/bin/node`, system-wide. An nvm-managed 20.11.0 also exists and is **not** the active interpreter — resolve with `which node` |
| pnpm | 10.30.3 | required by jol-hub and every `jol-site-*` spoke (`packageManager`); never substitute `npm install` |
| Python (repository venv) | 3.12.3 | `.venv/bin/python` |

`scripts/utils/check-tools.sh` validates CLI tools against minimum versions and
covers none of the rows above — IDE and agent-runtime drift is checked manually
at gate **G3** of [qoder-setup.md](qoder-setup.md), after every IDE or plugin
change and during the quarterly maintenance window.

## Verification
```bash
./scripts/utils/check-tools.sh
```
