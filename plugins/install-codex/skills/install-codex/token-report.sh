#!/usr/bin/env bash
# token-report.sh — after a Codex handoff, print a one-line cost comparison:
#
#   claude: 108,236in/1,103out  -->  codex: 15,192 tok
#
# Claude numbers come from the harness's own session transcript on disk
# (~/.claude/projects/<hashed-cwd>/<session>.jsonl); Codex numbers come from
# the captured `codex exec` log. Read-only; introspects no model, just ledgers.
#
# Usage:
#   token-report.sh [--codex-log PATH] [--session JSONL] [--since-last-user]
#
#   --codex-log PATH   Codex run log to parse (default: ./codex-run.log)
#   --session  JSONL   Claude transcript (default: newest for $PWD's project)
#   --since-last-user  Sum only assistant turns after the last user message
#                      (default; this is "the delegation turn"). Pass
#                      --whole-session to sum the entire session instead.
set -euo pipefail

CODEX_LOG="./codex-run.log"
SESSION=""
SCOPE="since-last-user"

while [ $# -gt 0 ]; do
  case "$1" in
    --codex-log) CODEX_LOG="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --since-last-user) SCOPE="since-last-user"; shift ;;
    --whole-session) SCOPE="whole"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- locate the Claude session transcript ----------------------------------
if [ -z "$SESSION" ]; then
  proj_hash=$(printf '%s' "$PWD" | sed 's#[^a-zA-Z0-9]#-#g')
  proj_dir="$HOME/.claude/projects/$proj_hash"
  if [ -d "$proj_dir" ]; then
    SESSION=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1 || true)
  fi
fi

claude_str="claude: (no transcript found)"
if [ -n "${SESSION:-}" ] && [ -f "$SESSION" ]; then
  claude_str=$(SCOPE="$SCOPE" python3 - "$SESSION" <<'PY'
import json, sys, os

path = sys.argv[1]
scope = os.environ.get("SCOPE", "since-last-user")

lines = []
with open(path, "r", errors="replace") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        try:
            lines.append(json.loads(raw))
        except Exception:
            continue

# Find the index of the last user-authored message; sum assistant usage after it.
start = 0
if scope == "since-last-user":
    for i, d in enumerate(lines):
        t = d.get("type") or d.get("role")
        msg = d.get("message", {}) if isinstance(d.get("message"), dict) else {}
        role = msg.get("role") or t
        if role == "user":
            start = i

inp = out = cc = cr = 0
seen = False
for d in lines[start:]:
    msg = d.get("message", {}) if isinstance(d.get("message"), dict) else {}
    u = msg.get("usage") or d.get("usage")
    if not isinstance(u, dict):
        continue
    seen = True
    inp += u.get("input_tokens", 0) or 0
    out += u.get("output_tokens", 0) or 0
    cc  += u.get("cache_creation_input_tokens", 0) or 0
    cr  += u.get("cache_read_input_tokens", 0) or 0

if not seen:
    print("claude: (no usage records)")
else:
    # "in" = everything the model had to read this turn (fresh prompt + cached
    # context + cache writes); "out" = generated tokens.
    total_in = inp + cc + cr
    print(f"claude: {total_in:,}in/{out:,}out")
PY
)
fi

# --- parse the Codex run log ----------------------------------------------
codex_str="codex: (no log at $CODEX_LOG)"
if [ -f "$CODEX_LOG" ]; then
  codex_str=$(python3 - "$CODEX_LOG" <<'PY'
import json, re, sys

path = sys.argv[1]
text = open(path, "r", errors="replace").read()

ci = co = ctot = 0

# 1) JSONL events (codex exec --json): look for token_count / usage events.
for line in text.splitlines():
    line = line.strip()
    if not (line.startswith("{") and '"' in line):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    u = d.get("usage") or (d.get("msg", {}) if isinstance(d.get("msg"), dict) else {}).get("usage")
    if isinstance(u, dict):
        ci = ci or u.get("input_tokens", 0) or u.get("prompt_tokens", 0) or 0
        co = co or u.get("output_tokens", 0) or u.get("completion_tokens", 0) or 0
        if u.get("total_tokens"):
            ctot = u["total_tokens"]

# 2) Plain "Token usage: input=.. output=.." style, if present.
m = re.search(r"input[ =:]+([\d,]+).*?output[ =:]+([\d,]+)", text, re.I | re.S)
if m and not (ci or co):
    ci = int(m.group(1).replace(",", ""))
    co = int(m.group(2).replace(",", ""))

# 3) Fallback: the single "tokens used\n<number>" total (codex 0.131 plain log).
if not (ci or co or ctot):
    m = re.search(r"tokens used\s*[\r\n]+\s*([\d,]+)", text, re.I)
    if m:
        ctot = int(m.group(1).replace(",", ""))

if ci or co:
    print(f"codex: {ci:,}in/{co:,}out")
elif ctot:
    print(f"codex: {ctot:,} tok")
else:
    print("codex: (no token total in log)")
PY
)
fi

echo "$claude_str  -->  $codex_str"
