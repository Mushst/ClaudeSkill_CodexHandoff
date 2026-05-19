#!/usr/bin/env bash
# token-report.sh — measure exactly what a Codex handoff cost on each side.
#
# Two calls, watermark-based (no turn-boundary guessing):
#
#   1. Right BEFORE `codex exec`:   token-report.sh mark
#        Records the current tail of Claude's session transcript.
#   2. AFTER the handoff + review:  token-report.sh report --codex-log PATH
#        Sums Claude usage from the marked tail to the new tail (= exactly the
#        delegation + review span) and parses the captured Codex log, then
#        prints one line:
#
#            claude: 1,234in/567out  -->  codex: 15,192 tok
#
# Claude numbers come from the harness's own on-disk transcript
# (~/.claude/projects/<hashed-cwd>/<session>.jsonl); Codex numbers from the
# captured `codex exec` log. Read-only; reads ledgers, introspects no model.
#
# Options:
#   --state PATH       watermark file (default: /tmp/codex-handoff.mark)
#   --codex-log PATH   Codex run log to parse   (default: ./codex-run.log)
#   --session JSONL    transcript override (default: newest for $PWD's project)
set -euo pipefail

CMD="${1:-}"; [ $# -gt 0 ] && shift || true
STATE="/tmp/codex-handoff.mark"
CODEX_LOG="./codex-run.log"
SESSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --codex-log) CODEX_LOG="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

resolve_session() {
  if [ -n "$SESSION" ]; then printf '%s' "$SESSION"; return; fi
  local h d
  h=$(printf '%s' "$PWD" | sed 's#[^a-zA-Z0-9]#-#g')
  d="$HOME/.claude/projects/$h"
  [ -d "$d" ] && ls -t "$d"/*.jsonl 2>/dev/null | head -1 || true
}

case "$CMD" in
  mark)
    S=$(resolve_session)
    if [ -z "$S" ] || [ ! -f "$S" ]; then
      echo "token-report: no session transcript found; cannot mark" >&2
      exit 1
    fi
    # Tail = current line count. The in-flight delegation turn is not yet
    # flushed, so this baseline correctly excludes it.
    LINES=$(wc -l < "$S" | tr -d ' ')
    printf 'session=%s\nlines=%s\n' "$S" "$LINES" > "$STATE"
    echo "token-report: marked $S @ ${LINES} lines"
    ;;

  report)
    if [ ! -f "$STATE" ]; then
      echo "claude: (no mark — call 'token-report.sh mark' before codex exec)  -->  codex: (skipped)"
      exit 0
    fi
    S=$(sed -n 's/^session=//p' "$STATE")
    OFFSET=$(sed -n 's/^lines=//p' "$STATE")
    [ -n "$SESSION" ] && S="$SESSION"

    claude_str="claude: (transcript gone)"
    if [ -n "$S" ] && [ -f "$S" ]; then
      claude_str=$(OFFSET="${OFFSET:-0}" python3 - "$S" <<'PY'
import json, os, sys
path = sys.argv[1]
offset = int(os.environ.get("OFFSET", "0"))
inp = out = cc = cr = 0
seen = False
with open(path, "r", errors="replace") as fh:
    for n, raw in enumerate(fh):
        if n < offset:            # only lines added since the mark
            continue
        raw = raw.strip()
        if not raw:
            continue
        try:
            d = json.loads(raw)
        except Exception:
            continue
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
    print("claude: (0 — no flushed usage in span yet)")
else:
    print(f"claude: {inp + cc + cr:,}in/{out:,}out")
PY
)
    fi

    codex_str="codex: (no log at $CODEX_LOG)"
    if [ -f "$CODEX_LOG" ]; then
      codex_str=$(python3 - "$CODEX_LOG" <<'PY'
import json, re, sys
text = open(sys.argv[1], "r", errors="replace").read()
ci = co = ctot = 0
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
m = re.search(r"input[ =:]+([\d,]+).*?output[ =:]+([\d,]+)", text, re.I | re.S)
if m and not (ci or co):
    ci = int(m.group(1).replace(",", "")); co = int(m.group(2).replace(",", ""))
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
    ;;

  -h|--help|help|"")
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "unknown command: $CMD (expected: mark | report)" >&2
    exit 2 ;;
esac
