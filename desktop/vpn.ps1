# Управление VPN на сервере Dell с ноутбука.
# Вызывается ярлыками с рабочего стола; сам ничего не решает,
# только передаёт команду vpnctl на сервере.
#
#   vpn.ps1 on | off | restart | status | fastest | nodes | reload | stats | report

param(
    [Parameter(Position = 0)]
    [ValidateSet('on', 'off', 'restart', 'status', 'fastest', 'nodes', 'reload', 'stats', 'report')]
    [string]$Command = 'status'
)

$ErrorActionPreference = 'Stop'

$DellHost = '192.168.88.13'
$KeyPath  = Join-Path $env:USERPROFILE '.ssh\dell_sysrescue_ed25519'

$titles = @{
    on      = 'ВКЛЮЧЕНИЕ VPN'
    off     = 'ВЫКЛЮЧЕНИЕ VPN'
    restart = 'ПЕРЕЗАПУСК VPN'
    status  = 'СОСТОЯНИЕ VPN'
    fastest = 'ПОИСК БЫСТРЕЙШЕГО СЕРВЕРА'
    nodes   = 'СПИСОК СЕРВЕРОВ'
    reload  = 'ПРИМЕНЕНИЕ policy.conf'
    stats   = 'ТЕЛЕМЕТРИЯ (СБОР+СВОДКА)'
    report  = 'ТЕЛЕМЕТРИЯ (СВОДКА)'
}

Write-Host ''
Write-Host "  $($titles[$Command])" -ForegroundColor Cyan
Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path $KeyPath)) {
    Write-Host "  Не найден SSH-ключ: $KeyPath" -ForegroundColor Red
    Read-Host "`n  Enter — закрыть"
    exit 1
}

# Включение/перезапуск поднимает TUN и рвёт текущую SSH-сессию, поэтому
# запускаем командой, отвязанной от сессии, и проверяем результат отдельно.
$detached = $Command -in @('on', 'restart', 'reload')

try {
    if ($detached) {
        $unit = "vpn-cmd-$(Get-Random -Maximum 99999)"
        ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=15 "root@$DellHost" `
            "systemd-run --unit=$unit --no-block /usr/local/bin/vpnctl $Command" 2>&1 | Out-Null
        Write-Host '  Команда отправлена, жду применения…' -ForegroundColor DarkGray
        Start-Sleep -Seconds 18
        ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=15 "root@$DellHost" 'vpnctl status' 2>&1
    }
    else {
        ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=20 "root@$DellHost" "vpnctl $Command" 2>&1
    }
}
catch {
    Write-Host "  Ошибка связи с сервером: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Проверьте, включён ли Dell (dell-power.ps1 status)' -ForegroundColor Yellow
}

Write-Host ''
Read-Host '  Enter — закрыть'
