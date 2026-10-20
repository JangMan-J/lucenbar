#!/bin/bash
# usage: cbcheck.sh <FirstPageName> <waitSeconds> <out.png>
set -e
PAGE="${1:-General}"; WAIT="${2:-12}"; OUT="${3:-/tmp/win.png}"
CFG=~/.local/share/plasma/plasmoids/io.github.jangmanj.lucenbarlite/contents/config/config.qml
systemctl --user restart plasma-plasmashell.service; sleep 9
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$(cat "$(dirname "$0")/movepanel.js")" >/dev/null; sleep 1
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$(cat "$(dirname "$0")/opencfg.js")" >/dev/null; sleep 1.5
W=$(kdotool search --name "CodexBar Settings" | head -1)
kdotool windowmove "$W" 0 60; kdotool windowsize "$W" 2000 1050
sleep "$WAIT"
python3 "$(dirname "$0")/capwin.py" "$W" "$OUT"
