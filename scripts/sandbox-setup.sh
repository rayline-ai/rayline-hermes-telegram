#!/usr/bin/env bash
# One-time setup INSIDE the sandbox: install Hermes + the Rayline rld router,
# wire the mounted .env into the shell, and point Hermes at the router.
#
# Run it interactively from the repo (so the long installs aren't torn down):
#   sbx exec -it rayline-hermes-telegram bash scripts/sandbox-setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# Pinned, not `latest`, so a demo someone runs next month installs what was tested.
# Set RAYLINE_VERSION=latest to track the channel instead.
RAYLINE_VERSION="${RAYLINE_VERSION:-0.2.6+7bd2849c99d2}"

echo "==> Repo (mounted in sandbox): $REPO"

# 1. Auto-load the mounted .env + tool paths in ~/.bashrc (idempotent).
if ! grep -q "rayline-hermes-telegram env autoload" ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc <<EOF

# rayline-hermes-telegram env autoload
set -a
[ -f "$REPO/.env" ] && source "$REPO/.env"
set +a
export PATH="\$HOME/.local/bin:\$HOME/.rayline/bin:\$PATH"
EOF
  echo "==> Wired ~/.bashrc to load $REPO/.env"
fi
set -a; [ -f "$REPO/.env" ] && source "$REPO/.env"; set +a
export PATH="$HOME/.local/bin:$HOME/.rayline/bin:$PATH"

# 2. System deps.
#
# A freshly created sandbox is still running the shell template's own apt work when this script
# first runs, so plain apt calls lose a race: "Could not get lock /var/lib/apt/lists/lock. It is
# held by process N (apt-get)". DPkg::Lock::Timeout alone does not fix this — it governs the
# dpkg lock, not the lists lock that `apt-get update` takes — so the wait has to be explicit.
apt_retry() {
  local tries=60 n=1
  until sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 "$@"; do
    if [ "$n" -ge "$tries" ]; then
      echo "ERROR: 'apt-get $*' still blocked after $((tries * 5))s — another process holds the apt lock" >&2
      return 1
    fi
    echo "    apt is locked (sandbox still provisioning) — retrying $n/$tries..."
    n=$((n + 1))
    sleep 5
  done
}

# Best-effort refresh: if the template holds the lists lock, it is because it is mid-update, so
# the lists it leaves behind are fresh enough to install from. Not worth failing setup over.
apt_update_soft() {
  sudo apt-get -o DPkg::Lock::Timeout=60 update -qq \
    || echo "    (apt lists busy — installing from the lists already present)"
}

if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "==> Installing system deps (git, curl)..."
  apt_update_soft
  apt_retry install -y -qq git curl
fi

# 2b. C++ toolchain, BEFORE the Hermes installer runs.
#
# Hermes compiles native Node modules (node-pty). With no compiler present its installer warns,
# tries `apt install build-essential` itself, and if that fails stops at an interactive prompt —
# which, run without a TTY (plain `sbx exec`, CI), reads EOF and makes the installer **exit 0
# having installed nothing**. A zero exit code and no `hermes` on PATH is a confusing place to
# start debugging, so install the compiler here and never reach that branch.
if ! command -v c++ >/dev/null 2>&1; then
  echo "==> Installing build-essential (Hermes builds node-pty from source)..."
  apt_update_soft
  apt_retry install -y -qq build-essential
fi

# 3. Install Hermes (Nous Research) if missing.
if ! command -v hermes >/dev/null 2>&1; then
  echo "==> Installing Hermes Agent..."
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o /tmp/hermes-install.sh
  bash /tmp/hermes-install.sh --skip-browser --skip-setup --non-interactive
  export PATH="$HOME/.local/bin:$PATH"
fi
hermes config migrate 2>/dev/null || true

# 4. Install (or upgrade) the Rayline rld daemon.
#
# get.rayline.ai is the official channel. The rayline-ai/rayline GitHub releases page is a
# stale mirror — its newest tag is still v0.2.0-rc.1, which predates `rld serve
# --no-local-model`, the flag rayline/start-router.sh now relies on.
#
# Version-compare rather than test for the binary: a sandbox set up before this change has a
# working older `rld` at that path, and "already installed" would leave it there forever.
if [ "$RAYLINE_VERSION" = "latest" ]; then
  RAYLINE_VERSION="$(curl -fsSL https://get.rayline.ai/cli/latest.txt | tr -d '[:space:]')"
  echo "==> Latest Rayline is $RAYLINE_VERSION"
fi
INSTALLED_RAYLINE=""
[ -x "$HOME/.rayline/bin/rld" ] && INSTALLED_RAYLINE="$("$HOME/.rayline/bin/rld" --version 2>/dev/null | awk '{print $2}')"
if [ "$INSTALLED_RAYLINE" != "$RAYLINE_VERSION" ]; then
  echo "==> Installing Rayline $RAYLINE_VERSION${INSTALLED_RAYLINE:+ (replacing $INSTALLED_RAYLINE)}..."
  curl -fsSL https://get.rayline.ai/install.sh -o /tmp/install-rayline.sh
  # bash, not sh: this installer is a bash script (the GitHub one was POSIX sh).
  # NO_PATH_UPDATE because step 1 already puts ~/.rayline/bin on PATH in ~/.bashrc, and the
  # installer would append a second, redundant export.
  RAYLINE_NO_PATH_UPDATE=1 bash /tmp/install-rayline.sh "$RAYLINE_VERSION"
else
  echo "==> Rayline $RAYLINE_VERSION already installed"
fi

# 5. Point Hermes at the Rayline injector + enable Telegram (patch Hermes' own config).
echo "==> Patching ~/.hermes/config.yaml (model -> Rayline injector, Telegram enabled)..."
"$HOME/.hermes/hermes-agent/venv/bin/python" - <<'PY'
import os, yaml
p = os.path.expanduser('~/.hermes/config.yaml')
c = yaml.safe_load(open(p)) or {}
# Route Hermes' LLM traffic through the on-device Rayline router.
# provider 'custom' + api_mode 'anthropic_messages' points Hermes at the injector as a
# generic Anthropic-compatible endpoint. (Do NOT use provider 'anthropic': recent Hermes
# only honors model.base_url there for *.anthropic.com / *.azure.com / */anthropic hosts,
# so a loopback URL is silently dropped and traffic falls back to api.anthropic.com.)
c['model'] = {'default': 'rayline-router', 'provider': 'custom',
              'base_url': 'http://127.0.0.1:20809', 'api_mode': 'anthropic_messages'}
# Enable the Telegram platform + its toolset.
c.setdefault('platforms', {})['telegram'] = {'enabled': True, 'reply_to_mode': 'first'}
c.setdefault('platform_toolsets', {}).setdefault('telegram', ['hermes-telegram'])
yaml.safe_dump(c, open(p, 'w'), sort_keys=False)
print('   patched', p)
PY

echo
echo "==> Setup complete."
echo "    hermes --version && rld --version"
echo "    Start the stack from the host with run.ps1, then DM your Telegram bot."
