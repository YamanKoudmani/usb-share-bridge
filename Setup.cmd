@echo off
REM ================================================================
REM  USB Share Bridge - one-click setup
REM
REM  Why a batch file? PowerShell's execution policy blocks unsigned
REM  scripts extracted from a ZIP download, but batch files are exempt,
REM  so this runs with a plain double-click.
REM ================================================================
setlocal

REM Already elevated?
net session >nul 2>&1
if "%errorlevel%"=="0" goto :install

echo Requesting administrator access (approve the UAC prompt)...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:install
cd /d "%~dp0"

echo [1/3] Clearing the "downloaded from internet" marker from extracted files...
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File"
if not "%errorlevel%"=="0" echo        Nothing to unblock - continuing.

echo.
echo [2/3] Installing usbipd-win (via winget) and the USB Share Bridge app...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\Install.ps1" -LaunchGui
if not "%errorlevel%"=="0" goto :failed

echo.
echo [3/3] Done. The GUI is opening (if not: Start Menu - "USB Share Bridge").
echo You can delete this downloaded folder now.
timeout /t 10 >nul
exit /b 0

:failed
echo.
echo Setup failed. Common causes:
echo   - winget could not find the package - run "winget source update", then retry
echo   - no winget - install usbipd-win from https://github.com/dorssel/usbipd-win/releases
echo.
pause
exit /b 1
