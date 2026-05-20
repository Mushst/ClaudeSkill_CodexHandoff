#!/usr/bin/env bash
# token-report.sh — measure how efficient/effective a Codex handoff was, in
# the resource we value: DEFAULT-MODEL Claude tokens.
#
# GOAL & SEMANTICS. The valued number is the default-model marginal tokens
# spent *because we chose to delegate* (manifest + dispatch + contract +
# review + this report). Therefore:
#   - Run `mark` and `report` in the PARENT (default model), NOT in a Haiku
#     subagent. A subagent measurement reports the wrong (cheap) model and
#     omits manifest/review/dispatch — the costs that matter.
#   - The script reads the transcript JSONL in a subprocess; it does NOT pull
#     the transcript into the model context. Running `report` in the parent
#     costs the model only this one call — it is not the "fat context re-read"
#     overhead; that conflation was a prior bug.
#
# CAVEAT: Claude input is fresh + cache-creation + cache-read, billed very
# differently (cr ~0.1x fresh, cc ~1.25x). The output shows fresh + cc as the
# cost-driving input; cr (standing context) is reported separately, never summed.
#
# Codex tokens are a SEPARATE, cheap currency (credit arbitrage). They are
# reported for context only — never a ratio/comparison with the Claude figure.
# Effectiveness is the --outcome tag (accepted | N-fixups | reverted), since a
# botched handoff Claude must redo is inefficient regardless of token counts.
#
# Protocol (no turn-boundary guessing), all in the PARENT:
#   1. On deciding to delegate (before writing the manifest): token-report.sh mark
#   2. ... author manifest, dispatch handoff (subagent or inline), review ...
#   3. token-report.sh report --codex-log P --outcome accepted
#        ->          input(1×)  cache-write(1.25×)  output(5×)  cache-read(0.1×)
#           claude      1,000           1,790           500          25,000
#           codex   27,284 tok
#           result  accepted
#
# Options:
#   --state PATH        watermark file       (default: /tmp/codex-handoff.mark)
#   --baseline PATH     no-op baseline file  (default: /tmp/codex-handoff.base)
#   --codex-log PATH    Codex run log        (default: ./codex-run.log)
#   --session JSONL     transcript override  (default: newest for $PWD project)
#   --minus-baseline    subtract a recorded no-op baseline (advanced/inline)
#   --outcome STR       effectiveness tag: accepted | N-fixups | reverted
#   --subagent-span STR optional: the Haiku subagent's own cheap span, shown
#                       as an informational extra line (never the headline)
#
# Cost weights (approx list-price ratios; override with env):
#   W_OUT=5.0   (output vs input price ratio; ~5× for Sonnet, varies by model)
set -euo pipefail

CMD="${1:-}"; [ $# -gt 0 ] && shift || true
STATE="/tmp/codex-handoff.mark"
BASEFILE="/tmp/codex-handoff.base"
CODEX_LOG="./codex-run.log"
SESSION=""
MINUS_BASE=0
OUTCOME=""
SUBAGENT_SPAN=""
W_FRESH="${W_FRESH:-1.0}"; W_CC="${W_CC:-1.25}"; W_CR="${W_CR:-0.1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --baseline) BASEFILE="$2"; shift 2 ;;
    --codex-log) CODEX_LOG="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --minus-baseline) MINUS_BASE=1; shift ;;
    --outcome) OUTCOME="$2"; shift 2 ;;
    --subagent-span) SUBAGENT_SPAN="$2"; shift 2 ;;
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
      echo "claude (default-model handoff-marginal): (no mark — run 'token-report.sh mark' in the PARENT before delegating)"
      echo "outcome: (skipped)"
      exit 0
    fi
    S=$(sed -n 's/^session=//p' "$STATE"); OFF=$(sed -n 's/^lines=//p' "$STATE")
    [ -n "$SESSION" ] && S="$SESSION"

    # The valued metric: default-model marginal tokens caused by delegating.
    # Run this in the PARENT (default model) after review — it is an
    # out-of-context file read, so it costs the model only this call, not a
    # re-read of the transcript. Measuring in a Haiku subagent would report
    # the wrong (cheap) model and exclude manifest+review+dispatch.
    claude_str="claude (default-model handoff-marginal): (transcript gone)"
    if [ -n "$S" ] && [ -f "$S" ]; then
      U=$(span_usage "$S" "${OFF:-0}")
      if [ "$U" = "NONE" ]; then
        claude_str="claude (default-model handoff-marginal): (0 — no flushed usage in span yet)"
      else
        BASE="0 0 0 0"
        [ "$MINUS_BASE" = "1" ] && [ -f "$BASEFILE" ] && BASE=$(cat "$BASEFILE")
        claude_str=$(MINUS="$MINUS_BASE" W_OUT="${W_OUT:-5.0}" python3 - "$U" "$BASE" <<'PY'
import os, sys
f, cc, cr, out = map(int, sys.argv[1].split())
bf, bcc, bcr, bout = map(int, sys.argv[2].split())
minus = os.environ.get("MINUS") == "1"
if minus:
    f, cc, cr, out = max(f-bf,0), max(cc-bcc,0), max(cr-bcr,0), max(out-bout,0)
src = "  [vs-baseline]" if minus else ""
w_out = float(os.environ.get("W_OUT", "5.0"))
pad = " " * 9
hdrs = ["input(1×)", "cache-write(1.25×)", f"output({w_out:g}×)", "cache-read(0.1×)"]
vals = [f, cc, out, cr]
ws   = [max(len(h), len(f"{v:,}")) + 2 for h, v in zip(hdrs, vals)]
print(pad + "".join(h.rjust(w) for h, w in zip(hdrs, ws)))
print("claude   " + "".join(f"{v:>{w},}" for v, w in zip(vals, ws)) + src)
PY
)
      fi
    fi

    # Codex: a SEPARATE currency (its own credits, cheap by assumption). Not a
    # ratio with the Claude figure — reported for context only.
    codex_str="codex (separate cheap currency): (no log at $CODEX_LOG)"
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
body = (f"{ci:,}in / {co:,}out" if (ci or co)
        else (f"{ctot:,} tok" if ctot else "(no token total in log)"))
print(f"codex   {body}")
PY
)
    fi

    echo "$claude_str"
    [ -n "$SUBAGENT_SPAN" ] && echo "haiku   $SUBAGENT_SPAN  [orchestration only]"
    echo "$codex_str"
    echo "result  ${OUTCOME:-(unspecified — pass --outcome accepted|N-fixups|reverted)}"
    ;;

  -h|--help|help|"")
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "unknown command: $CMD (expected: mark | baseline | report)" >&2
    exit 2 ;;
esac
