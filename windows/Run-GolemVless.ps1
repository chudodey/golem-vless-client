$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdoutLog = Join-Path $root "state\sing-box-$stamp.out.log"
$stderrLog = Join-Path $root "state\sing-box-$stamp.err.log"
try {
  # Do not merge native stderr into PowerShell's error stream: the renderer
  # intentionally writes INFO diagnostics there, and $ErrorActionPreference
  # would otherwise turn a successful render into a terminating exception.
  # PowerShell 7 turns *any* native stderr into an exception under `Stop`,
  # even when redirected. These tools use stderr for harmless INFO messages,
  # so temporarily use Continue and decide by their real exit status instead.
  $ErrorActionPreference = 'Continue'
  & python "$root\bin\render_config.py" --endpoints "$root\config\endpoints.txt" --policy "$root\config\policy.conf" --out "$root\state\config.json" --state-dir "$root\state" --fetch --tun-stack mixed --log-level warn 1>> $stdoutLog 2>> $stderrLog
  $exitCode = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
  if ($exitCode -ne 0) { throw "config render failed: $exitCode" }
  $ErrorActionPreference = 'Continue'
  & "$root\bin\sing-box.exe" check -c "$root\state\config.json" 1>> $stdoutLog 2>> $stderrLog
  $exitCode = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
  if ($exitCode -ne 0) { throw "sing-box check failed: $exitCode" }
  $ErrorActionPreference = 'Continue'
  & "$root\bin\sing-box.exe" run -c "$root\state\config.json" 1>> $stdoutLog 2>> $stderrLog
} catch { "$(Get-Date -Format o) ERROR: $($_.Exception.Message)" | Out-File -Append -Encoding utf8 $stderrLog; exit 1 }
