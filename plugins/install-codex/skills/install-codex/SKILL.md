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

```bash
# Watermark Claude's transcript tail BEFORE delegating (for the token report).
bash "$CLAUDE_SKILL_DIR/token-report.sh" mark

codex exec \
  --cd "$PWD" \
  --sandbox workspace-write \
  -c approval_policy="never" \
  -c model_reasoning_effort="high" \
  "$(cat /tmp/handoff-manifest.md)" \
  < /dev/null 2>&1 | tee /tmp/codex-handoff.log
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
- `2>&1 | tee /tmp/codex-handoff.log` keeps Codex's output visible **and**
  captures it so the token report (below) can read Codex's `tokens used` total.
- Give Codex everything in the prompt (paths, signatures, style, criteria); it
  does not share Claude's conversation context. Prefer a clean-ish git state so
  the handoff diff is reviewable.

### Self-review (sanity check — scale to complexity, stay terse)

The whole point is to save tokens, so do **not** burn them on verbose analysis
or narrating Codex's output. Codex ran at high reasoning on a precise spec —
trust but verify, proportionate to risk.

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

### Report the token tradeoff (immediately, in a fresh turn)

The moment a handoff returns and review is done, **start a new turn** and run
the bundled reporter, then print its one-line output verbatim — nothing else:

```bash
bash "$CLAUDE_SKILL_DIR/token-report.sh" report --codex-log /tmp/codex-handoff.log
```

(If `$CLAUDE_SKILL_DIR` is unset, run `token-report.sh` next to this file.)

It diffs Claude's session transcript between the watermark set by `mark` (run
just before `codex exec`) and the current tail — so it measures **exactly the
delegation + review span**, not a guessed turn boundary — then parses the
captured Codex log, and prints exactly:

```
claude: 1,234in/567out  -->  codex: 15,192 tok
```

- This is the concrete proof of the credit-arbitrage trade: a small Claude
  spend (spec + light review) bought a larger Codex spend (the typing), paid
  from Codex/ChatGPT credits.
- Do **not** narrate or estimate token counts yourself — only this script's
  output is authoritative; a model cannot accurately introspect its own usage.
- `in` for Claude is total tokens read that turn (fresh prompt + cached
  context); Codex at 0.131 reports a single total, not an in/out split.

---

## Notes

- Codex auth tokens live in `~/.codex/` and are wiped when an ephemeral
  container is reclaimed; re-auth is expected in fresh sessions.
- bubblewrap installs via apt-get/dnf/yum/apk/pacman; otherwise Codex uses its
  bundled copy (harmless warning).
- For *always-on* proactive handoff offers (not just when this skill is
  invoked), add a one-line rule to the user's CLAUDE.md / global memory — offer
  to do that, don't assume it.
