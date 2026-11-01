#!/usr/bin/env bash
# =============================================================================
# pve-rotate-cipassword.sh — operator-executed rotation of the cloud-init console
# password on the AI-estate VMs (finding F-3, issue #128, Option A).
#
# WHY A SCRIPT AND NOT A CHAT COMMAND: the value must never enter this repo, an
# issue, a ticket, shell history, a log line, a file, or an agent's context
# (AGENTS.md §0.1 + the Tier-1 credential rule). Only the operator may type it.
# This script therefore REFUSES TO RUN without a real TTY — an automation agent
# (including the one that wrote it) cannot complete the rotation. That is a
# mechanical four-eyes gate, not a comment asking people to be careful.
#
# Installed at /usr/local/bin/jol-rotate-cipassword.sh, run by hand:
#   ssh -t pve 'sudo jol-rotate-cipassword.sh 100 101 102'
#
# What it does per VMID: §0.3 snapshot -> read -rs (no echo) -> qm set
# --cipassword -> prove the field changed by comparing TRUNCATED SHA-256
# DIGESTS of the line (never the value) -> unset. One prompt for the whole set,
# because today all three guests share one provisioning password (verified
# 2026-10-31: the digests differ per VM only because of the salt).
#
# Honest residual exposure: the value is transiently visible in argv to root on
# the hypervisor for the duration of `qm set`. That is not avoidable with PVE 9's
# CLI (measured 2026-11-01: /usr/share/perl5/PVE/CLIHandler.pm contains no
# interactive-prompt mechanism, `grep -c prompt` -> 0, and `qm set --help` is not a
# PVE 9 verb — it answers "Unknown option: help", so no prompt convention may be
# assumed), and root-on-hv01 already owns the cleartext-equivalent file, so it
# widens nothing. What IS avoided: history, chat, files, logs, tickets, this repo.
#
# Exit: 0 rotated and proven, 1 refused/failed, 2 usage error.
# =============================================================================
set -uo pipefail

VMIDS=("$@")
LINE='———————————————————————————————————————————————'

if [[ ${#VMIDS[@]} -eq 0 ]]; then
    echo "usage: sudo jol-rotate-cipassword.sh <vmid> [<vmid> …]" >&2
    exit 2
fi
for v in "${VMIDS[@]}"; do
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "VMID must be numeric, got '$v'" >&2; exit 2; }
    [[ -f "/etc/pve/qemu-server/$v.conf" ]] || { echo "VMID $v has no config on this node" >&2; exit 2; }
done

# --- the mechanical human gate -------------------------------------------------
if [[ ! -t 0 ]]; then
    echo "REFUSED: no controlling terminal. This rotation is operator-only (§0.1)." >&2
    echo "Run it interactively:  ssh -t pve 'sudo jol-rotate-cipassword.sh ${VMIDS[*]}'" >&2
    exit 1
fi

TS="$(date +%Y%m%d-%H%M)"
PRE_DIR="/root/prechange-$TS-cipassword"
install -d -m 700 "$PRE_DIR"

digest() { # sha-256 of the cipassword line, truncated: proves change, reveals nothing
    # Leading whitespace tolerated (F-20): an indented option line is still the credential field.
    grep -m1 -E '^[[:space:]]*cipassword:' "$1" 2>/dev/null | sha256sum | cut -c1-12
}

echo "F-3 credential rotation — VMIDs ${VMIDS[*]} — $(date '+%F %T %Z')"
echo "Pre-change copies + snapshots go to $PRE_DIR"

# --- capture BEFORE state, then one prompt -------------------------------------
declare -A BEFORE
for v in "${VMIDS[@]}"; do
    BEFORE[$v]="$(digest "/etc/pve/qemu-server/$v.conf")"
    cp -p "/etc/pve/qemu-server/$v.conf" "$PRE_DIR/$v.conf.before"
    echo "  vm $v: cipassword lines=$(grep -cE '^[[:space:]]*cipassword:' "/etc/pve/qemu-server/$v.conf") digest-before=${BEFORE[$v]:-none}"
    # PVE snapshots capture the VM CONFIG too (that is why a .conf holds inline
    # [snapshot] sections with parent:/snaptime:) — so this is a real rollback path.
    if qm snapshot "$v" "pre-f3-cipassword-$TS" >/dev/null 2>&1; then
        echo "  vm $v: snapshot pre-f3-cipassword-$TS taken"
    else
        echo "  vm $v: SNAPSHOT FAILED — aborting before any change (no rollback path otherwise)" >&2
        exit 1
    fi
done

PW=''
printf 'Type the NEW cloud-init console password (input hidden, then confirmed): '
IFS= read -rs PW
printf 'Type it once more to confirm:                          '
IFS= read -rs PW2
if [[ -z "$PW" || "$PW" != "$PW2" ]]; then
    echo; echo "REFUSED: empty or mismatched input; nothing was changed." >&2
    PW=''; PW2=''
    exit 1
fi
echo

# --- apply ---------------------------------------------------------------------
fail=0
for v in "${VMIDS[@]}"; do
    if qm set "$v" --cipassword "$PW" >/dev/null 2>&1; then
        after="$(digest "/etc/pve/qemu-server/$v.conf")"
        if [[ -n "$after" && "$after" != "${BEFORE[$v]}" ]]; then
            echo "  vm $v: UPDATED  digest ${BEFORE[$v]:-none} -> $after  (values never shown)"
        else
            echo "  vm $v: qm set returned 0 but the digest did NOT change — investigate" >&2
            fail=1
        fi
    else
        echo "  vm $v: qm set FAILED" >&2
        fail=1
    fi
done
PW=''; PW2=''      # drop from this shell's memory as soon as possible
unset PW PW2

# --- prove the archive gate still holds with the new values --------------------
# ⚠ FIXED 2026-11-01 (finding F-16). The first version printed
#     archive=$(basename "${A:-none}") values-unstripped=$(tar xzOf "$A" … | grep -c …) key-entries=$(tar tzf "$A" | grep -c …)
#   and told the operator "0 and 0 is the pass condition". With `$A` empty (no archive matched),
#   both `tar` calls FAIL and `grep -c` prints 0 anyway — measured on the workstation:
#   `archive=none values-unstripped=0 key-entries=0`, tar rc=2. So the stated pass condition was
#   satisfied by a NON-MEASUREMENT: exactly the class this fleet keeps excavating (gate 10's dead
#   branch, gate 3's all-zero tally, F-3's own wrong-path first attempt). The counters are now
#   gated on the archive existing AND on the gate having inspected at least one conf.
echo "$LINE"
echo "Verifying hv01-config-backup.sh still sanitises the archive (temp DEST_DIR, production untouched)…"
if command -v hv01-config-backup.sh >/dev/null 2>&1; then
    TV="${JOL_ROTATE_VERIFY_DIR:-/var/tmp/jol-rotate-verify-$TS}"
    # JOL_ROTATE_VERIFY_DIR exists only so the committed fixture
    # scripts/maintenance/tests/test-pve-rotate-verify.sh can drive this block on a workstation
    # without writing into /var/tmp. Unset in every real (operator) run.
    install -d -m 700 "$TV"
    if DEST_DIR="$TV" hv01-config-backup.sh > "$TV/run.log" 2>&1; then
        A="$(find "$TV" -maxdepth 1 -name 'pve-config-*.tar.gz' | sort | head -1)"
        if [[ -z "$A" || ! -s "$A" ]]; then
            echo "  VERIFY INCONCLUSIVE: hv01-config-backup.sh exited 0 but left no readable archive in $TV" >&2
            echo "  — counters would read 0/0 without measuring anything; treated as FAILURE" >&2
            tail -3 "$TV/run.log" >&2
            fail=1
        else
            # `|| true` on every counter: pipefail would abort the run on a legitimate zero-match.
            CONFS="$(tar tzf "$A" | grep -cE '/qemu-server/[^/]+\.conf$' || true)"
            UNSTRIPPED="$(tar xzOf "$A" --wildcards '*/qemu-server/*.conf' 2>/dev/null | grep -cE '^[[:space:]]*cipassword: [^<]' || true)"
            MARKERS="$(tar xzOf "$A" --wildcards '*/qemu-server/*.conf' 2>/dev/null | grep -cE '^[[:space:]]*cipassword: <STRIPPED' || true)"
            KEYENT="$(tar tzf "$A" | grep -cE 'etc/pve/priv|\.key$|\.pem$|\.srl$' || true)"
            echo "  archive=$(basename "$A") qemu_confs=$CONFS values_unstripped=$UNSTRIPPED stripped_markers=$MARKERS key_entries=$KEYENT"
            # PASS = a gate that actually reached confs (CONFS>0) AND zero survivors AND zero keys.
            # Expect stripped_markers to RISE after rotation: every `qm snapshot` taken above adds
            # a `[snapshot]` stanza carrying the OLD hash (measured 2026-10-31: 9 lines pre-change
            # = 1 live + 2/3/1 snapshot stanzas; +3 new snapshots ⇒ 12 after this run). A count of
            # 9 after rotation would mean the snapshots were NOT taken — it is not the pass signal.
            if (( CONFS == 0 )); then
                echo "  VERIFY INCONCLUSIVE: 0 qemu-server confs in the archive — the F-3 gate inspected nothing" >&2
                fail=1
            elif (( UNSTRIPPED != 0 || KEYENT != 0 )); then
                echo "  FAIL: credential or key material survived into the archive" >&2
                fail=1
            else
                echo "  PASS: the archive gate holds with the new credential (values never printed)"
                echo "  Left behind for you to remove (no secrets, stripped confs): $TV"
            fi
        fi
    else
        echo "  CONFIG-BACKUP FAILED — the refuse-to-publish gate fired or staging broke; see $TV/run.log" >&2
        tail -3 "$TV/run.log" >&2
        fail=1
    fi
else
    echo "  hv01-config-backup.sh not installed — cannot verify the archive path" >&2
    fail=1
fi

# --- what only the operator can still prove ------------------------------------
echo "$LINE"
if [[ $fail -eq 0 ]]; then
    echo "ROTATED. Last proof is yours, and only yours: console login with the NEW value"
    echo "  ssh -t pve 'qm terminal 100'      # login jol-admin + the password you typed"
    echo "SSH on the guests is key-only, so the password gates the CONSOLE only — a wrong"
    echo "value is invisible until someone needs it. Test it now, not during an incident."
    echo "Then store the value in Vaultwarden (never in a ticket/chat/repo) and the old"
    echo "entry can be retired. Rollback if needed: qm rollback <vmid> pre-f3-cipassword-$TS"
    echo "  (a snapshot rollback needs the VM stopped; the .conf copies in $PRE_DIR are the"
    echo "   config-level fallback)."
    echo "$LINE"
    echo "TWO RESIDUALS F-3 KEEPS AFTER A SUCCESSFUL ROTATION — name them at close-out:"
    echo "  1. the OLD hash does not disappear: it stays in every [snapshot] stanza of the live"
    echo "     conf and in $PRE_DIR/*.conf.before (dir 700 root). Expiring the pre-change"
    echo "     snapshots (qm delsnapshot) is the second half of the fix, and it is a §0.3 change."
    echo "  2. qm rollback restores the OLD password into the live stanza, so any rollback"
    echo "     invalidates the new Vaultwarden value until the console login is re-tested."
    exit 0
fi
echo "COMPLETED WITH FAILURES — check $PRE_DIR and the snapshots."
echo "Rollback options, in order of preference:"
echo "  1. set the previous Vaultwarden-custodied value back: jol-rotate-cipassword.sh <vmid>"
echo "  2. restore the config copy: cp -p $PRE_DIR/<vmid>.conf.before /etc/pve/qemu-server/<vmid>.conf"
echo "  3. qm rollback <vmid> pre-f3-cipassword-$TS (needs the VM stopped; heavier than needed)"
exit 1
