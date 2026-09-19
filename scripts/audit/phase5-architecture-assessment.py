#!/usr/bin/env python3
"""Phase 5 architecture assessment scanner.

Gathers architectural metadata from all repos:
  - Layering: src/ structure, packages/, modules/
  - Dependencies: pyproject.toml, package.json, requirements.txt
  - Config: .env*, config/, settings/
  - Tests: tests/, test/, *_test.py, test_*.py
  - Docker: Dockerfile, docker-compose.yml, .dockerignore
  - CI: .github/workflows/*.yml
  - Lockfiles: *.lock, package-lock.json, poetry.lock, Pipfile.lock
  - Build: Makefile, build.sh, tsup.config.*, webpack.config.*
"""
import json
import os
import subprocess
from pathlib import Path
from datetime import datetime

REPO_ROOT = Path("/opt/jol/repos")
OUTPUT_DIR = Path("/opt/jol/repos/jol-infrastructure/.staging/phase5-architecture")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

REPOS = [
    ".github", "jol-analytics-ai", "jol-auth", "jol-bitrix24-integration",
    "jol-compliance", "jol-core", "jol-devops", "jol-domain-taxonomy",
    "jol-ecommerce-engine", "jol-hermes-agents", "jol-hub", "jol-infrastructure",
    "jol-link-registry", "jol-llm", "jol-mcp-servers", "jol-rag-server",
    "jol-repo-template", "jol-scripts", "jol-security",
    "jol-site-basilica", "jol-site-cathedral", "jol-site-cemetery-care",
    "jol-site-deanery", "jol-site-diocese", "jol-site-funeral",
    "jol-site-orthodox", "jol-site-other-church", "jol-site-parish",
    "jol-site-protestant",
]


def count_files(repo_path: Path, pattern: str) -> int:
    """Count files matching a glob pattern."""
    try:
        return len(list(repo_path.glob(pattern)))
    except:
        return 0


def has_file(repo_path: Path, filename: str) -> bool:
    """Check if a file exists."""
    return (repo_path / filename).exists()


def read_first_lines(repo_path: Path, filename: str, n: int = 5) -> str:
    """Read first N lines of a file."""
    try:
        with open(repo_path / filename, 'r', errors='ignore') as f:
            return ''.join(f.readlines()[:n])
    except:
        return ""


def assess_repo(repo_name: str) -> dict:
    """Assess a single repo's architecture."""
    repo_path = REPO_ROOT / repo_name
    if not repo_path.exists():
        return {"repo": repo_name, "error": "NOT_FOUND"}

    info = {
        "repo": repo_name,
        "timestamp": datetime.now().isoformat(),
        
        # Layering
        "has_src_dir": (repo_path / "src").is_dir(),
        "has_packages_dir": (repo_path / "packages").is_dir(),
        "has_app_dir": (repo_path / "app").is_dir(),
        "has_lib_dir": (repo_path / "lib").is_dir(),
        
        # Dependencies
        "has_pyproject": has_file(repo_path, "pyproject.toml"),
        "has_package_json": has_file(repo_path, "package.json"),
        "has_requirements_txt": has_file(repo_path, "requirements.txt"),
        "has_pipfile": has_file(repo_path, "Pipfile"),
        
        # Config
        "has_env_example": has_file(repo_path, ".env.example"),
        "has_env": has_file(repo_path, ".env"),
        "has_config_dir": (repo_path / "config").is_dir(),
        "has_settings_dir": (repo_path / "settings").is_dir(),
        
        # Tests
        "has_tests_dir": (repo_path / "tests").is_dir(),
        "has_test_dir": (repo_path / "test").is_dir(),
        "test_file_count": count_files(repo_path, "**/test_*.py") + count_files(repo_path, "**/*_test.py"),
        
        # Docker
        "has_dockerfile": has_file(repo_path, "Dockerfile"),
        "has_docker_compose": has_file(repo_path, "docker-compose.yml") or has_file(repo_path, "docker-compose.yaml"),
        "has_dockerignore": has_file(repo_path, ".dockerignore"),
        
        # CI
        "workflow_count": count_files(repo_path, ".github/workflows/*.yml") + count_files(repo_path, ".github/workflows/*.yaml"),
        
        # Lockfiles
        "has_package_lock": has_file(repo_path, "package-lock.json"),
        "has_poetry_lock": has_file(repo_path, "poetry.lock"),
        "has_pipfile_lock": has_file(repo_path, "Pipfile.lock"),
        "has_requirements_lock": has_file(repo_path, "requirements.lock") or has_file(repo_path, "requirements-frozen.txt"),
        
        # Build
        "has_makefile": has_file(repo_path, "Makefile"),
        "has_tsup_config": count_files(repo_path, "tsup.config.*") > 0,
        "has_webpack_config": count_files(repo_path, "webpack.config.*") > 0,
        
        # Security
        "has_security_md": has_file(repo_path, "SECURITY.md"),
        "has_codeowners": has_file(repo_path, ".github/CODEOWNERS"),
        "has_precommit": has_file(repo_path, ".pre-commit-config.yaml"),
        
        # Docs
        "has_readme": has_file(repo_path, "README.md"),
        "has_changelog": has_file(repo_path, "CHANGELOG.md"),
        "has_contributing": has_file(repo_path, "CONTRIBUTING.md"),
        "has_docs_dir": (repo_path / "docs").is_dir(),
    }
    
    return info


def main():
    results = []
    for repo_name in REPOS:
        print(f"Assessing {repo_name}...")
        info = assess_repo(repo_name)
        results.append(info)
    
    # Write JSON
    json_file = OUTPUT_DIR / "phase5-architecture.json"
    with open(json_file, "w") as f:
        json.dump(results, f, indent=2)
    
    # Write summary
    summary_file = OUTPUT_DIR / "phase5-summary.txt"
    with open(summary_file, "w") as f:
        f.write(f"{'REPO':<30} {'SRC':>3} {'PKG':>3} {'APP':>3} {'PY':>3} {'NPM':>3} {'TST':>3} {'DKR':>3} {'CI':>3} {'LCK':>3} {'BLD':>3}\n")
        f.write("-" * 110 + "\n")
        for r in results:
            if "error" in r:
                continue
            src = "✓" if r["has_src_dir"] else "·"
            pkg = "✓" if r["has_packages_dir"] else "·"
            app = "✓" if r["has_app_dir"] else "·"
            py = "✓" if r["has_pyproject"] or r["has_requirements_txt"] else "·"
            npm = "✓" if r["has_package_json"] else "·"
            tst = "✓" if r["has_tests_dir"] or r["test_file_count"] > 0 else "·"
            dkr = "✓" if r["has_dockerfile"] else "·"
            ci = str(r["workflow_count"])
            lck = "✓" if r["has_package_lock"] or r["has_poetry_lock"] or r["has_pipfile_lock"] else "·"
            bld = "✓" if r["has_makefile"] or r["has_tsup_config"] else "·"
            f.write(f"{r['repo']:<30} {src:>3} {pkg:>3} {app:>3} {py:>3} {npm:>3} {tst:>3} {dkr:>3} {ci:>3} {lck:>3} {bld:>3}\n")
    
    print(f"\nWrote {len(results)} assessments to {OUTPUT_DIR}")
    print(f"JSON: {json_file}")
    print(f"Summary: {summary_file}")


if __name__ == "__main__":
    main()
