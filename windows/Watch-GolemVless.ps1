$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$failuresPath = Join-Path $root 'state\watchdog-failures.txt'
$alive = Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue
# xray-core (B-007, xhttp/splithttp nodes) is only expected when the last
# render actually needed it — xray-config.json's presence is that signal.
# Missing-but-not-expected must not count as a failure.
$xrayExpected = Test-Path -LiteralPath (Join-Path $root 'state\xray-config.json')
$xrayAlive = -not $xrayExpected -or (Get-Process -Name 'xray' -ErrorAction SilentlyContinue)
$probe = & curl.exe --proxy http://127.0.0.1:2080 --max-time 15 -fsS https://www.gstatic.com/generate_204 -o NUL -w '%{http_code}'
if (-not $alive -or -not $xrayAlive -or $probe -ne '204') { $failures = 1 + [int](Get-Content -Raw $failuresPath -ErrorAction SilentlyContinue) } else { $failures = 0 }
$failures | Set-Content -NoNewline $failuresPath
if ($failures -ge 3) {
  Stop-ScheduledTask -TaskName 'GolemVLESS'
  Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process xray -ErrorAction SilentlyContinue | Stop-Process -Force
  # Relaunch the runner fully hidden — a console-hosted `powershell.exe
  # -WindowStyle Hidden` can still flash a window; wscript.exe + Run-Hidden.vbs
  # allocates no console at all. Start-Process so the watchdog does not block
  # waiting (Run-Hidden.vbs waits for the runner to exit).
  Start-Process -FilePath 'wscript.exe' -WindowStyle Hidden -ArgumentList @("$root\bin\Run-Hidden.vbs", "$root\bin\Run-GolemVless.ps1")
  '0' | Set-Content -NoNewline $failuresPath
}
