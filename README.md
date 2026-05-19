# ClaudeSkill_CodexHandoff

A personal [Claude Code](https://code.claude.com) plugin marketplace
(`claude-skill-codex-handoff`).

## Plugins

### `install-codex`

Installs the OpenAI Codex CLI (`@openai/codex`) and the `bubblewrap` sandbox
backend, and exposes an `/install-codex` skill usable in any session/directory.

The skill also defines a **token-saving delegation workflow**: when a
code-writing task is mechanical enough for a model lower-tier than the active
Claude model, Claude asks the user, hands the task to Codex running headless
(`codex exec`, write-confined to the working directory), then reviews the
result itself. Claude specs and verifies; a cheaper model does the typing.

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
