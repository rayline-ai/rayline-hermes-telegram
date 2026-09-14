#!/usr/bin/env bash
# Start the Rayline rld router (RRL mode) INSIDE the sandbox.
#
# RRL = the on-device static router (LSR) decides the route on your machine and forwards
# it to the Rayline cloud, which executes the model. Hermes talks to the injector at
# http://127.0.0.1:20809 as an Anthropic-compatible endpoint (Hermes is configured with
# provider=custom, api_mode=anthropic_messages, base_url=http://127.0.0.1:20809).
#
# Reads RAYLINE_ROUTER_API_KEY (rlk- key) from the environment (loaded from the mounted
# .env via ~/.bashrc). `rld serve` runs in the FOREGROUND, so launch it detached:
#   sbx exec -d <name> bash -c "source ~/.bashrc && bash <repo>/rayline/start-router.sh"
# Idempotent: exits early if the injector port is already serving.
set -euo pipefail

export PATH="$HOME/.rayline/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="${RAYLINE_CONFIG:-$SCRIPT_DIR/router.json}"
LOG="${RAYLINE_LOG:-$REPO/logs/rld.log}"
INJECTOR_PORT="${RAYLINE_INJECTOR_PORT:-20809}"

: "${RAYLINE_ROUTER_API_KEY:?RAYLINE_ROUTER_API_KEY is not set — source the mounted .env first}"

if [ ! -x "$HOME/.rayline/bin/rld" ]; then
  echo "ERROR: rld not installed at ~/.rayline/bin/rld — run scripts/sandbox-setup.sh first" >&2
  exit 1
fi

# --no-local-model arrived in 0.2.6. A sandbox created before that has a working older rld,
# which would reject the flag and exit — an unknown-argument error is not an obvious "re-run
# setup", so say it here.
if ! rld serve --help 2>&1 | grep -q -- '--no-local-model'; then
  echo "ERROR: rld $(rld --version 2>/dev/null | awk '{print $2}') is too old — it has no" >&2
  echo "       --no-local-model. Re-run: sbx exec -it <sandbox> bash scripts/sandbox-setup.sh" >&2
  exit 1
fi

# Already up? Any HTTP response on the injector port means it is listening.
if curl -sS -m 3 -o /dev/null "http://127.0.0.1:${INJECTOR_PORT}/version" 2>/dev/null; then
  echo "rld router already running on :${INJECTOR_PORT}"
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
echo "starting rld router on :${INJECTOR_PORT} (config=$CONFIG, log=$LOG)"

# RRL routes every class to the Rayline cloud, so the bundled-llama / adapter path is never
# exercised. --no-local-model is what says that: serve the router only, download no GGUF,
# advertise local availability as unavailable. (Before 0.2.6 `rld serve` demanded a model
# source, and this script satisfied it with `--upstream-url http://127.0.0.1:1 --upstream-model
# dummy` — an adapter aimed at a dead port. That workaround is gone. The adapter still binds
# :20808 either way; what changes is that nothing claims a local model is reachable there.)
# `exec` so this PID becomes rld and a detached `sbx exec -d` keeps it alive.
exec rld serve \
  --decision-plane local \
  --router-config-path "$CONFIG" \
  --no-local-model \
  >> "$LOG" 2>&1
