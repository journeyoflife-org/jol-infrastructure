# PyCharm Remote Development + Qodana Setup

## Prerequisites
- PyCharm Professional 2024.1+
- JetBrains Gateway installed
- Remote server with SSH access

## Remote Development Setup

### 1. Connect via JetBrains Gateway
1. Open JetBrains Gateway
2. Select "Connect via SSH"
3. Enter host: `your-dev-server.example.com`
4. Select project path: `/opt/jol/repos/jol-infrastructure`

### 2. Configure Python Interpreter
1. Settings → Project → Python Interpreter
2. Add → SSH Interpreter
3. Path: `/opt/jol/repos/jol-infrastructure/.venv/bin/python`

### 3. Terminal Configuration
- Shell: `/bin/bash`
- Working directory: `/opt/jol/repos/jol-infrastructure`
- Activate venv: enabled (automatic)

## Qodana Configuration

The `qodana.yaml` at the repository root configures the community linter profile.

### Running Qodana Locally
```bash
# Via Docker
docker run --rm -v $(pwd):/data/project \
  jetbrains/qodana-community:latest

# Via CLI
qodana scan --project-dir . --results-dir ./qodana-results
```

### CI Integration
Qodana runs automatically in the `infra-validate.yml` GitHub Actions workflow.
It fails the pipeline on CRITICAL severity issues.

### Qodana in PyCharm
1. Install "Qodana" plugin from Marketplace
2. Tools → Qodana → Run Local Analysis
3. Review findings in the Qodana tool window

## See Also

- [qoder-setup.md](qoder-setup.md) — Qoder agent configuration (index, rules, MCP, verification)
