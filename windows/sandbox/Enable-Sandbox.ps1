$ErrorActionPreference = 'Stop'
$resultDir = Join-Path $env:LOCALAPPDATA 'GolemVLESS\sandbox'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
$resultPath = Join-Path $resultDir 'enable-result.txt'
try {
  $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM'
  if ($feature.State -ne 'Enabled') {
    $change = Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All -NoRestart
    "State: $($change.State)`nRestartNeeded: $($change.RestartNeeded)" | Set-Content -Encoding utf8 $resultPath
  } else {
    "State: Enabled`nRestartNeeded: False" | Set-Content -Encoding utf8 $resultPath
  }
} catch {
  "ERROR: $($_.Exception.Message)" | Set-Content -Encoding utf8 $resultPath
  throw
}
