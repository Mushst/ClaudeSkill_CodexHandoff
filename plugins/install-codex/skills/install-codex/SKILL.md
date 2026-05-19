---
name: install-codex
description: Install the OpenAI Codex CLI + bubblewrap, and use Codex as a headless agent Claude can hand low-complexity code-writing off to in order to save Claude tokens. Use when the user asks to install/set up Codex, or when a code task is mechanical enough to delegate to a cheaper model ("hand this to codex/gpt", "offload this", "save tokens").
---

# Install & Delegate to Codex

Two capabilities:

1. **Install** the OpenAI Codex CLI (`@openai/codex`) + `bubblewrap` sandbox.
2. **Delegate** suitable code-writing to Codex running headless (`codex exec`),
   so a cheaper model does the typing while Claude specs and reviews — saving
   Claude tokens.

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

- **Headless / remote container (common):** run `codex login --device-auth`
  as a **background** process (it must keep running to poll). Read its log for
  the one-time code + `https://auth.openai.com/codex/device`, give both to the
  user, wait for the background task to finish, then verify with
  `codex login status`.
- **API key:** `printenv OPENAI_API_KEY | codex login --with-api-key`.
- The no-flag `codex login` opens `localhost:1455` and will NOT work in an
  isolated remote container — always prefer `--device-auth` there.

Confirm end-to-end: `codex exec "acknowledge this message"`.

---

## Part 2 — Delegate code-writing to Codex (token-saving handoff)

### When to consider a handoff

Offer a handoff only when ALL of these hold:

- The task is **code-writing** (not analysis, design, or debugging that needs
  judgment).
- It is **mechanical / well-specified** and, in Claude's judgement, doable by a
  model **lower-tier than the currently selected Claude model** — e.g.
  boilerplate, scaffolding, repetitive edits, straightforward functions from a
  clear spec, test stubs, mechanical refactors, format/lint fixups.
- Acceptance criteria can be stated **precisely up front**.
- It is confined to the working (sandbox) directory and needs **no secrets,
  credentials, or network** beyond policy.

Do NOT delegate: ambiguous/under-specified work, security-sensitive code,
cross-cutting architecture, anything needing deep repo context or live
iteration, or tasks where reviewing the output would cost more than just doing
it.

### Always ask the user first

Never auto-delegate silently. Use `AskUserQuestion` to offer the handoff,
stating: the task in one line, why it's a good candidate, and that it saves
Claude tokens. The user opts in **per handoff** (or can say "always, stop
asking" — honor that for the rest of the session).

### Run Codex headless (self-review permission model)

Claude is the reviewer; the user already gave the go-ahead, so run Codex
autonomously but **confined to the working directory**:

```bash
codex exec \
  --cd "$PWD" \
  --sandbox workspace-write \
  "<precise, self-contained task prompt including explicit acceptance criteria>"
```

- `--sandbox workspace-write` lets it write only within the workdir; it cannot
  escape the Claude sandbox directory. (Verify available flags with
  `codex exec --help`; never use `danger-full-access`.)
- Approval is non-interactive (`never` by default) — this is the intended
  "self review" model: no human approval loop, Claude validates after.
- Give Codex everything it needs in the prompt (paths, signatures, style,
  acceptance criteria). It does not share Claude's conversation context.
- Prefer a clean-ish git state first so the handoff diff is reviewable.

### Self-review (mandatory — this is how quality is guaranteed)

After Codex returns, Claude MUST:

1. Inspect what changed: `git diff` (and `git status` for new files).
2. Check every stated acceptance criterion is met.
3. Run the relevant build / tests / linter / type-check.
4. Read the code for correctness, security, and fit with the codebase.

Then:

- **Satisfactory** → keep it; briefly report what was delegated and that it
  passed review.
- **Minor gaps** → issue one or two more focused `codex exec` prompts to fix
  specifics.
- **Unsatisfactory / not converging after ~2 iterations** → revert or take
  over directly. Don't burn the token savings chasing a bad handoff.

Always tell the user the outcome and the rough tradeoff (delegated vs. review
cost). The token win comes from Claude not generating the code — keep Claude's
spec and review tight.

---

## Notes

- Codex auth tokens live in `~/.codex/` and are wiped when an ephemeral
  container is reclaimed; re-auth is expected in fresh sessions.
- bubblewrap installs via apt-get/dnf/yum/apk/pacman; otherwise Codex uses its
  bundled copy (harmless warning).
- For *always-on* proactive handoff offers (not just when this skill is
  invoked), add a one-line rule to the user's CLAUDE.md / global memory — offer
  to do that, don't assume it.
