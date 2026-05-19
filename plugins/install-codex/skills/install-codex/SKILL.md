---
name: install-codex
description: Install the OpenAI Codex CLI + bubblewrap, and use Codex as a headless agent Claude can hand clearly-specified code-writing off to — spending Codex/ChatGPT credits instead of Claude budget (credit arbitrage), not because Codex is a weaker model. Use when the user asks to install/set up Codex, or when a code task has a precise input/output spec and the user wants to conserve Claude budget ("hand this to codex/gpt", "offload this", "save tokens", "use my codex credits").
---

# Install & Delegate to Codex

Two capabilities:

1. **Install** the OpenAI Codex CLI (`@openai/codex`) + `bubblewrap` sandbox.
2. **Delegate** clearly-specified code-writing to Codex running headless
   (`codex exec`): Claude specs and lightly reviews, Codex does the typing.

### Why this is worth doing (the actual rationale)

The win is **credit arbitrage, not a cheaper model.** Codex (`gpt-5.5` at high
reasoning) is a capable model — the point is *which budget pays*: offloading to
`codex exec` spends Codex/ChatGPT credit headroom instead of Claude budget. Use
it when Codex credits are the more plentiful resource.

The gate is **spec clarity, not model tier.** Codex is reliable on tasks with a
precise, defined input/output spec (functions to a contract, scaffolding,
mechanical refactors, test stubs). Trust it less for open-ended thinking,
design, or creative problem-solving — keep those on Claude. A tight spec is
also what makes Claude's later review cheap, which is where the savings hold up.

---

## Part 1 — Install

1. Run the bundled installer (idempotent — skips what's present):

   ```bash
   bash "$CLAUDE_SKILL_DIR/install-codex.sh"
   ```

   If `$CLAUDE_SKILL_DIR` is unset, run `install-codex.sh` next to this file.

2. Report `codex --version`, `bwrap --version`, and `codex login status`.

### Authentication (interactive — never silently skip the user)

`codex exec` needs auth. The installer only reports status.

**Default: device auth.** Always use `codex login --device-auth` unless the
user explicitly asks for the API-key path. Do **not** prompt for or ask about
an API key — most users authenticate with a ChatGPT subscription, and device
auth is the only flow that works in headless / remote containers.

- **Device auth (default — do this):** run `codex login --device-auth` as a
  **background** process (it must keep running to poll). Read its log for the
  one-time code + `https://auth.openai.com/codex/device`, give both to the
  user, wait for the background task to finish, then verify with
  `codex login status`.
- **API key (only if the user explicitly opts in):** if — and only if — the
  user states they want to use an API key, run
  `printenv OPENAI_API_KEY | codex login --with-api-key`. Never default here,
  never ask the user to supply a key unprompted.
- The no-flag `codex login` opens `localhost:1455` and will NOT work in an
  isolated remote container — never use it; prefer `--device-auth` always.

Confirm end-to-end: `codex exec "acknowledge this message"`.

---

## Part 2 — Delegate code-writing to Codex (credit-arbitrage handoff)

### When to consider a handoff

Offer a handoff only when ALL of these hold:

- The task is **code-writing** (not analysis, design, or debugging that needs
  judgment).
- It has a **precise, defined input/output spec** — boilerplate, scaffolding,
  repetitive edits, functions to a clear contract, test stubs, mechanical
  refactors, format/lint fixups. The gate is spec clarity, **not** "is Codex
  good enough" — it is; ambiguity is the disqualifier, not difficulty tier.
- Acceptance criteria can be stated **precisely up front**.
- It is confined to the working (sandbox) directory and needs **no secrets,
  credentials, or network** beyond policy.

Do NOT delegate: ambiguous/under-specified work, security-sensitive code,
cross-cutting architecture, anything needing deep repo context or live
iteration, or tasks where reviewing the output would cost more than just doing
it.

### Always ask the user first

Never auto-delegate silently. Use `AskUserQuestion` to offer the handoff,
stating: the task in one line, why it's a good candidate (clear spec), and that
it spends Codex/ChatGPT credits instead of Claude budget. The user opts in
**per handoff** (or can say "always, stop asking" — honor that for the rest of
the session).

### Write a handoff manifest, then run Codex headless

Before delegating, Claude writes a short **handoff manifest** to a temp file —
a terse bullet list of the exact deliverables and acceptance criteria. This one
artifact is both Codex's task prompt **and** Claude's review checklist, so the
later check is a cheap cross-reference instead of fresh analysis. Keep it
bullets, not prose.

#### Preferred execution: a Haiku orchestration subagent

The dominant Claude cost of a handoff is *standing session context re-read on
every turn*, not the spec. So when a subagent tool is available (Claude Code's
Task/Agent tool), **dispatch the mechanical run as a subagent pinned to the
cheapest model** (`model: haiku`). This stacks two wins: a cheaper model *and*
an isolated, near-empty context — the long run + log parse no longer costs
default-model tokens on a fat context.

Strict division of labor — **Haiku does plumbing, never judgment**:

- The **Haiku subagent** receives only the manifest text and a fixed recipe:
  run `token-report.sh mark`, the `codex exec` command below, then
  `token-report.sh report`; collect `git status -s`, `git diff --stat`, the
  one-line token report, and the contents of `/tmp/codex-last.md`. It must
  **not** evaluate correctness. It returns exactly this compact contract:

  ```
  TOKEN_LINE: <verbatim token-report.sh output>
  GIT_STATUS: <git status -s>
  DIFFSTAT:   <git diff --stat>
  CODEX_MSG:  <contents of /tmp/codex-last.md>
  RUN_ERROR:  <none | first error/non-zero exit observed>
  ```

- The **default (calling) model** then does the actual sanity check from that
  contract — semantic cross-check of the diff against the manifest, pulling a
  targeted `git diff <file>` only if something looks off. The verbose run log
  and full diff stay in the subagent's throwaway context; only the small
  contract crosses back.

Also prefer to **delegate early**, before parent context grows.

If no subagent tool is available (other harnesses, or it's disabled), fall
back to running the block below inline — correctness is unchanged, only the
overhead is higher.

```bash
# Watermark Claude's transcript tail BEFORE delegating (for the token report).
bash "$CLAUDE_SKILL_DIR/token-report.sh" mark

codex exec \
  --cd "$PWD" \
  --sandbox workspace-write \
  -c approval_policy="never" \
  -c model_reasoning_effort="high" \
  -o /tmp/codex-last.md \
  "$(cat /tmp/handoff-manifest.md)" \
  < /dev/null > /tmp/codex-handoff.log 2>&1
```

- `< /dev/null` is **mandatory**. `codex exec` reads stdin and concatenates it
  with the prompt, then blocks on stdin EOF. With no controlling tty
  (background task, CI, nested agent) stdin never closes and Codex hangs
  forever at 0% CPU with no output. Always redirect stdin.
- `-c approval_policy="never"` is **mandatory**. A user `~/.codex/config.toml`
  may set `approval_policy = "on-request"`, which overrides `exec`'s
  non-interactive default and silently blocks waiting for an approval that
  never comes. Force it off explicitly; don't rely on the default.
- `-c model_reasoning_effort="high"` — Codex is a capable model; high reasoning
  makes it reliable on well-specified work, which is what lets Claude's review
  stay lightweight.
- `--sandbox workspace-write` confines writes to the workdir; it cannot escape
  the Claude sandbox dir. Never use `danger-full-access`. (Check flags with
  `codex exec --help`.)
- `> /tmp/codex-handoff.log 2>&1` (note: **no `| tee`**). The full Codex log is
  verbose; piping it back through Claude's context is pure waste — it was the
  bulk of the measured handoff overhead. Redirect to a file only. The token
  reporter parses that file out-of-context for the `tokens used` total; Claude
  never reads the raw log.
- `-o /tmp/codex-last.md` writes Codex's **final message only**. For review,
  Claude reads just that file plus `git diff` — never the full run log.
- Give Codex everything in the prompt (paths, signatures, style, criteria); it
  does not share Claude's conversation context. Prefer a clean-ish git state so
  the handoff diff is reviewable.

### Self-review (sanity check — scale to complexity, stay terse)

The whole point is to save tokens, so do **not** burn them on verbose analysis
or narrating Codex's output. Codex ran at high reasoning on a precise spec —
trust but verify, proportionate to risk.

Review inputs are **only** the subagent's returned contract (`GIT_STATUS`,
`DIFFSTAT`, `CODEX_MSG`) — or, on the inline fallback, `git status -s` +
`git diff` + `/tmp/codex-last.md`. Pull a targeted `git diff <file>` only if
the contract shows something off. Never `cat` the full run log — that defeats
the purpose.

**Default (mechanical / well-specified task) — lightweight semantic check:**
read the diff against the handoff manifest and confirm only:

1. every manifest point is implemented,
2. nothing out-of-scope, weird, or unrequested was added,
3. it builds / obvious tests pass — one cheap command, if applicable.

That's it. No line-by-line audit, no diff dumps back to the user.

**Ramp up only as complexity/risk rises** (security-sensitive, cross-cutting,
non-obvious logic, large surface): add a full correctness/edge-case/codebase-fit
read and run the real test / lint / type suite.

Outcome:

- **Pass** → keep it. Report in **one line**: what was delegated + "review
  passed". Nothing more.
- **Minor gaps** → one or two focused follow-up `codex exec` prompts.
- **Not converging in ~2 iterations** → revert or take over. Don't burn the
  savings chasing a bad handoff.

The token win comes from Claude neither generating nor re-deriving the code —
keep the spec tight and the review as light as the task safely allows.

### When a handoff actually pays off (economics — read before offering)

A handoff is **not free**. Claude still pays: the manifest, the review, and —
dominant — standing session context re-read on the run turn and the report
turn. Empirically, a trivial 4-line task cost ~7k Claude marginal tokens of
pure overhead while Codex did the same work for ~27k of *its* credits.

So the trade only wins when **Codex writes substantially more than the
spec + diff Claude must read back**. Rule of thumb:

- **Good**: sizeable generation from a tight spec — many files, boilerplate at
  scale, big mechanical refactor, a full test suite. Codex output ≫ review
  surface.
- **Loses to overhead**: small/trivial edits, a few lines, anything where the
  diff Claude reads is close to what Codex wrote. Just do it directly.

Bias the `AskUserQuestion` offer accordingly: only pitch a handoff when the
generation clearly dwarfs the spec+review, and say so. Credit arbitrage still
applies, but spending 27k Codex credits to save 0 net Claude tokens is not a
win — it's just slower.

### Report the token tradeoff (immediately, in a fresh turn)

**Preferred (subagent path):** the Haiku subagent already ran
`token-report.sh report` and returned it as `TOKEN_LINE` in the contract. The
calling model just **prints `TOKEN_LINE` verbatim** — do **not** re-run the
reporter on the fat parent context (that re-incurs the very overhead this
avoids). Note this measures the cheap Haiku orchestration span by design; the
strong-model review is a separate, deliberately small cost.

**Inline fallback only:** the moment the handoff returns and review is done,
**start a new turn** and run the reporter, then print its one line verbatim:

```bash
bash "$CLAUDE_SKILL_DIR/token-report.sh" report --codex-log /tmp/codex-handoff.log
# true marginal (subtracts a no-op baseline, if you captured one):
#   token-report.sh report --codex-log /tmp/codex-handoff.log --minus-baseline
```

(If `$CLAUDE_SKILL_DIR` is unset, run `token-report.sh` next to this file.)

It diffs Claude's session transcript between the watermark set by `mark` (just
before `codex exec`) and the current tail — measuring **exactly the delegation
+ review span**, not a guessed turn boundary — parses the captured Codex log,
and prints, e.g.:

```
claude: 2,310 fresh / 480 cc / 91,572 cr / 1,240 out  (~12k cost-eq; marginal≈fresh+cc 2,790)  -->  codex: 27,284 tok
```

- **`cr` (cache-read) is not real cost.** It bills ~0.1× fresh and is mostly
  standing session context every turn pays anyway. The honest handoff cost is
  `fresh + cc` (the `marginal` figure), or the cost-eq. Do not quote the raw
  sum as "the handoff cost" — that's the overstatement this rewrite fixes.
- For a **true marginal** number, optionally: `mark` → take one no-op turn →
  `token-report.sh baseline` → run the handoff → `report --minus-baseline`.
  That subtracts the standing per-turn context so only the handoff's delta
  remains.
- Do **not** narrate or estimate token counts yourself — only this script's
  output is authoritative; a model cannot accurately introspect its own usage.
- Codex at 0.131 reports a single total, not an in/out split.

---

## Notes

- Codex auth tokens live in `~/.codex/` and are wiped when an ephemeral
  container is reclaimed; re-auth is expected in fresh sessions.
- bubblewrap installs via apt-get/dnf/yum/apk/pacman; otherwise Codex uses its
  bundled copy (harmless warning).
- For *always-on* proactive handoff offers (not just when this skill is
  invoked), add a one-line rule to the user's CLAUDE.md / global memory — offer
  to do that, don't assume it.
