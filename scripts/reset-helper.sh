#!/bin/bash
# reset-helper.sh — clear CoolMyMac helper registrations (needs sudo).
#
# Why this exists:
#   macOS keys a background-item registration to the code identity of the app that created it, and
#   will not re-parent it to a different identity. Because every ad-hoc rebuild produces a new code
#   identity, a registration can go stale and then either refuse to spawn (launchd: `spawn failed`,
#   `EX_CONFIG 78`) or keep an old helper instance alive that fights the current one over the fans.
#   The app cannot clear a stale registration by itself, so do it here and then relaunch the app.
#
# Usage:
#   ./scripts/reset-helper.sh
#
# Afterwards: launch CoolMyMac. It registers the helper again on first launch.

set -uo pipefail

SERVICES=(
  "com.coolmymac.app.macos13.daemon"   # current identity
  "com.coolmymac.app.daemon"           # pre-rename identity
)

echo "Clearing CoolMyMac helper registrations (sudo required)..."
for svc in "${SERVICES[@]}"; do
  if sudo launchctl print "system/$svc" >/dev/null 2>&1; then
    sudo launchctl bootout "system/$svc" 2>/dev/null \
      && echo "  cleared: $svc" \
      || echo "  could not clear: $svc"
  else
    echo "  not registered: $svc"
  fi
done

# Stop any helper that is still running from an earlier registration.
if pgrep -f "CoolMyMac-Daemon" >/dev/null 2>&1; then
  echo "Stopping leftover helper processes..."
  sudo pkill -TERM -f "CoolMyMac-Daemon" 2>/dev/null || true
  sleep 2
fi

echo
echo "Done. Remaining helper processes:"
pgrep -fl "CoolMyMac-Daemon" || echo "  (none)"
echo
echo "Next: launch CoolMyMac and let it register the helper (or use Preferences -> Helper Tool -> Install)."
