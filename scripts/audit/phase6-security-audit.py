#!/usr/bin/env python3
"""
Phase 6: Security Audit Scanner
Scans all repos for security vulnerabilities, secret exposure, and control gaps.
READ-ONLY — no mutations.
"""

import json
import os
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple

# Repo roots
REPO_ROOTS = [
    "/opt/jol/repos",
]

# Skip patterns
SKIP_PATTERNS = [
    ".git/",
    "node_modules/",
    "__pycache__/",
    ".venv/",
    "venv/",
    ".terraform/",
    "*.pyc",
    "*.pyo",
    ".DS_Store",
]

# Secret patterns (redacted output only)
SECRET_PATTERNS = [
    (r"API_KEY\s*=\s*['\"][^'\"]{20,}['\"]", "API_KEY"),
    (r"SECRET_KEY\s*=\s*['\"][^'\"]{20,}['\"]", "SECRET_KEY"),
    (r"PASSWORD\s*=\s*['\"][^'\"]{8,}['\"]", "PASSWORD"),
    (r"TOKEN\s*=\s*['\"][^'\"]{20,}['\"]", "TOKEN"),
    (r"PRIVATE_KEY\s*=\s*['\"][^'\"]{20,}['\"]", "PRIVATE_KEY"),
    (r"-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----", "PRIVATE_KEY_BLOCK"),
    (r"AKIA[0-9A-Z]{16}", "AWS_ACCESS_KEY"),
    (r"ghp_[a-zA-Z0-9]{36}", "GITHUB_PAT"),
    (r"sk-[a-zA-Z0-9]{32,}", "OPENAI_KEY"),
    (r"eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}", "JWT_TOKEN"),
]

# Workflow security patterns
WORKFLOW_PATTERNS = {
    "permissions_write_all": r"permissions:\s*write-all",
    "permissions_unrestricted": r"permissions:\s*\{\s*\}",
    "unpinned_action": r"uses:\s*[^@]+@(main|master|v\d+|v\d+\.\d+)",
    "dangerous_checkout": r"uses:\s*actions/checkout.*\n.*fetch-depth:\s*0",
}


def should_skip(path: Path) -> bool:
    """Check if path should be skipped."""
    path_str = str(path)
    return any(pattern in path_str for pattern in SKIP_PATTERNS)


def scan_secrets(repo_path: Path) -> List[Dict]:
    """Scan for hardcoded secrets (redacted output only)."""
    findings = []
    
    for file_path in repo_path.rglob("*"):
        if not file_path.is_file() or should_skip(file_path):
            continue
        
        # Skip binary files
        try:
            content = file_path.read_text(errors="ignore")
        except Exception:
            continue
        
        # Check each pattern
        for pattern, secret_type in SECRET_PATTERNS:
            matches = re.finditer(pattern, content, re.IGNORECASE)
            for match in matches:
                # Get line number
                line_num = content[:match.start()].count("\n") + 1
                
                # Redact the secret (show only first 8 chars)
                matched_text = match.group(0)
                if len(matched_text) > 20:
                    redacted = matched_text[:8] + "...[REDACTED]"
                else:
                    redacted = "[REDACTED]"
                
                findings.append({
                    "type": "HARDCODED_SECRET",
                    "secret_type": secret_type,
                    "file": str(file_path.relative_to(repo_path)),
                    "line": line_num,
                    "redacted_value": redacted,
                    "severity": "CRITICAL" if secret_type in ["PRIVATE_KEY_BLOCK", "AWS_ACCESS_KEY", "GITHUB_PAT"] else "HIGH",
                })
    
    return findings


def scan_workflow_security(repo_path: Path) -> List[Dict]:
    """Scan workflow files for security issues."""
    findings = []
    workflows_dir = repo_path / ".github" / "workflows"
    
    if not workflows_dir.exists():
        return findings
    
    for workflow_file in workflows_dir.glob("*.yml"):
        try:
            content = workflow_file.read_text()
        except Exception:
            continue
        
        # Check for permissions overgrant
        if re.search(WORKFLOW_PATTERNS["permissions_write_all"], content):
            findings.append({
                "type": "WORKFLOW_PERMISSIONS",
                "issue": "write-all permissions",
                "file": str(workflow_file.relative_to(repo_path)),
                "severity": "HIGH",
            })
        
        # Check for unpinned actions
        unpinned = re.findall(WORKFLOW_PATTERNS["unpinned_action"], content)
        if unpinned:
            findings.append({
                "type": "UNPINNED_ACTION",
                "issue": f"Unpinned action: {unpinned[0]}",
                "file": str(workflow_file.relative_to(repo_path)),
                "severity": "MEDIUM",
            })
    
    return findings


def check_branch_protection(repo_path: Path) -> Dict:
    """Check if repo has branch protection (via git config)."""
    try:
        # Check if main branch exists
        result = subprocess.run(
            ["git", "branch", "--list", "main"],
            cwd=repo_path,
            capture_output=True,
            text=True,
            timeout=5,
        )
        
        if "main" not in result.stdout:
            return {"protected": False, "reason": "no main branch"}
        
        # Check for protection rules (local git config only)
        # Note: This doesn't check GitHub-side protection
        return {"protected": None, "reason": "requires GitHub API check"}
    
    except Exception as e:
        return {"protected": False, "reason": str(e)}


def scan_dependencies(repo_path: Path) -> List[Dict]:
    """Scan for dependency files (CVE check would require external tool)."""
    findings = []
    
    # Python dependencies
    for dep_file in ["requirements.txt", "pyproject.toml", "Pipfile"]:
        dep_path = repo_path / dep_file
        if dep_path.exists():
            findings.append({
                "type": "DEPENDENCY_FILE",
                "file": dep_file,
                "ecosystem": "python",
                "severity": "INFO",
            })
    
    # Node dependencies
    for dep_file in ["package.json", "package-lock.json"]:
        dep_path = repo_path / dep_file
        if dep_path.exists():
            findings.append({
                "type": "DEPENDENCY_FILE",
                "file": dep_file,
                "ecosystem": "node",
                "severity": "INFO",
            })
    
    return findings


def check_sops_config(repo_path: Path) -> Dict:
    """Check if repo has SOPS configuration."""
    sops_file = repo_path / ".sops.yaml"
    
    if not sops_file.exists():
        return {"configured": False}
    
    try:
        content = sops_file.read_text()
        # Check for age keys
        has_age = "age:" in content
        # Check for creation rules
        has_rules = "creation_rules:" in content
        
        return {
            "configured": True,
            "has_age": has_age,
            "has_rules": has_rules,
        }
    except Exception:
        return {"configured": False, "error": "read failed"}


def scan_repo(repo_path: Path) -> Dict:
    """Scan a single repo for security issues."""
    print(f"Scanning {repo_path.name}...")
    
    return {
        "repo": repo_path.name,
        "path": str(repo_path),
        "secrets": scan_secrets(repo_path),
        "workflow_security": scan_workflow_security(repo_path),
        "branch_protection": check_branch_protection(repo_path),
        "dependencies": scan_dependencies(repo_path),
        "sops": check_sops_config(repo_path),
    }


def main():
    """Main entry point."""
    print("=" * 80)
    print("Phase 6: Security Audit Scanner")
    print("=" * 80)
    print()
    
    all_findings = []
    
    for repo_root in REPO_ROOTS:
        root_path = Path(repo_root)
        if not root_path.exists():
            print(f"WARNING: {repo_root} does not exist, skipping")
            continue
        
        # Scan each repo
        for repo_dir in sorted(root_path.iterdir()):
            if not repo_dir.is_dir():
                continue
            
            # Skip non-git dirs
            if not (repo_dir / ".git").exists():
                continue
            
            findings = scan_repo(repo_dir)
            all_findings.append(findings)
    
    # Output results
    output_dir = Path("/opt/jol/repos/jol-infrastructure/.staging/phase6-security")
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # JSON output
    json_file = output_dir / "phase6-security.json"
    with open(json_file, "w") as f:
        json.dump(all_findings, f, indent=2)
    
    print()
    print("=" * 80)
    print(f"Scan complete. Results written to {json_file}")
    print("=" * 80)
    
    # Summary
    total_secrets = sum(len(f["secrets"]) for f in all_findings)
    total_workflow_issues = sum(len(f["workflow_security"]) for f in all_findings)
    
    print()
    print("Summary:")
    print(f"  Repos scanned: {len(all_findings)}")
    print(f"  Hardcoded secrets found: {total_secrets}")
    print(f"  Workflow security issues: {total_workflow_issues}")
    print()
    
    if total_secrets > 0:
        print("⚠️  CRITICAL: Hardcoded secrets detected!")
        print("   Review phase6-security.json for locations (redacted).")
        print()


if __name__ == "__main__":
    main()
