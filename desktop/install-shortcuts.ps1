# Создаёт на рабочем столе папку «VPN Dell» с ярлыками управления.
# Запускать один раз (и повторно — если ярлыки удалили).
#
#   powershell -ExecutionPolicy Bypass -File install-shortcuts.ps1

$ErrorActionPreference = 'Stop'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner  = Join-Path $here 'vpn.ps1'
$folder  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'VPN Dell'

if (-not (Test-Path $runner)) { throw "Не найден $runner" }
New-Item -ItemType Directory -Force -Path $folder | Out-Null

# imageres.dll — системная библиотека иконок Windows; индексы подобраны так,
# чтобы ярлыки различались на глаз.
$shortcuts = @(
    @{ Name = '1. Включить VPN';        Cmd = 'on';      Icon = 'imageres.dll,101' }
    @{ Name = '2. Выключить VPN';       Cmd = 'off';     Icon = 'imageres.dll,100' }
    @{ Name = '3. Состояние';           Cmd = 'status';  Icon = 'imageres.dll,109' }
    @{ Name = '4. Быстрейший сервер';   Cmd = 'fastest'; Icon = 'imageres.dll,230' }
    @{ Name = '5. Список серверов';     Cmd = 'nodes';   Icon = 'imageres.dll,172' }
    @{ Name = '6. Перезапустить';       Cmd = 'restart'; Icon = 'imageres.dll,228' }
    @{ Name = '7. Применить настройки'; Cmd = 'reload';  Icon = 'imageres.dll,166' }
    @{ Name = '8. Телеметрия';          Cmd = 'stats';   Icon = 'imageres.dll,218' }
    @{ Name = '9. Сводка';              Cmd = 'report';  Icon = 'imageres.dll,217' }
)

$shell = New-Object -ComObject WScript.Shell
foreach ($s in $shortcuts) {
    $lnk = $shell.CreateShortcut((Join-Path $folder "$($s.Name).lnk"))
    $lnk.TargetPath       = 'powershell.exe'
    $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" $($s.Cmd)"
    $lnk.WorkingDirectory = $here
    $lnk.IconLocation     = "$env:SystemRoot\System32\$($s.Icon)"
    $lnk.Description      = "VPN Dell — $($s.Cmd)"
    $lnk.Save()
}

Write-Host ''
Write-Host "  Готово. Ярлыки: $folder" -ForegroundColor Green
Write-Host ''
Get-ChildItem $folder -Filter *.lnk | ForEach-Object { Write-Host "   • $($_.BaseName)" }
Write-Host ''
Read-Host '  Enter — закрыть'
