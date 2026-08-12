# ─────────────────────────────────────────────────────────────────────────────
#  Установка ярлыка «Golem VPN — страна выхода» (оплата картой)
# ─────────────────────────────────────────────────────────────────────────────
#  Копирует в %LOCALAPPDATA%\GolemVLESS\bin:
#    • CountrySwitch.ps1 — само окно выбора страны (B-019);
#    • render_config.py  — обновление рендерера (фильтр стран B-018 и --probe-out)
#      — важно: без этого bin-копия не поймёт строку countries= в policy.conf;
#  и кладёт на рабочий стол ярлык «VPN страна выхода (оплата).lnk» в папку
#  «Golem VPN Windows».
#
#  Права администратора НЕ требуются (копирование в %LOCALAPPDATA% + ярлык).
#  Само окно при запуске само попросит UAC (перезапуск sing-box).
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
$clientRoot = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$bin = Join-Path $clientRoot 'bin'
$config = Join-Path $clientRoot 'config'

if (-not (Test-Path -LiteralPath $bin)) {
    Write-Error "Клиент GolemVLESS не установлен ($bin). Сначала: .\windows\Install-GolemVless.ps1 -Start"
    return
}

Copy-Item -Force -LiteralPath (Join-Path $source 'scripts\render_config.py') "$bin\render_config.py"
Copy-Item -Force -LiteralPath (Join-Path $source 'windows\CountrySwitch.ps1') "$bin\CountrySwitch.ps1"
Write-Host "[OK] Скопированы render_config.py и CountrySwitch.ps1 -> $bin"

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutDir = Join-Path $desktop 'Golem VPN Windows'
New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $shortcutDir 'VPN страна выхода (оплата).lnk'))
$shortcut.TargetPath = 'PowerShell.exe'
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$bin\CountrySwitch.ps1`""
$shortcut.WorkingDirectory = $bin
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,253"
$shortcut.Description = 'Golem VPN: временно ограничить страну выхода (например, US/GB) для оплаты, затем вернуть рейтинг-автовыбор'
$shortcut.Save()

Write-Host "[OK] Ярлык создан: $shortcutDir\VPN страна выхода (оплата).lnk"
Write-Host ''
Write-Host 'Запустите ярлык — откроется окно выбора страны.'
Write-Host 'Перед переключением закройте Durev VPN (один TUN-клиент одновременно).'