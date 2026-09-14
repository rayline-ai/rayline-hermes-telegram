# rayline-hermes-telegram — start script.
# Brings up Docker (if needed), then the sbx sandbox, the Rayline router, and the Hermes
# gateway (Telegram). On a fresh checkout it also creates the sandbox and runs the one-time
# install, so this is the only command needed after filling in .env.
#
# `sbx exec` runs in the mounted repo, so all in-sandbox paths below are relative.

$ErrorActionPreference = "Stop"

$Sandbox = "rayline-hermes-telegram"

# Run from the repo so host-side relative paths resolve regardless of the caller's cwd.
Set-Location $PSScriptRoot

Write-Host "=== rayline-hermes-telegram startup ===" -ForegroundColor Cyan

# 0. Credentials. .env is git-ignored, so it is always absent on a fresh checkout — catch that
# here rather than 300 lines later as "RAYLINE_ROUTER_API_KEY is not set" from the router.
if (-not (Test-Path (Join-Path $PSScriptRoot ".env"))) {
    Write-Host "ERROR: .env not found. Create it and fill in your two secrets:" -ForegroundColor Red
    Write-Host "         Copy-Item .env.sample .env" -ForegroundColor White
    Write-Host "       RAYLINE_ROUTER_API_KEY  from platform.rayline.ai/keys" -ForegroundColor White
    Write-Host "       TELEGRAM_BOT_TOKEN      from @BotFather on Telegram" -ForegroundColor White
    exit 1
}

# 1. Docker engine (sbx runs sandboxes on it)
Write-Host "Checking Docker..." -ForegroundColor Yellow
if (-not (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue)) {
    Write-Host "Starting Docker Desktop..." -ForegroundColor Yellow
    Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        docker info *> $null
        if ($LASTEXITCODE -eq 0) { break }
        Write-Host "  Waiting for Docker... ($($i*3)s)" -ForegroundColor Gray
    }
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Docker is not responding." -ForegroundColor Red; exit 1 }
Write-Host "  Docker is running." -ForegroundColor Green

# 2. Sandbox — created and provisioned on first run.
# `sbx ls` is also the auth probe: unauthenticated, it fails instead of listing, and a bare
# -notmatch would report that as "sandbox not found" — the wrong fix to go chase.
$sandboxList = (sbx ls 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: sbx is not authenticated (or its daemon can't start). Run 'sbx login' first." -ForegroundColor Red
    exit 1
}
sbx policy init allow-all *> $null            # no-op if already initialized

if ($sandboxList -notmatch $Sandbox) {
    Write-Host "First run: creating sandbox '$Sandbox'..." -ForegroundColor Yellow
    # Mounts this folder into the sandbox at the same path as on the host.
    sbx create --name $Sandbox shell $PSScriptRoot
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: 'sbx create' failed." -ForegroundColor Red; exit 1 }

    Write-Host "Installing Hermes + Rayline in the sandbox (several minutes, one time only)..." -ForegroundColor Yellow
    sbx exec $Sandbox bash scripts/sandbox-setup.sh
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: in-sandbox setup failed - see the output above." -ForegroundColor Red
        Write-Host "       It is safe to re-run this script; setup skips what is already installed." -ForegroundColor White
        exit 1
    }
    # The installer puts `hermes` on PATH via ~/.bashrc; if it is missing, the install exited
    # early (this is what a torn-down or prompt-blocked installer looks like) and the gateway
    # would fail later with a far less obvious error.
    $hermesOk = (sbx exec $Sandbox bash -c "source ~/.bashrc; command -v hermes >/dev/null && echo ok") -join ""
    if ($hermesOk -notmatch "ok") {
        Write-Host "ERROR: setup finished but 'hermes' is not installed. Re-run this script." -ForegroundColor Red
        exit 1
    }
}
Write-Host "Starting sandbox..." -ForegroundColor Yellow
sbx exec $Sandbox bash -c "echo ready" *> $null

# 3. Rayline router (RRL)
#
# Not `sbx exec -d`: despite the help text ("run command in the background"), sbx v0.34 does
# not return from a detached exec — it blocks for the life of the command, so the script would
# hang here and never reach the gateway. Background it *inside* the sandbox instead, with all
# three stdio streams detached from the exec so nothing holds the pipe open.
Write-Host "Starting Rayline router (RRL)..." -ForegroundColor Yellow
sbx exec $Sandbox bash -c "source ~/.bashrc; nohup bash rayline/start-router.sh >> logs/rld.log 2>&1 </dev/null & disown"
$routerReady = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    $code = sbx exec $Sandbox bash -c "curl -sS -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:20809/version 2>/dev/null" 2>$null
    if ($code -and $code -ne "000") { $routerReady = $true; break }
}
if ($routerReady) { Write-Host "  Rayline router listening on :20809." -ForegroundColor Green }
else { Write-Host "WARNING: router not responding on :20809 — check logs/rld.log" -ForegroundColor Yellow }

# 4. Hermes gateway (Telegram) — a host-side session holder, NOT a detached in-sandbox process.
#
# sbx auto-stops a sandbox 30s after its last session disconnects, so the gateway cannot be
# backgrounded inside the sandbox the way the router is: it would be killed moments after this
# script exits. It runs in the foreground of its own `sbx exec` instead, and that host process
# — which outlives this script — is what keeps the sandbox (and with it the router) up.
# See scripts/start-gateway.sh. Stopping is unchanged: `sbx stop` ends the session and the bot.
#
# Every -ArgumentList element is a single word on purpose. Start-Process joins them with
# spaces *without* quoting, so a compound `bash -c "source ~/.bashrc; hermes gateway"` arrives
# at bash pre-split — it reads as `source` with no filename and the gateway never starts.
$gwUp = (sbx exec $Sandbox bash -c "pgrep -f '[h]ermes gateway' >/dev/null && echo up || echo down") -join ""
if ($gwUp -match "up") {
    Write-Host "  Hermes gateway already running." -ForegroundColor Green
} else {
    Write-Host "Starting Hermes gateway..." -ForegroundColor Yellow
    Start-Process -FilePath "sbx" `
        -ArgumentList "exec", $Sandbox, "bash", "scripts/start-gateway.sh" `
        -WorkingDirectory $PSScriptRoot `
        -RedirectStandardOutput (Join-Path $PSScriptRoot "logs\gateway-holder.log") `
        -RedirectStandardError  (Join-Path $PSScriptRoot "logs\gateway-holder.err") `
        -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 15
}
$connected = sbx exec $Sandbox bash -c "grep -i 'telegram connected' ~/.hermes/logs/agent.log 2>/dev/null | tail -1" 2>$null

Write-Host ""
if ($connected) { Write-Host "=== Running — Telegram connected. DM your bot. ===" -ForegroundColor Green }
else { Write-Host "=== Gateway starting. Give it a few seconds, then DM your bot. ===" -ForegroundColor Green }
Write-Host "  Logs: repo logs/ (gateway.log, rld.log) and ~/.hermes/logs/agent.log" -ForegroundColor White
