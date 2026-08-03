$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'GolemVLESS'
python "$root\bin\render_config.py" --endpoints "$root\config\endpoints.txt" --policy "$root\config\policy.conf" --out "$root\state\config.json" --state-dir "$root\state" --fetch --tun-stack mixed
& "$root\bin\sing-box.exe" check -c "$root\state\config.json"
& "$root\bin\sing-box.exe" run -c "$root\state\config.json"
