#!/usr/bin/env bash
# rayline-hermes-telegram — start script (macOS / Linux).
# Brings up the sbx sandbox, the Rayline router, and the Hermes gateway (Telegram). On a fresh
# checkout it also creates the sandbox and runs the one-time install, so this is the only
# command needed after filling in .env.
#
# POSIX counterpart to run.ps1. `sbx exec` runs in the mounted repo, so all in-sandbox
# paths below are relative. On macOS/Linux sbx manages its own runtime (its own sandboxd),
# so — unlike the Windows script — Docker Desktop does not need to be running.

set -euo pipefail

Sandbox="rayline-hermes-telegram"

# Run from the repo so host-side relative paths (logs/) resolve regardless of caller cwd.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- colors (fall back to plain text if not a tty) -------------------------
if [ -t 1 ]; then
  Cyan=$'\033[36m'; Yellow=$'\033[33m'; Green=$'\033[32m'; Red=$'\033[31m'; White=$'\033[37m'; Reset=$'\033[0m'
else
  Cyan=""; Yellow=""; Green=""; Red=""; White=""; Reset=""
fi
say() { printf '%s%s%s\n' "$2" "$1" "$Reset"; }

say "=== rayline-hermes-telegram startup ===" "$Cyan"

# 0. Credentials. .env is git-ignored, so it is always absent on a fresh checkout — catch that
# here rather than 300 lines later as "RAYLINE_ROUTER_API_KEY is not set" from the router.
if [ ! -f .env ]; then
  say "ERROR: .env not found. Create it and fill in your two secrets:" "$Red"
  say "         cp .env.sample .env" "$White"
  say "       RAYLINE_ROUTER_API_KEY  from platform.rayline.ai/keys" "$White"
  say "       TELEGRAM_BOT_TOKEN      from @BotFather on Telegram" "$White"
  exit 1
fi

# 1. sbx present + authenticated
say "Checking Docker Sandboxes (sbx)..." "$Yellow"
if ! command -v sbx >/dev/null 2>&1; then
  say "ERROR: 'sbx' not found. Install it: brew install docker/tap/sbx  (see README.md)" "$Red"
  exit 1
fi
if ! sbx ls >/dev/null 2>&1; then
  say "ERROR: sbx is not authenticated (or its daemon can't start). Run 'sbx login' first." "$Red"
  exit 1
fi
say "  sbx is ready." "$Green"

# 2. Sandbox — created and provisioned on first run.
sbx policy init allow-all >/dev/null 2>&1 || true   # no-op if already initialized

if ! sbx ls 2>&1 | grep -q "$Sandbox"; then
  say "First run: creating sandbox '$Sandbox'..." "$Yellow"
  # Mounts this folder into the sandbox at the same path as on the host.
  if ! sbx create --name "$Sandbox" shell "$PWD"; then
    say "ERROR: 'sbx create' failed." "$Red"
    exit 1
  fi

  say "Installing Hermes + Rayline in the sandbox (several minutes, one time only)..." "$Yellow"
  if ! sbx exec "$Sandbox" bash scripts/sandbox-setup.sh; then
    say "ERROR: in-sandbox setup failed — see the output above." "$Red"
    say "       It is safe to re-run this script; setup skips what is already installed." "$White"
    exit 1
  fi
  # The installer puts `hermes` on PATH via ~/.bashrc; if it is missing, the install exited
  # early (this is what a torn-down or prompt-blocked installer looks like) and the gateway
  # would fail later with a far less obvious error.
  if ! sbx exec "$Sandbox" bash -c "source ~/.bashrc; command -v hermes >/dev/null" 2>/dev/null; then
    say "ERROR: setup finished but 'hermes' is not installed. Re-run this script." "$Red"
    exit 1
  fi
fi
say "Starting sandbox..." "$Yellow"
sbx exec "$Sandbox" bash -c "echo ready" >/dev/null 2>&1 || true   # 'exec' auto-starts a stopped sandbox

# 3. Rayline router (RRL)
#
# Not `sbx exec -d`: despite the help text ("run command in the background"), sbx v0.34 does
# not return from a detached exec — it blocks for the life of the command, so the script would
# hang here and never reach the gateway. Background it *inside* the sandbox instead, with all
# three stdio streams detached from the exec so nothing holds the pipe open.
say "Starting Rayline router (RRL)..." "$Yellow"
sbx exec "$Sandbox" bash -c "source ~/.bashrc; nohup bash rayline/start-router.sh >> logs/rld.log 2>&1 </dev/null & disown"
routerReady=false
for i in $(seq 0 14); do
  sleep 2
  code="$(sbx exec "$Sandbox" bash -c "curl -sS -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:20809/version 2>/dev/null" 2>/dev/null || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then routerReady=true; break; fi
done
if [ "$routerReady" = true ]; then
  say "  Rayline router listening on :20809." "$Green"
else
  say "WARNING: router not responding on :20809 — check logs/rld.log" "$Yellow"
fi

# 4. Hermes gateway (Telegram) — a host-side session holder, NOT a detached in-sandbox process.
#
# sbx auto-stops a sandbox 30s after its last session disconnects, so the gateway cannot be
# backgrounded inside the sandbox the way the router is: it would be killed moments after this
# script exits. It runs in the foreground of its own `sbx exec` instead, and that host process
# — detached here with nohup, so it outlives this script — is what keeps the sandbox (and with
# it the router) up. See scripts/start-gateway.sh. `sbx stop` still stops everything.
if sbx exec "$Sandbox" bash -c "pgrep -f '[h]ermes gateway' >/dev/null" 2>/dev/null; then
  say "  Hermes gateway already running." "$Green"
else
  say "Starting Hermes gateway..." "$Yellow"
  nohup sbx exec "$Sandbox" bash scripts/start-gateway.sh \
    > logs/gateway-holder.log 2>&1 < /dev/null &
  sleep 15
fi
connected="$(sbx exec "$Sandbox" bash -c "grep -i 'telegram connected' ~/.hermes/logs/agent.log 2>/dev/null | tail -1" 2>/dev/null || true)"

echo ""
if [ -n "$connected" ]; then
  say "=== Running — Telegram connected. DM your bot. ===" "$Green"
else
  say "=== Gateway starting. Give it a few seconds, then DM your bot. ===" "$Green"
fi
say "  Logs: repo logs/ (gateway.log, rld.log) and ~/.hermes/logs/agent.log" "$White"
say "  Stop with: sbx stop $Sandbox" "$White"
