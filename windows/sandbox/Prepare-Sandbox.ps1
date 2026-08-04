[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$clientRoot = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
$sandboxRoot = Join-Path $clientRoot 'sandbox'
$results = Join-Path $sandboxRoot 'results'
$secret = Join-Path $source 'secrets\endpoints.txt'
if (-not (Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue)) {
  throw 'Windows Sandbox не включён. Запустите windows\sandbox\Enable-Sandbox.ps1 от администратора и перезагрузите ПК.'
}
if (-not (Test-Path $secret)) { throw "Не найден локальный ключ Dell: $secret" }
if (-not (Test-Path "$clientRoot\bin\sing-box.exe")) { throw 'Сначала выполните Install-GolemVless.ps1.' }

New-Item -ItemType Directory -Force -Path $sandboxRoot,$results | Out-Null
Copy-Item -Force "$clientRoot\bin\sing-box.exe" "$sandboxRoot\sing-box.exe"
Copy-Item -Force (Join-Path $PSScriptRoot 'Start-SandboxTest.ps1') "$sandboxRoot\Start-SandboxTest.ps1"
$ErrorActionPreference = 'Continue'
& python "$source\scripts\render_config.py" --endpoints $secret --policy "$source\policy.conf" --out "$sandboxRoot\config.json" --state-dir 'C:\GolemResults' --fetch --no-tun --no-rule-sets --mixed-port 2080 --log-level warn 1>> "$sandboxRoot\prepare.out.log" 2>> "$sandboxRoot\prepare.err.log"
$exitCode = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
if ($exitCode -ne 0) { throw "Не удалось подготовить sandbox-конфиг (код $exitCode)." }

$escapedRoot = [Security.SecurityElement]::Escape($sandboxRoot)
$escapedResults = [Security.SecurityElement]::Escape($results)
@"
<Configuration>
  <Networking>Enable</Networking>
  <VGpu>Disable</VGpu>
  <MappedFolders>
    <MappedFolder><HostFolder>$escapedRoot</HostFolder><SandboxFolder>C:\GolemSandbox</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$escapedResults</HostFolder><SandboxFolder>C:\GolemResults</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File C:\GolemSandbox\Start-SandboxTest.ps1</Command></LogonCommand>
</Configuration>
"@ | Set-Content -Encoding utf8 "$sandboxRoot\Golem-VPN-Test.wsb"
Write-Host "Sandbox готов: $sandboxRoot\Golem-VPN-Test.wsb"
Write-Host "После закрытия Sandbox отчёт: $results\report.txt"
