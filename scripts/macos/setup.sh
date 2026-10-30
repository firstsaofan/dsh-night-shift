#!/bin/bash
# DSH Night-Shift Watchdog setup (macOS) -- DESIGN-ALIGNED, NOT TESTED ON THIS MACHINE.
#
# Install:  bash setup.sh
# Uninstall: bash setup.sh -u
# Dry run:   bash setup.sh -n
#
# Installs a LaunchAgent that runs watchdog.sh every 600 seconds.
# It does NOT register auto-start at login (RunAtLoad is false by design).
#
# Requires: bash, python3, launchctl.
# Env: DSH_HOME (default: $HOME/.dsh)
set -eu

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
ROOT="$DSH_HOME/night-shift"
CONFIG="$ROOT/config.json"
SCRIPTS="$ROOT/scripts"
RUNS="$ROOT/runs"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG_SRC="$SRC_DIR/watchdog.sh"
WATCHDOG_DST="$SCRIPTS/watchdog.sh"
PLIST="$HOME/Library/LaunchAgents/com.deepseek.nightshift.watchdog.plist"
LABEL="com.deepseek.nightshift.watchdog"

UNINSTALL=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    -u|--uninstall) UNINSTALL=1 ;;
    -n|--dry-run)   DRY=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$1"; }

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -f "$PLIST" ]; then
    [ "$DRY" -eq 1 ] && say "[dry-run] would unload and remove $PLIST" || {
      launchctl unload "$PLIST" 2>/dev/null || true
      rm -f "$PLIST"
      say "LaunchAgent removed"
    }
  else
    say "LaunchAgent not found (nothing to remove)"
  fi
  if [ -f "$CONFIG" ] && command -v python3 >/dev/null 2>&1; then
    [ "$DRY" -eq 1 ] && say "[dry-run] would set hostSetup.watchdog.installed=false" || python3 - "$CONFIG" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p, encoding='utf-8'))
cfg.setdefault('hostSetup', {}).setdefault('watchdog', {})['installed'] = False
json.dump(cfg, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
EOF
  fi
  say "uninstall done (scripts/config left on disk)"
  exit 0
fi

say "DSH home: $DSH_HOME"
for d in "$ROOT" "$SCRIPTS" "$RUNS"; do
  if [ ! -d "$d" ]; then
    [ "$DRY" -eq 1 ] && say "[dry-run] would create directory $d" || { mkdir -p "$d"; say "created $d"; }
  fi
done

[ -f "$WATCHDOG_SRC" ] || { echo "watchdog.sh not found next to setup.sh: $WATCHDOG_SRC" >&2; exit 1; }
if [ "$DRY" -eq 1 ]; then
  say "[dry-run] would copy $WATCHDOG_SRC -> $WATCHDOG_DST"
else
  cp "$WATCHDOG_SRC" "$WATCHDOG_DST"
  chmod +x "$WATCHDOG_DST"
  say "copied watchdog -> $WATCHDOG_DST"
fi

# --- config.json ---
if command -v python3 >/dev/null 2>&1; then
  if [ "$DRY" -eq 1 ]; then
    say "[dry-run] would create/update $CONFIG (hostSetup.watchdog.installed=true)"
  else
    python3 - "$CONFIG" "$ROOT/central-knowledge" <<'EOF'
import json, os, sys
from datetime import datetime
p, central = sys.argv[1], sys.argv[2]
if os.path.exists(p):
    cfg = json.load(open(p, encoding='utf-8'))
else:
    cfg = {
        "version": 1,
        "centralKnowledge": central,
        "dshExecutable": "",
        "dshProcessName": "DeepSeek Harness",
        "heartbeatSeconds": 900,
        "stallMinutes": 40,
        "staleHours": 18,
        "enableStallCheck": False,
    }
for k, v in (("dshProcessName", "DeepSeek Harness"), ("staleHours", 18),
             ("stallMinutes", 40), ("heartbeatSeconds", 900),
             ("enableStallCheck", False)):
    cfg.setdefault(k, v)
hs = cfg.setdefault("hostSetup", {})
hs.setdefault("subagentModel", {"configured": False, "note": "set manually in your user preset"})
w = hs.setdefault("watchdog", {})
w["installed"] = True
w["installedAt"] = datetime.now().strftime("%Y-%m-%d")
json.dump(cfg, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("config.json updated")
EOF
  fi
else
  say "warning: python3 not found; config.json not written"
fi

# --- LaunchAgent (StartInterval 600, no RunAtLoad) ---
PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$WATCHDOG_DST</string>
  </array>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$ROOT/watchdog.out.log</string>
  <key>StandardErrorPath</key><string>$ROOT/watchdog.err.log</string>
</dict>
</plist>
"

if [ "$DRY" -eq 1 ]; then
  say "[dry-run] would write $PLIST"
  say "[dry-run] would load it with launchctl"
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
printf '%s' "$PLIST_CONTENT" > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
say "LaunchAgent loaded (every 600s, no login auto-start)"
say ""
say "verify : launchctl list | grep nightshift"
say "uninstall: bash setup.sh -u"
