<#
.SYNOPSIS
    Builds the production release APK for Coucou Android.
.DESCRIPTION
    Verifies JDK 17, Android SDK, configures release signing, runs Gradle assembleRelease,
    applies R8 minification/obfuscation, strips debug logs, and outputs the final production APK.
#>
param(
    [switch]$GenerateKeystore = $false
)

$ErrorActionPreference = "Continue"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AndroidDir = Split-Path -Parent $ScriptDir
Set-Location $AndroidDir

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Coucou Android - Production APK Builder" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Detect / Configure Java (JDK 17)
if (-not $env:JAVA_HOME) {
    $CommonJdks = @(
        "C:\Program Files\Android\Android Studio\jbr",
        "C:\Program Files\Eclipse Adoptium\jdk-17*",
        "C:\Program Files\Microsoft\jdk-17*",
        "C:\Program Files\Java\jdk-17*",
        "C:\Program Files\Java\jdk-21*"
    )
    foreach ($pattern in $CommonJdks) {
        $found = Get-Item $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found -and (Test-Path "$($found.FullName)\bin\java.exe")) {
            $env:JAVA_HOME = $found.FullName
            Write-Host "Found JDK at: $env:JAVA_HOME" -ForegroundColor Green
            break
        }
    }
}

if (-not $env:JAVA_HOME -or -not (Test-Path "$env:JAVA_HOME\bin\java.exe")) {
    Write-Host "ERROR: JDK 17+ is required to build the Android APK." -ForegroundColor Red
    Write-Host "Please install OpenJDK 17 via:" -ForegroundColor Yellow
    Write-Host "    winget install Microsoft.OpenJDK.17" -ForegroundColor White
    Write-Host "or set `$env:JAVA_HOME to your JDK 17 directory." -ForegroundColor White
    exit 1
}

$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
$javaExe = "$env:JAVA_HOME\bin\java.exe"
$keytoolExe = "$env:JAVA_HOME\bin\keytool.exe"

# java -version writes to stderr by design
$tempVer = Join-Path $env:TEMP "coucou_java_ver.txt"
& $javaExe -version 2> $tempVer
$firstVerLine = if (Test-Path $tempVer) { (Get-Content $tempVer | Select-Object -First 1) } else { "JDK 17" }
Write-Host "Using Java: $firstVerLine" -ForegroundColor Gray

# 2. Detect or Auto-Provision Android SDK
function Test-ValidSdk($dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return $false }
    return (Test-Path "$dir\platforms") -or (Test-Path "$dir\cmdline-tools\latest\bin\sdkmanager.bat")
}

$SdkFound = $null

if ($env:ANDROID_HOME -and (Test-ValidSdk $env:ANDROID_HOME)) {
    $SdkFound = $env:ANDROID_HOME
} elseif ($env:ANDROID_SDK_ROOT -and (Test-ValidSdk $env:ANDROID_SDK_ROOT)) {
    $SdkFound = $env:ANDROID_SDK_ROOT
}

if (-not $SdkFound) {
    $PotentialPaths = @(
        "$env:LOCALAPPDATA\Android\Sdk",
        "$env:ProgramFiles\Android\android-sdk",
        "C:\Android\sdk",
        "$AndroidDir\.sdk"
    )
    foreach ($path in $PotentialPaths) {
        if (Test-ValidSdk $path) {
            $SdkFound = $path
            break
        }
    }
}

# Auto-provision if no Android SDK exists
if (-not $SdkFound) {
    $SdkTargetDir = "$AndroidDir\.sdk"
    Write-Host "Android SDK not found. Auto-provisioning local Android SDK at: $SdkTargetDir" -ForegroundColor Yellow

    # Clean up any partial or broken previous installation
    if (Test-Path $SdkTargetDir) {
        Remove-Item -Recurse -Force $SdkTargetDir -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $SdkTargetDir -Force | Out-Null

    $CmdlineZipUrl = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip"
    $ZipPath = Join-Path $SdkTargetDir "cmdline-tools.zip"

    Write-Host "Downloading Google Android Command Line Tools (~130 MB)..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $CmdlineZipUrl -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Please ensure you have an active internet connection." -ForegroundColor Yellow
        exit 1
    }

    if (-not (Test-Path $ZipPath) -or (Get-Item $ZipPath).Length -lt 1000) {
        Write-Host "ERROR: Downloaded tools archive is invalid or missing." -ForegroundColor Red
        exit 1
    }

    Write-Host "Extracting Command Line Tools..." -ForegroundColor Cyan
    $ExtractTemp = Join-Path $SdkTargetDir "cmdline_temp"
    if (Test-Path $ExtractTemp) { Remove-Item -Recurse -Force $ExtractTemp }
    New-Item -ItemType Directory -Path $ExtractTemp -Force | Out-Null

    $extracted = $false
    # Method 1: Built-in Windows tar.exe (fast, reliable, handles zip natively)
    if (Get-Command "tar.exe" -ErrorAction SilentlyContinue) {
        & tar.exe -xf "$ZipPath" -C "$ExtractTemp" 2>&1 | Out-Null
        if (Test-Path "$ExtractTemp\cmdline-tools") {
            $extracted = $true
        }
    }

    # Method 2: .NET ZipFile fallback (standard 2-argument API)
    if (-not $extracted) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $ExtractTemp)
        if (Test-Path "$ExtractTemp\cmdline-tools") {
            $extracted = $true
        }
    }

    if (-not $extracted) {
        Write-Host "ERROR: Could not extract Command Line Tools archive." -ForegroundColor Red
        exit 1
    }

    $LatestDir = Join-Path $SdkTargetDir "cmdline-tools\latest"
    $ParentDir = Split-Path -Parent $LatestDir
    if (-not (Test-Path $ParentDir)) {
        New-Item -ItemType Directory -Path $ParentDir -Force | Out-Null
    }
    if (Test-Path $LatestDir) { Remove-Item -Recurse -Force $LatestDir }

    Move-Item -Path "$ExtractTemp\cmdline-tools" -Destination $LatestDir -Force
    Remove-Item -Recurse -Force $ExtractTemp
    Remove-Item -Force $ZipPath

    $SdkFound = $SdkTargetDir
    Write-Host "Command Line Tools unpacked successfully." -ForegroundColor Green
}

$env:ANDROID_HOME = $SdkFound
$env:ANDROID_SDK_ROOT = $SdkFound

# Pre-seed Accepted Android SDK Licenses
$LicensesDir = Join-Path $env:ANDROID_HOME "licenses"
if (-not (Test-Path $LicensesDir)) {
    New-Item -ItemType Directory -Path $LicensesDir -Force | Out-Null
}

$KnownLicenses = @{
    "android-sdk-license" = @(
        "8933bad161af4178b1185d1a37fbf41ea5269c55",
        "d56f5187479451eabf01fb78af6dfcb131a6481e",
        "24333f8a6351dd792de57de7861e804d82641afc"
    )
    "android-sdk-preview-license" = @(
        "84831b9409646a226e73ac49875ff9e123814e4e"
    )
    "android-googletv-license" = @(
        "601085b94cd77f0b54ff86406957099fed7926d4"
    )
    "android-sdk-arm-dbt-license" = @(
        "859f317696e35e288c505046fc371f8f23fb04ac"
    )
    "google-gdk-license" = @(
        "33b6a2b649200204f14e9638674c6d37672e4526"
    )
    "mips-android-sysimage-license" = @(
        "e9acab5b5fbb560a72cfa4f6d0ee0da0df705f65"
    )
}

foreach ($licFile in $KnownLicenses.Keys) {
    $licPath = Join-Path $LicensesDir $licFile
    $content = ($KnownLicenses[$licFile] -join "`n") + "`n"
    Set-Content -Path $licPath -Value $content -NoNewline
}
Write-Host "Configured accepted Android SDK licenses." -ForegroundColor Green

# Check and install required SDK components: Platform 35 and Build-Tools 35.0.0
$SdkManagerBat = Join-Path $env:ANDROID_HOME "cmdline-tools\latest\bin\sdkmanager.bat"
if (-not (Test-Path $SdkManagerBat)) {
    $FoundManager = Get-ChildItem -Path $env:ANDROID_HOME -Filter "sdkmanager.bat" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($FoundManager) {
        $SdkManagerBat = $FoundManager.FullName
    }
}

$HasPlatform35 = Test-Path "$env:ANDROID_HOME\platforms\android-35"
$HasBuildTools35 = Test-Path "$env:ANDROID_HOME\build-tools\35.0.0"

if ((-not $HasPlatform35 -or -not $HasBuildTools35) -and (Test-Path $SdkManagerBat)) {
    Write-Host "Installing Android SDK Platform 35 & Build-Tools 35.0.0..." -ForegroundColor Yellow
    & $SdkManagerBat --sdk_root="$env:ANDROID_HOME" "platforms;android-35" "build-tools;35.0.0"
}

# Update or generate local.properties (using forward slashes for cross-platform Gradle safety)
$NormSdk = $env:ANDROID_HOME.Replace("\", "/")
Set-Content -Path "$AndroidDir\local.properties" -Value "sdk.dir=$NormSdk"
Write-Host "Configured Android SDK at: $env:ANDROID_HOME" -ForegroundColor Green

# 3. Release Keystore Generation / Verification
$KeystorePath = "$AndroidDir\app\release.keystore"
if ($GenerateKeystore -or (-not (Test-Path $KeystorePath) -and -not $env:COUCOU_KEYSTORE_FILE)) {
    if (-not (Test-Path $KeystorePath)) {
        Write-Host "Generating local release signing keystore..." -ForegroundColor Yellow
        & $keytoolExe -genkeypair -v `
            -keystore $KeystorePath `
            -alias "coucou" `
            -keyalg RSA `
            -keysize 2048 `
            -validity 10000 `
            -storepass "coucou123" `
            -keypass "coucou123" `
            -dname "CN=Coucou, OU=Coucou Mobile, O=Coucou, L=Paris, ST=IDF, C=FR"
        Write-Host "Release keystore generated at: $KeystorePath" -ForegroundColor Green
    }
}

# 4. Check strings generation
Write-Host "Validating Android localized string resources..." -ForegroundColor Gray
node "$ScriptDir\gen-strings.mjs" --check
if ($LASTEXITCODE -ne 0) {
    Write-Host "Updating Android string resources..." -ForegroundColor Yellow
    node "$ScriptDir\gen-strings.mjs"
}

# 5. Execute Gradle Build
Write-Host "Running Gradle assembleRelease (R8 Minification & Log Stripping)..." -ForegroundColor Cyan
& .\gradlew.bat assembleRelease --no-daemon

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed! Please inspect the Gradle output above." -ForegroundColor Red
    exit $LASTEXITCODE
}

# 6. Locate & Verify Generated APK
$ApkDir = "$AndroidDir\app\build\outputs\apk\release"
$Apks = Get-ChildItem -Path $ApkDir -Filter "*.apk" -ErrorAction SilentlyContinue

if ($Apks) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "   PRODUCTION APK BUILT SUCCESSFULLY!     " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    foreach ($apk in $Apks) {
        $hashStr = ""
        try {
            if (Get-Command "Get-FileHash" -ErrorAction SilentlyContinue) {
                $hashStr = (Get-FileHash -Path $apk.FullName -Algorithm SHA256).Hash
            } else {
                $stream = [System.IO.File]::OpenRead($apk.FullName)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $bytes = $sha.ComputeHash($stream)
                $stream.Close()
                $hashStr = [System.BitConverter]::ToString($bytes).Replace("-", "")
            }
        } catch {
            $hashStr = "N/A"
        }
        $sizeMb = [math]::Round($apk.Length / 1MB, 2)
        Write-Host "File:      $($apk.Name)" -ForegroundColor White
        Write-Host "Path:      $($apk.FullName)" -ForegroundColor White
        Write-Host "Size:      $sizeMb MB ($($apk.Length) bytes)" -ForegroundColor White
        Write-Host "SHA-256:   $hashStr" -ForegroundColor White
    }
    $adbExe = Join-Path $SdkFound "platform-tools\adb.exe"
    if (-not (Test-Path $adbExe)) { $adbExe = "adb" }
    Write-Host ""
    Write-Host "To install on your connected phone via ADB:" -ForegroundColor Gray
    Write-Host "    & `"$adbExe`" install -r `"$($Apks[0].FullName)`"" -ForegroundColor Cyan
    Write-Host "Or run the one-click installer:" -ForegroundColor Gray
    Write-Host "    scripts\install-apk.bat" -ForegroundColor Cyan
    Write-Host "Or transfer directly to your phone via Coudrop!" -ForegroundColor Gray
} else {
    Write-Host "Warning: Build finished, but no APK found in $ApkDir" -ForegroundColor Yellow
}
