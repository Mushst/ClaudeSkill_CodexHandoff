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

### Check for updates (once per session, before offering a handoff)

```bash
bash "$CLAUDE_SKILL_DIR/check-update.sh"
```

If it prints a notice, surface it to the user before proceeding. Silent = current.
Network failures are swallowed; never block a handoff over a version check.

### Always ask the user first

Never auto-delegate silently. Use `AskUserQuestion` to offer the handoff,
stating: the task in one line, why it's a good candidate (clear spec), and that
it spends Codex/ChatGPT credits instead of Claude budget. The user opts in
**per handoff** (or can say "always, stop asking" — honor that for the rest of
the session).

### Run Codex headless (sequence: mark → manifest → dispatch → review → report)

The resource we value is **default-model Claude tokens**. The metric is the
default-model marginal tokens spent *because we chose to delegate*. So the
watermark and report are taken in the **parent (default model)**, around the
whole delegation — never inside a cheap subagent (that would measure the wrong
model and omit the manifest/review/dispatch costs that matter).

#### 1. Mark in the parent, the moment you decide to delegate

Run this **before writing the manifest**, in the parent/default model, right
after the user opts in — so the measured span includes the full marginal cost
of the delegation choice (manifest + dispatch + review + report):

```bash
bash "$CLAUDE_SKILL_DIR/token-report.sh" mark
```

`mark`/`report` read the transcript JSONL in a subprocess; they do **not**
pull it into model context. Running them in the parent costs the model only
the tool call — this is *not* the "fat context re-read" overhead (that earlier
conflation was a bug). Measuring the valued number correctly is the priority.

#### 2. Create the per-run dir and write the handoff manifest

Every handoff gets its **own** temp dir so a stale artifact from a previous run
can never be mistaken for the current one. In the parent, before writing the
manifest:

```bash
export RUN_DIR=$(mktemp -d /tmp/codex-handoff.XXXXXX)
```

Then write the handoff manifest to `$RUN_DIR/manifest.md` — a terse bullet list
of the exact deliverables and acceptance criteria. This one artifact is both
Codex's task prompt **and** Claude's review checklist. Keep it bullets.

Never use the legacy fixed paths (`/tmp/codex-last.md`, `/tmp/codex-handoff.log`,
`/tmp/handoff-manifest.md`). Those are the regression vector — if Codex fails
to launch or dies early, leftover files from a prior run look like a success.

#### 3. Preferred dispatch: a Haiku orchestration subagent

When a subagent tool is available (Claude Code's Task/Agent tool), **dispatch
the mechanical run as a subagent pinned to the cheapest model**
(`model: haiku`) in an isolated context, so the long run + log parse don't
cost default-model tokens on a fat context.

Strict division of labor — **Haiku does plumbing, never judgment**, and
**never runs `mark`/`report`** (those are the parent's, see steps 1 & 5):

- The **Haiku subagent** is told the value of `$RUN_DIR` and gets only the
  manifest text + a fixed recipe: run the `codex exec` command below, then
  collect `git status -s`, `git diff --stat`, the contents of
  `$RUN_DIR/last.md`, and (optional, informational only) its own cheap span via
  `token-report.sh report` against its own transcript. It returns exactly this
  compact contract:

  ```
  RUN_DIR:       <the $RUN_DIR it ran in>
  GIT_STATUS:    <git status -s>
  DIFFSTAT:      <git diff --stat>
  CODEX_MSG:     <contents of $RUN_DIR/last.md>
  RUN_ERROR:     <none | first error/non-zero exit observed | "timed out">
  SUBAGENT_SPAN: <optional: its own token-report line, Haiku-priced>
  ```

- The **default (calling) model** does the sanity check from that contract —
  semantic cross-check of the diff against the manifest, pulling a targeted
  `git diff <file>` only if something looks off. Verbose log + full diff stay
  in the subagent's throwaway context.

Prefer to **delegate early**, before parent context grows. If no subagent tool
is available, run the block below inline — correctness unchanged, overhead
higher.

**Do NOT spawn a separate "waiter" bash.** The dispatch is synchronous: the
Haiku subagent waits for `codex exec` to return, then hands back the contract.
If you want the parent to stay responsive while Codex runs, background the
`codex exec` bash itself (`run_in_background: true`) — the harness already
notifies on completion. Never launch an extra `while pgrep …; sleep …; done`
or `tail -f …` task alongside it. Those polls have no reliable termination
condition, end up orphaned when the codex process exits in a different shell
session, and pin a background slot until the user manually clicks Stop.

```bash
timeout 30m codex exec \
  --cd "$PWD" \
  --sandbox workspace-write \
  -c approval_policy="never" \
  -c model_reasoning_effort="high" \
  -o "$RUN_DIR/last.md" \
  "$(cat "$RUN_DIR/manifest.md")" \
  < /dev/null > "$RUN_DIR/codex.log" 2>&1
```

- `timeout 30m` is **mandatory**. Even with the stdin/approval guards below, an
  unforeseen hang (network stall, runaway reasoning, bad sandbox state) would
  otherwise pin a background slot indefinitely. 30 min comfortably covers real
  handoffs and turns a hang into a clean non-zero exit that `RUN_ERROR:` picks
  up. Tune up only if you have a genuinely longer task.
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
- `> "$RUN_DIR/codex.log" 2>&1` (note: **no `| tee`**). The full Codex log is
  verbose; piping it back through Claude's context is pure waste — it was the
  bulk of the measured handoff overhead. Redirect to a file only. The token
  reporter parses that file out-of-context for the `tokens used` total; Claude
  never reads the raw log.
- `-o "$RUN_DIR/last.md"` writes Codex's **final message only**. For review,
  Claude reads just that file plus `git diff` — never the full run log.
- Give Codex everything in the prompt (paths, signatures, style, criteria); it
  does not share Claude's conversation context. Prefer a clean-ish git state so
  the handoff diff is reviewable.

### 4. Self-review (sanity check — scale to complexity, stay terse)

The whole point is to save tokens, so do **not** burn them on verbose analysis
or narrating Codex's output. Codex ran at high reasoning on a precise spec —
trust but verify, proportionate to risk.

Review inputs are **only** the subagent's returned contract (`GIT_STATUS`,
`DIFFSTAT`, `CODEX_MSG`) — or, on the inline fallback, `git status -s` +
`git diff` + `$RUN_DIR/last.md`. Pull a targeted `git diff <file>` only if
the contract shows something off. Never `cat` the full run log — that defeats
the purpose.

Before trusting `CODEX_MSG`, confirm `RUN_DIR` in the contract matches the
`$RUN_DIR` the parent created and `RUN_ERROR: none`. If `RUN_ERROR` is
`timed out` or non-zero, the diff is whatever Codex managed before exiting —
treat it as a failed handoff, not a partial success.

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

### 5. Report the token tradeoff (parent, after review)

Once review is done, the **parent (default model)** runs the reporter and
prints its output verbatim — nothing else. This is mandatory and runs in the
**parent**, not the subagent: it measures the valued resource (default-model
marginal), and it's an out-of-context file read, so it costs only this call.

```bash
bash "$CLAUDE_SKILL_DIR/token-report.sh" report \
  --codex-log "$RUN_DIR/codex.log" \
  --outcome "<accepted | N-fixups | reverted>" \
  # optional, if the subagent returned its own cheap span:
  # --subagent-span "<SUBAGENT_SPAN from the contract>"

# Clean up the per-run dir immediately after report — no stale artifacts.
rm -rf "$RUN_DIR"
```

(If `$CLAUDE_SKILL_DIR` is unset, run `token-report.sh` next to this file.)

It diffs Claude's transcript from the `mark` watermark (set in step 1, before
the manifest) to now — so the span is the **full marginal cost of choosing to
delegate**: manifest + dispatch + review + report. It prints, e.g.:

```
claude  2,790 real   2,310 fresh + 480 cc   1,240 out   [+91,572 cr ctx]
codex   27,284 tok
result  accepted
```

Reading it correctly:

- **`real` (fresh+cc)** — default-model tokens that exist *only because* we
  delegated. That is the efficiency number.
- **`cr ctx`** — standing context billed ~0.1×; shown for transparency, never
  counted as cost.
- **`codex` is a separate currency.** Not a ratio — by assumption Codex credits
  are the plentiful resource; it's context, not a denominator.
- **`result` is the effectiveness half.** A small token cost with
  `result: reverted` or `3-fixups` is an *ineffective* handoff, not a cheap
  one. Always pass a truthful `--outcome`.
- We deliberately do **not** emit a counterfactual ("what Claude-only would
  have cost") — that can't be measured, only estimated, and the skill forbids
  self-estimated token counts. Worth-it judgement stays the qualitative
  economics rule above, now anchored by a real cost + a real outcome.
- Advanced/inline only: `mark` → one no-op turn → `baseline` → handoff →
  `report --minus-baseline` nets out standing context for a true marginal.
  Not used in the subagent path.
- Do **not** narrate or estimate token counts yourself — only this script's
  output is authoritative; a model cannot introspect its own usage.

---

## Notes

- Codex auth tokens live in `~/.codex/` and are wiped when an ephemeral
  container is reclaimed; re-auth is expected in fresh sessions.
- bubblewrap installs via apt-get/dnf/yum/apk/pacman; otherwise Codex uses its
  bundled copy (harmless warning).
- For *always-on* proactive handoff offers (not just when this skill is
  invoked), add a one-line rule to the user's CLAUDE.md / global memory — offer
  to do that, don't assume it.
