[CmdletBinding()]
param([ValidateSet('status','start','stop','restart','logs','diagnose')] [string]$Command = 'status')

$ErrorActionPreference = 'Stop'
$root  = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$state = Join-Path $root 'state'

# Все команды требуют прав администратора: остановка elevated sing-box,
# Enable/Stop-ScheduledTask и запись системного прокси не работают из
# неадминистативного окна. Само-поднимаемся, чтобы ярлыки на рабочем столе
# работали без запуска PowerShell от имени администратора вручную.
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $elevArg = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Command)
    try {
        Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -ArgumentList $elevArg | Out-Null
    } catch {
        Write-Host "  [XX] Не удалось поднять права: $($_.Exception.Message)"
    }
    exit 0
}

# ── Helper: pretty header ────────────────────────────────────────────────────
function Write-Header([string]$title) {
    Write-Host ''
    Write-Host "  ══════════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "    $title" -ForegroundColor Cyan
    Write-Host "  ══════════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Ok([string]$msg)   { Write-Host "  [OK] $msg"   -ForegroundColor Green  }
function Write-Warn([string]$msg) { Write-Host "  [!!] $msg"   -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "  [XX] $msg"   -ForegroundColor Red    }
function Write-Info([string]$msg) { Write-Host "       $msg"   -ForegroundColor Gray   }

# ── System proxy management ──────────────────────────────────────────────────
function Get-RealUserRegPath {
    $loggedIn = (Get-WmiObject Win32_ComputerSystem).UserName
    $sid = (New-Object Security.Principal.NTAccount($loggedIn)).Translate(
               [Security.Principal.SecurityIdentifier]).Value
    if (-not (Test-Path 'HKU:')) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script | Out-Null
    }
    return "HKU:\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
}

function Invoke-ProxyRefresh {
    $sig = 'using System; using System.Runtime.InteropServices; public class WinInet2 { [DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l); }'
    Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue
    [WinInet2]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [WinInet2]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

function Set-SystemProxy {
    try {
        $reg = Get-RealUserRegPath
        Set-ItemProperty -Path $reg -Name ProxyEnable   -Value 1
        Set-ItemProperty -Path $reg -Name ProxyServer    -Value '127.0.0.1:2080'
        Set-ItemProperty -Path $reg -Name ProxyOverride  -Value 'localhost;127.*;192.168.*;10.*;*.local;<local>'
        Invoke-ProxyRefresh
        Write-Ok 'Системный прокси: ВКЛЮЧЕН  (127.0.0.1:2080)'
    } catch { Write-Warn "Не удалось включить прокси: $_" }
}

function Clear-SystemProxy {
    try {
        $reg = Get-RealUserRegPath
        Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0
        Invoke-ProxyRefresh
        Write-Ok 'Системный прокси: ВЫКЛЮЧЕН'
    } catch { Write-Warn "Не удалось выключить прокси: $_" }
}

# ── Helper: show server info from outbounds.jsonl ────────────────────────────
function Show-ServerInfo {
    $outboundsFile = Join-Path $state 'outbounds.jsonl'
    if (-not (Test-Path $outboundsFile)) { Write-Warn 'outbounds.jsonl не найден (VPN ещё не запускался?)'; return }
    $lines = Get-Content $outboundsFile -ErrorAction SilentlyContinue
    $total = $lines.Count
    $active = $lines | Where-Object { $_ -match '"active":\s*true' } | Select-Object -First 1
    Write-Info "Серверов в подписке:  $total"
    if ($active) {
        $j = $active | ConvertFrom-Json
        Write-Ok  "Активный сервер:      #$($j.index)/$total  —  $($j.name)"
        Write-Info "  Хост:     $($j.server):$($j.server_port)"
        Write-Info "  Протокол: $($j.security) / $($j.network)"
        Write-Info "  URI:      $($j.uri_preview)..."
    } else { Write-Warn 'Активный сервер не найден в outbounds.jsonl' }
}

# ── Helper: show key/endpoint info ──────────────────────────────────────────
function Show-KeyInfo {
    $epFile = Join-Path $root 'config\endpoints.txt'
    if (-not (Test-Path $epFile)) { Write-Err "endpoints.txt не найден: $epFile"; return }
    $lines = Get-Content $epFile
    $directVless = ($lines | Where-Object { $_ -match '^vless://' }).Count
    $b64blocks   = ($lines | Where-Object { $_ -match '^[A-Za-z0-9+/=]{100,}$' }).Count
    if ($directVless -gt 0) {
        Write-Ok  "Ключи:  $directVless vless:// строк найдено"
    } elseif ($b64blocks -gt 0) {
        # Decode and count
        $encoded = ($lines | Where-Object { $_ -match '^[A-Za-z0-9+/=]{100,}$' }) -join ''
        try {
            $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
            $cnt = (($decoded -split "`n") | Where-Object { $_ -match '^vless://' }).Count
            Write-Ok  "Ключи:  $cnt серверов (base64-блок)"
        } catch { Write-Ok "Ключи:  base64-блок найден ($b64blocks строк)" }
    } else { Write-Err 'Ключи: НЕ НАЙДЕНЫ — вставьте vless:// ключи в endpoints.txt' }
}

# ── Helper: extract start info from latest log ───────────────────────────────
function Show-StartLog {
    $log = Get-ChildItem -LiteralPath $state -Filter 'sing-box-*.err.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { return }
    $lines = Get-Content $log.FullName -ErrorAction SilentlyContinue
    $decodedLine = $lines | Select-String 'decoded \d+ vless' | Select-Object -Last 1
    $activeLine  = $lines | Select-String 'Active outbound' | Select-Object -Last 1
    $fatalLine   = $lines | Select-String 'FATAL|Access is denied|failed' | Select-Object -Last 1
    if ($decodedLine) { Write-Info "Рендер: $($decodedLine.Line.Trim())" }
    if ($activeLine)  { Write-Info "Сервер: $($activeLine.Line.Trim())" }
    if ($fatalLine)   { Write-Err  "Ошибка: $($fatalLine.Line.Trim())" }
}

# ── VPN process management ───────────────────────────────────────────────────
function Stop-GolemProcess {
    Disable-ScheduledTask 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
    Stop-ScheduledTask    'GolemVLESS'           -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Start-GolemProcess {
    if (Get-Process sing-box -ErrorAction SilentlyContinue) {
        Write-Warn 'sing-box уже запущен — пропускаю старт'
        return
    }
    $runner = Join-Path $root 'bin\Run-GolemVless.ps1'
    Write-Info 'Запускаю sing-box (нужны права администратора)...'
    Start-Process -FilePath 'PowerShell.exe' -Verb RunAs -WindowStyle Hidden `
        -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', $runner)
    Write-Info 'Жду инициализации (5 сек)...'
    Start-Sleep -Seconds 5
    if (Get-Process sing-box -ErrorAction SilentlyContinue) {
        Write-Ok 'sing-box запущен'
    } else {
        Write-Err 'sing-box НЕ запустился — проверьте логи (VPN logs)'
        Show-StartLog
    }
}

function Get-LatestLog {
    Get-ChildItem -LiteralPath $state -Filter 'sing-box-*.err.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# ── Commands ─────────────────────────────────────────────────────────────────
switch ($Command) {

    'start' {
        Write-Header 'ВКЛЮЧЕНИЕ VPN'
        Show-KeyInfo
        Write-Host ''
        Enable-ScheduledTask 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
        Write-Ok 'Watchdog: включён'
        Start-GolemProcess
        Show-StartLog
        Write-Host ''
        Set-SystemProxy
        Write-Host ''
        Show-ServerInfo
    }

    'stop' {
        Write-Header 'ВЫКЛЮЧЕНИЕ VPN'
        Stop-GolemProcess
        Write-Ok 'sing-box остановлен'
        Write-Ok 'Watchdog: отключён'
        Write-Host ''
        Clear-SystemProxy
    }

    'restart' {
        Write-Header 'ПЕРЕЗАПУСК VPN'
        Write-Info 'Останавливаю...'
        Stop-GolemProcess
        Write-Ok 'sing-box остановлен'
        Write-Host ''
        Show-KeyInfo
        Write-Host ''
        Enable-ScheduledTask 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
        Write-Ok 'Watchdog: включён'
        Start-GolemProcess
        Show-StartLog
        Write-Host ''
        Set-SystemProxy
        Write-Host ''
        Show-ServerInfo
    }

    'status' {
        Write-Header 'СОСТОЯНИЕ VPN'

        # Scheduled tasks
        $tasks = Get-ScheduledTask -TaskName 'GolemVLESS','GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
        foreach ($t in $tasks) {
            $stateColor = if ($t.State -eq 'Running') { 'Green' } elseif ($t.State -eq 'Ready') { 'Yellow' } else { 'Red' }
            Write-Host "  Задача $($t.TaskName): $($t.State)" -ForegroundColor $stateColor
        }

        # Process
        $proc = Get-Process sing-box -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Ok  "sing-box PID $($proc.Id), запущен с $($proc.StartTime.ToString('HH:mm:ss'))"
        } else {
            Write-Err 'sing-box: НЕ ЗАПУЩЕН'
        }
        Write-Host ''

        # Keys & server
        Show-KeyInfo
        Write-Host ''
        Show-ServerInfo
        Write-Host ''

        # Proxy & external IP
        $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $proxyOn = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).ProxyEnable
        if ($proxyOn -eq 1) { Write-Ok  'Системный прокси: ВКЛЮЧЕН  (127.0.0.1:2080)' }
        else                { Write-Warn 'Системный прокси: ВЫКЛЮЧЕН' }

        Write-Host ''
        Write-Info 'Проверяю внешний IP через VPN (до 8 сек)...'
        $oldEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $ip = & curl.exe --proxy http://127.0.0.1:2080 --max-time 8 -fsS https://ifconfig.io/ip 2>$null
        $ErrorActionPreference = $oldEAP
        if ($ip) { Write-Ok  "Внешний IP через VPN: $($ip.Trim())" }
        else      { Write-Err 'Прокси недоступен — VPN не работает или не запущен' }
    }

    'logs' {
        Write-Header 'ПОСЛЕДНИЕ ЛОГИ SING-BOX'
        $log = Get-LatestLog
        if ($log) {
            Write-Info "Файл: $($log.Name)  (изменён: $($log.LastWriteTime.ToString('HH:mm:ss')))"
            Write-Host ''
            Get-Content -Tail 60 $log.FullName
            $out = $log.FullName -replace '\.err\.log$','.out.log'
            if (Test-Path $out) { Write-Host '--- stdout ---'; Get-Content -Tail 20 $out }
        } else { Write-Warn 'Логов пока нет.' }
    }

    'diagnose' {
        Write-Header 'ДИАГНОСТИКА'
        $report = Join-Path $state 'diagnostic.txt'
        @("Golem VPN diagnostic $(Get-Date -Format o)", '--- status ---',
          (& $PSCommandPath status | Out-String), '--- latest log ---') |
            Set-Content -Encoding utf8 $report
        $log = Get-LatestLog
        if ($log) {
            Get-Content -Tail 120 $log.FullName | Add-Content -Encoding utf8 $report
            $out = $log.FullName -replace '\.err\.log$','.out.log'
            if (Test-Path $out) { Get-Content -Tail 120 $out | Add-Content -Encoding utf8 $report }
        } else { 'No logs yet.' | Add-Content -Encoding utf8 $report }
        Write-Ok "Отчёт сохранён: $report"
    }
}

Write-Host ''