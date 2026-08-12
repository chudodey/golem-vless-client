# ─────────────────────────────────────────────────────────────────────────────
#  Golem VPN — страна выхода (временный режим для оплаты) — консольный мастер
# ─────────────────────────────────────────────────────────────────────────────
#  Открывает терминальное окно и ведёт по шагам:
#    1. если фильтр сейчас выключен — спрашивает целевую страну (US / GB / US, GB…);
#    2. показывает, какие ноды попадут под фильтр, со временем отклика каждой;
#    3. подтверждаете — пишет countries = <страна> в config\policy.conf и
#       перезапускает клиент (GolemVpn.ps1 restart, прогресс в этом же окне);
#    4. окно «замирает» — пока занимаетесь делом (оплатой), клиент уже в US/GB;
#    5. по [Enter] — возвращает прежний режим (countries = ) и перезапускает;
#    6. окно закрывается.
#
#  Основано на B-018 ([auto-select] countries в policy.conf) и B-019.
#  Первый запуск запросит UAC — без администратора нельзя перезапустить sing-box.
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param([string]$Country)

$ErrorActionPreference = 'Stop'

$root  = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$cfg   = Join-Path $root 'config'
$bin   = Join-Path $root 'bin'
$state = Join-Path $root 'state'
$policy    = Join-Path $cfg 'policy.conf'
$endpoints = Join-Path $cfg 'endpoints.txt'
$render    = Join-Path $bin 'render_config.py'
$control   = Join-Path $bin 'GolemVpn.ps1'

# ── под какого PowerShell запускаться в elevated: тот же, что и сейчас ──────
# PS7 = pwsh.exe в $PSHOME, PS5.1 = powershell.exe (у PS7 его там нет).
function Get-ShellHost {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $p = Join-Path $PSHOME 'pwsh.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return (Join-Path $PSHOME 'powershell.exe')
}

# ── само-подъём прав (UAC) ───────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Country) { $args += $Country }
    Start-Process -FilePath (Get-ShellHost) -Verb RunAs `
        -WorkingDirectory $env:SystemRoot -ArgumentList $args | Out-Null
    exit 0
}

# ── предварительная проверка установки ──────────────────────────────────────
if (-not (Test-Path -LiteralPath $bin) -or -not (Test-Path -LiteralPath $policy)) {
    Write-Host "Клиент GolemVLESS не установлен ($bin)." -ForegroundColor Red
    Write-Host 'Запустите:  powershell -File windows\Install-GolemVless.ps1 -Start'
    Read-Host '  [Enter] закрыть окно'
    exit 1
}

# ── helpers ──────────────────────────────────────────────────────────────────
function Write-Ok([string]$m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Err([string]$m)  { Write-Host "  [XX] $m" -ForegroundColor Red }
function Write-Info([string]$m) { Write-Host "       $m" -ForegroundColor Gray  }

function Get-CleanName([string]$n) {
    $c = $n -replace '[^\p{L}\p{N} _-]', ' '
    $c = $c -replace '\s+', ' '
    $c = $c.Trim()
    if ($c.Length -gt 24) { $c = $c.Substring(0, 24) }
    if (-not $c) { $c = '?' }
    return $c
}

function Get-FlagCountry([string]$name) {
    $m = [regex]::Match($name, '\uD83C[\uDDE6-\uDDFF]\uD83C[\uDDE6-\uDDFF]')
    if (-not $m.Success) { return '' }
    $s = $m.Value
    $a = [string][char](([int]$s[1]) - 0xDDE6 + 65)
    $b = [string][char](([int]$s[3]) - 0xDDE6 + 65)
    return $a + $b
}

function Get-CurrentCountry {
    if (-not (Test-Path -LiteralPath $policy)) { return '' }
    foreach ($ln in Get-Content -LiteralPath $policy) {
        if ($ln -match '^\s*countries\s*=\s*(.*?)\s*$') { return $Matches[1].Trim() }
    }
    return ''
}

function Set-CountryLine {
    param([string]$Path, [string]$Val)
    $lines = @(Get-Content -LiteralPath $Path)
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*countries\s*=') { $idx = $i; break }
    }
    if ($idx -ge 0) {
        $lines[$idx] = 'countries = ' + $Val
    } else {
        $anchor = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*test_url\s*=') { $anchor = $i; break }
        }
        if ($anchor -ge 0) {
            $head = $lines[0..$anchor]
            $tail = if ($anchor -lt $lines.Count - 1) { $lines[($anchor + 1)..($lines.Count - 1)] } else { @() }
            $lines = $head + @('countries = ' + $Val) + $tail
        } else {
            $lines += 'countries = ' + $Val
        }
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $lines, $enc)
}

# ── предпросмотр: ноды под фильтром + время отклика ─────────────────────────
function Show-Preview([string]$countries) {
    $tmpBase = Join-Path $env:TEMP ("golem-country-" + $PID)
    if (Test-Path -LiteralPath $tmpBase) { Remove-Item -Recurse -Force -LiteralPath $tmpBase }
    $tmpCfg = Join-Path $tmpBase 'cfg'; $tmpOut = Join-Path $tmpBase 'out'
    New-Item -ItemType Directory -Force -Path $tmpCfg, $tmpOut | Out-Null
    $tmpPolicy = Join-Path $tmpCfg 'policy.conf'
    Copy-Item -LiteralPath $policy -Destination $tmpPolicy -Force
    Set-CountryLine -Path $tmpPolicy -Val $countries

    Write-Info 'Рендер предпросмотра (временный, клиент не трогаю)…'
    $out = $null
    $ErrorActionPreference = 'Continue'
    $out = & python $render --endpoints $endpoints --policy $tmpPolicy `
        --out (Join-Path $tmpOut 'config.json') --state-dir (Join-Path $tmpOut 'state') `
        --fetch --no-tun --no-http-probe --probe-out (Join-Path $tmpOut 'probe.jsonl') 2>&1
    $rc = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    $obf = Join-Path $tmpOut 'outbounds.jsonl'
    if ($rc -ne 0 -or -not (Test-Path -LiteralPath $obf)) {
        Write-Err "Рендер предпросмотра упал (код: $rc)"
        $out | ForEach-Object { Write-Info $_.ToString() }
        return $false
    }
    $lat = @{}
    $plf = Join-Path $tmpOut 'probe.jsonl'
    if (Test-Path -LiteralPath $plf) {
        foreach ($l in Get-Content -LiteralPath $plf) {
            try { $p = $l | ConvertFrom-Json; $lat[[string]$p.index] = $p.lat_ms } catch {}
        }
    }
    Write-Host ''
    Write-Host '   №    СТР  НОДА                        ПРОВАЙДЕР  СЕРВЕР                    ОТКЛИК'
    Write-Host '   ───  ───  ──────────────────────────  ────────  ────────────────────────  ──────'
    $rows = 0
    foreach ($l in Get-Content -LiteralPath $obf) {
        $j = $null
        try { $j = $l | ConvertFrom-Json } catch { continue }
        $ms = $lat[[string]$j.index]
        $latTxt = if ($null -eq $ms) { 'мёртв' } else { "$ms мс" }
        $fmt = '   {0,3}  {1,-3}  {2,-26} {3,-8} {4,-23} {5}'
        if ($null -eq $ms) { Write-Host ($fmt -f $j.index, (Get-FlagCountry $j.name), (Get-CleanName $j.name), $j.provider, ("$($j.server):$($j.server_port)"), $latTxt) -ForegroundColor DarkGray }
        else {
            $color = if ($ms -lt 120) { 'Green' } elseif ($ms -lt 300) { 'Yellow' } else { 'Red' }
            Write-Host ($fmt -f $j.index, (Get-FlagCountry $j.name), (Get-CleanName $j.name), $j.provider, ("$($j.server):$($j.server_port)"), $latTxt) -ForegroundColor $color
        }
        $rows++
    }
    Write-Host ''
    if ($rows -eq 0) {
        Write-Warn "Под фильтр '$countries' не попало ни одной ноды — проверьте имена нод (--check-only проекта) или выберите другую страну."
        return $false
    }
    Write-Ok "Под фильтр '$countries' попадает нод: $rows (серым — недоступные, в списке ни одной непонятной страны)"
    return $true
}

# ── применить режим и перезапустить клиент (мы уже elevated) ────────────────
function Invoke-Switch([string]$countries) {
    $before = Get-CurrentCountry
    if ($before -ne $countries) {
        try { Set-CountryLine -Path $policy -Val $countries }
        catch { Write-Err "Не удалось записать policy.conf: $_"; return $false }
        Write-Ok ('policy.conf: countries = {0}' -f $(if ($countries) { $countries } else { '(пусто — рейтинг)' }))
    }
    Write-Host ''
    Write-Host '  Перезапускаю клиент (подбор живых нод может занять до минуты)…' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $control)) {
        Write-Err "GolemVpn.ps1 не найден ($control) — перезапустите Install-GolemVless.ps1"
        return $false
    }
    & $control restart
    return $true
}

function Check-IP {
    Write-Host '  Проверяю внешний IP через VPN…'
    $ErrorActionPreference = 'Continue'
    $ip = & curl.exe --proxy http://127.0.0.1:2080 --max-time 10 -fsS https://ifconfig.io/ip 2>$null
    $ErrorActionPreference = 'Stop'
    if ($ip) { Write-Ok "Внешний IP через VPN: $($ip.Trim())" } else { Write-Warn 'IP не получился — клиент, возможно, ещё перезапускается' }
}

# ═══════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '  ════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan
Write-Host '    GOLEM VPN — СТРАНА ВЫХОДА (временный режим для оплаты)' -ForegroundColor Cyan
Write-Host '  ════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan
Write-Host ''

$current = Get-CurrentCountry
$target  = ''

if ($current) {
    # фильтр уже активен — самый частый сценарий повторного запуска: снять его
    Write-Host "  Сейчас активен фильтр стран: $current" -ForegroundColor Yellow
    Write-Host ''
    $r = Read-Host '  [Enter] — вернуть рейтинг-режим | c — выбрать другую страну/посмотреть ноды'
    if ($r -notmatch '^[СсCc]') {
        Write-Host ''
        Write-Host '  Снимаю фильтр и возвращаю рейтинг-автовыбор…' -ForegroundColor Cyan
        if (Invoke-Switch '') {
            Write-Host ''
            Check-IP
            Write-Host ''
            Write-Ok 'Готово. Обычный режим (рейтинг) восстановлен.'
        }
        Read-Host '  [Enter] закрыть окно'
        exit 0
    }
    Write-Host ''
}

# выбор целевой страны (и при старте, и при выборе варианта «c» выше)
if ($Country) {
    $target = ($Country -replace '\s+', ' ').Trim().ToUpper()
    if ($target -eq 'US,GB') { $target = 'US, GB' }
    Write-Host "  Целевая страна (из параметра): $target" -ForegroundColor Cyan
} else {
    Write-Host '  Выберите целевую страну выхода на время оплаты:'
    Write-Host '      1) US          2) GB          3) US, GB      4) RU' -ForegroundColor Gray
    Write-Host '      или просто введите свою (например NL, FR, SE)' -ForegroundColor Gray
    Write-Host ''
    $reply = Read-Host '  Страна'
    switch -Regex ($reply.Trim()) {
        '^1$' { $target = 'US' }
        '^2$' { $target = 'GB' }
        '^3$' { $target = 'US, GB' }
        '^4$' { $target = 'RU' }
        default { $target = ($reply -replace '\s+', ' ') -replace '^[^A-Za-z0-9]*', '' }
    }
    $target = $target.Trim().ToUpper()
    if ($target -eq 'US,GB') { $target = 'US, GB' }
}
if ($target -and $target -notmatch '^[A-Z0-9]+(, ?[A-Z0-9]+)*$') {
    Write-Err "Некорректный формат страны: '$target' (пример: US или NL, FR)"
    Read-Host '  [Enter] закрыть окно'
    exit 1
}
if (-not $target) {
    Write-Warn 'Страна не задана — нечего включать. Завершаю.'
    Read-Host '  [Enter] закрыть окно'
    exit 1
}

# ── предпросмотр нод ────────────────────────────────────────────────────────
Write-Host ''
Write-Host "  Предпросмотр для стран: $target`n" -ForegroundColor Cyan
$ok = Show-Preview $target
if (-not $ok) {
    Read-Host '  [Enter] закрыть окно'
    exit 1
}

# ── подтверждение включения ─────────────────────────────────────────────────
Write-Host ''
$c = Read-Host ("  Включить фильтр '$target' и перезапустить VPN? [y/N]")
if ($c -notmatch '^[YyДд]') {
    Write-Warn 'Ничего не менял. Окно закроется.'
    Read-Host '  [Enter] закрыть окно'
    exit 0
}

Write-Host ''
if (-not (Invoke-Switch $target)) {
    Read-Host '  [Enter] закрыть окно'
    exit 1
}
Write-Host ''
Check-IP
Write-Host ''
Write-Ok "VPN работает через ноды стран: $target"

# ═══════════════════════════════════════════════════════════════════════════
# «пауза» пока занимаетесь делом — окно висит, клиент уже в нужной стране
# ═══════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '  ────────────────────────────────────────────────────────────' -ForegroundColor DarkCyan
Write-Host '   Делайте свои дела (оплата, проверка ip: curl ifconfig.io/ip).' -ForegroundColor Gray
Write-Host '   Клиент работает с фильтром. Окно не закрывайте.' -ForegroundColor Gray
Write-Host '  ────────────────────────────────────────────────────────────' -ForegroundColor DarkCyan
Write-Host ''
$r2 = Read-Host '  [Enter] — завершить и вернуть рейтинг-режим | q — закрыть, оставив фильтр'
if ($r2 -notmatch '^[QqКк]') {
    Write-Host ''
    Write-Host '  Возвращаю обычный режим (рейтинг-автовыбор)…' -ForegroundColor Cyan
    if (Invoke-Switch '') {
        Write-Host ''
        Check-IP
        Write-Host ''
        Write-Ok 'Готово. Фильтр снят, клиент перезапущен.'
    }
} else {
    Write-Warn "Фильтр '$target' остаётся активным."
    Write-Host '  Снять позже: запустите ярлык «VPN страна выхода (оплата)» → [Enter].'
}
Write-Host ''
Read-Host '  [Enter] закрыть окно'

exit 0