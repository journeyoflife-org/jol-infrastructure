#!/usr/bin/env python3
"""check-changelog-table.py — CHANGELOG.md rows must stay a valid 5-column table.

WHY THIS EXISTS (issue #134): `CHANGELOG.md` is the SOC 2 CC8.1 evidence artifact, and every
record is a single markdown table row. In GFM a `|` inside a code span STILL splits a cell unless
it is escaped as `\\|`. Six pre-existing rows (added 2026-10-22..24) carry raw pipes from shell
snippets such as `lvs | grep -c vm-199`, which makes the row render with phantom columns — i.e.
part of a compliance record is displayed in the wrong place, and anything that parses the table
sees the wrong fields. Nothing in CI catches it today: `infra-validate.yml` gates `on.push.paths`
to terraform/kubernetes/helm/policies/scripts, so docs-only merges run no job at all.

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


def structural_pipes(line: str) -> int:
    return len(UNESCAPED_PIPE.findall(line.rstrip("\n")))


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
    for no, got, exp, head in bad:
        print("ERROR %s:%d has %d cell delimiters, expected %d — an unescaped `|` inside the row "
              "splits a cell; escape it as \\|  |  %s…" % (path, no, got, exp, head))
    if bad:
        print("CHANGELOG table check FAILED: %d row(s) would render with phantom columns" % len(bad))
        return 1
    print("CHANGELOG table check PASS (%s, %d delimiters per data row)" % (path, want))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
