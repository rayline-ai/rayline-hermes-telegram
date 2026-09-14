# rayline-hermes-telegram — daily start script.
# Brings up Docker (if needed), then the sbx sandbox, the Rayline router, and the Hermes
# gateway (Telegram). Assumes one-time setup is done (see README.md).
#
# `sbx exec` runs in the mounted repo, so all in-sandbox paths below are relative.

$ErrorActionPreference = "Stop"

$Sandbox = "rayline-hermes-telegram"

Write-Host "=== rayline-hermes-telegram startup ===" -ForegroundColor Cyan

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

# 2. Sandbox (must already exist — see README one-time setup)
# `sbx ls` is also the auth probe: unauthenticated, it fails instead of listing, and a bare
# -notmatch would report that as "sandbox not found" — the wrong fix to go chase.
$sandboxList = (sbx ls 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: sbx is not authenticated (or its daemon can't start). Run 'sbx login' first." -ForegroundColor Red
    exit 1
}
if ($sandboxList -notmatch $Sandbox) {
    Write-Host "ERROR: Sandbox '$Sandbox' not found. Run the one-time setup in README.md first." -ForegroundColor Red
    exit 1
}
Write-Host "Starting sandbox..." -ForegroundColor Yellow
sbx policy init allow-all *> $null            # no-op if already initialized
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

# 4. Hermes gateway (Telegram), detached (see the note on step 3 for why not `sbx exec -d`)
# Idempotent like start-router.sh: a second gateway would poll Telegram concurrently and both
# pollers then trade 409 Conflict. The [h] bracket keeps the pgrep from matching its own
# command line (which contains the literal "[h]ermes gateway", not "hermes gateway").
$gwUp = (sbx exec $Sandbox bash -c "pgrep -f '[h]ermes gateway' >/dev/null && echo up || echo down") -join ""
if ($gwUp -match "up") {
    Write-Host "  Hermes gateway already running." -ForegroundColor Green
} else {
    Write-Host "Starting Hermes gateway..." -ForegroundColor Yellow
    sbx exec $Sandbox bash -c "source ~/.bashrc; nohup hermes gateway > logs/gateway.log 2>&1 </dev/null & disown"
    Start-Sleep -Seconds 12
}
$connected = sbx exec $Sandbox bash -c "grep -i 'telegram connected' ~/.hermes/logs/agent.log 2>/dev/null | tail -1" 2>$null

Write-Host ""
if ($connected) { Write-Host "=== Running — Telegram connected. DM your bot. ===" -ForegroundColor Green }
else { Write-Host "=== Gateway starting. Give it a few seconds, then DM your bot. ===" -ForegroundColor Green }
Write-Host "  Logs: repo logs/ (gateway.log, rld.log) and ~/.hermes/logs/agent.log" -ForegroundColor White
