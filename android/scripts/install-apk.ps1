$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$AndroidDir = Split-Path -Parent $ScriptDir

$AdbExe = Join-Path $AndroidDir ".sdk\platform-tools\adb.exe"
if (-not (Test-Path $AdbExe)) {
    if (Get-Command "adb.exe" -ErrorAction SilentlyContinue) {
        $AdbExe = "adb.exe"
    } else {
        Write-Host "[ERROR] adb.exe not found." -ForegroundColor Red
        exit 1
    }
}

$ApkPath = Join-Path $AndroidDir "app\build\outputs\apk\release\app-release.apk"
if (-not (Test-Path $ApkPath)) {
    Write-Host "[ERROR] app-release.apk not found at $ApkPath" -ForegroundColor Red
    Write-Host "Please run scripts\build-apk.bat first." -ForegroundColor Yellow
    exit 1
}

Write-Host "Checking connected Android devices..." -ForegroundColor Cyan
& $AdbExe devices

Write-Host "`nInstalling Coucou release APK ($ApkPath)..." -ForegroundColor Cyan
& $AdbExe install -r $ApkPath

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n==============================================" -ForegroundColor Green
    Write-Host "   Coucou APK installed successfully!         " -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
} else {
    Write-Host "`n[ERROR] Installation failed. Ensure your phone has USB debugging enabled and is authorized." -ForegroundColor Red
}
