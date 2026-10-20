# Build Coucou in release mode on the Windows disk and drop Coucou.exe on the desktop.
# Works from Windows (PowerShell) and from WSL (via `make release`).
$ErrorActionPreference = 'Stop'

$repo  = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$build = Join-Path $env:USERPROFILE 'coucou-build'
$win   = Join-Path $build 'windows'

Write-Host "==> Sync $repo -> $build"
robocopy $repo $build /MIR /XD node_modules target .git /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

Set-Location $win
Write-Host '==> npm install'
npm.cmd install
if ($LASTEXITCODE) { throw 'npm install failed' }

Write-Host '==> tauri build (release, no installer)'
npx.cmd tauri build --no-bundle
if ($LASTEXITCODE) { throw 'tauri build failed' }

$exe     = Join-Path $win 'target\release\coucou.exe'
$desktop = [Environment]::GetFolderPath('Desktop')
$dest    = Join-Path $desktop 'Coucou.exe'
Get-Process coucou -ErrorAction SilentlyContinue | Stop-Process -Force
Copy-Item $exe $dest -Force
Write-Host "==> Done: $dest"
