# JOL RAG Service

Production-ready Retrieval-Augmented Generation system for the Journey of Life (JOL) Roman Catholic Digital Mission Platform. Pilot deployment: Lithuania (`rag-prod-lt01`).

**Compliance:** SOC 2 Type II / GDPR (EU 2016/679) / ISO 27001:2022

## Architecture

```
[Reverse Proxy :443] --> [FastAPI :8000] --> [Qdrant :6333] (vector store, LUKS encrypted)
                              |
                              +--> [Ollama @ 10.30.30.10:11434] (LLM inference, GPU)
                              |
                              +--> [MinIO :9000] (document storage, SSE-S3)
                              |
                              +--> [all-MiniLM-L6-v2] (local embeddings, CPU)
```

See [docs/architecture.md](docs/architecture.md) for full diagrams and design decisions.

## Prerequisites

- Ubuntu 24.04 LTS (mandatory baseline)
- Docker CE 27.x + Compose v2
- LUKS2 encrypted volumes for data directories
- Network access to `llm-prod-lt01` (10.30.30.10:11434) for LLM inference
- `age` encryption tool for backups

## Quick Start (Development)

```bash
cd rag/
cp .env.example .env
# Edit .env — replace all CHANGE_ME values:
#   openssl rand -hex 32  (for each secret)

docker compose up -d --build
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/docs  # Swagger UI
```

## Production Deployment

```bash
# 1. Provision encrypted volumes (first time only)
sudo ./deploy/setup-luks.sh

# 2. Install Docker (first time only)
sudo ./deploy/setup-docker.sh

# 3. Apply kernel hardening
sudo ./scripts/harden-kernel.sh

# 4. Deploy via Ansible (from control node)
cd ansible/
ansible-playbook ../rag/deploy/ansible/provision-rag.yml --limit rag-prod-lt01

# 5. Populate secrets in /opt/jol/rag/.env on the target host
# 6. Restart: sudo systemctl restart jol-rag
```

## API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | /health | None | Liveness probe |
| GET | /ready | None | Readiness probe (checks dependencies) |
| GET | /metrics | None | Prometheus metrics |
| POST | /ingest | admin | Ingest document (parse, chunk, embed, store) |
| POST | /query | analyst+ | RAG query (retrieve, generate) |
| DELETE | /admin/documents/{id} | admin | GDPR Art. 17 — erase document data |
| DELETE | /admin/users/{id} | admin | GDPR Art. 17 — erase user data |

Full reference: [docs/api-reference.md](docs/api-reference.md)

## Running Tests

```bash
cd rag/
pip install -r src/requirements.txt pytest pytest-cov
PYTHONPATH=src pytest tests/ -v --cov=app --cov-report=term-missing
```

## Batch Document Ingestion

```bash
# Place documents in /data/raw_docs/ (PDF, DOCX, TXT, HTML)
./scripts/ingest-docs.sh --dir /data/raw_docs --token <jwt> --api http://127.0.0.1:8000

# Dry run (list files only)
./scripts/ingest-docs.sh --dry-run
```

## Backup and Restore

```bash
# Manual backup (also runs nightly via cron at 02:30 UTC)
sudo ./scripts/backup-qdrant.sh

# Restore from backup
sudo ./scripts/restore-qdrant.sh /var/backups/jol-rag/jol-rag-backup-<timestamp>.tar.gz.age
```

## Monitoring

- Prometheus scrape config: [monitoring/prometheus-rag.yml](monitoring/prometheus-rag.yml)
- Grafana dashboard: [monitoring/grafana-dashboard.json](monitoring/grafana-dashboard.json)
- Key metrics: query latency (p95), error rate, embedding throughput, disk usage

## Directory Structure

```
rag/
├── deploy/          # Ansible playbooks, LUKS/Docker setup scripts
├── src/             # Python application (FastAPI, services, workers)
├── scripts/         # Backup, restore, hardening, CLI tools
├── tests/           # Pytest suite (auth, RBAC, GDPR, audit)
├── monitoring/      # Prometheus + Grafana configs
├── docs/            # Architecture, API ref, compliance, runbook
├── docker-compose.yml
└── .env.example
```

## Compliance Evidence

| Framework | Mapping Document |
|-----------|-----------------|
| SOC 2 Type II | [docs/compliance-mapping.md](docs/compliance-mapping.md) |
| GDPR | [docs/compliance-mapping.md](docs/compliance-mapping.md) |
| ISO 27001 | [docs/compliance-mapping.md](docs/compliance-mapping.md) |

## Key Design Decisions

- **LLM via Ollama on llm-prod-lt01** — RAG host has no GPU; Ollama is GPU-backed and already provisioned
- **Local embeddings (all-MiniLM-L6-v2)** — CPU-friendly, 384-dim, zero external API calls (GDPR)
- **Docker Compose for pilot** — Simplicity; extractable to Kubernetes for scale
- **mTLS deferred** — Risk accepted for pilot; VLAN isolation + API keys compensate
- **JWT HS256 for pilot** — Structure supports RS256/OIDC migration post-pilot

## Version

- Application: 1.0.0
- Qdrant: v1.14.1
- Python: 3.12
- Last updated: 2026-08-02
