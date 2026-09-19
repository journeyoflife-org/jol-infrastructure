#!/usr/bin/env python3
"""
Phase 7: Compliance Review — GDPR Art.9 / PCI / ISO-27001 Control Mapping
Maps controls to repos, checks evidence completeness, produces gap list.
"""

import json
import os
from pathlib import Path
from datetime import datetime

# Configuration
REPOS_BASE = Path("/opt/jol/repos")
COMPLIANCE_REPO = REPOS_BASE / "jol-compliance"
INFRASTRUCTURE_REPO = REPOS_BASE / "jol-infrastructure"
OUTPUT_DIR = INFRASTRUCTURE_REPO / ".staging" / "phase7-compliance"
OUTPUT_FILE = OUTPUT_DIR / "phase7-compliance.json"

# Sensitivity table (from Step 3 / AGENTS.md §0.2)
SENSITIVITY_TABLE = {
    "Tier 0 (Contracts)": {
        "repos": ["jol-core", "jol-hub"],
        "data_types": ["GDPR Art.9 (religious)", "PCI-DSS (donations)", "PII"],
        "compliance": ["GDPR", "PCI-DSS", "ISO 27001", "SOC 2"],
        "risk_level": "CRITICAL"
    },
    "Tier 1 (Primary Apps)": {
        "repos": ["jol-rag-server", "jol-backend-platform"],
        "data_types": ["GDPR Art.9 (religious)", "PII"],
        "compliance": ["GDPR", "ISO 27001", "SOC 2"],
        "risk_level": "HIGH"
    },
    "Tier 2 (AI Estate)": {
        "repos": ["jol-llm", "jol-mcp-servers", "jol-hermes-agents"],
        "data_types": ["PII (prompts)", "Telemetry"],
        "compliance": ["GDPR", "ISO 27001"],
        "risk_level": "MEDIUM"
    },
    "Tier 4 (Infra/Gov)": {
        "repos": ["jol-infrastructure", "jol-compliance", "jol-devops"],
        "data_types": ["Infrastructure configs", "Compliance docs"],
        "compliance": ["ISO 27001", "SOC 2"],
        "risk_level": "MEDIUM"
    }
}

# GDPR Art.9 controls (special category data)
GDPR_ART9_CONTROLS = [
    {"id": "GDPR-ART9-1", "requirement": "Lawful basis for processing special category data", "article": "Art. 9(2)(d)"},
    {"id": "GDPR-ART9-2", "requirement": "Data protection impact assessment (DPIA)", "article": "Art. 35"},
    {"id": "GDPR-ART9-3", "requirement": "Explicit consent or legitimate activities basis", "article": "Art. 9(2)(a)/(d)"},
    {"id": "GDPR-ART9-4", "requirement": "Enhanced security measures for special category", "article": "Art. 32"},
    {"id": "GDPR-ART9-5", "requirement": "Records of processing activities (ROPA)", "article": "Art. 30"},
    {"id": "GDPR-ART9-6", "requirement": "Data retention policy for special category", "article": "Art. 5(1)(e)"},
    {"id": "GDPR-ART9-7", "requirement": "Data subject rights procedures (DSR)", "article": "Art. 15-22"},
    {"id": "GDPR-ART9-8", "requirement": "Breach notification (72 hours)", "article": "Art. 33-34"},
]

# PCI-DSS controls (payment card data)
PCI_CONTROLS = [
    {"id": "PCI-REQ1", "requirement": "Install and maintain a firewall configuration", "scope": "Cardholder data environment"},
    {"id": "PCI-REQ2", "requirement": "Do not use vendor-supplied defaults for system passwords", "scope": "All systems"},
    {"id": "PCI-REQ3", "requirement": "Protect stored cardholder data", "scope": "Storage systems"},
    {"id": "PCI-REQ4", "requirement": "Encrypt transmission of cardholder data", "scope": "Network"},
    {"id": "PCI-REQ5", "requirement": "Protect all systems against malware", "scope": "All systems"},
    {"id": "PCI-REQ6", "requirement": "Develop and maintain secure systems and applications", "scope": "Development"},
    {"id": "PCI-REQ7", "requirement": "Restrict access to cardholder data by business need-to-know", "scope": "Access control"},
    {"id": "PCI-REQ8", "requirement": "Identify and authenticate access to system components", "scope": "Authentication"},
    {"id": "PCI-REQ9", "requirement": "Restrict physical access to cardholder data", "scope": "Physical security"},
    {"id": "PCI-REQ10", "requirement": "Log and monitor all access to network resources and cardholder data", "scope": "Logging"},
    {"id": "PCI-REQ11", "requirement": "Regularly test security systems and processes", "scope": "Testing"},
    {"id": "PCI-REQ12", "requirement": "Maintain a policy that addresses information security for all personnel", "scope": "Policies"},
]

# ISO 27001:2022 key controls
ISO27001_CONTROLS = [
    {"id": "A.5.1", "title": "Policies for information security", "clause": "Annex A"},
    {"id": "A.5.9", "title": "Inventory of information and other associated assets", "clause": "Annex A"},
    {"id": "A.5.15", "title": "Access control", "clause": "Annex A"},
    {"id": "A.5.17", "title": "Authentication information", "clause": "Annex A"},
    {"id": "A.5.24", "title": "Information security incident management", "clause": "Annex A"},
    {"id": "A.7.4", "title": "Physical security monitoring", "clause": "Annex A"},
    {"id": "A.8.9", "title": "Configuration management", "clause": "Annex A"},
    {"id": "A.8.13", "title": "Information backup", "clause": "Annex A"},
    {"id": "A.8.24", "title": "Use of cryptography", "clause": "Annex A"},
    {"id": "A.8.29", "title": "Security testing in development", "clause": "Annex A"},
]

# SOC 2 TSC controls
SOC2_CONTROLS = [
    {"id": "CC6.1", "title": "Logical Access — Authorisation", "tsc": "CC6"},
    {"id": "CC6.6", "title": "Logical Access — MFA", "tsc": "CC6"},
    {"id": "CC7.1", "title": "System Operations — Monitoring", "tsc": "CC7"},
    {"id": "CC7.2", "title": "System Operations — Anomaly Detection", "tsc": "CC7"},
    {"id": "CC7.3", "title": "System Operations — Incident Response", "tsc": "CC7"},
    {"id": "CC7.4", "title": "System Operations — Vulnerability Management", "tsc": "CC7"},
    {"id": "CC8.1", "title": "Change Management — Authorisation", "tsc": "CC8"},
    {"id": "CC8.2", "title": "Change Management — Testing", "tsc": "CC8"},
]


def check_evidence_completeness():
    """Check if compliance evidence exists and is complete."""
    gaps = []
    evidence_status = {}
    
    # Check GDPR evidence
    gdpr_dirs = {
        "privacy-policies": COMPLIANCE_REPO / "gdpr" / "privacy-policies",
        "dsr-procedures": COMPLIANCE_REPO / "gdpr" / "dsr-procedures",
        "ropas": COMPLIANCE_REPO / "gdpr" / "ropa",
        "dpias": COMPLIANCE_REPO / "gdpr" / "dpias",
        "retention-policies": COMPLIANCE_REPO / "gdpr" / "retention-policies",
        "cookie-policies": COMPLIANCE_REPO / "gdpr" / "cookie-policies",
    }
    
    for control, path in gdpr_dirs.items():
        if path.exists():
            files = list(path.glob("*.md"))
            if len(files) == 0:
                gaps.append({
                    "control": f"GDPR-{control.upper()}",
                    "gap": f"No {control} documents found",
                    "severity": "HIGH",
                    "evidence_path": str(path)
                })
                evidence_status[control] = "MISSING"
            elif any("template" in f.name.lower() for f in files):
                gaps.append({
                    "control": f"GDPR-{control.upper()}",
                    "gap": f"Only template found for {control} — no implemented documents",
                    "severity": "MEDIUM",
                    "evidence_path": str(path)
                })
                evidence_status[control] = "TEMPLATE_ONLY"
            else:
                evidence_status[control] = "PRESENT"
        else:
            gaps.append({
                "control": f"GDPR-{control.upper()}",
                "gap": f"{control} directory does not exist",
                "severity": "HIGH",
                "evidence_path": str(path)
            })
            evidence_status[control] = "MISSING"
    
    # Check ISO 27001 evidence
    iso27001_dirs = {
        "policies": COMPLIANCE_REPO / "iso27001" / "policies",
        "procedures": COMPLIANCE_REPO / "iso27001" / "procedures",
        "risk-register": COMPLIANCE_REPO / "iso27001" / "risk-register",
        "soa": COMPLIANCE_REPO / "iso27001" / "soa",
        "asset-register": COMPLIANCE_REPO / "iso27001" / "asset-register",
    }
    
    for control, path in iso27001_dirs.items():
        if path.exists():
            files = list(path.glob("*.md"))
            if len(files) == 0:
                gaps.append({
                    "control": f"ISO27001-{control.upper()}",
                    "gap": f"No {control} documents found",
                    "severity": "HIGH",
                    "evidence_path": str(path)
                })
                evidence_status[control] = "MISSING"
            else:
                evidence_status[control] = "PRESENT"
        else:
            gaps.append({
                "control": f"ISO27001-{control.upper()}",
                "gap": f"{control} directory does not exist",
                "severity": "HIGH",
                "evidence_path": str(path)
            })
            evidence_status[control] = "MISSING"
    
    # Check audit evidence
    audit_dirs = {
        "vulnerability-scans": COMPLIANCE_REPO / "audit-evidence" / "vulnerability-scans",
        "penetration-tests": COMPLIANCE_REPO / "audit-evidence" / "penetration-tests",
        "github": COMPLIANCE_REPO / "audit-evidence" / "github",
        "infrastructure": COMPLIANCE_REPO / "audit-evidence" / "infrastructure",
    }
    
    for control, path in audit_dirs.items():
        if path.exists():
            files = list(path.glob("*"))
            if len(files) == 0:
                gaps.append({
                    "control": f"AUDIT-{control.upper()}",
                    "gap": f"No {control} evidence found",
                    "severity": "MEDIUM",
                    "evidence_path": str(path)
                })
                evidence_status[control] = "MISSING"
            else:
                evidence_status[control] = "PRESENT"
        else:
            gaps.append({
                "control": f"AUDIT-{control.upper()}",
                "gap": f"{control} directory does not exist",
                "severity": "MEDIUM",
                "evidence_path": str(path)
            })
            evidence_status[control] = "MISSING"
    
    return gaps, evidence_status


def map_controls_to_repos():
    """Map compliance controls to repos based on sensitivity table."""
    control_mapping = []
    
    for tier, info in SENSITIVITY_TABLE.items():
        for repo_name in info["repos"]:
            repo_path = REPOS_BASE / repo_name
            if not repo_path.exists():
                continue
            
            for framework in info["compliance"]:
                if framework == "GDPR":
                    for control in GDPR_ART9_CONTROLS:
                        control_mapping.append({
                            "repo": repo_name,
                            "tier": tier,
                            "framework": "GDPR",
                            "control_id": control["id"],
                            "requirement": control["requirement"],
                            "article": control.get("article", ""),
                            "risk_level": info["risk_level"]
                        })
                elif framework == "PCI-DSS":
                    for control in PCI_CONTROLS:
                        control_mapping.append({
                            "repo": repo_name,
                            "tier": tier,
                            "framework": "PCI-DSS",
                            "control_id": control["id"],
                            "requirement": control["requirement"],
                            "scope": control.get("scope", ""),
                            "risk_level": info["risk_level"]
                        })
                elif framework == "ISO 27001":
                    for control in ISO27001_CONTROLS:
                        control_mapping.append({
                            "repo": repo_name,
                            "tier": tier,
                            "framework": "ISO 27001",
                            "control_id": control["id"],
                            "requirement": control["title"],
                            "clause": control.get("clause", ""),
                            "risk_level": info["risk_level"]
                        })
                elif framework == "SOC 2":
                    for control in SOC2_CONTROLS:
                        control_mapping.append({
                            "repo": repo_name,
                            "tier": tier,
                            "framework": "SOC 2",
                            "control_id": control["id"],
                            "requirement": control["title"],
                            "tsc": control.get("tsc", ""),
                            "risk_level": info["risk_level"]
                        })
    
    return control_mapping


def check_compliance_matrix_status():
    """Check if COMPLIANCE_MATRIX.md is filled out."""
    matrix_file = COMPLIANCE_REPO / "COMPLIANCE_MATRIX.md"
    gaps = []
    
    if not matrix_file.exists():
        gaps.append({
            "control": "COMPLIANCE-MATRIX",
            "gap": "COMPLIANCE_MATRIX.md does not exist",
            "severity": "CRITICAL",
            "evidence_path": str(matrix_file)
        })
        return gaps
    
    content = matrix_file.read_text()
    
    # Check for placeholder statuses
    placeholder_count = content.count("[STATUS]")
    if placeholder_count > 0:
        gaps.append({
            "control": "COMPLIANCE-MATRIX",
            "gap": f"COMPLIANCE_MATRIX.md has {placeholder_count} placeholder [STATUS] values",
            "severity": "HIGH",
            "evidence_path": str(matrix_file)
        })
    
    # Check for placeholder dates
    placeholder_dates = content.count("[DATE]")
    if placeholder_dates > 0:
        gaps.append({
            "control": "COMPLIANCE-MATRIX",
            "gap": f"COMPLIANCE_MATRIX.md has {placeholder_dates} placeholder [DATE] values",
            "severity": "MEDIUM",
            "evidence_path": str(matrix_file)
        })
    
    return gaps


def main():
    """Main compliance review function."""
    print("=" * 80)
    print("Phase 7: Compliance Review — GDPR Art.9 / PCI / ISO-27001")
    print("=" * 80)
    print()
    
    # Create output directory
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    
    # Map controls to repos
    print("[1/4] Mapping controls to repos...")
    control_mapping = map_controls_to_repos()
    print(f"  ✓ Mapped {len(control_mapping)} controls across {len(SENSITIVITY_TABLE)} tiers")
    print()
    
    # Check evidence completeness
    print("[2/4] Checking evidence completeness...")
    evidence_gaps, evidence_status = check_evidence_completeness()
    print(f"  ✓ Found {len(evidence_gaps)} evidence gaps")
    print()
    
    # Check compliance matrix status
    print("[3/4] Checking compliance matrix status...")
    matrix_gaps = check_compliance_matrix_status()
    print(f"  ✓ Found {len(matrix_gaps)} compliance matrix gaps")
    print()
    
    # Combine all gaps
    all_gaps = evidence_gaps + matrix_gaps
    
    # Categorize gaps by severity
    critical_gaps = [g for g in all_gaps if g["severity"] == "CRITICAL"]
    high_gaps = [g for g in all_gaps if g["severity"] == "HIGH"]
    medium_gaps = [g for g in all_gaps if g["severity"] == "MEDIUM"]
    
    print("[4/4] Producing gap list...")
    print(f"  ✓ CRITICAL: {len(critical_gaps)}")
    print(f"  ✓ HIGH: {len(high_gaps)}")
    print(f"  ✓ MEDIUM: {len(medium_gaps)}")
    print()
    
    # Save results
    results = {
        "scan_date": datetime.now().isoformat(),
        "summary": {
            "total_controls_mapped": len(control_mapping),
            "total_gaps": len(all_gaps),
            "critical_gaps": len(critical_gaps),
            "high_gaps": len(high_gaps),
            "medium_gaps": len(medium_gaps),
        },
        "control_mapping": control_mapping,
        "evidence_status": evidence_status,
        "gaps": all_gaps,
    }
    
    with open(OUTPUT_FILE, "w") as f:
        json.dump(results, f, indent=2)
    
    print(f"✓ Results saved to: {OUTPUT_FILE}")
    print()
    print("=" * 80)
    print("Compliance review complete.")
    print("=" * 80)
    
    return results


if __name__ == "__main__":
    main()
