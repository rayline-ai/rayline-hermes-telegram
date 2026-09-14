# Rayline × Hermes — Telegram demo

A minimal, self-contained demo that runs the [Hermes Agent](https://hermes-agent.nousresearch.com)
(Nous Research) inside an isolated **`sbx` MicroVM sandbox** (Docker Sandboxes), with all of its LLM traffic
routed through the **[Rayline](https://rayline.ai) local router**, and exposes it as a
**Telegram bot** you can chat with.

```
You (Telegram)
   │  DM your bot
   ▼
Telegram Bot API ──(long-poll, outbound)──►  Hermes gateway   ┐
                                                              │  inside the
Hermes agent (provider: custom, anthropic_messages, :20809) ──┤  sbx sandbox
   │                                                          │  (isolated MicroVM)
   ▼                                                          │
Rayline rld router  :20809 injector → :20811 local router ────┘
   │  (RRL mode: the decision runs on-device, per rayline/router.json)
   ▼
https://api.rayline.ai   ──►  executes the model, returns the reply
```

**Why a sandbox + Telegram?** The MicroVM gives Hermes VM-level isolation. The sandbox
allows only **outbound** networking, so the natural way to chat with it is a messaging
platform whose gateway *dials out* — Telegram (long-polling) needs no inbound port, no
public URL, and no app manifest. Just a bot token.

**Why Rayline?** Rayline sits between the agent and the models and decides where each
request goes. This demo uses **[RRL mode](https://github.com/rayline-ai/rayline/blob/main/examples/routing-modes/README.md#modes)**: the routing decision runs on *your* machine
(the on-device static router), while the Rayline cloud executes the chosen model — so you
get local control of routing with hosted execution.

---

## What you need

| Requirement | Where | Notes |
|---|---|---|
| The **`sbx` CLI** (Docker Sandboxes) | [docker.com/products/docker-sandboxes](https://www.docker.com/products/docker-sandboxes) | Runs the agent in an isolated MicroVM; manages its own runtime. Install: **macOS** `brew install docker/tap/sbx` · **Windows** `winget install Docker.sbx`. Then run `sbx login` once (Docker sign-in). |
| A **Rayline account** | [platform.rayline.ai](https://platform.rayline.ai) | Sign up; this is what executes the models. |
| A **Rayline router key** (`rlk-…`) | [platform.rayline.ai/keys](https://platform.rayline.ai/keys) | Create one and copy it — goes in `.env` as `RAYLINE_ROUTER_API_KEY`. |
| A **Telegram bot token** | [@BotFather](https://t.me/BotFather) | `/newbot` → name → username ending in `bot` → copy the token. |
| **Git** | | Only manual dependency for the Hermes installer; the sandbox setup installs the rest. |

No OpenAI/Anthropic keys are required — Rayline provides model execution.

---

## Setup

### 1. Clone and configure credentials

```bash
git clone <this-repo> rayline-hermes-telegram
cd rayline-hermes-telegram
cp .env.sample .env
```

Edit `.env` and fill in your two secrets (kept local — `.env` is git-ignored):

```bash
RAYLINE_ROUTER_API_KEY=rlk-...      # from platform.rayline.ai/keys
TELEGRAM_BOT_TOKEN=123456:AA...     # from @BotFather
GATEWAY_ALLOW_ALL_USERS=true        # demo: bot replies to anyone who messages it
```

### 2. Sign in to sbx

Once per machine:

```bash
sbx login                 # Docker sign-in
```

### 3. Start it and chat

From the host:

```bash
./run.sh        # macOS / Linux
.\run.ps1       # Windows (PowerShell 7 — `pwsh`, not Windows PowerShell 5.1)
```

**On the first run this does the whole setup for you**: creates the sandbox (mounting this
folder — and `.env` — at the same path inside it), then installs Hermes and the Rayline `rld`
router and points Hermes at the router. Expect several minutes and a lot of installer output;
every later run skips straight to starting things and takes seconds.

Then open Telegram, find **your bot**, tap **Start**, and send a message — the reply is
generated through Rayline.

The install step is `scripts/sandbox-setup.sh`, and it is safe to re-run on its own: it skips
what is already there, and upgrades `rld` if the sandbox has an older one than the pinned
`RAYLINE_VERSION`. Set `RAYLINE_VERSION=latest` to track the channel instead of the pin.

```bash
sbx exec -it rayline-hermes-telegram bash scripts/sandbox-setup.sh
```

The run script leaves one **`sbx exec` process running on the host** (hidden on Windows,
`nohup`-ed on macOS/Linux) with the gateway in its foreground. That is deliberate: sbx
auto-stops a sandbox 30 seconds after its *last session disconnects*, so a gateway
backgrounded inside the sandbox would connect to Telegram, report success, and then go
silent half a minute later when the sandbox stopped under it. Keeping the gateway in a
foreground session means the sandbox lives exactly as long as the bot does.

To stop:

```bash
sbx stop rayline-hermes-telegram
```

---

## Telegram integration

Telegram is enabled purely by setting `TELEGRAM_BOT_TOKEN` in `.env` (the sandbox setup
also flips `platforms.telegram.enabled: true` in Hermes' config). The gateway connects in
**polling mode** — it dials out to Telegram, so nothing needs to be exposed from the sandbox.

**Create the bot** (if you haven't): message [@BotFather](https://t.me/BotFather) →
`/newbot` → give it a display name and a username ending in `bot` → copy the token.

**Access control** (in `.env`):
- `GATEWAY_ALLOW_ALL_USERS=true` — anyone who messages the bot gets a reply (simplest for a demo).
- or `TELEGRAM_ALLOWED_USERS=<id>,<id>` — restrict to specific numeric Telegram user IDs.

**Verify** it connected:

```bash
sbx exec rayline-hermes-telegram bash -c "grep -i 'telegram connected' ~/.hermes/logs/agent.log | tail -1"
# INFO gateway.run: ✓ telegram connected
```

Want a different front-end instead? Hermes' gateway also supports Discord, WhatsApp, and
more — the same "dials outbound" model applies. Telegram is just the lowest-friction.

---

## Choosing the model

The model is controlled by **`rayline/router.json`** → `routes.main.model`. This demo ships
with the virtual router model so the Rayline cloud picks per your account settings:

```jsonc
"main": {
  "endpoint": "rayline-cloud",
  "model": "rayline-router",     // ← the Rayline cloud decides the concrete model
  "router": "rayline-local"      //   (per your Main Chat Model settings on the platform)
}
```

**To pin a specific model** — e.g. GLM — set it to a real catalog id:

```jsonc
"model": "z-ai/glm-5.2",         // ← every request served by GLM 5.2
```

> Use the **model id**, not a display label: it's `z-ai/glm-5.2`, not `GLM-5.2`. List the
> ids your account serves with:
> ```bash
> curl -s https://api.rayline.ai/v1/models -H "authorization: Bearer $RAYLINE_ROUTER_API_KEY"
> ```
> (e.g. `rayline-router`, `z-ai/glm-5.2`, `gpt-5.5`, …). Then restart the router — the
> daemon reloads the config. Hermes' own model setting stays `rayline-router`; it's just a
> passthrough label, so **change the served model in `router.json`, not in Hermes' config.**

---

## How it works

- Hermes is configured with `model.provider: custom`, `model.api_mode: anthropic_messages`,
  and `model.base_url: http://127.0.0.1:20809` — i.e. a generic Anthropic-compatible endpoint
  pointed at the Rayline **injector** instead of `api.anthropic.com`. (`provider: custom` is
  used rather than `provider: anthropic` because recent Hermes only honors a `base_url`
  override on the `anthropic` provider for `*.anthropic.com` / `*.azure.com` / `*/anthropic`
  hosts — a loopback URL would be silently ignored.) `127.0.0.1` is in the sandbox's
  `NO_PROXY`, so it's a clean loopback call — no CA certs, no proxy chaining.
- The injector adds your `rlk-` router key and forwards to the **local router** (`:20811`),
  which — in **RRL** mode (`"router": "rayline-local"`) — makes the routing decision
  *on-device* per `rayline/router.json`, then forwards to `https://api.rayline.ai`.
- The Rayline cloud executes the model and returns an Anthropic-format response.

Everything runs inside the sandbox, so the router lives right next to Hermes — no host↔VM
networking involved.

---

## Files

| Path | Purpose |
|---|---|
| `.env.sample` | Template for `.env` (Rayline key, Telegram token). |
| `scripts/sandbox-setup.sh` | One-time in-sandbox install of Hermes + `rld` and config wiring. |
| `rayline/router.json` | Rayline routing config (RRL mode); set `routes.main.model` here. |
| `rayline/start-router.sh` | Launches the `rld` router inside the sandbox (idempotent). |
| `scripts/start-gateway.sh` | Runs the Hermes gateway in the sandbox foreground, so the host `sbx exec` session holds the sandbox open (see below). |
| `run.sh` | Daily start (macOS / Linux): sandbox → Rayline router → Hermes gateway. |
| `run.ps1` | Daily start (Windows): sandbox → Rayline router → Hermes gateway. |

---

## Troubleshooting

**Bot doesn't reply.** Check the router is up and Telegram connected:
```bash
sbx exec rayline-hermes-telegram bash -c "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:20809/version"   # any code = up; 000 = down
sbx exec rayline-hermes-telegram bash -c "tail -20 ~/.hermes/logs/agent.log"
```

**Router log shows `status=401 routed=cloud`.** The `rlk-` key is missing/invalid — check
`RAYLINE_ROUTER_API_KEY` in `.env` and re-source (`source ~/.bashrc`).

**Watch a request flow end-to-end:**
```bash
sbx exec rayline-hermes-telegram bash -c "tail -f logs/rld.log"
# local route endpoint:rayline-cloud requested=rayline-router ... → POST /v1/messages status=200 routed=cloud
```

---

*Not affiliated with Telegram. Hermes Agent is by Nous Research; Rayline Local is by Atlas Futures, Inc.*
