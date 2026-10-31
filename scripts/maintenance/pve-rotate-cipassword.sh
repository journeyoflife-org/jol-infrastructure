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
    grep -m1 '^cipassword:' "$1" 2>/dev/null | sha256sum | cut -c1-12
}

echo "F-3 credential rotation — VMIDs ${VMIDS[*]} — $(date '+%F %T %Z')"
echo "Pre-change copies + snapshots go to $PRE_DIR"

# --- capture BEFORE state, then one prompt -------------------------------------
declare -A BEFORE
for v in "${VMIDS[@]}"; do
    BEFORE[$v]="$(digest "/etc/pve/qemu-server/$v.conf")"
    cp -p "/etc/pve/qemu-server/$v.conf" "$PRE_DIR/$v.conf.before"
    echo "  vm $v: cipassword lines=$(grep -c '^cipassword:' "/etc/pve/qemu-server/$v.conf") digest-before=${BEFORE[$v]:-none}"
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
echo "$LINE"
echo "Verifying hv01-config-backup.sh still sanitises the archive (temp DEST_DIR, production untouched)…"
if command -v hv01-config-backup.sh >/dev/null 2>&1; then
    TV="/var/tmp/jol-rotate-verify-$TS"
    install -d -m 700 "$TV"
    if DEST_DIR="$TV" hv01-config-backup.sh > "$TV/run.log" 2>&1; then
        A="$(find "$TV" -maxdepth 1 -name 'pve-config-*.tar.gz' | sort | head -1)"
        echo "  archive=$(basename "${A:-none}") values-unstripped=$(tar xzOf "$A" --wildcards '*/qemu-server/*.conf' 2>/dev/null | grep -cE '^cipassword: [^<]') key-entries=$(tar tzf "$A" | grep -cE 'etc/pve/priv|\.key$|\.pem$|\.srl$')"
        echo "  (0 and 0 is the pass condition; the digests themselves are never printed)"
    else
        echo "  CONFIG-BACKUP FAILED — the refuse-to-publish gate fired or staging broke; see $TV/run.log" >&2
        tail -3 "$TV/run.log" >&2
        fail=1
    fi
else
    echo "  hv01-config-backup.sh not installed — cannot verify the archive path" >&2
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
    exit 0
fi
echo "COMPLETED WITH FAILURES — check $PRE_DIR and the snapshots."
echo "Rollback options, in order of preference:"
echo "  1. set the previous Vaultwarden-custodied value back: jol-rotate-cipassword.sh <vmid>"
echo "  2. restore the config copy: cp -p $PRE_DIR/<vmid>.conf.before /etc/pve/qemu-server/<vmid>.conf"
echo "  3. qm rollback <vmid> pre-f3-cipassword-$TS (needs the VM stopped; heavier than needed)"
exit 1
