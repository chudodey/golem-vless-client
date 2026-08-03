$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdoutLog = Join-Path $root "state\sing-box-$stamp.out.log"
$stderrLog = Join-Path $root "state\sing-box-$stamp.err.log"
try {
  # Capture the physical default route before creating our TUN. Explicitly
  # binding outbounds to it prevents direct traffic from being routed back
  # into GolemTUN on Windows.
  $uplink = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | ForEach-Object {
    $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Name -notmatch 'Golem|Durev|sing' -and $adapter.InterfaceDescription -notmatch 'sing-tun') { [pscustomobject]@{ Name=$adapter.Name; Metric=$_.RouteMetric } }
  } | Sort-Object Metric | Select-Object -First 1
  if (-not $uplink) { throw 'Не найден физический сетевой адаптер с default route.' }
  # Do not merge native stderr into PowerShell's error stream: the renderer
  # intentionally writes INFO diagnostics there, and $ErrorActionPreference
  # would otherwise turn a successful render into a terminating exception.
  # PowerShell 7 turns *any* native stderr into an exception under `Stop`,
  # even when redirected. These tools use stderr for harmless INFO messages,
  # so temporarily use Continue and decide by their real exit status instead.
  $ErrorActionPreference = 'Continue'
  & python "$root\bin\render_config.py" --endpoints "$root\config\endpoints.txt" --policy "$root\config\policy.conf" --out "$root\state\config.json" --state-dir "$root\state" --fetch --tun-stack mixed --mixed-port 2080 --log-level warn --default-interface $uplink.Name 1>> $stdoutLog 2>> $stderrLog
  $exitCode = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
  if ($exitCode -ne 0) { throw "config render failed: $exitCode" }
  $ErrorActionPreference = 'Continue'
  & "$root\bin\sing-box.exe" check -c "$root\state\config.json" 1>> $stdoutLog 2>> $stderrLog
  $exitCode = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
  if ($exitCode -ne 0) { throw "sing-box check failed: $exitCode" }
  $ErrorActionPreference = 'Continue'
  & "$root\bin\sing-box.exe" run -c "$root\state\config.json" 1>> $stdoutLog 2>> $stderrLog
} catch { "$(Get-Date -Format o) ERROR: $($_.Exception.Message)" | Out-File -Append -Encoding utf8 $stderrLog; exit 1 }
