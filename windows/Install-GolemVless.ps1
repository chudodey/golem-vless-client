[CmdletBinding()]
param(
  [switch]$Start
)

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
$clientRoot = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$config = Join-Path $clientRoot 'config'
$bin = Join-Path $clientRoot 'bin'
$state = Join-Path $clientRoot 'state'
$secret = Join-Path $source 'secrets\endpoints.txt'

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Запустите PowerShell от имени администратора: .\windows\Install-GolemVless.ps1 -Start'
}
if (-not (Test-Path -LiteralPath $secret)) { throw "Не найден Dell-ключ: $secret" }

New-Item -ItemType Directory -Force -Path $clientRoot,$config,$bin,$state | Out-Null
Copy-Item -Force "$source\scripts\render_config.py" "$bin\render_config.py"
Copy-Item -Force "$source\policy.conf" "$config\policy.conf"
Copy-Item -Force $secret "$config\endpoints.txt"

$version = '1.11.15'; $archive = Join-Path $env:TEMP "sing-box-$version-windows-amd64.zip"
Invoke-WebRequest -UseBasicParsing "https://github.com/SagerNet/sing-box/releases/download/v$version/sing-box-$version-windows-amd64.zip" -OutFile $archive
Expand-Archive -Force $archive (Join-Path $env:TEMP "sing-box-$version")
Copy-Item -Force (Get-ChildItem (Join-Path $env:TEMP "sing-box-$version") -Recurse -Filter sing-box.exe | Select-Object -First 1).FullName "$bin\sing-box.exe"

$runner = Join-Path $PSScriptRoot 'Run-GolemVless.ps1'; $watchdog = Join-Path $PSScriptRoot 'Watch-GolemVless.ps1'
Copy-Item -Force $runner "$bin\Run-GolemVless.ps1"; Copy-Item -Force $watchdog "$bin\Watch-GolemVless.ps1"
$runAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$bin\Run-GolemVless.ps1`""
$watchAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$bin\Watch-GolemVless.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -Force -TaskName 'GolemVLESS' -Action $runAction -Principal $principal | Out-Null
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 365)
Register-ScheduledTask -Force -TaskName 'GolemVLESS-Watchdog' -Action $watchAction -Trigger $trigger -Principal $principal | Out-Null
Write-Host 'Установлено. Перед запуском закройте Durev VPN: два TUN-клиента одновременно конфликтуют.'
if ($Start) { Start-ScheduledTask -TaskName 'GolemVLESS' }
