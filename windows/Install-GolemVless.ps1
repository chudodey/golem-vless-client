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
if (-not (Test-Path -LiteralPath $secret)) {
  Write-Warning "Не найден ключ в $secret — установлю шаблон. Вставьте ваш ключ после установки:"
  Write-Warning "  notepad $config\endpoints.txt"
  $secret = Join-Path $source 'secrets\endpoints.example.txt'
}

New-Item -ItemType Directory -Force -Path $clientRoot,$config,$bin,$state | Out-Null
Copy-Item -Force "$source\scripts\render_config.py" "$bin\render_config.py"
Copy-Item -Force "$source\policy.conf" "$config\policy.conf"
Copy-Item -Force $secret "$config\endpoints.txt"

if (-not (Test-Path -LiteralPath "$bin\sing-box.exe")) {
  $version = '1.13.16'; $archive = Join-Path $env:TEMP "sing-box-$version-windows-amd64.zip"
  Invoke-WebRequest -UseBasicParsing "https://github.com/SagerNet/sing-box/releases/download/v$version/sing-box-$version-windows-amd64.zip" -OutFile $archive
  Expand-Archive -Force $archive (Join-Path $env:TEMP "sing-box-$version")
  Copy-Item -Force (Get-ChildItem (Join-Path $env:TEMP "sing-box-$version") -Recurse -Filter sing-box.exe | Select-Object -First 1).FullName "$bin\sing-box.exe"
}
if (Test-Path -LiteralPath "$source\windows\wintun.dll") {
  Copy-Item -Force "$source\windows\wintun.dll" "$bin\wintun.dll"
}

# Xray-core: the only engine that speaks xhttp/splithttp (sing-box does not
# — see docs/backlog.yaml B-007/B-011). Downloaded fresh, same as sing-box
# above — not bundled in the repo (34 MiB, not worth the git history cost;
# see .gitignore). Needed whenever the subscription contains such nodes;
# render_config.py degrades gracefully (skips them) if this binary is
# absent, so a failed download here is not fatal to install.
if (-not (Test-Path -LiteralPath "$bin\xray.exe")) {
  try {
    $xrayVersion = '26.3.27'
    $xrayArchive = Join-Path $env:TEMP "xray-$xrayVersion-windows-64.zip"
    Invoke-WebRequest -UseBasicParsing "https://github.com/XTLS/Xray-core/releases/download/v$xrayVersion/Xray-windows-64.zip" -OutFile $xrayArchive
    Expand-Archive -Force $xrayArchive (Join-Path $env:TEMP "xray-$xrayVersion")
    Copy-Item -Force (Join-Path $env:TEMP "xray-$xrayVersion\xray.exe") "$bin\xray.exe"
  } catch {
    Write-Warning "Не удалось скачать xray-core: $_. xhttp-ноды подписки будут пропущены (см. B-007); остальное установится нормально."
  }
}

$runner = Join-Path $PSScriptRoot 'Run-GolemVless.ps1'; $watchdog = Join-Path $PSScriptRoot 'Watch-GolemVless.ps1'; $control = Join-Path $PSScriptRoot 'GolemVpn.ps1'; $refresh = Join-Path $PSScriptRoot 'Refresh-Subscription.ps1'
Copy-Item -Force $runner "$bin\Run-GolemVless.ps1"; Copy-Item -Force $watchdog "$bin\Watch-GolemVless.ps1"; Copy-Item -Force $control "$bin\GolemVpn.ps1"; Copy-Item -Force $refresh "$bin\Refresh-Subscription.ps1"
$runAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bin\Run-GolemVless.ps1`""
$watchAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bin\Watch-GolemVless.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -Force -TaskName 'GolemVLESS' -Action $runAction -Principal $principal | Out-Null
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 365)
Register-ScheduledTask -Force -TaskName 'GolemVLESS-Watchdog' -Action $watchAction -Trigger $trigger -Principal $principal | Out-Null
# Daily node-list refresh: only restarts the client when the subscription
# actually changed (sha256 in state\subscription.sha256). Fetches a fresh
# subscription into state\last-subscription.txt, which render_config.py also
# uses as its offline fallback on fetch failure.
$refreshAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bin\Refresh-Subscription.ps1`""
$refreshTrigger = New-ScheduledTaskTrigger -Daily -At 04:00
Register-ScheduledTask -Force -TaskName 'GolemVLESS-Refresh' -Action $refreshAction -Trigger $refreshTrigger -Principal $principal | Out-Null
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutDir = Join-Path $desktop 'Golem VPN Windows'
New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null
$shell = New-Object -ComObject WScript.Shell
foreach ($command in 'status','start','stop','restart','logs','diagnose','refresh') {
  $shortcut = $shell.CreateShortcut((Join-Path $shortcutDir "VPN $command.lnk"))
  $shortcut.TargetPath = 'PowerShell.exe'
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$bin\GolemVpn.ps1`" $command -Wait"
  $shortcut.WorkingDirectory = $bin
  $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,18"
  $shortcut.Save()
}
Write-Host "Установлено. Управление: & '$bin\GolemVpn.ps1' status|start|stop|logs"
Write-Host 'Перед запуском закройте Durev VPN: два TUN-клиента одновременно конфликтуют.'
if (-not (Test-Path -LiteralPath $secret)) {
  Write-Host "Вставьте свой ключ, если ещё не сделали: notepad $config\endpoints.txt"
  Write-Host '  (vless://... напрямую, ссылка https:// подписки или ссылка на блок из браузера — см. пример в файле)'
}
if ($Start) { Start-ScheduledTask -TaskName 'GolemVLESS' }
