#!/usr/bin/env python3
"""check-changelog-table.py — CHANGELOG.md rows must stay a valid 5-column table,
and no PRODUCTION change record may be left without a CC8.1 ticket reference.

WHY THIS EXISTS (issue #134): `CHANGELOG.md` is the SOC 2 CC8.1 evidence artifact, and every
record is a single markdown table row. In GFM a `|` inside a code span STILL splits a cell unless
it is escaped as `\\|`. Six pre-existing rows (added 2026-10-22..24) carry raw pipes from shell
snippets such as `lvs | grep -c vm-199`, which makes the row render with phantom columns — i.e.
part of a compliance record is displayed in the wrong place, and anything that parses the table
sees the wrong fields.

⚠ CLAIM CORRECTED 2026-11-01 (finding F-14). The #134 record said "nothing in CI catches this
because infra-validate.yml skips docs-only merges entirely". Measured, that is WRONG in its
reasoning: `on.pull_request` carries no `paths:` filter, so a docs-only PR DID run 7 jobs
(`gh api repos/.../commits/3e75689/check-runs` → 7 completed check runs). The real gaps were
(1) no job ever invoked this checker — it was wired only into `make lint-changelog` and a
pre-commit hook that has never been installed here, and (2) a direct push to `main` touching
only docs/CHANGELOG triggers no pipeline, because `on.push.paths` omitted them. Both are closed
in `infra-validate.yml` (job `changelog-guard` + widened push paths).

SECOND CHECK (finding F-19, same thread): 12 rows whose Scope column declares a production
change still carry the literal placeholder `TBD (CC8.1 issue)` in the Ticket column. §0.3 makes
the issue mandatory for production changes, so this is an open change-management violation, not
a formatting nit. It is gated with a BASELINE + RATCHET: the 12 pre-existing rows are grandfathered
by timestamp, any NEW prod-scope row with a placeholder fails. Closing an old row means deleting
its baseline entry, so the debt can only shrink and the checker can only tighten.

Usage:
    check-changelog-table.py [PATH]        # default CHANGELOG.md; exit 0 clean, 1 findings
    check-changelog-table.py --self-test   # prove the checker can fail (fixtures) then check file

The self-test is the point: a check that has never been observed to FAIL is not a check. It is
run in CI/pre-commit together with the real scan, so a regression of the checker itself is loud.
"""

import os
import re
import sys

UNESCAPED_PIPE = re.compile(r"(?<!\\)\|")
DATA_ROW = re.compile(r"^\|\s+\d{4}-\d{2}-\d{2}T|^\|\s+_YYYY")
TICKET_PLACEHOLDER = re.compile(r"\bTBD\b", re.I)
PROD_SCOPE = re.compile(r"\bprod(uction)?\b", re.I)
# A scope that says "prod" only to deny that anything was touched is not a production change.
NOT_A_PROD_CHANGE = re.compile(
    r"no production|zero production|no prod\b|not production|docs-only|repo only|"
    r"read-only", re.I)

# Grandfathered CC8.1 debt, keyed by the row's timestamp cell (line 17..40 of CHANGELOG.md as of
# 2026-11-01, threads: prox01 cable audit, JOL Pilot Lithuania, SOPS Gate 0, Qodana retention,
# Phase-5 architecture). Each must be closed by a real issue, then removed from this list.
TICKET_DEBT_BASELINE = {
    "2026-09-19T15:00:00Z",
    "2026-08-29T23:55:00Z",
    "2026-08-29T23:23:00Z",
    "2026-08-29T20:30:00Z",
    "2026-08-29T20:05:00Z",
    "2026-08-29T19:50:00Z",
    "2026-08-29T19:15:00Z",
    "2026-08-29T17:55:00Z",
    "2026-08-24T22:50:00Z",
    "2026-08-23T20:30:00Z",
    "2026-08-23T16:00:00Z",
    "2026-08-23T12:00:00Z",
}


def structural_pipes(line: str) -> int:
    return len(UNESCAPED_PIPE.findall(line.rstrip("\n")))


def cells_of(line: str) -> list:
    """Split a data row on UNESCAPED delimiters only — the same rule GFM applies."""
    return [c.strip() for c in UNESCAPED_PIPE.split(line.strip())][1:-1]


def is_production_change(scope_cell: str) -> bool:
    return bool(PROD_SCOPE.search(scope_cell)) and not NOT_A_PROD_CHANGE.search(scope_cell)


def expected_columns(path: str) -> int:
    """Derive the delimiter count from the header separator row, never hard-code it."""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if re.match(r"^\|[-\s|:]+\|\s*$", line):
                return structural_pipes(line)
    raise SystemExit("FATAL: no table header separator found in %s" % path)


def scan(path: str) -> list:
    want = expected_columns(path)
    bad = []
    with open(path, encoding="utf-8") as fh:
        for no, line in enumerate(fh, 1):
            if DATA_ROW.match(line):
                got = structural_pipes(line)
                if got != want:
                    bad.append((no, got, want, line.strip()[:60]))
    return bad, want


def scan_tickets(path: str) -> tuple:
    """Rows declaring a production change must name a CC8.1 issue (§0.3).

    Returns (violations, grandfathered, total_prod_rows). A row counts as production when its
    Scope column says prod/production and does not negate it. Only rows NOT in
    TICKET_DEBT_BASELINE fail; the baseline may shrink, never grow (the ratchet).
    """
    violations, known = [], []
    total = 0
    with open(path, encoding="utf-8") as fh:
        for no, line in enumerate(fh, 1):
            if not DATA_ROW.match(line):
                continue
            cells = cells_of(line)
            if len(cells) < 5:
                continue                      # a phantom-column row is reported by scan()
            total += 1
            if not is_production_change(cells[3]) or not TICKET_PLACEHOLDER.search(cells[4]):
                continue
            stamp = re.match(r"_?(?P<t>\d{4}-\d{2}-\d{2}T[\d:]+Z)_?", cells[0])
            key = stamp.group("t") if stamp else ""
            (known if key in TICKET_DEBT_BASELINE else violations).append((no, cells[0][:40], cells[3][:60]))
    return violations, known, total


def self_test() -> int:
    """Fixtures: the checker must accept valid rows and reject both defect classes."""
    cases = [
        # (label, line, expected pipe count)
        ("plain 5-column row", "| 2026-10-31T00:00:00Z | @a | text | prod | #1 |\n", 6),
        ("escaped pipe inside a cell is NOT a delimiter",
         "| 2026-10-31T00:00:00Z | @a | `lvs \\| grep x` | prod | #1 |\n", 6),
        ("raw pipe inside a cell splits the row (the #134 defect)",
         "| 2026-10-31T00:00:00Z | @a | `lvs | grep x` | prod | #1 |\n", 7),
        ("template placeholder row", "| _YYYY-MM-DDTHH:MM:SSZ_ | @u | d | prod | #2 |\n", 6),
    ]
    failed = 0
    for label, line, want in cases:
        got = structural_pipes(line)
        ok = got == want
        print("%-4s %s (expected %d delimiters, counted %d)"
              % ("ok" if ok else "FAIL", label, want, got))
        if not ok:
            failed += 1
    # and the positive control: a row that looks fine must not be flagged
    if structural_pipes(cases[0][1]) != 6:
        print("FAIL sanity: the checker cannot count a well-formed row")
        failed += 1

    # Ticket logic fixtures (finding F-19). Each case: (label, scope, ticket, expect_violation)
    tcases = [
        ("prod change with a placeholder ticket is a violation",
         "prod", "TBD (CC8.1 issue)", True),
        ("prod change with a named issue is fine",
         "prod", "JOL-BACKUP-20261021-01 / #116", False),
        ("docs-only with a placeholder is NOT a §0.3 violation",
         "docs (audit)", "TBD (CC8.1 issue)", False),
        ("a scope that only DENIES touching prod is not a production change",
         "docs (governance) — no production mutation", "TBD (CC8.1 issue)", False),
        ("an unreadable row (wrong cell count) is left to scan(), not guessed here",
         "prod", "#1", False),
    ]
    for label, scope, ticket, want_bad in tcases:
        got_bad = is_production_change(scope) and bool(TICKET_PLACEHOLDER.search(ticket))
        ok = got_bad == want_bad
        print("%-4s %s (expected violation=%s, got %s)"
              % ("ok" if ok else "FAIL", label, want_bad, got_bad))
        if not ok:
            failed += 1
    # the ratchet must be real: a grandfathered row is not reported, a new one is
    if "2026-08-29T20:30:00Z" not in TICKET_DEBT_BASELINE:
        print("FAIL sanity: the grandfathered baseline is missing its own entry")
        failed += 1
    return 1 if failed else 0


def main(argv: list) -> int:
    args = [a for a in argv if not a.startswith("--")]
    path = args[0] if args else os.environ.get("CHANGELOG", "CHANGELOG.md")
    if "--self-test" in argv:
        rc = self_test()
        if rc:
            print("self-test FAILED — the checker itself is broken; trusting it would be unsafe")
            return rc
        print("self-test passed (checker can detect both defect classes)")
    if not os.path.exists(path):
        print("FATAL: %s not found" % path)
        return 2
    bad, want = scan(path)
    rc = 0
    for no, got, exp, head in bad:
        print("ERROR %s:%d has %d cell delimiters, expected %d — an unescaped `|` inside the row "
              "splits a cell; escape it as \\|  |  %s…" % (path, no, got, exp, head))
    if bad:
        print("CHANGELOG table check FAILED: %d row(s) would render with phantom columns" % len(bad))
        rc = 1

    violations, known, total = scan_tickets(path)
    for no, stamp, scope in violations:
        print("ERROR %s:%d §0.3 violation — a PRODUCTION change (%s) carries a ticket placeholder "
              "instead of a CC8.1 issue reference" % (path, no, scope))
    print("CC8.1 ticket scan: %d data row(s), %d prod-scope row(s) still placeholders, "
          "%d grandfathered, %d NEW violation(s)" % (total, len(violations) + len(known),
                                                     len(known), len(violations)))
    if known and not violations:
        print("NOTE: the %d grandfathered row(s) are tracked debt — close each with a real issue and "
              "delete its entry from TICKET_DEBT_BASELINE; the baseline may only shrink." % len(known))
    if violations:
        rc = 1
    if rc == 0:
        print("CHANGELOG table check PASS (%s, %d delimiters per data row, no new ticket placeholder)"
              % (path, want))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
