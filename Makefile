# =============================================================================
# Makefile — jol-infrastructure
# Common targets for validation, scanning, planning, and deployment
# SOC 2 CC8.1 — All changes validated before merge
# =============================================================================

.DEFAULT_GOAL := help
SHELL := /bin/bash
.ONESHELL:
.DELETE_ON_ERROR:

# Colors
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
NC     := \033[0m

# Environments
ENVS := dev staging prod

# ---------------------------------------------------------------------------
# Validation & Linting
# ---------------------------------------------------------------------------
.PHONY: validate
validate: fmt lint opa-test opa-fmt helm-lint checkov trivy  ## Run all validation checks

.PHONY: fmt
fmt:  ## Format Terraform files
	@echo "$(GREEN)Formatting Terraform...$(NC)"
	terraform fmt -recursive terraform/

.PHONY: lint
lint: lint-yaml lint-shell lint-terraform  ## Lint all code

.PHONY: lint-yaml
lint-yaml:  ## Lint YAML files
	@echo "$(GREEN)Linting YAML...$(NC)"
	yamllint -c .yamllint.yaml .

.PHONY: lint-shell
lint-shell:  ## Lint shell scripts
	@echo "$(GREEN)Linting shell scripts...$(NC)"
	find scripts/ -name '*.sh' -exec shellcheck -x {} +

.PHONY: lint-terraform
lint-terraform:  ## Validate Terraform per environment
	@echo "$(GREEN)Validating Terraform...$(NC)"
	@for env in $(ENVS); do \
		echo "  → $$env" ; \
		(cd "terraform/environments/$$env" && terraform init -backend=false -input=false > /dev/null 2>&1 && terraform validate) || exit 1 ; \
	done

.PHONY: opa-test
opa-test:  ## Run OPA policy tests
	@echo "$(GREEN)Running OPA tests...$(NC)"
	opa test policies/opa/ -v --coverage

.PHONY: opa-fmt
opa-fmt:  ## Check OPA formatting
	@echo "$(GREEN)Checking OPA format...$(NC)"
	opa fmt --fail policies/opa/

# ---------------------------------------------------------------------------
# Security Scanning
# ---------------------------------------------------------------------------
.PHONY: scan
scan: checkov trivy trufflehog  ## Run all security scans

.PHONY: checkov
checkov:  ## Run Checkov policy scan
	@echo "$(GREEN)Running Checkov...$(NC)"
	checkov -d terraform/ --config-file policies/checkov/.checkov.yaml

.PHONY: trivy
trivy:  ## Run Trivy IaC security scan (replaces deprecated tfsec)
	@echo "$(GREEN)Running Trivy...$(NC)"
	trivy fs --scanners misconfig --severity HIGH,CRITICAL --exit-code 1 terraform/

.PHONY: trufflehog
trufflehog:  ## Scan for secrets with TruffleHog
	@echo "$(GREEN)Running TruffleHog...$(NC)"
	trufflehog filesystem --only-verified .

# ---------------------------------------------------------------------------
# Helm
# ---------------------------------------------------------------------------
.PHONY: helm-lint
helm-lint:  ## Lint all Helm charts
	@echo "$(GREEN)Linting Helm charts...$(NC)"
	@for chart in helm/charts/jol-*/; do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			echo "  → $$(basename $$chart)" ; \
			helm lint "$$chart" || exit 1 ; \
		fi \
	done

.PHONY: helm-template
helm-template:  ## Dry-run Helm template rendering
	@echo "$(GREEN)Rendering Helm templates...$(NC)"
	@for chart in helm/charts/jol-backend helm/charts/jol-frontend helm/charts/jol-analytics helm/charts/jol-commerce; do \
		name=$$(basename $$chart) ; \
		echo "  → $$name" ; \
		helm template "$$name" "$$chart" > /dev/null || exit 1 ; \
	done

# ---------------------------------------------------------------------------
# Terraform Plan
# ---------------------------------------------------------------------------
.PHONY: plan-dev
plan-dev:  ## Terraform plan for dev environment
	@echo "$(GREEN)Planning dev...$(NC)"
	cd terraform/environments/dev && terraform init -input=false && terraform plan -input=false -out=tfplan

.PHONY: plan-staging
plan-staging:  ## Terraform plan for staging environment
	@echo "$(GREEN)Planning staging...$(NC)"
	cd terraform/environments/staging && terraform init -input=false && terraform plan -input=false -out=tfplan

.PHONY: plan-prod
plan-prod:  ## Terraform plan for prod environment
	@echo "$(GREEN)Planning prod...$(NC)"
	cd terraform/environments/prod && terraform init -input=false && terraform plan -input=false -out=tfplan

# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------
.PHONY: kube-lint
kube-lint:  ## Validate Kubernetes manifests with kubeval
	@echo "$(GREEN)Validating Kubernetes manifests...$(NC)"
	find kubernetes/ -name '*.yaml' -exec kubeval --strict {} +

# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------
.PHONY: cost-dev
cost-dev:  ## Estimate cost for dev environment
	@echo "$(CYAN)Estimating dev costs...$(NC)"
	./scripts/utils/tf-cost-estimate.sh dev

.PHONY: cost-staging
cost-staging:  ## Estimate cost for staging environment
	@echo "$(CYAN)Estimating staging costs...$(NC)"
	./scripts/utils/tf-cost-estimate.sh staging

.PHONY: cost-prod
cost-prod:  ## Estimate cost for prod environment
	@echo "$(CYAN)Estimating prod costs...$(NC)"
	./scripts/utils/tf-cost-estimate.sh prod

# ---------------------------------------------------------------------------
# Documentation
# ---------------------------------------------------------------------------
.PHONY: docs
docs:  ## Generate Terraform documentation
	@echo "$(GREEN)Generating Terraform docs...$(NC)"
	./scripts/utils/generate-terraform-docs.sh

# ---------------------------------------------------------------------------
# Pre-commit
# ---------------------------------------------------------------------------
.PHONY: pre-commit
pre-commit:  ## Run all pre-commit hooks
	@echo "$(GREEN)Running pre-commit...$(NC)"
	pre-commit run --all-files

# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------
.PHONY: audit-evidence
audit-evidence:  ## Collect SOC 2 evidence artifacts
	@echo "$(GREEN)Collecting SOC 2 evidence...$(NC)"
	./scripts/audit/collect-soc2-evidence.sh

.PHONY: verify-encryption
verify-encryption:  ## Verify state bucket encryption
	@echo "$(GREEN)Verifying encryption...$(NC)"
	./scripts/utils/verify-state-encryption.sh

.PHONY: check-tools
check-tools:  ## Verify all required tools are installed
	@echo "$(GREEN)Checking tools...$(NC)"
	./scripts/utils/check-tools.sh

# ---------------------------------------------------------------------------
# RAG Service
# ---------------------------------------------------------------------------
.PHONY: lint-rag
lint-rag:  ## Lint RAG Python code (ruff + mypy)
	@echo "$(GREEN)Linting RAG service...$(NC)"
	cd rag/src && python -m ruff check app/ workers/
	cd rag/src && python -m mypy app/ --ignore-missing-imports

.PHONY: test-rag
test-rag:  ## Run RAG service tests (pytest)
	@echo "$(GREEN)Running RAG tests...$(NC)"
	cd rag && PYTHONPATH=src python -m pytest tests/ -v --tb=short

.PHONY: scan-rag
scan-rag:  ## Scan RAG Docker image for vulnerabilities (Trivy)
	@echo "$(GREEN)Scanning RAG image...$(NC)"
	cd rag && docker build -t jol-rag-scan ./src
	trivy image --severity HIGH,CRITICAL --exit-code 1 jol-rag-scan

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
.PHONY: help
help:  ## Show this help
	@echo "jol-infrastructure Makefile targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(NC) %s\n", $$1, $$2}'
