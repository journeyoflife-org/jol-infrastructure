#!/usr/bin/env bash
# =============================================================================
# test-hv01-config-backup-f3.sh — fixtures for the F-3 credential strip + publish gates
# of hv01-config-backup.sh (issue #128).
#
# WHY THIS FILE EXISTS (finding F-15, 2026-11-01): the proof that closed F-3 was run from
# `.staging/test-cfgbk-f3.sh`, and `.staging/` is in `.gitignore` (line 96). Every red/green run
# cited in CHANGELOG.md and in the runbook was therefore unrecoverable from the repository an
# auditor reads — while the sibling controls (pbs01 gate 3, hv01 gate 13) DO have committed
# fixtures. This file is that promoted version: it runs on a workstation against a SYNTHETIC tree
# (via the script's SRC_PATHS test hook), so the gates can be re-proven by anyone, anywhere.
#
# The FIRST attempt at this control failed its own test and that is the reason these cases exist:
# the strip and the gate were anchored to `etc/pve/qemu-server/*.conf`, while pmxcfs archives
# configs under `etc/pve/nodes/<node>/qemu-server/*.conf` — the gate inspected nothing and still
# reported success. Case 3 below is that defect kept as a permanent negative control.
#
# Exit: 0 all cases behaved, 1 a case failed, 2 the script under test is missing.
# Writes only inside its own mktemp workdir. Fabricated values only — a real credential hash must
# never appear here (§0.1).
# =============================================================================
set -uo pipefail

SUT="${1:-/opt/jol/repos/jol-infrastructure/scripts/maintenance/hv01-config-backup.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[[ -f "$SUT" ]] || { echo "FATAL: $SUT not found" >&2; exit 2; }

pass=0
fail=0
report_ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
report_bad() {
    fail=$((fail + 1))
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"
}
expect_text() { if grep -qF -- "$2" <<<"$3"; then report_ok "$1"; else report_bad "$1" "$2" "$3"; fi }
expect_eq()   { if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_bad "$1" "$3" "$2"; fi }
expect_rc()   { if [[ "$2" == "$3" ]]; then report_ok "$1 (rc=$2)"; else report_bad "$1" "expected rc=$3" "got rc=$2"; fi }

mkstage() { # $1=name — builds a pmxcfs-like tree; prints its root
    local root="$WORK/src-$1" conf
    mkdir -p "$root/etc/pve/nodes/pve-prod-hv01/qemu-server"
    conf="$root/etc/pve/nodes/pve-prod-hv01/qemu-server/100.conf"
    # SC2016: the `$5$…` below is the literal sha256crypt PREFIX of a hash, not a shell variable —
    # single quotes are exactly what keeps these fabricated values from ever being expanded.
    # shellcheck disable=SC2016
    case "$1" in
        # one live stanza + two snapshot stanzas: exactly the 3-lines-in-one-conf shape measured
        # on the host (vm100 3 = 1 live + 2 snapshot), which is why a rotation raises the fleet
        # total from 9 to 12 rather than keeping it at 9.
        values) printf 'agent: enabled=1\ncipassword: $5$rounds=5000$s1$FAKEone\n[snapshot]: pre-x\n  cipassword: $5$rounds=5000$s2$FAKEtwo\n[snapshot]: pre-y\n  cipassword: $5$rounds=5000$s3$FAKEthree\n' >"$conf" ;;
        clean)  printf 'agent: enabled=1\ncipassword: <STRIPPED already>\n' >"$conf" ;;
        noconf) printf 'cluster: quorum=1\n' >"$root/etc/pve/cluster.cfg" ;;
        keys)   printf 'cipassword: $5$rounds=5000$s1$FAKEone\n' >"$conf"
                mkdir -p "$root/etc/pve/priv"
                # Content is irrelevant — the gate under test matches the NAME pattern
                # (`etc/pve/priv|\.key$`). Deliberately no PEM header: a fixture must not trip the
                # repo's own detect-private-key / secret-scan hooks with a fabricated key body.
                printf 'FABRICATED-PLACEHOLDER-NOT-A-KEY\n' >"$root/etc/pve/priv/authkey.key" ;;
    esac
    echo "$root"
}

run_sut() { # $1=script $2=stage root -> sets RC / OUT / DEST globals
    local script="$1" root="$2"
    DEST="$WORK/dest-$RANDOM"
    install -d -m 700 "$DEST"
    # SRC_PATHS is passed RELATIVE to the synthetic root on purpose: tar stores an absolute path
    # without its leading slash but WITH the whole `/tmp/tmp.XXXX/src-values` prefix, which would
    # put the confs somewhere the script's `$STAGE/etc/pve` lookup cannot reach — i.e. the fixture
    # would be proving nothing. Production passes absolute paths (/etc/pve …), and tar's stored
    # layout for those is `etc/pve/…`, identical to what this builds.
    OUT="$(cd "$root" && SRC_PATHS="etc/pve" DEST_DIR="$DEST" KEEP_DAYS=30 bash "$script" 2>&1)"
    RC=$?
}

echo "--- 1: credential values in the archived layout are stripped and the counter is PRINTED"
run_sut "$SUT" "$(mkstage values)"
expect_rc 'strip run -> publishes' 0 "$RC"
expect_text 'OK line reports 0 surviving values' 'cipassword_values_unstripped=0' "$OUT"
expect_text 'OK line reports the 3 markers it wrote' 'cipassword_markers=3' "$OUT"
expect_text 'OK line names the confs it reached' 'qemu_confs=1' "$OUT"
expect_text 'archive mode is 600' 'mode=600' "$OUT"
A="$(find "$DEST" -maxdepth 1 -name 'pve-config-*.tar.gz' | head -1)"
if [[ -n "$A" ]] && tar xzOf "$A" --wildcards '*/qemu-server/*.conf' 2>/dev/null | grep -q 'FAKE'; then
    report_bad 'no fabricated value may travel into the archive' 'archive free of values' 'value present'
else
    report_ok 'no fabricated value travels into the archive'
fi

echo "--- 2 (NEGATIVE): with the strip disabled, publishing MUST be refused"
sed -E 's|^([[:space:]]*)sed -i -E .*|\1:|' "$SUT" >"$WORK/nostrip.sh"
expect_eq 'the disabled copy really lost its strip' "$(grep -c 'sed -i -E' "$WORK/nostrip.sh")" 0
run_sut "$WORK/nostrip.sh" "$(mkstage values)"
expect_rc 'strip disabled -> refuses to publish' 1 "$RC"
expect_text 'refusal is named' 'cipassword value survived staging' "$OUT"
if [[ -n "$(find "$DEST" -maxdepth 1 -name 'pve-config-*.tar.gz' 2>/dev/null)" ]]; then
    report_bad 'no archive may be left behind' 'no published archive' 'archive present'
else
    report_ok 'no published archive'
fi
if [[ -n "$(find "$DEST" -maxdepth 1 -name '*.new' 2>/dev/null)" ]]; then
    report_bad 'no .new leftover may be left behind' 'no .new leftover' '.new present'
else
    report_ok 'no .new leftover'
fi

echo "--- 3 (THE F-3 ROOT-CAUSE CONTROL): a tree with no qemu-server conf must NOT pass"
run_sut "$SUT" "$(mkstage noconf)"
expect_rc 'no confs reachable -> refuses' 1 "$RC"
expect_text 'and says the gate proved nothing' 'the F-3 gate cannot prove anything' "$OUT"

echo "--- 4: key material in the same tree is excluded, not merely reported"
run_sut "$SUT" "$(mkstage keys)"
expect_rc 'keys present but excluded -> publishes' 0 "$RC"
A4="$(find "$DEST" -maxdepth 1 -name 'pve-config-*.tar.gz' | head -1)"
if [[ -n "$A4" ]] && tar tzf "$A4" | grep -qE 'etc/pve/priv|\.key$'; then
    report_bad 'priv/ and *.key must not be in the archive' 'no key entries' 'key entry found'
else
    report_ok 'no key entry in the archive'
fi
expect_text 'and the credential field is still stripped' 'cipassword_values_unstripped=0' "$OUT"

echo "--- 5: an already-sanitised tree stays publishable (idempotence of the gate, not of the run)"
run_sut "$SUT" "$(mkstage clean)"
expect_rc 'clean tree -> publishes' 0 "$RC"
expect_text 'and reports zero surviving values' 'cipassword_values_unstripped=0' "$OUT"

echo
echo "config-backup F-3 fixtures: $pass passed, $fail failed"
if (( fail > 0 )); then exit 1; fi
exit 0
