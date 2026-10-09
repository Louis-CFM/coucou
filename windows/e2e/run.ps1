$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$binary = Join-Path $root 'target\debug\coucou.exe'

if (Get-Process -Name coucou -ErrorAction SilentlyContinue) {
  throw 'Quit the running Coucou before E2E; the single-instance lock would reuse it.'
}

Push-Location $root
try {
  if (-not (Test-Path -LiteralPath 'e2e\node_modules\.bin\wdio.cmd')) {
    npm --prefix e2e install --offline=false
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the E2E test dependencies.' }
  }
  npm run build
  if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed.' }
  cargo build --workspace
  if ($LASTEXITCODE -ne 0) { throw 'Debug app build failed.' }

  $profile = Join-Path $root ('target\e2e-profile-' + [guid]::NewGuid().ToString('N'))
  $env:APPDATA = Join-Path $profile 'Roaming'
  $env:LOCALAPPDATA = Join-Path $profile 'Local'
  $env:COUCOU_AUTO_QUIT_TEST = '1'
  New-Item -ItemType Directory -Path $env:APPDATA, $env:LOCALAPPDATA -Force | Out-Null
  Write-Host "E2E profile: $profile"

  & 'e2e\node_modules\.bin\wdio.cmd' run 'e2e\wdio.conf.mjs'
  if ($LASTEXITCODE -ne 0) { throw "E2E failed; inspect $profile\Local\Coucou\coucou.log" }
}
finally {
  Get-Process -Name coucou -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $binary } |
    Stop-Process -Force
  Pop-Location
}
