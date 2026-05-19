# ClaudeSkill_CodexHandoff

A personal [Claude Code](https://code.claude.com) plugin marketplace
(`claude-skill-codex-handoff`).

## Plugins

### `install-codex`

Installs the OpenAI Codex CLI (`@openai/codex`) and the `bubblewrap` sandbox
backend, and exposes an `/install-codex` skill usable in any session/directory.

The skill also defines a **credit-arbitrage delegation workflow**: when a
code-writing task has a precise input/output spec, Claude asks the user, hands
it to Codex running headless (`codex exec`, write-confined to the working
directory), then does a light review. The point is *which budget pays* —
offloading spends your Codex/ChatGPT credits instead of Claude budget — not
that Codex is a weaker model (it runs `gpt-5.5` at high reasoning).

## Prerequisites

- **A Codex / ChatGPT subscription** (or an OpenAI API key). `codex exec` will
  not run without an authenticated account — there is no free tier.
- **First-run authentication is interactive and needs a browser.** The first
  time you use the delegation workflow, Codex must be logged in: it runs
  `codex login --device-auth`, which prints a one-time code and a
  `https://auth.openai.com/codex/device` URL you open in a browser to approve.
  This is a one-time step per machine/container (tokens live in `~/.codex/`);
  ephemeral web containers re-auth on each fresh start. Installing the CLI
  itself does not require this — only the headless delegation does.

## Setup

This repo is the marketplace root — it lives at the public repo
`github.com/Mushst/ClaudeSkill_CodexHandoff`. Use the commands below.

### Use locally (any machine)

```bash
claude plugin marketplace add Mushst/ClaudeSkill_CodexHandoff
claude plugin install install-codex@claude-skill-codex-handoff
```

Then `/install-codex` is available in every session on that machine.

### Persist in Claude Code on the web (fresh containers)

Add these two idempotent lines to your **environment setup script**
(configured in the web UI — see
https://code.claude.com/docs/en/claude-code-on-the-web):

```bash
claude plugin marketplace add Mushst/ClaudeSkill_CodexHandoff
claude plugin install install-codex@claude-skill-codex-handoff
```

These re-enable the plugin on every fresh container, across any repo.
