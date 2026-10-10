# Gives the installed Coucou a package identity, so Windows lets it read
# notifications (Phone Link's iPhone calls and messages included).
#
#   powershell -ExecutionPolicy Bypass -File identity\make-identity.ps1
#
# It builds a "sparse" package (no files of its own, only an identity for the
# coucou.exe already installed), signs it with a self-signed certificate made
# for this PC, and prints the two commands that trust and register it.
param(
  # Where coucou.exe is installed (the folder, not the exe).
  [string]$InstallDir = ""
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here "out"
New-Item -ItemType Directory -Force $out | Out-Null

if (-not $InstallDir) {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA "Coucou"),
    (Join-Path $env:LOCALAPPDATA "Programs\Coucou"),
    (Join-Path $env:ProgramFiles "Coucou")
  )
  $InstallDir = $candidates | Where-Object { Test-Path (Join-Path $_ "coucou.exe") } | Select-Object -First 1
}
if (-not $InstallDir -or -not (Test-Path (Join-Path $InstallDir "coucou.exe"))) {
  throw "coucou.exe not found. Install Coucou first, or pass -InstallDir 'C:\path\to\folder'."
}

$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
  Where-Object { Test-Path (Join-Path $_.FullName "x64\makeappx.exe") } |
  Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdk) { throw "Windows SDK not found (makeappx.exe). Install the Windows 10/11 SDK." }
$makeappx = Join-Path $sdk.FullName "x64\makeappx.exe"
$signtool = Join-Path $sdk.FullName "x64\signtool.exe"

# A certificate for this PC only, kept in your personal store.
$subject = "CN=Coucou Windows Plus"
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject } | Select-Object -First 1
if (-not $cert) {
  $cert = New-SelfSignedCertificate -Type Custom -Subject $subject -KeyUsage DigitalSignature `
    -FriendlyName "Coucou Windows Plus (local)" -CertStoreLocation Cert:\CurrentUser\My `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
}
$cer = Join-Path $out "CoucouWindowsPlus.cer"
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

$msix = Join-Path $out "CoucouWindowsPlus.msix"
$staging = Join-Path $out "pkg"
Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $staging | Out-Null
Copy-Item (Join-Path $here "AppxManifest.xml"), (Join-Path $here "logo.png") $staging
& $makeappx pack /o /d $staging /p $msix /nv | Out-Null
& $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $msix | Out-Null

Write-Host ""
Write-Host "Built and signed: $msix" -ForegroundColor Green
Write-Host ""
Write-Host "1) In a PowerShell opened as Administrator, trust the certificate (once):" -ForegroundColor Cyan
Write-Host "   Import-Certificate -FilePath `"$cer`" -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
Write-Host ""
Write-Host "2) In a normal PowerShell, register the identity for the installed Coucou:" -ForegroundColor Cyan
Write-Host "   Add-AppxPackage -Path `"$msix`" -ExternalLocation `"$InstallDir`""
Write-Host ""
Write-Host "3) Restart Coucou, turn on Settings -> iPhone -> Notifications in the island, and click Allow."
