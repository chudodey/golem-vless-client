[CmdletBinding()]
param([ValidateSet('status','start','stop','restart','logs')] [string]$Command = 'status')

$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$log = Join-Path $root 'state\sing-box.log'
switch ($Command) {
  'start'   { Enable-ScheduledTask 'GolemVLESS-Watchdog'; Start-ScheduledTask 'GolemVLESS' }
  'stop'    { Disable-ScheduledTask 'GolemVLESS-Watchdog'; Stop-ScheduledTask 'GolemVLESS' }
  'restart' { Disable-ScheduledTask 'GolemVLESS-Watchdog'; Stop-ScheduledTask 'GolemVLESS'; Enable-ScheduledTask 'GolemVLESS-Watchdog'; Start-ScheduledTask 'GolemVLESS' }
  'logs'    { Get-Content -Tail 80 -Wait $log }
  'status'  {
    Get-ScheduledTask -TaskName 'GolemVLESS','GolemVLESS-Watchdog' | Select-Object TaskName,State
    Get-Process sing-box -ErrorAction SilentlyContinue | Select-Object Id,StartTime
    $proxy = & curl.exe --proxy http://127.0.0.1:2080 --max-time 10 -fsS https://ifconfig.io/ip
    "VPN IP: $proxy"
  }
}
