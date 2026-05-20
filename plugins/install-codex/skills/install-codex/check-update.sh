#!/usr/bin/env bash
# check-update.sh — compare installed plugin version against GitHub main.
# Exits 0 always; prints a one-line notice if an update is available, nothing if current.
# Usage: bash "$CLAUDE_SKILL_DIR/check-update.sh"
set -euo pipefail

SKILL_DIR="${CLAUDE_SKILL_DIR:-$(dirname "$0")}"
PLUGIN_JSON="$SKILL_DIR/../../.claude-plugin/plugin.json"
REMOTE_URL="https://raw.githubusercontent.com/Mushst/ClaudeSkill_CodexHandoff/main/plugins/install-codex/.claude-plugin/plugin.json"

installed=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" \
  "$(cd "$SKILL_DIR/../.." && pwd)/.claude-plugin/plugin.json" 2>/dev/null || echo "unknown")

remote=$(curl -sf --max-time 5 "$REMOTE_URL" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "")

if [ -z "$remote" ]; then
  : # network unavailable — silent, don't block the handoff
elif [ "$installed" = "$remote" ]; then
  : # up to date — silent
else
  echo "install-codex update available: $installed → $remote  (git pull in the plugin dir to update)"
fi
