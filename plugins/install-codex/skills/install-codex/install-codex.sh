#!/usr/bin/env bash
# Idempotent installer for the OpenAI Codex CLI + bubblewrap sandbox.
# Safe to re-run: skips anything already installed.
set -euo pipefail

log() { printf '\033[1;34m[install-codex]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-codex] WARN:\033[0m %s\n' "$*"; }

# 1. Codex CLI (npm global)
if command -v codex >/dev/null 2>&1; then
  log "codex already installed: $(codex --version 2>/dev/null || echo unknown)"
else
  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not found on PATH; cannot install @openai/codex. Install Node.js/npm first."
    exit 1
  fi
  log "Installing @openai/codex globally via npm..."
  npm i -g @openai/codex
  log "codex installed: $(codex --version 2>/dev/null || echo unknown)"
fi

# 2. bubblewrap (sandbox backend for codex exec)
if command -v bwrap >/dev/null 2>&1; then
  log "bubblewrap already installed: $(bwrap --version 2>/dev/null || echo unknown)"
else
  log "Installing bubblewrap..."
  if command -v apt-get >/dev/null 2>&1; then
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    $SUDO apt-get update -qq && $SUDO apt-get install -y bubblewrap
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y bubblewrap
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y bubblewrap
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache bubblewrap
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm bubblewrap
  else
    warn "No supported package manager found; codex will fall back to its bundled bubblewrap."
  fi
  command -v bwrap >/dev/null 2>&1 && log "bubblewrap installed: $(bwrap --version 2>/dev/null || echo unknown)"
fi

# 3. Login status (informational only; auth is interactive)
echo
if codex login status >/dev/null 2>&1; then
  log "Auth: $(codex login status 2>&1)"
else
  warn "Not logged in. Codex CLI works but 'codex exec' needs auth."
  warn "Headless/remote: run  codex login --device-auth  (gives a one-time code to enter at https://auth.openai.com/codex/device)."
  warn "Or set OPENAI_API_KEY and use:  printenv OPENAI_API_KEY | codex login --with-api-key"
fi

log "Done."
