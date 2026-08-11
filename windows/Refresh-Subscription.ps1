[CmdletBinding()]
param(
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$root  = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$state = Join-Path $root 'state'
$configDir = Join-Path $root 'config'
$endpoints = Join-Path $configDir 'endpoints.txt'
$runner = Join-Path $root 'bin\Run-GolemVless.ps1'
$lockState = Join-Path $state 'subscription.sha256'
$logPath = Join-Path $state 'subscription-refresh.log'

function Write-RefreshLog([string]$msg) {
  "$(Get-Date -Format o) $msg" | Out-File -Append -Encoding utf8 $logPath
  Write-Host "  [..] $msg"
}

if (-not (Test-Path -LiteralPath $endpoints)) {
  Write-RefreshLog "не найден endpoints.txt: $endpoints — пропуск"
  exit 1
}

# ── 1. Fetch fresh subscription → cache file used by render_config.py ────────
# re-use the same cache so the *renderer* and the *refresher* agree on "what
# the provider currently serves". renderer wrote it on the last successful
# --fetch; here we try to refresh it now (and fall back silently if down).
$cache = Join-Path $state 'last-subscription.txt'
$subUrl = Get-Content $endpoints | Where-Object { $_ -match '^https?://' } | Select-Object -First 1
if (-not $subUrl) {
  Write-RefreshLog "в endpoints.txt нет http(s) строки подписки — пропуск"
  exit 1
}

$ErrorActionPreference = 'Continue'
try {
  $resp = Invoke-WebRequest -UseBasicParsing -Uri $subUrl -TimeoutSec 30
  $body = $resp.Content
  if ($body) {
    $decoded = ''
    # body is one base64 line, or (rarely) plain vless:// lines
    if ($body -match '^[A-Za-z0-9+/=]+$') {
      $b = $body.Trim(); $b = $b.Replace('-', '+').Replace('_', '/')
      $b = $b + ("=" * ((4 - ($b.Length % 4)) % 4))
      $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))
    } else {
      $decoded = $body
    }
    $uris = ($decoded -split "`n" | Where-Object { $_ -match '^vless://' } | ForEach-Object { $_.Trim() })
    if ($uris.Count -ge 5) {
      # Sort so hash is stable even when the provider shuffles the order.
      Set-Content -Encoding utf8 -Path $cache -Value (($uris | Sort-Object) -join "`n")
      Write-RefreshLog "подписка обновлена: $($uris.Count) нод"
    } else {
      Write-RefreshLog "в ответе подписки мало vless-строк ($($uris.Count)) — оставляю кэш"
    }
  }
} catch {
  Write-RefreshLog "не удалось обновить подписку: $($_.Exception.Message) — использую кэш"
}

# ── 2. Hash current state vs pool config → restart only when changed ─────────
$now = Get-Content $cache -Raw -ErrorAction SilentlyContinue
if (-not $now) { Write-RefreshLog "кэша подписки нет ($cache) — пропуск"; exit 1 }
$hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($now))) -Algorithm SHA256).Hash
$old = Get-Content $lockState -Raw -ErrorAction SilentlyContinue

if (-not $Force -and $old -eq $hash) {
  Write-RefreshLog "подписка не изменилась (sha256 $($hash.Substring(0,12))...) — рестарт не нужен"
  exit 0
}

# Changed (or -Force): restart the client so it re-renders with fresh nodes.
$oldShort = if ($old) { $old.Substring(0, [Math]::Min(12, $old.Length)) } else { '(нет)' }
Write-RefreshLog "подписка ИЗМЕНИЛАСЬ ($oldShort -> $($hash.Substring(0,12))..) — перезапускаю клиент"
Set-Content -Encoding ascii -Path $lockState -Value $hash

# Same teardown as GolemVpn.ps1 stop, then relaunch the runner (needs admin).
Disable-ScheduledTask 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
Stop-ScheduledTask    'GolemVLESS'           -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process xray     -ErrorAction SilentlyContinue | Stop-Process -Force

Start-Sleep -Seconds 3
# Relaunch the runner fully hidden (wscript + Run-Hidden.vbs, no console window).
$hidden = Join-Path (Split-Path $runner) 'Run-Hidden.vbs'
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process -FilePath 'wscript.exe' -Verb RunAs -WindowStyle Hidden `
    -WorkingDirectory $env:SystemRoot `
    -ArgumentList @($hidden, $runner)
  Write-RefreshLog "клиент перезапускается (UAC)"
} else {
  Start-Process -FilePath 'wscript.exe' -WindowStyle Hidden -WorkingDirectory $env:SystemRoot `
    -ArgumentList @($hidden, $runner)
  Write-RefreshLog "клиент перезапускается"
}
Enable-ScheduledTask 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
exit 0