@echo off
setlocal
cd /d "%~dp0\.."

set "ADB_PATH=%CD%\.sdk\platform-tools\adb.exe"
if not exist "%ADB_PATH%" (
    where adb >nul 2>nul
    if %ERRORLEVEL% equ 0 (
        set "ADB_PATH=adb"
    ) else (
        echo [ERROR] adb.exe not found in .sdk\platform-tools or system PATH.
        exit /b 1
    )
)

set "APK_PATH=%CD%\app\build\outputs\apk\release\app-release.apk"
if not exist "%APK_PATH%" (
    echo [ERROR] app-release.apk not found at %APK_PATH%
    echo Please run scripts\build-apk.bat first.
    exit /b 1
)

echo Checking connected Android devices...
"%ADB_PATH%" devices
echo.
echo Installing Coucou release APK...
"%ADB_PATH%" install -r "%APK_PATH%"

if %ERRORLEVEL% equ 0 (
    echo.
    echo ==============================================
    echo    Coucou APK installed successfully!
    echo ==============================================
) else (
    echo.
    echo [ERROR] Installation failed. Ensure your phone has USB debugging enabled and is authorized.
)

exit /b %ERRORLEVEL%
