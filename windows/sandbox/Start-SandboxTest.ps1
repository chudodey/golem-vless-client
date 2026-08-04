$ErrorActionPreference = 'Continue'
$result = 'C:\GolemResults\report.txt'
$out = 'C:\GolemResults\sing-box.out.log'
$err = 'C:\GolemResults\sing-box.err.log'
"Golem Sandbox test $(Get-Date -Format o)" | Set-Content -Encoding utf8 $result
try {
  $p = Start-Process 'C:\GolemSandbox\sing-box.exe' -ArgumentList 'run','-c','C:\GolemSandbox\config.json' -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  Start-Sleep -Seconds 8
  $ip = & curl.exe --proxy http://127.0.0.1:2080 --max-time 20 -fsS https://ifconfig.io/ip 2>$null
  "Process running: $(-not $p.HasExited)" | Add-Content $result
  "VPN IP: $ip" | Add-Content $result
  if ($p.HasExited) { "Exit code: $($p.ExitCode)" | Add-Content $result }
} catch { "ERROR: $($_.Exception.Message)" | Add-Content $result }
finally { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
if (Test-Path $err) { '--- sing-box stderr ---' | Add-Content $result; Get-Content -Tail 80 $err | Add-Content $result }
