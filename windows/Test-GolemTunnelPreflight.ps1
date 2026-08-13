# Safety preflight shared by manual start, scheduled runner and watchdog.
# It never stops a foreign VPN: it only reports the conflict and returns exit 2.
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$eventsPath = Join-Path $root 'state\connection-events.jsonl'

function Write-ConnectionEvent([hashtable]$data) {
    try {
        $data.timestamp = (Get-Date).ToString('o')
        ($data | ConvertTo-Json -Compress) | Out-File -LiteralPath $eventsPath -Append -Encoding utf8
    } catch {}
}

$foreignProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '^(Durev VPN|durev|happ|happd|hiddify|nekoray|clash|v2ray|openvpn|wireguard|outline|warp)$'
} | Select-Object -ExpandProperty ProcessName -Unique)
$foreignAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
    # Golem's own TUN is named golem-tun / described as sing-tun — never treat
    # it as a foreign VPN, or the watchdog blocks every restart as a "conflict".
    $_.Name -ne 'golem-tun' -and $_.Name -notmatch 'golem|sing' -and
    $_.InterfaceDescription -notmatch 'golem|sing-tun' -and
    $_.Status -eq 'Up' -and (
        $_.Name -match 'durev|happ|hiddify|nekoray|clash|v2ray|openvpn|wireguard|outline|warp' -or
        $_.InterfaceDescription -match 'durev|happ|hiddify|nekoray|clash|v2ray|openvpn|wireguard|outline|warp'
    )
} | ForEach-Object { "$($_.Name) [$($_.InterfaceDescription)]" })

if ($foreignProcesses.Count -gt 0 -or $foreignAdapters.Count -gt 0) {
    $details = @()
    if ($foreignProcesses.Count -gt 0) { $details += "processes: $($foreignProcesses -join ', ')" }
    if ($foreignAdapters.Count -gt 0) { $details += "adapters: $($foreignAdapters -join '; ')" }
    $message = 'Foreign VPN/TUN detected — Golem did not start or restart. ' + ($details -join ' | ')
    Write-ConnectionEvent @{ action = 'preflight_blocked'; message = $message; foreign_processes = $foreignProcesses; foreign_adapters = $foreignAdapters }
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  [XX] Обнаружен другой активный VPN/TUN. Golem ничего не менял.' -ForegroundColor Red
        $details | ForEach-Object { Write-Host "       $_" -ForegroundColor Yellow }
        Write-Host '       Закройте Durev/Happ, дождитесь исчезновения их туннеля и повторите запуск.' -ForegroundColor Yellow
    }
    exit 2
}

Write-ConnectionEvent @{ action = 'preflight_ok'; message = 'No foreign VPN/TUN detected; Golem may start.' }
if (-not $Quiet) { Write-Host '  [OK] Других активных VPN/TUN не обнаружено.' -ForegroundColor Green }
exit 0
