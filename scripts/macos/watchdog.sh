#!/bin/bash
# DSH Night-Shift Watchdog (macOS) -- DESIGN-ALIGNED, NOT TESTED ON THIS MACHINE.
#
# Same contract as scripts/windows/watchdog.ps1:
#   - exit if config.json is missing (not installed)
#   - single-instance lock
#   - prune stale run entries (startedAt older than staleHours, default 18h)
#   - no active run -> exit, never touch DSH
#   - active run + DSH not running -> open it
#   - optional stall check (enableStallCheck=true): newest session log older than
#     stallMinutes -> kill + restart
#
# Requires: bash, pgrep, python3 (for JSON parsing).
# Env: DSH_HOME (default: $HOME/.dsh)
set -u

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
ROOT="$DSH_HOME/night-shift"
CONFIG="$ROOT/config.json"
RUNS="$ROOT/runs"
LOG="$ROOT/watchdog.log"
LOCK="$ROOT/watchdog.lock"
PROC_NAME="DeepSeek Harness"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null || true; }

[ -f "$CONFIG" ] || exit 0

# --- single-instance lock (mkdir is atomic on POSIX) ---
if [ -d "$LOCK" ]; then
  # remove stale lock older than 15 minutes
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null || true
    log "stale watchdog.lock removed"
  else
    exit 0
  fi
fi
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

PY=python3
command -v "$PY" >/dev/null 2>&1 || { log "python3 not found; watchdog cannot read config"; exit 1; }

# --- read config ---
read_cfg() { "$PY" - "$CONFIG" "$1" <<'EOF'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(path, encoding='utf-8'))
except Exception:
    print(''); raise SystemExit(0)
val = cfg
for part in key.split('.'):
    if isinstance(val, dict):
        val = val.get(part)
    else:
        val = None
        break
print('' if val is None else val)
EOF
}

STALE_HOURS=$(read_cfg staleHours); STALE_HOURS=${STALE_HOURS:-18}
STALL_MIN=$(read_cfg stallMinutes); STALL_MIN=${STALL_MIN:-40}
DSH_EXE=$(read_cfg dshExecutable)
STALL_CHECK=$(read_cfg enableStallCheck)

# --- prune stale runs, count active ---
ACTIVE=0
if [ -d "$RUNS" ]; then
  for f in "$RUNS"/*.json; do
    [ -f "$f" ] || continue
    RESULT=$("$PY" - "$f" "$STALE_HOURS" <<'EOF'
import json, sys
from datetime import datetime, timezone
path, stale_h = sys.argv[1], float(sys.argv[2])
try:
    run = json.load(open(path, encoding='utf-8'))
    started = datetime.fromisoformat(run['startedAt'])
    now = datetime.now(started.tzinfo or timezone.utc)
    print('stale' if (now - started).total_seconds() / 3600.0 > stale_h else 'active')
except Exception:
    print('invalid')
EOF
)
    case "$RESULT" in
      active) ACTIVE=$((ACTIVE + 1)) ;;
      stale)  rm -f "$f"; log "stale run pruned: $(basename "$f")" ;;
      *)      rm -f "$f"; log "invalid run file removed: $(basename "$f")" ;;
    esac
  done
fi

[ "$ACTIVE" -gt 0 ] || exit 0

# --- DSH running? ---
if ! pgrep -f "$PROC_NAME" >/dev/null 2>&1; then
  if [ -n "$DSH_EXE" ] && [ -e "$DSH_EXE" ]; then
    log "DSH not running ($ACTIVE active run(s)) -> starting $DSH_EXE"
    open "$DSH_EXE" >/dev/null 2>&1 || true
  else
    log "DSH not running ($ACTIVE active run(s)) -> starting app bundle 'DeepSeek Harness'"
    open -a "$PROC_NAME" >/dev/null 2>&1 || true
  fi
  exit 0
fi

# --- optional stall check (engine-written signal only) ---
if [ "$STALL_CHECK" = "True" ] || [ "$STALL_CHECK" = "true" ]; then
  LATEST=$(find "$DSH_HOME/sessions" -name 'session.jsonl.zstd' -type f -print0 2>/dev/null \
           | xargs -0 stat -f '%m %N' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f1)
  if [ -n "$LATEST" ]; then
    NOW=$(date +%s)
    IDLE_MIN=$(( (NOW - LATEST) / 60 ))
    if [ "$IDLE_MIN" -gt "$STALL_MIN" ]; then
      log "stalled: no session write for ${IDLE_MIN} min (limit ${STALL_MIN}) -> restarting DSH"
      pkill -f "$PROC_NAME" 2>/dev/null || true
      sleep 3
      if [ -n "$DSH_EXE" ] && [ -e "$DSH_EXE" ]; then
        open "$DSH_EXE" >/dev/null 2>&1 || true
      else
        open -a "$PROC_NAME" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi

exit 0
