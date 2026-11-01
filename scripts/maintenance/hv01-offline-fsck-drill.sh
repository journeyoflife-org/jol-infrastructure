#!/usr/bin/env bash
# =============================================================================
# hv01-offline-fsck-drill.sh — prove a restored backup image's FILESYSTEM
# metadata is sound, offline, without booting the guest and without repairing
# anything. Closes runbook §6's offline leg for an arbitrary VMID.
#
# WHY THIS SCRIPT EXISTS (issue #137, evidence §11 follow-up 4): the leg had
# been executed by throwaway /tmp harnesses twice, and BOTH times the harness
# failed silently while the run looked complete:
#   2026-10-22: `lvs -o lv_path local-lvm/vm-199-disk-0` is an invalid spec
#             (the VG is `pve`; `local-lvm` is the PVE storage id), so the
#             lookup printed nothing and NO filesystem was ever checked.
#   2026-11-01: `losetup -lx` is not a valid option on this util-linux, the
#             cleanup trap had been disarmed by blanking the variable, and
#             `qm destroy --purge` left a 50 GB orphan LV (thin pool
#             5.93 % -> 6.47 %) while reporting a clean teardown. `tail -6`
#             also discarded exactly the lines that explained rc=4.
# Every rule below is the direct codification of one of those failures.
#
# CONTRACT: idempotent (state checked before every mutation), change-logged
# (/var/log/jol-hv01 700, log 600), DRY_RUN by default, non-destructive to
# production (the only object created is the scratch VMID, and it is destroyed
# again; no production disk is ever opened). No credentials in this script, and
# the encryption key is only USED through PVE, never read or printed.
#
# Usage:  sudo DRY_RUN=1 ./hv01-offline-fsck-drill.sh --vmid 100      # preview
#         sudo DRY_RUN=0 ./hv01-offline-fsck-drill.sh --vmid 100      # apply
#         sudo ./hv01-offline-fsck-drill.sh --vmid 100 --group 2026-11-01T00:00:01Z
#         ./hv01-offline-fsck-drill.sh --self-test                    # no host needed
#
# Exit codes (decoded, because `e2fsck` exit codes are information):
#   0 clean      1 checked-with-residual (nothing severe)   2 usage error
#   3 precondition aborted (nothing was changed)            4 teardown unverified
#   5 SEVERE inconsistency — a human must read the log before any reuse
# =============================================================================
set -uo pipefail

EXIT_CLEAN=0; EXIT_RESIDUAL=1; EXIT_USAGE=2; EXIT_PRECOND=3; EXIT_TEARDOWN=4; EXIT_SEVERE=5
SEVERE_MARKERS='UNEXPECTED INCONSISTENCY|is corrupted|Missing offset|Wrong blocks count|Inode bitmap differences are not correct|GROUP DESCRIPTOR|fatal|structure needs cleaning'

DRY_RUN="${DRY_RUN:-1}"
EXPECTED_HOST="${EXPECTED_HOST:-pve-prod-hv01}"
PBS_STORAGE="${PBS_STORAGE:-pbs01}"
RESTORE_STORAGE="${RESTORE_STORAGE:-local-lvm}"
VG="${VG:-pve}"                 # NOT the storage id 'local-lvm' — see header
SCRATCH="${SCRATCH:-199}"
SCRIPT_NAME="hv01-offline-fsck-drill.sh"
LOG_DIR="/var/log/jol-hv01"
# ⚠ FIXED 2026-11-01 (finding F-32): the name was built from `date +%Y%m%d-%H%M%S` = HOST LOCAL
# time, while the stamps these logs are the proof-of for are labelled Z. evidence §12 measured the
# same class on the 2026-10-22 logs ("logs are named in HOST LOCAL time"). A durable artifact must
# not need a second lookup to be placed on the UTC timeline, so the NAME is UTC. The line prefixes
# stay local-with-offset because PVE/qm task logs are local, and correlating to them is the whole
# point of the per-line clock — but the offset is now printed, so no value can be misread as UTC.
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/offline-fsck-$TS.log"
VMID='' GROUP='' SELFTEST=0

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*" | tee -a "$LOG_FILE"; }
warn() { log "WARN : $*"; }
die()  { log "ABORT: $*"; exit "${2:-$EXIT_PRECOND}"; }

usage() {
    sed -n '2,40p' "$0" 2>/dev/null | grep -E '^# (Usage|hv01|—)' || true
    # ⚠ FIXED 2026-11-01 (finding F-32): this line advertised `[--force]`, which the parser below
    # has no case for — `--force` therefore printed "unknown option" and exited 2. A read-only drill
    # has no force mode (nothing here is skippable by design), so the option is removed rather than
    # implemented.
    echo "options: --vmid N [--group ISO-T] [--scratch N] [--self-test]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)     VMID="${2:-}"; shift 2 ;;
        --group)    GROUP="${2:-}"; shift 2 ;;
        --scratch)  SCRATCH="${2:-}"; shift 2 ;;
        --self-test) SELFTEST=1; shift ;;
        -h|--help)  usage; exit $EXIT_USAGE ;;
        *) echo "unknown option: $1" >&2; usage; exit $EXIT_USAGE ;;
    esac
done

# ---------------------------------------------------------------------------
# Self-test: proves the classifier can actually fail. A checker that cannot
# fail is not a checker (same rule as scripts/maintenance/check-changelog-table.py).
# Runs without a PVE host, so it is CI-safe.
# ---------------------------------------------------------------------------
classify_e2fsck_rc() {  # $1 = rc -> prints the human decode
    case "$1" in
        0) echo "CLEAN — no errors" ;;
        1) echo "errors CORRECTED (cannot happen under -n; would mean the run repaired)" ;;
        2) echo "reboot needed — soft errors, cannot be corrected offline" ;;
        4) echo "UNCORRECTED errors — -n never repairs, so this is a finding to read, not a pass" ;;
        8) echo "operational error (device busy / wrong path) — the check DID NOT RUN" ;;
        *) echo "protocol error (rc=$1) — the check DID NOT RUN" ;;
    esac
}
classify_vfat_rc() {
    case "$1" in
        0) echo "CLEAN" ;;
        1) echo "recoverable errors found — under -n NOTHING was repaired, this is a finding" ;;
        2) echo "unrecoverable errors" ;;
        *) echo "usage/operational error (rc=$1) — the check DID NOT RUN" ;;
    esac
}

# is_fat — the first version of this script used `[[ $fstype =~ ^fat ]]`, which
# does NOT match "vfat" (the type blkid actually reports for the EFI partition).
# Consequence measured 2026-11-01T15:41Z: the EFI rc=1 was decoded by the e2fsck
# classifier AND fell through the severity logic, so a real finding did not reach
# the exit code — with a clean root, the run would have exited 0. Match exactly.
is_fat() {
    case "$1" in
        vfat|fat12|fat16|fat32|msdos|Win95B2) return 0 ;;
        *) return 1 ;;
    esac
}

# severity_of FAT RC SEV -> prints the script exit level this result implies. FACTORED OUT
# 2026-11-01 (findings F-29 + F-30) so that --self-test can exercise the aggregation decision,
# which it previously could not reach — the classifier fixtures tested the human-readable decode
# strings, not the code that picks the exit code, so both bugs below stayed invisible.
#
# F-29, the bitmask: `e2fsck` exit codes are a SUM of condition bits (1 corrected | 2 reboot |
#   4 uncorrected | 8 operational | 16 library/superblock | 128 signalled). The first version tested
#   `-eq 4` and `-ge 8`, so rc=5/6/7 (4 combined with 1 or 2 — i.e. errors AND a broken read-only
#   contract) and plain rc=1/2/3 matched NEITHER branch, left worst=EXIT_CLEAN and the run printed
#   "exit 0 (clean)" over a filesystem that had reported errors.
# F-30, the empty scan: if `losetup -P` produced no children (GPT-less LV, udev not settled), the
#   partition loop body never executed, `worst` stayed 0 and the run again printed "clean" — the
#   "0 inspected presented as health" class this file exists to eliminate (see the 2026-10-22 and
#   2026-11-01 harness failures in the header).
#
# Bits 1/2 under `-n` mean the tool repaired or demanded a reboot — a read-only proof that mutated
# its subject is not a proof, so those are SEVERE, not residual. rc=1 for fsck.vfat under `-n` is
# the opposite: `-n` cannot repair, so "recoverable errors found" is a genuine finding = residual.
severity_of() {
    local fat="$1" rc="$2" sev="${3:-0}"
    [[ "$rc" =~ ^[0-9]+$ ]] || { echo $EXIT_SEVERE; return; }   # unreadable code = did not run
    if (( fat )); then
        case "$rc" in
            0) echo $EXIT_CLEAN ;;
            1) echo $EXIT_RESIDUAL ;;
            *) echo $EXIT_SEVERE ;;                             # 2 unrecoverable, >2 did not run
        esac
        return
    fi
    if (( rc == 0 )); then echo $EXIT_CLEAN; return; fi
    if (( rc == 4 )); then
        # the measured vm/101 case: uncorrected bookkeeping, no severe marker -> residual
        if (( sev > 0 )); then echo $EXIT_SEVERE; else echo $EXIT_RESIDUAL; fi
        return
    fi
    if (( rc == 12 )); then
        # 4|8: errors reported AND the check aborted — the incomplete run wins
        echo $EXIT_SEVERE; return
    fi
    echo $EXIT_SEVERE
}

self_test() {
    local fails=0 pass=0
    check() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
              else fails=$((fails+1)); printf '  FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"; fi; }
    printf '%s --self-test (red/green of the classifier itself)\n' "$SCRIPT_NAME"
    check "e2fsck rc=0 decodes CLEAN"        "$(classify_e2fsck_rc 0)"        "CLEAN — no errors"
    check "e2fsck rc=4 is NOT a pass"        "$(classify_e2fsck_rc 4)"        "UNCORRECTED errors — -n never repairs, so this is a finding to read, not a pass"
    check "e2fsck rc=8 = did not run"        "$(classify_e2fsck_rc 8)"        "operational error (device busy / wrong path) — the check DID NOT RUN"
    check "e2fsck rc=99 = did not run"       "$(classify_e2fsck_rc 99)"       "protocol error (rc=99) — the check DID NOT RUN"
    check "vfat rc=2 unrecoverable"          "$(classify_vfat_rc 2)"          "unrecoverable errors"
    check "vfat rc=1 is a finding"           "$(classify_vfat_rc 1)"          "recoverable errors found — under -n NOTHING was repaired, this is a finding"
    # dispatch fixtures — the ^fat regex bug that hid the EFI finding from the exit code
    if is_fat vfat; then check "is_fat matches blkid 'vfat'" ok ok; else check "is_fat matches blkid 'vfat'" fail ok; fi
    if is_fat ext4; then check "is_fat does NOT swallow ext4" fail pass; else check "is_fat does NOT swallow ext4" pass pass; fi
    # severity grep: fixture with a severe marker must be caught, fixture without must not
    local sev_ok sev_bad
    sev_ok=$(printf 'Inode 5368 has zero dtime\nPass 5: Checking group summary information\n')
    sev_bad=$(printf 'Inode 5368 has zero dtime\n/fsck: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY\n')
    check "no-severe fixture -> 0 hits"  "$(printf '%s' "$sev_ok"  | grep -cE "$SEVERE_MARKERS" || true)" "0"
    check "severe fixture   -> 1 hit"    "$(printf '%s' "$sev_bad" | grep -cE "$SEVERE_MARKERS" || true)" "1"
    # ---- severity_of fixtures (F-29/F-30, added 2026-11-01) ------------------------------------
    # These are the fixtures that were MISSING when the bug shipped: the decode-string fixtures
    # above all passed while the aggregation still returned EXIT_CLEAN for rc=5. Every bitmask
    # combination that is not 0/4/8 must be refused, never quietly averaged away.
    lvl() { severity_of "$1" "$2" "${3:-0}"; }
    check "e2fs rc=0 sev=0 -> clean"        "$(lvl 0 0 0)" "$EXIT_CLEAN"
    check "e2fs rc=4 sev=0 -> residual"     "$(lvl 0 4 0)" "$EXIT_RESIDUAL"
    check "e2fs rc=4 sev=1 -> severe"       "$(lvl 0 4 1)" "$EXIT_SEVERE"
    check "e2fs rc=5 (4|1) -> severe"       "$(lvl 0 5 0)" "$EXIT_SEVERE"
    check "e2fs rc=6 (4|2) -> severe"       "$(lvl 0 6 0)" "$EXIT_SEVERE"
    check "e2fs rc=7 (4|2|1)-> severe"      "$(lvl 0 7 0)" "$EXIT_SEVERE"
    check "e2fs rc=1 corrected -> severe"   "$(lvl 0 1 0)" "$EXIT_SEVERE"
    check "e2fs rc=2 reboot -> severe"      "$(lvl 0 2 0)" "$EXIT_SEVERE"
    check "e2fs rc=3 -> severe"             "$(lvl 0 3 0)" "$EXIT_SEVERE"
    check "e2fs rc=8 did-not-run -> severe" "$(lvl 0 8 0)" "$EXIT_SEVERE"
    check "e2fs rc=12 (4|8) -> severe"      "$(lvl 0 12 0)" "$EXIT_SEVERE"
    check "e2fs rc=16 -> severe"            "$(lvl 0 16 0)" "$EXIT_SEVERE"
    check "e2fs rc=128 -> severe"           "$(lvl 0 128 0)" "$EXIT_SEVERE"
    check "e2fs rc=unparseable -> severe"   "$(lvl 0 'n/a' 0)" "$EXIT_SEVERE"
    check "vfat rc=0 -> clean"              "$(lvl 1 0 0)" "$EXIT_CLEAN"
    check "vfat rc=1 -> residual (not clean)" "$(lvl 1 1 0)" "$EXIT_RESIDUAL"
    check "vfat rc=2 -> severe"             "$(lvl 1 2 0)" "$EXIT_SEVERE"
    check "vfat rc=4 -> severe"             "$(lvl 1 4 0)" "$EXIT_SEVERE"
    # NEGATIVE CONTROL: a zero-partition scan must not be able to report clean. The guard in step 4
    # is `[[ $checked -eq 0 ]] -> die`, so the fixture replays the real loop construct against an
    # EMPTY device list and asserts the counter it reads stays 0 (guard fires).
    local z=0
    while read -r _dev _fs; do z=$((z + 1)); done < <(printf '')
    check "empty partition list -> checked stays 0, guard fires" "$z" "0"
    # empty output must never be read as a pass (the 2026-10-22 failure mode)
    check "empty probe -> non-zero abort path" "$(printf '' | grep -c 'vm-199-disk-0' || true)" "0"
    printf 'self-test: %d passed, %d failed\n' "$pass" "$fails"
    [[ $fails -eq 0 ]] || { echo "SELF-TEST FAILED — refusing to trust the scan" >&2; return 1; }
    return 0
}

if [[ $SELFTEST -eq 1 ]]; then
    self_test; rc=$?
    # usage red/green too: a bad option must exit 2. Only possible when the
    # script was invoked as a real file — over `bash -s` (the SSH pipe) $0 is
    # "bash", so re-executing it is impossible and the check is REPORTED AS
    # SKIPPED rather than silently passing (the lesson of this whole file).
    if [[ -f "$0" ]]; then
        bash "$0" --bogus >/dev/null 2>&1; got=$?
        if [[ "$got" == "$EXIT_USAGE" ]]; then
            echo "  ok   bad option rejected with rc=$EXIT_USAGE"
        else
            echo "  FAIL bad option rejection: got rc=$got want rc=$EXIT_USAGE" >&2; rc=1
        fi
    else
        echo "  SKIP bad-option rejection (\$0='$0' is not a file — piped invocation)"
    fi
    exit $rc
fi

# ---------------------------------------------------------------------------
# 0. Preflight — host identity, root, args, and the tool table.
#    The tool table is printed from a live `command -v` probe, never from
#    memory: the 2026-11-01 record claimed `fsck.vfat` absent on this host and
#    that claim was FALSE (measured 2026-11-01T14:21Z: /usr/sbin/fsck.vfat,
#    package dosfstools 4.2-1.2, file mtime 2025-02-25). Do not re-assert it.
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || die "must run as root" $EXIT_USAGE
[[ "$(hostname)" == "$EXPECTED_HOST" ]] || die "refusing to run on $(hostname) (expected $EXPECTED_HOST)"
[[ "$VMID" =~ ^[0-9]+$ ]] || { usage; die "--vmid <numeric> is required" $EXIT_USAGE; }
[[ "$SCRATCH" =~ ^[0-9]+$ ]] || die "--scratch must be numeric, got '$SCRATCH'" $EXIT_USAGE
[[ "$VMID" != "$SCRATCH" ]] || die "--scratch must differ from --vmid" $EXIT_USAGE
[[ -f "/etc/pve/qemu-server/$VMID.conf" ]] || die "VMID $VMID has no config on this node"

mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true

log "=== $SCRIPT_NAME start (DRY_RUN=$DRY_RUN) vmid=$VMID scratch=$SCRATCH ==="
log "UTC now $(date -u +%FT%TZ) | local $(date +%FT%T%z) | TZ $(timedatectl show -p Timezone --value 2>/dev/null)"

MISSING=''
for t in qm qmrestore pvesm losetup e2fsck dumpe2fs blkid fdisk; do
    command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[[ -z "$MISSING" ]] || die "required tools absent:$MISSING"
VFAT_TOOL='present'; command -v fsck.vfat >/dev/null 2>&1 || VFAT_TOOL='absent'
log "tools OK (e2fsck $(e2fsck -V 2>&1 | head -1), fsck.vfat=$VFAT_TOOL, kpartx=$(command -v kpartx >/dev/null 2>&1 && echo present || echo 'absent -> using losetup -P'))"

# ---------------------------------------------------------------------------
# 1. Preconditions — every one of them fail-closed, with the measured value
#    printed. An empty result is an ABORT here, never a silent pass.
# ---------------------------------------------------------------------------
[[ -e "/etc/pve/qemu-server/$SCRATCH.conf" ]] && \
    die "scratch VMID $SCRATCH already exists — refusing to touch someone else's VM (pass --scratch <free>)"

if [[ -z "$GROUP" ]]; then
    GROUP="$(pvesm list "$PBS_STORAGE" --content backup 2>/dev/null \
             | awk -v v="/vm/$VMID/" 'index($1,v)>0 && $1 ~ /2[0-9]{3}-/' | sort | tail -1 \
             | sed 's#.*/vm/'"$VMID"'/##; s# .*##')"
fi
[[ -n "$GROUP" ]] || die "no backup group found for vm/$VMID on $PBS_STORAGE — the source does not exist (NOT treating empty as pass)"
VOVID="$PBS_STORAGE:backup/vm/$VMID/$GROUP"
log "source group: $VOVID"

ENC="$(pvesh get "/nodes/$(hostname)/storage/$PBS_STORAGE/content" --content backup --output-format json 2>/dev/null \
       | python3 -c 'import json,sys
v=sys.argv[1]
try: rows=json.load(sys.stdin)
except Exception as e: print("PARSE-FAIL",e); raise SystemExit(3)
m=[r for r in rows if r.get("volid","")==v or r.get("volid","").endswith("/"+v.split(":",1)[1])]
print(m[0].get("encrypted","") if m else "NO-SUCH-GROUP")' "$VOVID")" || die "could not parse the content query for $VOVID"
case "$ENC" in
    NO-SUCH-GROUP|"") die "content query does not list $VOVID — aborting before any restore" ;;
    PARSE-FAIL*)      die "content query returned unparseable JSON: $ENC" ;;
    *) log "client-side encryption fingerprint: ${ENC:0:14}… (value not a secret; the KEY never is)" ;;
esac

POOL_BEFORE="$(lvs --noheadings -o data_percent "$VG/data" 2>/dev/null | tr -d ' %')"
[[ -n "$POOL_BEFORE" ]] || die "cannot read data% of thin pool $VG/data"
LOOP_BASELINE="$(losetup -a 2>/dev/null | grep -c . || true)"
LVG_NAME="$VG/vm-$SCRATCH-disk-0"
log "pre-state: thin pool $VG/data at ${POOL_BEFORE}% | loop mappings $LOOP_BASELINE | scratch conf absent | lv '$LVG_NAME' present=$(lvs --noheadings -o lv_name "$VG" 2>/dev/null | grep -c "vm-$SCRATCH-disk-0")"

# ---------------------------------------------------------------------------
# 2. Teardown trap — installed BEFORE the first mutation, and it never reads
#    a variable the script has blanked (failure (a) of 2026-11-01).
# ---------------------------------------------------------------------------
LOOP=''
teardown() {
    [[ "$DRY_RUN" == "0" ]] || return 0          # never mutate in a preview run
    [[ -n "${TEARDOWN_DONE:-}" ]] && return 0    # idempotent: step 5 calls it, the trap calls it again
    TEARDOWN_DONE=1
    if [[ -n "$LOOP" ]]; then
        if losetup -d "$LOOP" 2>/dev/null; then
            log "teardown: detached $LOOP (its p* children go with it)"
        else
            warn "teardown: could not detach $LOOP"
        fi
    fi
    if [[ -e "/etc/pve/qemu-server/$SCRATCH.conf" ]]; then
        qm stop "$SCRATCH" >/dev/null 2>&1 || true
        qm destroy "$SCRATCH" --purge >/dev/null 2>&1 || log "teardown: qm destroy returned $?"
    fi
    # `qm destroy --purge` can leave the thin LV behind "with 1 warning" —
    # reclaim it, but only after proving the conf is gone (an in-use LV must
    # never be removed).
    if [[ ! -e "/etc/pve/qemu-server/$SCRATCH.conf" ]]; then
        for lv in $(lvs --noheadings -o lv_name "$VG" 2>/dev/null | grep "vm-$SCRATCH-" | tr -d ' '); do
            lvremove -y "$VG/$lv" >/dev/null 2>&1 && log "teardown: reclaimed orphan LV $VG/$lv"
        done
    fi
    return 0
}
trap teardown EXIT

# ---------------------------------------------------------------------------
# 3. Restore to the scratch VMID — and NEVER BOOT IT.
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "0" ]]; then
    qmrestore "$VOVID" "$SCRATCH" --storage "$RESTORE_STORAGE" > "$LOG_FILE.restore" 2>&1
    RCR=$?
    tail -4 "$LOG_FILE.restore" | tee -a "$LOG_FILE"
    [[ $RCR -eq 0 ]] || { mv -f "$LOG_FILE.restore" "$LOG_DIR/offline-fsck-$TS-restore-failed.log" 2>/dev/null; die "qmrestore rc=$RCR"; }
    [[ -e "/etc/pve/qemu-server/$SCRATCH.conf" ]] || die "restore reported rc=0 but $SCRATCH.conf is absent — nothing was created"
    qm set "$SCRATCH" --delete net0 >/dev/null 2>&1 && log "scratch net0 deleted (defence in depth: it must never reach a network)"
    LV_PATH="$(readlink -f "/dev/$VG/vm-$SCRATCH-disk-0")"
    [[ -b "$LV_PATH" ]] || die "'$LV_PATH' is not a block device — the 2026-10-22 silent-skip class"
    log "restored without boot: LV $LV_PATH (VG $VG) is a real block device"
    LOOP="$(losetup -f --show -P "$LV_PATH")" || die "losetup -f --show -P failed on $LV_PATH"
    log "loop-mapped $LOOP -> partitions: $(find /dev -maxdepth 1 -name "$(basename "$LOOP")p*" -printf '%f ')"
    fdisk -l "$LOOP" >> "$LOG_FILE" 2>&1 || true
else
    log "DRY  : qmrestore $VOVID $SCRATCH --storage $RESTORE_STORAGE  (then losetup -f --show -P, never qm start)"
    log "DRY  : would check every partition by its ACTUAL blkid type: ext* -> e2fsck -fn, vfat -> fsck.vfat -n, else SKIPPED-with-reason"
    log "DRY  : teardown = losetup -d, qm destroy --purge, then reclaim any orphan vm-$SCRATCH-* LV, then verify post-state"
    log "=== $SCRIPT_NAME finished in DRY_RUN — nothing changed. log: $LOG_FILE ==="
    exit $EXIT_CLEAN
fi

# ---------------------------------------------------------------------------
# 4. Check each partition by its measured filesystem type. Full output stays in
#    $LOG_FILE (failure (c): `tail -6` threw away the explanation of rc=4).
# ---------------------------------------------------------------------------
worst=$EXIT_CLEAN
checked=0      # partitions a checker actually RAN on (F-30: 0 must never read as clean)
skipped=0      # partitions with no applicable offline checker — a named gap, not a pass
while read -r pdev fstype; do
    [[ -b "$pdev" ]] || continue
    case "$fstype" in
        ext2|ext3|ext4) TOOL='e2fsck -fn' ;;
        vfat|fat32|fat16) [[ "$VFAT_TOOL" == present ]] && TOOL='fsck.vfat -n -v' || TOOL='' ;;
        swap|"") TOOL='' ;;
        *) TOOL='' ;;
    esac
    if [[ -z "$TOOL" ]]; then
        log "SKIP : $pdev ($fstype) — no offline checker applicable on this host; recorded as a gap, not as a pass"
        skipped=$((skipped + 1))
        continue
    fi
    log "--- check $pdev ($fstype) with $TOOL (read-only by design, nothing is repaired) ---"
    LINES_BEFORE="$(wc -l < "$LOG_FILE")"
    # shellcheck disable=SC2086  # TOOL is intentionally word-split into argv
    $TOOL "$pdev" >> "$LOG_FILE" 2>&1
    rc=$?
    # decode with the classifier that matches the tool that ran — using the
    # e2fsck decode for fsck.vfat mislabelled its rc=1 as "errors CORRECTED"
    # on the first vm/100 run (measured 2026-11-01T15:21Z), i.e. the log would
    # have claimed a repair that -n never performs.
    if is_fat "$fstype"; then
        log "result: $pdev ($fstype) rc=$rc -> $(classify_vfat_rc "$rc")"
    else
        log "result: $pdev ($fstype) rc=$rc -> $(classify_e2fsck_rc "$rc")"
    fi
    # severity is attributed to THIS device only: grepping the whole cumulative
    # log would blame the next partition for the previous one's finding.
    sev=$(tail -n +"$((LINES_BEFORE + 1))" "$LOG_FILE" | grep -cE "$SEVERE_MARKERS" || true)
    log "severe-marker count for $pdev: $sev"
    checked=$((checked + 1))
    # F-29: the level comes from severity_of (bitmask-aware), not from an `-eq 4`/`-ge 8` pair that
    # let rc=1/2/3/5/6/7 fall through both branches and leave the run reporting clean.
    fat_flag=0; is_fat "$fstype" && fat_flag=1
    lvl=$(severity_of "$fat_flag" "$rc" "$sev")
    if (( lvl > worst )); then
        log "aggregate: exit level raised $worst -> $lvl by $pdev ($fstype rc=$rc, severe markers $sev)"
        worst=$lvl
    fi
    if [[ "$fstype" == ext* ]]; then
        dumpe2fs -h "$pdev" 2>/dev/null | grep -E 'Filesystem state|Mount count|Last checked' | sed 's/^/    /' | tee -a "$LOG_FILE" || true
    fi
done < <(find /dev -maxdepth 1 -name "$(basename "$LOOP")p*" -printf '%p\n' 2>/dev/null | sort \
         | while read -r d; do printf '%s %s\n' "$d" "$(blkid -s TYPE -o value "$d" 2>/dev/null || echo unknown)"; done)

# F-30 (2026-11-01): if nothing was inspected the run must NOT report clean. Both harness
# predecessors of this script failed this way — 2026-10-22 printed nothing for an invalid LV spec
# and 2026-11-01 leaked a loop mapping — and in both cases the absence of an error line was read as
# a pass. An empty scan is a precondition failure. The teardown trap stays ARMED on purpose: leaving
# a scratch VM + 50 GB thin LV behind for "forensics" is the exact 2026-11-01 run-1 leak, and the
# full child output is already in $LOG_FILE, so nothing needed for inspection is lost by cleaning up.
if [[ $checked -eq 0 ]]; then
    warn "0 partitions were CHECKED ($skipped skipped with a named reason) — NOT treating empty as pass"
    die "empty scan on $LOOP: no partition exposed a filesystem this host can check offline" $EXIT_PRECOND
fi
log "coverage: $checked partition(s) checked, $skipped skipped with a named reason"

# ---------------------------------------------------------------------------
# 5. Teardown VERIFIED BY POST-STATE, not by the absence of an error message.
# ---------------------------------------------------------------------------
teardown; LOOP=''
sleep 2
CONF_ABSENT=yes; [[ -e "/etc/pve/qemu-server/$SCRATCH.conf" ]] && CONF_ABSENT=no
LV_COUNT="$(lvs --noheadings -o lv_name "$VG" 2>/dev/null | grep -c "vm-$SCRATCH-" || true)"
LOOP_NOW="$(losetup -a 2>/dev/null | grep -c . || true)"
POOL_AFTER="$(lvs --noheadings -o data_percent "$VG/data" 2>/dev/null | tr -d ' %')"
RUNNING="$(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{printf "%s ",$1}')"
log "post-state: conf_absent=$CONF_ABSENT lv_count=$LV_COUNT loop_count=$LOOP_NOW (baseline $LOOP_BASELINE) pool ${POOL_BEFORE}% -> ${POOL_AFTER}%"
log "post-state: running VMs: ${RUNNING:-<EMPTY>}"
TEARDOWN_BAD=0
[[ "$CONF_ABSENT" == yes ]] || { warn "scratch conf still present"; TEARDOWN_BAD=1; }
[[ "$LV_COUNT" == 0 ]]      || { warn "orphan LVs remain for vm-$SCRATCH"; TEARDOWN_BAD=1; }
[[ "$LOOP_NOW" == "$LOOP_BASELINE" ]] || { warn "loop mappings differ from baseline ($LOOP_NOW vs $LOOP_BASELINE)"; TEARDOWN_BAD=1; }
[[ -n "${POOL_AFTER:-}" ]] || { warn "cannot re-read pool usage"; TEARDOWN_BAD=1; }
# An EMPTY "running" list is not a pass. The first vm/100 run on 2026-11-01
# printed "running VMs: " with nothing at all, because `qm list` columns are
# VMID / NODE / STATUS / NAME and this awk had tested $2 (the node) — the exact
# silent-empty-output class this whole script was written to eliminate, recreated
# inside the script written to eliminate it. Now: non-empty AND source VMID up.
[[ -n "$RUNNING" ]] || { warn "no VM reported running — the probe is broken or the fleet is down"; TEARDOWN_BAD=1; }
qm status "$VMID" 2>/dev/null | grep -q '^status: running' \
    || { warn "production VMID $VMID is not running after the drill"; TEARDOWN_BAD=1; }
[[ "$TEARDOWN_BAD" == 0 ]] || { log "=== TEARDOWN UNVERIFIED — clean up by hand before closing this run ==="; exit $EXIT_TEARDOWN; }

log "=== $SCRIPT_NAME finished: exit $worst ($( [[ $worst -eq $EXIT_CLEAN ]] && echo clean || echo residual-or-severe )) — full output: $LOG_FILE ==="
log "record the finding as measured. An rc=4 with only orphan-list/zero-dtime/negative-bitmap work is a quiesced copy's pending bookkeeping, and it stays an accepted NAMED residual — it is never retitled 'clean'."
exit "${worst}"
