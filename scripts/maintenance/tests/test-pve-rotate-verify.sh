#!/usr/bin/env bash
# =============================================================================
# test-pve-rotate-verify.sh — negative-control fixtures for the archive-verification
# block of pve-rotate-cipassword.sh (the F-3 rotation helper).
#
# WHY THIS FILE EXISTS (finding F-16, issue #128 follow-up): the block used to print
#     archive=$(basename "${A:-none}") values-unstripped=$(tar xzOf "$A" … | grep -c …) \
#            key-entries=$(tar tzf "$A" | grep -c …)
# and told the operator "(0 and 0 is the pass condition)". When the backup script exited 0 but
# produced NO archive, `$A` was empty, both `tar` calls failed against "" (measured: tar rc=2)
# and `grep -c` printed 0 anyway — so the printed line was
#     archive=none values-unstripped=0 key-entries=0
# i.e. the stated pass condition was satisfied by a NON-MEASUREMENT, in a security gate, at the
# one moment a human is watching a terminal to decide whether a credential rotation is finished.
# The block now requires a readable archive AND at least one conf before it will print PASS.
#
# The block is EXTRACTED FROM THE SCRIPT UNDER TEST and sourced — never copied. See the red:
#   git show main:scripts/maintenance/pve-rotate-cipassword.sh > /tmp/prefix.sh
#   ./test-pve-rotate-verify.sh /tmp/prefix.sh   # MUST fail: the no-archive case reports success
#   ./test-pve-rotate-verify.sh                  # passes against the fixed helper
#
# Exit: 0 all cases behaved, 1 a case failed, 2 the block could not be extracted.
# No host access, no credentials, no /var/tmp writes (the verification dir is redirected into the
# fixture's own mktemp workdir through JOL_ROTATE_VERIFY_DIR).
# =============================================================================
set -uo pipefail

# Path resolved from THIS file, not a hard-coded workstation path: `make test-gates` runs the
# fixtures in CI, where /opt/jol/repos/... does not exist (measured on PR #141: the job died
# with `FATAL: /opt/jol/repos/jol-infrastructure/scripts/maintenance/hv01-config-backup.sh not found`).
MAINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$MAINT_DIR/pve-rotate-cipassword.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/^# --- prove the archive gate/,/^# --- what only the operator/' "$SRC" | sed '1d;$d' \
    >"$WORK/block.sh"
if [[ ! -s "$WORK/block.sh" ]]; then
    echo "FATAL: could not extract the archive-verification block from $SRC — the fixture tests nothing" >&2
    exit 2
fi
echo "extracted $(grep -c '' "$WORK/block.sh") lines of the verification block from $SRC"

# --- fake `hv01-config-backup.sh` on PATH, in the pmxcfs ARCHIVED layout -----------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/hv01-config-backup.sh" <<'STUB'
#!/usr/bin/env bash
# MODE selects the behaviour the helper's verification block must cope with.
set -uo pipefail
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/etc/pve/nodes/pve-prod-hv01/qemu-server"
case "${MODE:-ok}" in
    noarchive) exit 0 ;;                       # exited 0, published NOTHING — the F-16 control
    broken)    echo "simulated refuse-to-publish" >&2; exit 1 ;;
esac
if [[ "${MODE:-ok}" != "noconf" ]]; then
    if [[ "${MODE:-ok}" == "value" ]]; then
        # fabricated, obviously fake — a real hash must never appear in a test fixture
        printf 'cipassword: $5$rounds=5000$fakesalt$FAKEVALUEneverreal\n' \
            >"$STAGE/etc/pve/nodes/pve-prod-hv01/qemu-server/100.conf"
    else
        printf 'cipassword: <STRIPPED by hv01-config-backup.sh 20261101 — issue #128>\n' \
            >"$STAGE/etc/pve/nodes/pve-prod-hv01/qemu-server/100.conf"
    fi
fi
tar -czf "$DEST_DIR/pve-config-20261101.tar.gz" -C "$STAGE" etc
exit 0
STUB
chmod 700 "$WORK/bin/hv01-config-backup.sh"

pass=0
bad=0
report_ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
report_bad() {
    bad=$((bad + 1))
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"
}

# run_block: execute the extracted block with the fixture environment bound.
# $1=MODE (ok|value|noarchive|noconf|broken|missing)  → prints the block output + "fail=N"
run_block() {
    local mode="$1"
    (
        # `fail` is the HELPER's own variable, read by the assertions below; it is deliberately not
        # the fixture's counter (that one is `bad`) so the two never collide across the subshell.
        # TS and LINE are inputs the sourced block consumes — shellcheck cannot see across the `.`.
        # shellcheck disable=SC2034
        fail=0
        # shellcheck disable=SC2034
        TS="fixture"
        # shellcheck disable=SC2034
        LINE='---'
        TV_BASE="$WORK/verify-$mode"
        export JOL_ROTATE_VERIFY_DIR="$TV_BASE"
        export MODE="$mode"        # the stub reads MODE from the ENVIRONMENT, so it must be exported
        mkdir -p "$WORK/empty-bin"
        if [[ "$mode" == "missing" ]]; then
            PATH="$WORK/empty-bin:/usr/bin:/bin"   # coreutils present, the backup script is NOT
        else
            PATH="$WORK/bin:/usr/bin:/bin"
        fi
        # SC1091: the block text is generated in a mktemp dir at runtime, so no path resolvable
        # at lint time exists. (A continuation comment must never begin with the literal
        # `# shellcheck` — it is parsed as a directive.)
        # shellcheck disable=SC1090,SC1091
        # The block writes its failure lines to stderr — correct for an operator terminal, but a
        # command substitution captures stdout ONLY, so the assertions would be blind to exactly
        # the messages they check. Merge them. (Found by RUNNING the fixture: 6 assertions failed
        # while the block itself behaved correctly — a harness defect, not a gate defect.)
        { . "$WORK/block.sh"; } 2>&1
        echo "fail=$fail"
    )
}

expect_text() { # $1=label $2=required substring $3=output
    if grep -qF -- "$2" <<<"$3"; then report_ok "$1"; else report_bad "$1" "$2" "$3"; fi
}
expect_fail() { # $1=label $2=expected fail value (0|1) $3=output
    local got
    got="$(grep -oE 'fail=[01]' <<<"$3" | tail -1)"
    if [[ "$got" == "fail=$2" ]]; then report_ok "$1 ($got)"; else report_bad "$1" "fail=$2" "${got:-none}"; fi
}

echo "--- 1 (THE F-16 CONTROL): exit 0 with NO archive must NOT read as a pass"
O1="$(run_block noarchive)"
expect_text 'no archive -> named as inconclusive' 'VERIFY INCONCLUSIVE' "$O1"
expect_text 'no archive -> says the counters measured nothing' 'without measuring anything' "$O1"
expect_fail 'no archive -> fail=1' 1 "$O1"

echo "--- 2: a surviving cipassword value in the archive must fail the run"
O2="$(run_block value)"
expect_text 'value survives -> FAIL is printed' 'FAIL: credential or key material survived' "$O2"
expect_fail 'value survives -> fail=1' 1 "$O2"

echo "--- 3: an archive with no qemu confs is an unproven gate, not a clean one"
O3="$(run_block noconf)"
expect_text 'no confs -> gate reach is reported' 'inspected nothing' "$O3"
expect_fail 'no confs -> fail=1' 1 "$O3"

echo "--- 4: the backup script exiting 1 (refused to publish) must propagate"
O4="$(run_block broken)"
expect_text 'refused publish -> CONFIG-BACKUP FAILED' 'CONFIG-BACKUP FAILED' "$O4"
expect_fail 'refused publish -> fail=1' 1 "$O4"

echo "--- 5: a stripped archive with confs present is the only PASS"
O5="$(run_block ok)"
expect_text 'clean archive -> PASS line' 'PASS: the archive gate holds' "$O5"
expect_text 'clean archive -> counters printed' 'values_unstripped=0' "$O5"
expect_text 'clean archive -> reach printed' 'qemu_confs=1' "$O5"
expect_fail 'clean archive -> fail=0' 0 "$O5"

echo "--- 6: no backup script installed must be a FAILURE, not a silent note"
O6="$(run_block missing)"
expect_text 'not installed -> says cannot verify' 'cannot verify the archive path' "$O6"
expect_fail 'not installed -> fail=1' 1 "$O6"

echo
echo "rotate-verify fixtures: $pass passed, $bad failed"
if (( bad > 0 )); then exit 1; fi
exit 0
