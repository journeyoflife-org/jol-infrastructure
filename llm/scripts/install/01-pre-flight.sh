#!/usr/bin/env bash
# 01-pre-flight.sh — hardware gates before bootstrapping llm-prod-lt01.
# Idempotent: read-only checks only. Exit 0 = go, 1 = blocked, 2 = warnings.
set -Eeuo pipefail

MIN_RAM_GIB=90
MIN_CORES=16
FAIL=0
WARN=0

log()  { printf '[pre-flight] %s\n' "$*"; }
ok()   { log "OK   — $*"; }
warn() { log "WARN — $*"; WARN=1; }
fail() { log "FAIL — $*"; FAIL=1; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

log "host: $(hostname)  kernel: $(uname -r)"

# --- RAM ---
ram_gib=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
if (( ram_gib >= MIN_RAM_GIB )); then
  ok "RAM ${ram_gib} GiB (>= ${MIN_RAM_GIB})"
else
  fail "RAM ${ram_gib} GiB < ${MIN_RAM_GIB} — Qwen3-32B Q8_0 will not fit"
fi

# --- CPU ---
cores=$(nproc)
if (( cores >= MIN_CORES )); then
  ok "CPU threads: ${cores}"
else
  fail "only ${cores} threads (< ${MIN_CORES})"
fi
if ! grep -qw avx2 /proc/cpuinfo; then
  fail "CPU lacks AVX2 — GGML CPU inference will be unacceptably slow"
else
  ok "AVX2 present"
fi

# --- NVMe health ---
nvme_dev=$(lsblk -dnpo NAME,TYPE,SIZE | awk '$2=="disk" && $3 ~ /[0-9]G/ {print $1; exit}')
if command -v smartctl >/dev/null && [[ -n ${nvme_dev} ]]; then
  if smartctl -H "${nvme_dev}" | grep -q "PASSED"; then
    ok "SMART overall: PASSED (${nvme_dev})"
  else
    fail "SMART check failed for ${nvme_dev}"
  fi
  realloc=$(smartctl -A "${nvme_dev}" 2>/dev/null \
    | awk '/Reallocated_Sector_Ct/ {print $10}')
  if [[ -n ${realloc} && ${realloc} -gt 0 ]]; then
    warn "reallocated sectors: ${realloc}"
  fi
else
  warn "smartctl unavailable — install smartmontools and re-run"
fi

# --- Temperatures ---
if command -v sensors >/dev/null; then
  max_temp=$(sensors 2>/dev/null | grep -oP '\+\K[0-9]+(?=\.[0-9]+°C)' | sort -n | tail -1)
  if [[ -n ${max_temp} ]]; then
    if (( max_temp < 60 )); then
      ok "idle max temp: ${max_temp} °C"
    else
      warn "idle temp ${max_temp} °C — check cooling before load"
    fi
  fi
else
  warn "lm-sensors not installed — skipping thermal check"
fi

# --- Disk space for models ---
opt_free_gib=$(df -BG --output=avail /opt 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n ${opt_free_gib} && ${opt_free_gib} -ge 120 ]]; then
  ok "/opt free: ${opt_free_gib} GiB"
else
  fail "/opt free ${opt_free_gib:-0} GiB < 120 GiB (model store requirement)"
fi

# --- GPU awareness (Polaris debt) ---
if lspci 2>/dev/null | grep -qi 'vga.*radeon\|display.*radeon'; then
  warn "AMD Polaris GPU detected — must remain unused for inference (roadmap doc)"
fi

echo
if (( FAIL )); then
  log "RESULT: BLOCKED — fix FAIL items before 02-bootstrap.sh"
  exit 1
elif (( WARN )); then
  log "RESULT: PASS WITH WARNINGS — review before go-live"
  exit 2
else
  log "RESULT: PASS"
fi
