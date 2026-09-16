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

## Qodana History Retention (fleet policy — all 23 journeyoflife-org repos)

Scan history must be retained in **two independent places** (SOC 2 CC7.2
evidence; survives JetBrains account changes):

| Layer | What it keeps | Retention |
|-------|---------------|-----------|
| Qodana Cloud | run-over-run trends, baselines, per-commit reports (`upload-result: true` + `QODANA_TOKEN`) | account lifetime |
| GitHub Actions artifacts | full SARIF/HTML/JSON report per run (`Archive Qodana report (history)` step) | 90 days per run |

### Activation checklist (per repository)
1. Repo → Settings → Secrets and variables → Actions → secret `QODANA_TOKEN`
   (from Qodana Cloud → project → Settings).
2. Same page → **Variables** → `QODANA_ENABLED=true` (the `qodana-scan` job
   is skipped unless this variable is set).
3. Confirm a run appears in Qodana Cloud **and** a `qodana-report-<run id>`
   artifact is attached to the workflow run.

### Local baseline (optional, Cloud-independent delta tracking)
```bash
qodana scan --project-dir . --results-dir ./qodana/results
# After the first accepted scan, promote the report to a baseline:
cp ./qodana/results/qodana.sarif.json qodana.sarif.json
# then add to qodana.yaml:  baseline: qodana.sarif.json
```
Subsequent runs then report only findings new vs. the committed baseline.

### Account continuity note
Qodana Cloud projects are bound to the JetBrains account/organization that
created them. If the organization account changes, prior Cloud history does
NOT migrate — the GitHub artifact archive is the durable fallback, which is
why it is mandatory fleet-wide.

## See Also

- [qoder-setup.md](qoder-setup.md) — Qoder agent configuration (index, rules, MCP, verification)
