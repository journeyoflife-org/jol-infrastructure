#!/usr/bin/env python3
"""Phase 3 empirical dependency scanner.

Scans all JOL repos for real cross-repo coupling:
  1. Shared CI workflows:  uses: journeyoflife-org/<repo>/...
  2. Python internal deps: jol-* / jol_* in pyproject/requirements/setup/Pipfile + imports
  3. Node scoped deps:     @jol-hub/*, @journeyoflife-org/*, jol-* in package.json
  4. Deployment refs:      Helm/Ansible/Terraform/compose/.gitmodules pointing at repos
Outputs machine-readable JSON + a console summary.
"""
import os
import re
import json
import glob

REPO_ROOT = "/opt/jol/repos"
ORG = "journeyoflife-org"
REPOS = [
    ".github", "jol-analytics-ai", "jol-auth", "jol-bitrix24-integration",
    "jol-compliance", "jol-core", "jol-devops", "jol-domain-taxonomy",
    "jol-ecommerce-engine", "jol-hermes-agents", "jol-hub", "jol-infrastructure",
    "jol-link-registry", "jol-llm", "jol-mcp-servers", "jol-rag-server",
    "jol-repo-template", "jol-scripts", "jol-security",
    "jol-site-basilica", "jol-site-cathedral", "jol-site-cemetery-care",
    "jol-site-deanery", "jol-site-diocese", "jol-site-funeral", "jol-site-orthodox",
    "jol-site-other-church", "jol-site-parish", "jol-site-protestant",
]

# All known repo short-names used to detect references
def repo_targets():
    t = set()
    for r in REPOS:
        t.add(r)             # jol-hub
        if r == ".github":
            t.add(".github")
    return t

TARGETS = repo_targets()

# Directories to skip during filesystem walks
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__",
             ".next", ".turbo", "dist", "build", ".pnpm", ".vercel-tmp",
             ".qodana", "site-packages"}

def walk_files(repo, extensions=None, names=None):
    path = os.path.join(REPO_ROOT, repo)
    if not os.path.isdir(path):
        return
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            fp = os.path.join(root, fn)
            if names and fn in names:
                yield fp
            elif extensions and fn.endswith(extensions):
                yield fp

def rel(repo, fp):
    return os.path.relpath(fp, os.path.join(REPO_ROOT, repo))

deps = {r: {"shared_workflows": [], "python_internal": set(),
            "node_internal": set(), "deploy_refs": [], "imports": set()}
        for r in REPOS}

# ---- 1. Shared workflows + uses refs ----
wf_pat = re.compile(rf"uses:\s*{re.escape(ORG)}/([^/\s]+)/\.github/workflows/([^\s@#]+)", re.I)
wf_pat2 = re.compile(rf"uses:\s*{re.escape(ORG)}/([^/\s]+)", re.I)
for r in REPOS:
    for fp in walk_files(r, extensions=(".yml", ".yaml")):
        if "/workflows/" not in fp and "/.github/" not in fp:
            continue
        try:
            with open(fp, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    m = wf_pat.search(line)
                    if m:
                        deps[r]["shared_workflows"].append(f"{m.group(1)} :: {m.group(2)} :: {rel(r, fp)}")
                    else:
                        m2 = wf_pat2.search(line)
                        if m2 and m2.group(1) != r:
                            deps[r]["shared_workflows"].append(f"{m2.group(1)} :: (action) :: {rel(r, fp)}")
        except Exception:
            pass

# ---- 2. Python internal deps from manifests + imports ----
py_manifest_names = {"pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "poetry.lock", "setup.cfg"}
internal_py_pat = re.compile(r"\b(jol[-_][a-z0-9][a-z0-9_-]*)\b", re.I)
import_pat = re.compile(r"^\s*(?:from|import)\s+(jol[a-z0-9_]*)", re.I)
for r in REPOS:
    for fp in walk_files(r, names=py_manifest_names):
        try:
            with open(fp, encoding="utf-8", errors="ignore") as f:
                for m in internal_py_pat.findall(f.read()):
                    norm = m.replace("_", "-").lower()
                    for t in TARGETS:
                        if norm == t.lower().replace("_", "-") and t != r:
                            deps[r]["python_internal"].add(t)
        except Exception:
            pass
    for fp in walk_files(r, extensions=(".py",)):
        try:
            with open(fp, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    m = import_pat.match(line)
                    if m:
                        deps[r]["imports"].add(m.group(1))
        except Exception:
            pass

# ---- 3. Node scoped deps ----
scoped_pat = re.compile(r"\"((?:@jol-hub|@journeyoflife-org|@jolarca)/[^\"]+|jol-[a-z0-9-]+)\"\s*:")
for r in REPOS:
    for fp in walk_files(r, names={"package.json"}):
        try:
            with open(fp, encoding="utf-8", errors="ignore") as f:
                for m in scoped_pat.findall(f.read()):
                    deps[r]["node_internal"].add(m)
        except Exception:
            pass

# ---- 4. Deployment references ----
# Terraform git:: sources, Helm dependency repositories, compose images, .gitmodules
tf_git_pat = re.compile(rf"git::https://github\.com/{re.escape(ORG)}/([a-z0-9._-]+)", re.I)
helm_dep_pat = re.compile(rf"(?:repository|name):\s*.*{re.escape(ORG)}/([a-z0-9._-]+)", re.I)
for r in REPOS:
    for fp in walk_files(r, extensions=(".tf",)):
        try:
            with open(fp, encoding="utf-8", errors="ignore") as f:
                for m in tf_git_pat.findall(f.read()):
                    if m != r:
                        deps[r]["deploy_refs"].append(f"tf-git::{m} :: {rel(r, fp)}")
        except Exception:
            pass
    for fp in walk_files(r, names={"Chart.yaml", ".gitmodules"}):
        try:
            with open(fp, encoding="utf-8", errors="ignore") as f:
                for m in helm_dep_pat.findall(f.read()):
                    if m != r:
                        deps[r]["deploy_refs"].append(f"helm::{m} :: {rel(r, fp)}")
                if fp.endswith(".gitmodules"):
                    f.seek(0)
                    for line in f:
                        mm = re.search(rf"{re.escape(ORG)}/([a-z0-9._-]+)\.git", line)
                        if mm and mm.group(1) != r:
                            deps[r]["deploy_refs"].append(f"submodule::{mm.group(1)} :: {rel(r, fp)}")
        except Exception:
            pass

# ---- Emit ----
out = {}
for r in REPOS:
    out[r] = {
        "shared_workflows": sorted(set(deps[r]["shared_workflows"])),
        "python_internal": sorted(deps[r]["python_internal"]),
        "node_internal": sorted(deps[r]["node_internal"]),
        "deploy_refs": sorted(set(deps[r]["deploy_refs"])),
        "internal_import_prefixes": sorted(deps[r]["imports"]),
    }

out_path = os.path.join(REPO_ROOT, "jol-infrastructure/.staging/phase3-deps.json")
with open(out_path, "w") as f:
    json.dump(out, f, indent=2)

# Console summary
for r in REPOS:
    d = out[r]
    edges = []
    if d["shared_workflows"]:
        edges.append(f"WF:{len(d['shared_workflows'])}")
    if d["python_internal"]:
        edges.append(f"PY:{','.join(d['python_internal'])}")
    if d["node_internal"]:
        edges.append(f"NODE:{','.join(d['node_internal'][:6])}")
    if d["deploy_refs"]:
        edges.append(f"DEPLOY:{len(d['deploy_refs'])}")
    imp = [i for i in d["internal_import_prefixes"] if i not in ("jolarca",)]
    if imp:
        edges.append(f"IMPORTS:{','.join(imp[:6])}")
    print(f"{r:32s} {' | '.join(edges) if edges else '(no internal edges detected)'}")

print(f"\nFull data: {out_path}")
