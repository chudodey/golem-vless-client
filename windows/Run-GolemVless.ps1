$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdoutLog = Join-Path $root "state\sing-box-$stamp.out.log"
$stderrLog = Join-Path $root "state\sing-box-$stamp.err.log"
# Log rotation: every run creates sing-box-<ts>.{out,err}.log (+ xray-*.log),
# which never get cleaned on their own — state ballooned to ~150 MB / 80 files
# before B-014. Keep only the newest $keep files, delete the rest.
$keep = 20
Get-ChildItem -LiteralPath (Join-Path $root 'state') -Filter 'sing-box-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $keep |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
Get-ChildItem -LiteralPath (Join-Path $root 'state') -Filter 'xray-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $keep |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
try {
  # Capture the physical default route before creating our TUN. Explicitly
  # binding outbounds to it prevents direct traffic from being routed back
  # into GolemTUN on Windows.
  $uplinkArgs = @()
  # Физический адаптер с default route, переопределяется при каждом старте.
  # Исключаем все TUN и виртуальные адаптеры, чтобы прямой трафик не замкнулся
  # в GolemTUN. auto_detect_interface в одиночку на Windows не надёжен: без
  # явной привязки к интерфейсу весь трафик (даже direct) зацикливается.
  # Берём uplink с наименьшей метрикой (это основной физический адаптер).
  $uplinks = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | ForEach-Object {
    $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $adapter -or $adapter.Status -ne 'Up') { return }
    if ($adapter.Name -notmatch 'golem|durev|sing' -and
        $adapter.InterfaceDescription -notmatch 'sing-tun|hyper-v|virtual|vethernet|wsl|loopback|tap|wireguard|tunnel') {
      [pscustomobject]@{ Name = $adapter.Name; Metric = [int]$_.RouteMetric }
    }
  } | Sort-Object Metric
  if ($uplinks) {
    $uplinkArgs = @('--default-interface', $uplinks[0].Name)
  }
  # Do not merge native stderr into PowerShell's error stream: the renderer
  # intentionally writes INFO diagnostics there, and $ErrorActionPreference
  # would otherwise turn a successful render into a terminating exception.
  # PowerShell 7 turns *any* native stderr into an exception under `Stop`,
  # even when redirected. These tools use stderr for harmless INFO messages,
  # so temporarily use Continue and decide by their real exit status instead.
  $ErrorActionPreference = 'Continue'
  & python "$root\bin\render_config.py" --endpoints "$root\config\endpoints.txt" --policy "$root\config\policy.conf" --out "$root\state\config.json" --state-dir "$root\state" --fetch --no-rule-sets --tun-stack mixed --mixed-port 2080 --xray-port 2081 --log-level warn @uplinkArgs 1>> $stdoutLog 2>> $stderrLog
  $exitCode = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
  if ($exitCode -ne 0) { throw "config render failed: $exitCode" }

  # Xray-core handles xhttp/splithttp nodes sing-box cannot dial at all (see
  # docs/backlog.yaml B-007). render_config.py writes state\xray-config.json
  # only when the surviving node pool actually needs it — its presence is
  # the sole signal for whether to start xray.exe here. sing-box's
  # "xray-pool" socks outbound (127.0.0.1:2081) depends on this being up
  # first: start it, wait for the port, then hand off to sing-box.
  $xrayConfig = "$root\state\xray-config.json"
  Get-Process xray -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $xrayConfig) {
    $xrayOutLog = Join-Path $root "state\xray-$stamp.out.log"
    $xrayErrLog = Join-Path $root "state\xray-$stamp.err.log"
    $ErrorActionPreference = 'Continue'
    & "$root\bin\xray.exe" run -test -config $xrayConfig 1>> $xrayOutLog 2>> $xrayErrLog
    $exitCode = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) { throw "xray config check failed: $exitCode" }

    Start-Process -FilePath "$root\bin\xray.exe" -ArgumentList @('run', '-config', $xrayConfig) `
      -WindowStyle Hidden -RedirectStandardOutput $xrayOutLog -RedirectStandardError $xrayErrLog
    $deadline = (Get-Date).AddSeconds(10)
    $up = $false
    while ((Get-Date) -lt $deadline) {
      if (Test-NetConnection -ComputerName 127.0.0.1 -Port 2081 -InformationLevel Quiet -WarningAction SilentlyContinue) { $up = $true; break }
      Start-Sleep -Milliseconds 300
    }
    if (-not $up) {
      "$(Get-Date -Format o) WARN: xray did not open :2081 within 10s — sing-box will still start, xray-pool nodes just lose the first urltest race" |
        Out-File -Append -Encoding utf8 $stderrLog
    }
  }

  $ErrorActionPreference = 'Continue'
  & "$root\bin\sing-box.exe" check -c "$root\state\config.json" 1>> $stdoutLog 2>> $stderrLog
  $exitCode = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
  if ($exitCode -ne 0) { throw "sing-box check failed: $exitCode" }
  $ErrorActionPreference = 'Continue'
  & "$root\bin\sing-box.exe" run -c "$root\state\config.json" 1>> $stdoutLog 2>> $stderrLog
} catch { "$(Get-Date -Format o) ERROR: $($_.Exception.Message)" | Out-File -Append -Encoding utf8 $stderrLog; exit 1 }
