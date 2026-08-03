[CmdletBinding()]
param([ValidateSet('status','start','stop','restart','logs','diagnose')] [string]$Command = 'status')

$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$state = Join-Path $root 'state'
function Stop-GolemProcess {
  Disable-ScheduledTask 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
  Stop-ScheduledTask 'GolemVLESS' -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
}
function Start-GolemProcess {
  if (Get-Process sing-box -ErrorAction SilentlyContinue) { return }
  $runner = Join-Path $root 'bin\Run-GolemVless.ps1'
  Start-Process -FilePath 'PowerShell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', $runner)
  Start-Sleep -Seconds 3
  if (-not (Get-Process sing-box -ErrorAction SilentlyContinue)) { throw 'sing-box не запустился; выполните команду logs.' }
}
function Get-LatestLog {
  Get-ChildItem -LiteralPath $state -Filter 'sing-box-*.err.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
switch ($Command) {
  'start'   { Enable-ScheduledTask 'GolemVLESS-Watchdog'; Start-GolemProcess }
  'stop'    { Stop-GolemProcess }
  'restart' { Stop-GolemProcess; Enable-ScheduledTask 'GolemVLESS-Watchdog'; Start-GolemProcess }
  'logs'    { $log = Get-LatestLog; if ($log) { Get-Content -Tail 80 $log.FullName; $out = $log.FullName -replace '\.err\.log$','.out.log'; if (Test-Path $out) { Get-Content -Tail 80 $out } } else { 'Логов пока нет.' } }
  'status'  {
    Get-ScheduledTask -TaskName 'GolemVLESS','GolemVLESS-Watchdog' | Select-Object TaskName,State
    Get-ScheduledTaskInfo -TaskName 'GolemVLESS' | Select-Object LastRunTime,LastTaskResult
    Get-Process sing-box -ErrorAction SilentlyContinue | Select-Object Id,StartTime
    $proxy = & curl.exe --proxy http://127.0.0.1:2080 --max-time 10 -fsS https://ifconfig.io/ip 2>$null
    "VPN IP: $proxy"
  }
  'diagnose' {
    $report = Join-Path $state 'diagnostic.txt'
    @("Golem VPN diagnostic $(Get-Date -Format o)", '--- status ---', (& $PSCommandPath status | Out-String), '--- latest log ---') | Set-Content -Encoding utf8 $report
    $log = Get-LatestLog
    if ($log) { Get-Content -Tail 120 $log.FullName | Add-Content -Encoding utf8 $report; $out = $log.FullName -replace '\.err\.log$','.out.log'; if (Test-Path $out) { Get-Content -Tail 120 $out | Add-Content -Encoding utf8 $report } } else { 'Логов пока нет.' | Add-Content -Encoding utf8 $report }
    "Отчёт сохранён: $report"
  }
}
