$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$failuresPath = Join-Path $root 'state\watchdog-failures.txt'
$eventsPath = Join-Path $root 'state\watchdog-events.jsonl'
$countryLockPath = Join-Path $root 'state\country-lock.json'
$policyPath = Join-Path $root 'config\policy.conf'
$selectionStatePath = Join-Path $root 'state\live-selection.json'
$preflight = Join-Path $root 'bin\Test-GolemTunnelPreflight.ps1'

function Write-WatchdogEvent([hashtable]$data) {
  try {
    $data.timestamp = (Get-Date).ToString('o')
    ($data | ConvertTo-Json -Compress) | Out-File -Append -Encoding utf8 $eventsPath
  } catch {
    # A watchdog must still be able to restore connectivity when its audit log
    # is temporarily locked or unavailable.
  }
}

function Set-CountryLine([string]$value) {
  $lines = @(Get-Content -LiteralPath $policyPath)
  $found = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*countries\s*=') { $lines[$i] = 'countries = ' + $value; $found = $true; break }
  }
  if (-not $found) { throw 'countries = line not found in policy.conf' }
  [System.IO.File]::WriteAllLines($policyPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

if (Test-Path -LiteralPath $preflight) {
  & $preflight -Quiet
  if ($LASTEXITCODE -ne 0) {
    Write-WatchdogEvent @{ action = 'foreign_tunnel_detected'; healthy = $null; message = 'watchdog skipped: external VPN/TUN is active; Golem was not restarted' }
    exit 0
  }
}

# Country pin is intentionally self-expiring.  Old/manual `countries =` lines
# have no lock file and are never changed automatically — only a temporary
# session created by CountrySwitch.ps1 may be reverted by the watchdog.
if (Test-Path -LiteralPath $countryLockPath) {
  try {
    $lock = Get-Content -LiteralPath $countryLockPath -Raw | ConvertFrom-Json
    $expires = [datetimeoffset]$lock.expires_at
    if ([datetimeoffset]::Now -ge $expires) {
      Set-CountryLine ([string]$lock.previous_countries)
      Write-WatchdogEvent @{ action = 'country_filter_expired'; healthy = $true; countries = $lock.countries; message = "temporary country filter expired; restored countries = $($lock.previous_countries)" }
      Remove-Item -LiteralPath $countryLockPath -Force
      Stop-ScheduledTask -TaskName 'GolemVLESS' -ErrorAction SilentlyContinue
      Start-Process -FilePath 'wscript.exe' -WindowStyle Hidden -ArgumentList @("$root\bin\Run-Hidden.vbs", "$root\bin\Run-GolemVless.ps1")
      Write-WatchdogEvent @{ action = 'restart_requested'; healthy = $true; message = 'restart requested after country-filter expiry' }
      exit 0
    }
  } catch {
    Write-WatchdogEvent @{ action = 'country_filter_lock_error'; healthy = $true; message = $_.Exception.Message }
  }
}

$alive = Get-NetTCPConnection -LocalPort 2080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
# xray-core (B-007, xhttp/splithttp nodes) is only expected when the last
# render actually needed it — xray-config.json's presence is that signal.
# Missing-but-not-expected must not count as a failure.
$xrayExpected = Test-Path -LiteralPath (Join-Path $root 'state\xray-config.json')
$xrayAlive = -not $xrayExpected -or (Test-NetConnection -ComputerName 127.0.0.1 -Port 2081 -InformationLevel Quiet -WarningAction SilentlyContinue)
$probe = & curl.exe --proxy http://127.0.0.1:2080 --max-time 15 -fsS https://www.gstatic.com/generate_204 -o NUL -w '%{http_code}' 2>$null
$reasons = @()
if (-not $alive) { $reasons += 'sing-box process missing' }
if (-not $xrayAlive) { $reasons += 'xray process missing (required by current pool)' }
if ($probe -ne '204') { $reasons += "VPN health URL returned '$probe' instead of 204" }
if ($reasons.Count -gt 0) { $failures = 1 + [int](Get-Content -Raw $failuresPath -ErrorAction SilentlyContinue) } else { $failures = 0 }
$failures | Set-Content -NoNewline $failuresPath
Write-WatchdogEvent @{
  action = 'check'; healthy = ($reasons.Count -eq 0); failure_streak = $failures
  probe_http = "$probe"; reasons = $reasons
  sing_box_pid = if ($alive) { $alive.OwningProcess } else { $null }
  xray_expected = $xrayExpected
}

# Clash API exposes `now` for a urltest group. Record only transitions, not
# every five-minute poll, so this stays a useful connection/switch journal.
try {
  $group = Invoke-RestMethod -Uri 'http://127.0.0.1:9090/proxies/proxy' -TimeoutSec 3
  $now = [string]$group.now
  if ($now) {
    $previous = Get-Content -LiteralPath $selectionStatePath -Raw -ErrorAction SilentlyContinue
    if ($previous -ne $now) {
      Set-Content -LiteralPath $selectionStatePath -Encoding utf8 -NoNewline -Value $now
      Write-WatchdogEvent @{ action = 'node_selected'; healthy = ($reasons.Count -eq 0); selected = $now; previous = $previous; source = 'sing-box Clash API urltest' }
    }
  }
} catch {
  # A fixed/one-node proxy does not expose a `now` member. This is normal.
}
if ($failures -ge 3) {
  Write-WatchdogEvent @{ action = 'restart'; healthy = $false; failure_streak = $failures; reasons = $reasons; message = 'three consecutive failed health checks; restarting VPN processes' }
  Stop-ScheduledTask -TaskName 'GolemVLESS'
  # The Golem task is the ownership boundary. Never kill same-named engines:
  # they may belong to Durev/Happ or another VPN client.
  # Relaunch the runner fully hidden — a console-hosted `powershell.exe
  # -WindowStyle Hidden` can still flash a window; wscript.exe + Run-Hidden.vbs
  # allocates no console at all. Start-Process so the watchdog does not block
  # waiting (Run-Hidden.vbs waits for the runner to exit).
  Start-Process -FilePath 'wscript.exe' -WindowStyle Hidden -ArgumentList @("$root\bin\Run-Hidden.vbs", "$root\bin\Run-GolemVless.ps1")
  '0' | Set-Content -NoNewline $failuresPath
  Write-WatchdogEvent @{ action = 'restart_requested'; healthy = $false; failure_streak = 0; message = 'restart launcher started; next check will verify recovery' }
}
