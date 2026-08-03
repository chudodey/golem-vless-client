$ErrorActionPreference = 'SilentlyContinue'
$alive = Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue
$probe = & curl.exe --proxy http://127.0.0.1:2080 --max-time 15 -fsS https://www.gstatic.com/generate_204 -o NUL -w '%{http_code}'
if (-not $alive -or $probe -ne '204') {
  Stop-ScheduledTask -TaskName 'GolemVLESS'
  Start-ScheduledTask -TaskName 'GolemVLESS'
}
