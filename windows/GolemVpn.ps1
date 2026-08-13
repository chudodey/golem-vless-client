[CmdletBinding()]
param([ValidateSet('status','start','stop','restart','logs','diagnose','refresh','stats','report','watchdog','uninstall','help')] [string]$Command = 'status', [switch]$Wait)

$ErrorActionPreference = 'Stop'
$root  = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$state = Join-Path $root 'state'

# ── Helper: keep the console open after a shortcut-triggered run ─────────────
function Wait-Close {
    if (-not $Wait) { return }
    if ($env:GOLEM_NO_WAIT) { return }
    Write-Host ''
    Read-Host '   [Enter] закрыть окно'
}

# Все команды требуют прав администратора: остановка elevated sing-box,
# Enable/Stop-ScheduledTask и запись системного прокси не работают из
# неадминистативного окна. Само-поднимаемся, чтобы ярлыки на рабочем столе
# работали без запуска PowerShell от имени администратора вручную.
function Get-ShellHost {
    # Вариант 7 PowerShell (pwsh.exe) или 5.1 (powershell.exe) — тот же, что
    # сейчас запустил скрипт: у PS7 нет powershell.exe в $PSHOME.
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $p = Join-Path $PSHOME 'pwsh.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return (Join-Path $PSHOME 'powershell.exe')
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $elevArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Command)
    if ($Wait) { $elevArgs += '-Wait' }
    # Keep the elevated window visible even if the command throws. This is
    # especially important for restart/diagnose/stop shortcuts: their output
    # is the user's first-line debugging report.
    if ($Wait) { $elevArgs = @('-NoExit') + $elevArgs }
    try {
        Start-Process -FilePath (Get-ShellHost) -Verb RunAs -WindowStyle Normal `
            -WorkingDirectory $env:SystemRoot -ArgumentList $elevArgs | Out-Null
    } catch {
        Write-Host "  [XX] Не удалось поднять права: $($_.Exception.Message)"
    }
    Wait-Close
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
    $loggedIn = (Get-CimInstance Win32_ComputerSystem).UserName
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
    [CmdletBinding(SupportsShouldProcess)]
    param()
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
        Write-Info "Стартовый кандидат:   #$($j.index)/$total  —  $($j.name)"
        Write-Info "  Хост:     $($j.server):$($j.server_port)"
        Write-Info "  Протокол: $($j.security) / $($j.network)"
        $selection = Join-Path $state 'selection.json'
        if (Test-Path -LiteralPath $selection) {
            try {
                $s = Get-Content -LiteralPath $selection -Raw | ConvertFrom-Json
                $at = ([datetimeoffset]$s.rendered_at).ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss')
                if ($s.mode -eq 'urltest') {
                    Write-Ok "Текущий выбор:        urltest (автоматически среди $($s.candidate_count) кандидатов)"
                    Write-Info "  Последний отбор: $at"
                } else {
                    Write-Ok 'Текущий выбор:        закреплённый/единственный кандидат'
                    Write-Info "  Последний отбор: $at"
                }
                Write-Info "  Почему: $($s.reason)"
                if ($s.country_filter) { Write-Warn "  Ограничение страны АКТИВНО: countries = $($s.country_filter)" }
            } catch { Write-Warn 'Не удалось прочитать selection.json с объяснением выбора' }
        } else {
            Write-Warn 'Объяснение выбора ещё не записано — перезапустите VPN после обновления клиента'
        }
        Write-Info "  URI:      $($j.uri_preview)..."
    } else { Write-Warn 'Активный сервер не найден в outbounds.jsonl' }
}

function Show-WatchdogInfo {
    $task = Get-ScheduledTask -TaskName 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
    $info = Get-ScheduledTaskInfo -TaskName 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
    if ($task) {
        $last = if ($info -and $info.LastRunTime) { $info.LastRunTime.ToString('dd.MM HH:mm:ss') } else { 'ещё не запускался' }
        $next = if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('dd.MM HH:mm:ss') } else { '—' }
        Write-Info "Watchdog: $($task.State); последний запуск $last; следующий $next"
    } else { Write-Warn 'Watchdog: задача не найдена' }

    $streakPath = Join-Path $state 'watchdog-failures.txt'
    $streak = Get-Content -LiteralPath $streakPath -Raw -ErrorAction SilentlyContinue
    if ($streak -match '^\d+$') {
        if ([int]$streak -gt 0) { Write-Warn "  Серия неудачных проверок: $streak/3 (после 3 watchdog перезапускает VPN)" }
        else { Write-Ok '  Последняя проверка watchdog: канал исправен' }
    }
    $eventsPath = Join-Path $state 'watchdog-events.jsonl'
    if (Test-Path -LiteralPath $eventsPath) {
        try {
            $allEvents = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json })
            $checks = @($allEvents | Where-Object { $_.action -eq 'check' })
            $restarts = @($allEvents | Where-Object { $_.action -eq 'restart' })
            $switches = @($allEvents | Where-Object { $_.action -eq 'node_selected' })
            $countryChanges = @($allEvents | Where-Object { $_.action -match '^country_filter_' })
            Write-Info "  За всю сохранённую историю: проверок $($checks.Count), перезапусков $($restarts.Count), смен ноды $($switches.Count)"
            if ($countryChanges.Count -gt 0) {
                $lastCountry = @($countryChanges | Select-Object -Last 1)[0]
                Write-Info "  Последнее действие с фильтром: $($lastCountry.action) — $($lastCountry.message)"
            }
            if ($switches.Count -gt 0) {
                $lastSwitch = @($switches | Select-Object -Last 1)[0]
                $switchAt = ([datetimeoffset]$lastSwitch.timestamp).ToLocalTime().ToString('dd.MM HH:mm:ss')
                $from = if ($lastSwitch.previous) { $lastSwitch.previous } else { 'нет данных (первый опрос)' }
                Write-Info "  Последняя смена ноды: $switchAt — $from → $($lastSwitch.selected)"
            }
            $lastEvent = @($allEvents | Select-Object -Last 1)[0]
            if ($lastEvent) {
                $when = ([datetimeoffset]$lastEvent.timestamp).ToLocalTime().ToString('dd.MM HH:mm:ss')
                if ($lastEvent.healthy -eq $true) {
                    Write-Info "  Последнее действие: $when — проверка успешна (HTTP $($lastEvent.probe_http))"
                } else {
                    $why = @($lastEvent.reasons) -join '; '
                    if (-not $why) { $why = $lastEvent.message }
                    Write-Warn "  Последнее действие: $when — $($lastEvent.action): $why"
                }
            }
        } catch { Write-Warn 'Не удалось прочитать журнал watchdog' }
    } else { Write-Info '  История watchdog появится после первого запуска обновлённой версии' }
}

# ── Helper: show key/endpoint info ──────────────────────────────────────────
function Show-KeyInfo {
    $epFile = Join-Path $root 'config\endpoints.txt'
    if (-not (Test-Path $epFile)) { Write-Err "endpoints.txt не найден: $epFile"; return }
    $lines = Get-Content $epFile
    $directVless = ($lines | Where-Object { $_ -match '^vless://' }).Count
    $b64blocks   = ($lines | Where-Object { $_ -match '^[A-Za-z0-9+/=]{100,}$' }).Count
    $subUrl      = ($lines | Where-Object { $_ -match '^https?://' } | Select-Object -First 1)
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
    } elseif ($subUrl) {
        $cacheFile = Join-Path $state 'last-subscription.txt'
        $cached = (Get-Content $cacheFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^vless://' }).Count
        if ($cached -gt 0) {
            Write-Ok  "Ключи:  $cached серверов (подписка $($subUrl.Substring(0, [Math]::Min(40, $subUrl.Length)))...)"
        } else {
            Write-Ok  "Подписка: $($subUrl.Substring(0, [Math]::Min(60, $subUrl.Length)))..."
            Write-Warn 'Кэш нод ещё пуст — клиент сам скачает ключи при первом старте (--fetch)'
        }
    } else { Write-Err 'Ключи: НЕ НАЙДЕНЫ — вставьте vless:// ключи или URL подписки в endpoints.txt' }
}

# ── Helper: extract start info from latest log ───────────────────────────────
function Show-StartLog {
    $log = Get-ChildItem -LiteralPath $state -Filter 'sing-box-*.err.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { return }
    $lines = Get-Content $log.FullName -ErrorAction SilentlyContinue
    $decodedLine = $lines | Select-String 'decoded \d+ vless' | Select-Object -Last 1
    $activeLine  = $lines | Select-String 'Active outbound' | Select-Object -Last 1
    # Считать фатальными только настоящие поломки. «WARN: subscription fetch
    # failed … using cached» — это штатный фолбэк на кэш, ошибкой не является.
    $fatalLine   = $lines | Select-String 'FATAL|Access is denied|ERROR:|render failed|check failed' | Select-Object -Last 1
    if ($decodedLine) { Write-Info "Рендер: $($decodedLine.Line.Trim())" }
    if ($activeLine)  { Write-Info "Сервер: $($activeLine.Line.Trim())" }
    if ($fatalLine)   { Write-Err  "Ошибка: $($fatalLine.Line.Trim())" }
}

# ── VPN process management ───────────────────────────────────────────────────
function Stop-GolemProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $eventsPath = Join-Path $state 'connection-events.jsonl'
    $before2080 = Get-NetTCPConnection -LocalPort 2080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    $before2081 = Get-NetTCPConnection -LocalPort 2081 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    ([ordered]@{ timestamp=(Get-Date).ToString('o'); action='golem_stop_requested'; port2080_pid=if($before2080){$before2080.OwningProcess}else{$null}; port2081_pid=if($before2081){$before2081.OwningProcess}else{$null} } | ConvertTo-Json -Compress) |
        Out-File -LiteralPath $eventsPath -Append -Encoding utf8
    Disable-ScheduledTask 'GolemVLESS-Watchdog' -ErrorAction SilentlyContinue
    Stop-ScheduledTask    'GolemVLESS'           -ErrorAction SilentlyContinue
    # Do NOT kill processes merely by the names sing-box/xray: Durev and other
    # VPN clients use the same engines. The scheduled Golem runner owns its
    # child processes and stopping that task is the safe ownership boundary.
    $deadline = (Get-Date).AddSeconds(12)
    do {
        $left2080 = Get-NetTCPConnection -LocalPort 2080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left2080) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    # If the scheduled task left its Golem listener behind, terminate only the
    # exact owner of Golem's own mixed proxy port. Never select by process name.
    $left2080 = Get-NetTCPConnection -LocalPort 2080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($left2080) {
        Stop-Process -Id $left2080.OwningProcess -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    $after2080 = Get-NetTCPConnection -LocalPort 2080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    ([ordered]@{ timestamp=(Get-Date).ToString('o'); action='golem_stop_completed'; port2080_closed=(-not $after2080); remaining_port2080_pid=if($after2080){$after2080.OwningProcess}else{$null} } | ConvertTo-Json -Compress) |
        Out-File -LiteralPath $eventsPath -Append -Encoding utf8
    if ($after2080) { Write-Err "Golem proxy :2080 всё ещё занят PID $($after2080.OwningProcess) — ничего более не завершаю" }
    else { Write-Ok 'Golem остановлен: локальный прокси :2080 закрыт; watchdog отключён' }
}

function Start-GolemProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-Process sing-box -ErrorAction SilentlyContinue) {
        Write-Warn 'sing-box уже запущен — пропускаю старт'
        return
    }
    $preflight = Join-Path $root 'bin\Test-GolemTunnelPreflight.ps1'
    if (Test-Path -LiteralPath $preflight) {
        & $preflight
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'Запуск отменён: сначала отключите другой VPN/TUN, затем повторите start/restart.'
            return
        }
    }
    $runner = Join-Path $root 'bin\Run-GolemVless.ps1'
    Write-Info 'Запускаю sing-box (нужны права администратора)...'
    Start-Process -FilePath 'PowerShell.exe' -Verb RunAs -WindowStyle Hidden `
        -WorkingDirectory $env:SystemRoot `
        -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', $runner)
    # Full node qualification (subscription → TCP → 3 HTTP endpoints) is
    # intentionally thorough and can take several minutes.  Show a heartbeat
    # from the live runner log so the user sees exactly which stage is active.
    $startupTimeoutSec = 240
    Write-Info "Рендер подписки: TCP + HTTP-проверка нод; ожидание до $startupTimeoutSec сек."
    Write-Info 'Статус ниже обновляется каждые 5 сек; это не зависание, пока меняется этап.'
    $deadline = (Get-Date).AddSeconds($startupTimeoutSec)
    $startedAt = Get-Date
    $lastProgress = ''
    $up = $false
    while ((Get-Date) -lt $deadline) {
        if (Get-NetTCPConnection -LocalPort 2080 -State Listen -ErrorAction SilentlyContinue) { $up = $true; break }
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        $left = [math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
        $log = Get-LatestLog
        $stage = 'ожидание запуска повышенного процесса'
        if ($log) {
            $tail = Get-Content -LiteralPath $log.FullName -Tail 50 -ErrorAction SilentlyContinue
            if ($tail -match 'Проверяю ноды по HTTP') { $stage = 'HTTP-проверка доступа к Anthropic / YouTube / OpenRouter' }
            elseif ($tail -match 'Проверяю живость нод') { $stage = 'TCP-проверка доступности нод' }
            elseif ($tail -match 'subscription fetched|decoded \d+ vless') { $stage = 'подписка получена; готовлю проверку нод' }
            $fatal = $tail | Select-String 'ERROR:|config render failed|check failed' | Select-Object -Last 1
            if ($fatal) { Write-Err "Запуск остановлен: $($fatal.Line.Trim())"; break }
        }
        $progress = "  [$elapsed/$startupTimeoutSec сек, осталось ~$left сек] $stage"
        if ($progress -ne $lastProgress) { Write-Info $progress.Trim(); $lastProgress = $progress }
        Start-Sleep -Seconds 5
    }
    if ($up) {
        Write-Ok 'sing-box запущен и слушает :2080'
    } else {
        Write-Err "sing-box НЕ запустился за $startupTimeoutSec сек — покажу причину из лога"
        Show-StartLog
    }
    # xray.exe is only expected when the subscription has xhttp/splithttp
    # nodes (B-007) — xray-config.json's presence is exactly that signal.
    if (Test-Path -LiteralPath (Join-Path $state 'xray-config.json')) {
        if (Test-NetConnection -ComputerName 127.0.0.1 -Port 2081 -InformationLevel Quiet -WarningAction SilentlyContinue) {
            Write-Ok 'xray-core запущен (обслуживает xhttp-ноды)'
        } else {
            Write-Warn 'xray-core НЕ запустился — xhttp-ноды подписки недоступны, работают только ws/tcp'
        }
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
        $port2080 = Get-NetTCPConnection -LocalPort 2080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($port2080) {
            Write-Ok  "Golem proxy слушает :2080 (PID $($port2080.OwningProcess))"
        } else {
            Write-Err 'Golem proxy :2080 не слушает — VPN не запущен'
        }
        # xray.exe (xhttp-ноды, B-007) экспектится только когда рендер решил,
        # что он нужен — иначе состояние "не запущен" не является проблемой.
        $xrayExpected = Test-Path -LiteralPath (Join-Path $state 'xray-config.json')
        $port2081 = Test-NetConnection -ComputerName 127.0.0.1 -Port 2081 -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($port2081) {
            Write-Ok  'xray-core слушает :2081  (xhttp-ноды)'
        } elseif ($xrayExpected) {
            Write-Err 'xray-core: НЕ ЗАПУЩЕН, а нужен (xhttp-ноды в подписке недоступны)'
        } else {
            Write-Info 'xray-core: не требуется (в подписке нет xhttp-нод)'
        }
        Write-Host ''

        # Keys & server
        Show-KeyInfo
        Write-Host ''
        Show-ServerInfo
        Write-Host ''
        Show-WatchdogInfo
        Write-Host ''

        # Subscription auto-refresh: next scheduled run tells the user when the
        # node list will self-update (GolemVLESS-Refresh, daily 04:00).
        $refreshTask = Get-ScheduledTask -TaskName 'GolemVLESS-Refresh' -ErrorAction SilentlyContinue
        if ($refreshTask) {
            $info = Get-ScheduledTaskInfo -TaskName 'GolemVLESS-Refresh' -ErrorAction SilentlyContinue
            $next = if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('dd.MM HH:mm') } else { '—' }
            Write-Info "Авто-refresh подписки: задача активна, следующий запуск $next"
        }
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

        Write-Info 'Проверяю OpenRouter API через VPN...'
        $oldEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $openrouterStatus = & curl.exe --proxy http://127.0.0.1:2080 `
            --max-time 12 -sS -o NUL -w '%{http_code}' `
            https://openrouter.ai/api/v1/models 2>$null
        $ErrorActionPreference = $oldEAP
        if ($openrouterStatus -eq '200') {
            Write-Ok 'OpenRouter API: доступен (HTTP 200)'
        } elseif ($openrouterStatus) {
            Write-Err "OpenRouter API: HTTP $openrouterStatus — текущая VPN-нода заблокирована"
        } else {
            Write-Err 'OpenRouter API: соединение не установлено'
        }
    }

    'logs' {
        Write-Header 'ПОСЛЕДНИЕ ЛОГИ SING-BOX'
        $log = Get-LatestLog
        if ($log) {
            Write-Info "Файл: $($log.Name)  (изменён: $($log.LastWriteTime.ToString('HH:mm:ss')))"
            Get-Content -Tail 60 $log.FullName
            $out = $log.FullName -replace '\.err\.log$','.out.log'
            if (Test-Path $out) { Write-Host '--- stdout ---'; Get-Content -Tail 20 $out }
        } else { Write-Warn 'Логов пока нет.' }
    }

    'diagnose' {
        Write-Header 'ДИАГНОСТИКА'
        $report = Join-Path $state 'diagnostic.txt'
        @("Golem VPN diagnostic $(Get-Date -Format o)", '--- status ---',
          (& $PSCommandPath status | Out-String), '--- watchdog history ---') |
            Set-Content -Encoding utf8 $report
        $watchdogEvents = Join-Path $state 'watchdog-events.jsonl'
        if (Test-Path -LiteralPath $watchdogEvents) {
            Get-Content $watchdogEvents | Add-Content -Encoding utf8 $report
        } else { 'No watchdog event history yet.' | Add-Content -Encoding utf8 $report }
        '--- latest log ---' | Add-Content -Encoding utf8 $report
        $log = Get-LatestLog
        if ($log) {
            Get-Content -Tail 120 $log.FullName | Add-Content -Encoding utf8 $report
            $out = $log.FullName -replace '\.err\.log$','.out.log'
            if (Test-Path $out) { Get-Content -Tail 120 $out | Add-Content -Encoding utf8 $report }
        } else { 'No logs yet.' | Add-Content -Encoding utf8 $report }
        Write-Ok "Отчёт сохранён: $report"
    }

    'refresh' {
        Write-Header 'ОБНОВЛЕНИЕ НОД (ПОДПИСКА)'
        $refreshScript = Join-Path $root 'bin\Refresh-Subscription.ps1'
        if (-not (Test-Path -LiteralPath $refreshScript)) {
            Write-Err "Не найден Refresh-Subscription.ps1: $refreshScript — перезапустите Install-GolemVless.ps1"
            break
        }
        Write-Info 'Проверяю подписку и (при изменении) перезапускаю клиент...'
        & $refreshScript -Force *>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
        Write-Host ''
        Write-Ok 'Готово. Смотрите state\subscription-refresh.log'
    }

    'stats' {
        Write-Header 'ТЕЛЕМЕТРИЯ (СБОР)'
        $py = Join-Path $root 'bin\stats.py'
        if (-not (Test-Path -LiteralPath $py)) {
            Write-Err "Не найден stats.py: $py — перезапустите Install-GolemVless.ps1"
            break
        }
        & python $py collect --endpoints (Join-Path $root 'config\endpoints.txt') --state-dir $state --fetch
        & python $py report --state-dir $state
    }

    'report' {
        Write-Header 'ТЕЛЕМЕТРИЯ (СВОДКА)'
        $py = Join-Path $root 'bin\stats.py'
        if (-not (Test-Path -LiteralPath $py)) {
            Write-Err "Не найден stats.py: $py — перезапустите Install-GolemVless.ps1"
            break
        }
        & python $py report --state-dir $state
    }

    'watchdog' {
        Write-Header 'WATCHDOG — ПРОВЕРКИ И ВОССТАНОВЛЕНИЯ'
        Show-WatchdogInfo
    }

    'uninstall' {
        Write-Header 'УДАЛЕНИЕ'
        Write-Warn 'Будут удалены: задачи GolemVLESS(-Watchdog/-Refresh), процессы sing-box/xray,'
        Write-Warn "  системный прокси, ярлыки «Golem VPN Windows» и весь каталог $root"
        Write-Host ''
        $yes = Read-Host '  Удалить клиент полностью? [y/N]'
        if ($yes -notmatch '^[YyДд]') {
            Write-Host '  Отменено.'
            break
        }
        Stop-GolemProcess
        Clear-SystemProxy
        foreach ($task in 'GolemVLESS','GolemVLESS-Watchdog','GolemVLESS-Refresh') {
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        }
        $shortcutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Golem VPN Windows'
        if (Test-Path -LiteralPath $shortcutDir) {
            Remove-Item -Recurse -Force -LiteralPath $shortcutDir
        }
        if (Test-Path -LiteralPath $root) {
            Remove-Item -Recurse -Force -LiteralPath $root
        }
        Write-Ok 'Клиент удалён. Каталог обновлений подписки и конфиг испарены вместе с %LOCALAPPDATA%.'
        Write-Info 'Осталось только: сам репозиторий локально + задача GolemVLESS-Watchdog не существует.'
    }

    'help' {
        Write-Header 'УПРАВЛЕНИЕ VPN'
        Write-Host "  GolemVpn.ps1 <команда> [-Wait]
"
        foreach ($c in 'status','start','stop','restart','logs','diagnose','refresh','stats','report','watchdog','uninstall') {
            switch ($c) {
                'status'    { $d = 'состояние задач, процессов, сервер, прокси, IP' }
                'start'     { $d = 'включить VPN' }
                'stop'      { $d = 'выключить VPN' }
                'restart'   { $d = 'перезапустить VPN' }
                'logs'      { $d = 'последние строки лога sing-box' }
                'diagnose'  { $d = 'отчёт state\diagnostic.txt' }
                'refresh'   { $d = 'обновить подписку и перезапустить при изменении' }
                'stats'     { $d = 'собрать телеметрию нод и показать сводку (B-015)' }
                'report'    { $d = 'показать сводку телеметрии (без сбора)' }
                'watchdog'  { $d = 'последние проверки и перезапуски watchdog' }
                'uninstall' { $d = 'полное удаление клиента (задачи, процессы, %LOCALAPPDATA%)' }
            }
            Write-Host "  $c".PadRight(16) $d
        }
        Write-Host ''
        Write-Info '-Wait держит окно открытым (используется ярлыками)'
        Write-Info 'Ежедневный авто-refresh: GolemVLESS-Refresh (04:00)'
    }
}

Wait-Close
