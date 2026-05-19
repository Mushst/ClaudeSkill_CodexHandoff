#!/usr/bin/env bash
# token-report.sh — measure what a Codex handoff actually cost on each side.
#
# CAVEAT (read this): Claude "tokens read" is NOT one number. A turn's input is
# fresh tokens + cache-creation + cache-read, and they bill very differently
# (cache-read ~= 0.1x fresh, cache-creation ~= 1.25x). Summing them into one
# "in" massively overstates real cost — cache-read is mostly *standing session
# context every turn pays anyway*, not the handoff's marginal cost. This tool
# therefore reports the breakdown and a cost-weighted equivalent, and supports
# a no-op baseline so you can isolate the handoff's *marginal* delta.
#
# Watermark protocol (no turn-boundary guessing):
#
#   1. Just BEFORE `codex exec`:        token-report.sh mark
#   2. (optional) take ONE no-op turn,  token-report.sh baseline
#        then run the handoff.            -> records standing per-turn context
#   3. After handoff + review:          token-report.sh report --codex-log P
#        prints, e.g.:
#          claude: 2,310 fresh / 480 cc / 91,572 cr  (~12k cost-eq;
#            marginal≈2,790)  -->  codex: 27,284 tok
#
# Claude numbers: harness session transcript on disk
#   (~/.claude/projects/<hashed-cwd>/<session>.jsonl).
# Codex numbers: the captured `codex exec` log. Read-only; reads ledgers,
# introspects no model.
#
# Options:
#   --state PATH      watermark file        (default: /tmp/codex-handoff.mark)
#   --baseline PATH   no-op baseline file   (default: /tmp/codex-handoff.base)
#   --codex-log PATH  Codex run log         (default: ./codex-run.log)
#   --session JSONL   transcript override   (default: newest for $PWD project)
#   --minus-baseline  in `report`: subtract the recorded no-op baseline to
#                     print the handoff's true marginal cost
#
# Cost weights (approx, list price ratios; override with env):
#   W_FRESH=1.0  W_CC=1.25  W_CR=0.1
set -euo pipefail

CMD="${1:-}"; [ $# -gt 0 ] && shift || true
STATE="/tmp/codex-handoff.mark"
BASEFILE="/tmp/codex-handoff.base"
CODEX_LOG="./codex-run.log"
SESSION=""
MINUS_BASE=0
W_FRESH="${W_FRESH:-1.0}"; W_CC="${W_CC:-1.25}"; W_CR="${W_CR:-0.1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --baseline) BASEFILE="$2"; shift 2 ;;
    --codex-log) CODEX_LOG="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --minus-baseline) MINUS_BASE=1; shift ;;
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

# Sum usage in $1 from line offset $2 to EOF -> "fresh cc cr out" (space-sep).
span_usage() {
  OFFSET="${2:-0}" python3 - "$1" <<'PY'
import json, os, sys
path = sys.argv[1]; offset = int(os.environ.get("OFFSET", "0"))
f = cc = cr = out = 0; seen = False
with open(path, "r", errors="replace") as fh:
    for n, raw in enumerate(fh):
        if n < offset: continue
        raw = raw.strip()
        if not raw: continue
        try: d = json.loads(raw)
        except Exception: continue
        msg = d.get("message", {}) if isinstance(d.get("message"), dict) else {}
        u = msg.get("usage") or d.get("usage")
        if not isinstance(u, dict): continue
        seen = True
        f   += u.get("input_tokens", 0) or 0
        cc  += u.get("cache_creation_input_tokens", 0) or 0
        cr  += u.get("cache_read_input_tokens", 0) or 0
        out += u.get("output_tokens", 0) or 0
print(f"{f} {cc} {cr} {out}" if seen else "NONE")
PY
}

case "$CMD" in
  mark)
    S=$(resolve_session)
    if [ -z "$S" ] || [ ! -f "$S" ]; then
      echo "token-report: no session transcript found; cannot mark" >&2; exit 1
    fi
    LINES=$(wc -l < "$S" | tr -d ' ')
    printf 'session=%s\nlines=%s\n' "$S" "$LINES" > "$STATE"
    echo "token-report: marked $S @ ${LINES} lines"
    ;;

  baseline)
    # Run AFTER `mark` and ONE no-op turn, BEFORE the handoff: captures the
    # standing per-turn context cost so `report --minus-baseline` can net it.
    [ -f "$STATE" ] || { echo "token-report: no mark; run 'mark' first" >&2; exit 1; }
    S=$(sed -n 's/^session=//p' "$STATE"); OFF=$(sed -n 's/^lines=//p' "$STATE")
    [ -n "$SESSION" ] && S="$SESSION"
    U=$(span_usage "$S" "${OFF:-0}")
    if [ "$U" = "NONE" ]; then
      echo "token-report: no flushed usage yet; take the no-op turn first" >&2; exit 1
    fi
    echo "$U" > "$BASEFILE"
    echo "token-report: baseline (fresh cc cr out) = $U"
    ;;

  report)
    if [ ! -f "$STATE" ]; then
      echo "claude: (no mark — run 'token-report.sh mark' before codex exec)  -->  codex: (skipped)"
      exit 0
    fi
    S=$(sed -n 's/^session=//p' "$STATE"); OFF=$(sed -n 's/^lines=//p' "$STATE")
    [ -n "$SESSION" ] && S="$SESSION"

    claude_str="claude: (transcript gone)"
    if [ -n "$S" ] && [ -f "$S" ]; then
      U=$(span_usage "$S" "${OFF:-0}")
      if [ "$U" = "NONE" ]; then
        claude_str="claude: (0 — no flushed usage in span yet)"
      else
        BASE="0 0 0 0"
        [ "$MINUS_BASE" = "1" ] && [ -f "$BASEFILE" ] && BASE=$(cat "$BASEFILE")
        claude_str=$(W_FRESH="$W_FRESH" W_CC="$W_CC" W_CR="$W_CR" \
          MINUS="$MINUS_BASE" python3 - "$U" "$BASE" <<'PY'
import os, sys
f, cc, cr, out = map(int, sys.argv[1].split())
bf, bcc, bcr, bout = map(int, sys.argv[2].split())
minus = os.environ.get("MINUS") == "1"
if minus:
    f, cc, cr, out = max(f-bf,0), max(cc-bcc,0), max(cr-bcr,0), max(out-bout,0)
wf, wcc, wcr = (float(os.environ[k]) for k in ("W_FRESH","W_CC","W_CR"))
eq = round(f*wf + cc*wcc + cr*wcr)
marginal = f + cc  # cache_read is standing context, billed ~10%
tag = "marginal-vs-baseline" if minus else "marginal≈fresh+cc"
print(f"claude: {f:,} fresh / {cc:,} cc / {cr:,} cr / {out:,} out  "
      f"(~{eq:,} cost-eq; {tag} {marginal:,})")
PY
)
      fi
    fi

    codex_str="codex: (no log at $CODEX_LOG)"
    if [ -f "$CODEX_LOG" ]; then
      codex_str=$(python3 - "$CODEX_LOG" <<'PY'
import json, re, sys
text = open(sys.argv[1], "r", errors="replace").read()
ci = co = ctot = 0
for line in text.splitlines():
    line = line.strip()
    if not (line.startswith("{") and '"' in line): continue
    try: d = json.loads(line)
    except Exception: continue
    u = d.get("usage") or (d.get("msg", {}) if isinstance(d.get("msg"), dict) else {}).get("usage")
    if isinstance(u, dict):
        ci = ci or u.get("input_tokens", 0) or u.get("prompt_tokens", 0) or 0
        co = co or u.get("output_tokens", 0) or u.get("completion_tokens", 0) or 0
        if u.get("total_tokens"): ctot = u["total_tokens"]
m = re.search(r"input[ =:]+([\d,]+).*?output[ =:]+([\d,]+)", text, re.I | re.S)
if m and not (ci or co):
    ci = int(m.group(1).replace(",", "")); co = int(m.group(2).replace(",", ""))
if not (ci or co or ctot):
    m = re.search(r"tokens used\s*[\r\n]+\s*([\d,]+)", text, re.I)
    if m: ctot = int(m.group(1).replace(",", ""))
print(f"codex: {ci:,}in/{co:,}out" if (ci or co)
      else (f"codex: {ctot:,} tok" if ctot else "codex: (no token total in log)"))
PY
)
    fi

    echo "$claude_str  -->  $codex_str"
    ;;

  -h|--help|help|"")
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "unknown command: $CMD (expected: mark | baseline | report)" >&2
    exit 2 ;;
esac
