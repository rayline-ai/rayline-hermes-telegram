#!/usr/bin/env bash
# Start the Hermes gateway (Telegram) INSIDE the sandbox, in the FOREGROUND.
#
# The foreground is the whole point. sbx auto-stops a sandbox 30 seconds after its last
# session disconnects ("auto-stop grace period expired, stopping runtime" in the sandboxd
# daemon log), so a gateway backgrounded *inside* the sandbox — `nohup hermes gateway &
# disown`, which is what this repo used to do — is killed along with the sandbox moments
# after the start script's last `sbx exec` returns. The symptom is a bot that reports
# "✓ telegram connected" and then silently stops answering half a minute later.
#
# Running the gateway in the foreground of its own `sbx exec` makes that host process a
# session holder: the sandbox stays up for exactly as long as the gateway runs, and the
# router (backgrounded inside the sandbox) stays up with it.
#
# Launch it from the host, detached *there* rather than here:
#   run.sh   nohup sbx exec <name> bash scripts/start-gateway.sh &
#   run.ps1  Start-Process sbx -ArgumentList exec,<name>,bash,scripts/start-gateway.sh

cd "$(cd "$(dirname "$0")/.." && pwd)"

# The mounted .env (Rayline key, bot token) is wired into ~/.bashrc by scripts/sandbox-setup.sh.
# Sourced before `set -e` on purpose: ~/.bashrc is not this repo's file and may well end on a
# non-zero command, which would abort the script before it ever reaches the gateway.
# shellcheck disable=SC1090
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"

set -uo pipefail

if ! command -v hermes >/dev/null 2>&1; then
  echo "ERROR: hermes not on PATH — run scripts/sandbox-setup.sh first" >&2
  exit 1
fi

# Idempotent: a second gateway would poll Telegram concurrently and both pollers would then
# trade 409 Conflict. The [h] bracket keeps the pgrep from matching its own command line.
existing="$(pgrep -f '[h]ermes gateway' | head -1 || true)"
if [ -n "$existing" ]; then
  # Hold rather than exit. This session is what keeps the sandbox alive (see above), so
  # returning here would auto-stop the sandbox 30s later and take that running gateway
  # down with it — an "already running" check that kills what it found.
  echo "hermes gateway already running (pid $existing) — holding the sandbox session open"
  while kill -0 "$existing" 2>/dev/null; do sleep 30; done
  exit 0
fi

mkdir -p logs
echo "starting hermes gateway (log=$PWD/logs/gateway.log)"

# `exec` so this PID becomes the gateway: the host's `sbx exec` session then ends exactly
# when the gateway does, rather than outliving it and pinning an idle sandbox.
exec hermes gateway >> logs/gateway.log 2>&1
