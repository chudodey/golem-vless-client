$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$failuresPath = Join-Path $root 'state\watchdog-failures.txt'
$alive = Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue
$probe = & curl.exe --proxy http://127.0.0.1:2080 --max-time 15 -fsS https://www.gstatic.com/generate_204 -o NUL -w '%{http_code}'
if (-not $alive -or $probe -ne '204') { $failures = 1 + [int](Get-Content -Raw $failuresPath -ErrorAction SilentlyContinue) } else { $failures = 0 }
$failures | Set-Content -NoNewline $failuresPath
if ($failures -ge 3) {
  Stop-ScheduledTask -TaskName 'GolemVLESS'
  Start-ScheduledTask -TaskName 'GolemVLESS'
  '0' | Set-Content -NoNewline $failuresPath
}
