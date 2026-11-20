# Installs USB Share Bridge on the Windows USB host.
# - verifies/installs usbipd-win (winget)
# - copies the app to Program Files
# - creates C:\ProgramData\USBShare\config.json from the example
# - registers a SYSTEM scheduled task that syncs at boot and every 5 min
# - scopes the firewall to allowedClients (if configured)

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'USBShare'),
    [string]$ConfigPath = (Join-Path $env:ProgramData 'USBShare\config.json'),
    [switch]$SkipWinget,
    [switch]$SkipTask,
    [switch]$SkipFirewall
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsbShare.psm1') -Force

$TaskName = 'USB Share Bridge Sync'

Write-Host '=== USB Share Bridge installer ===' -ForegroundColor Cyan

# --- 1. usbipd-win -----------------------------------------------------------
$usbipd = Find-Usbipd
if (-not $usbipd -and -not $SkipWinget) {
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host 'usbipd-win not found; installing via winget (interactive)...' -ForegroundColor Yellow
        & $winget.Source install --interactive --exact usbipd.usbipd-win
        $usbipd = Find-Usbipd
    } else {
        Write-Host 'winget not available.' -ForegroundColor Yellow
    }
}
if (-not $usbipd) {
    throw @(
        'usbipd-win is required but was not found.',
        'Install it manually from https://github.com/dorssel/usbipd-win/releases',
        '(or run: winget install --interactive --exact usbipd.usbipd-win)',
        'Then re-run this installer.'
    ) -join "`n"
}
Write-Host "[OK] usbipd-win found: $usbipd ($(Get-UsbipdVersion -UsbipdPath $usbipd))" -ForegroundColor Green

# --- 2. copy app -------------------------------------------------------------
$null = New-Item -ItemType Directory -Force -Path $InstallDir
foreach ($file in 'usb-share.ps1', 'UsbShare.psm1', 'config.example.json') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $InstallDir $file) -Force
}
Write-Host "[OK] app copied to $InstallDir" -ForegroundColor Green

# --- 3. config ---------------------------------------------------------------
$configDir = Split-Path -Parent $ConfigPath
$null = New-Item -ItemType Directory -Force -Path $configDir
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Copy-Item -LiteralPath (Join-Path $InstallDir 'config.example.json') -Destination $ConfigPath
    Write-Host "[OK] starter config created: $ConfigPath" -ForegroundColor Green
    Write-Host '     NEXT: run "usb-share.ps1 list --json", put your device VidPid ids and' -ForegroundColor Yellow
    Write-Host '     the HAOS VM IP into allowedClients there, then re-run install.' -ForegroundColor Yellow
} else {
    Write-Host "[OK] using existing config: $ConfigPath" -ForegroundColor Green
}

# --- 4. scheduled task --------------------------------------------------------
if (-not $SkipTask) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" sync' -f (Join-Path $InstallDir 'usb-share.ps1')
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    $null = Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Principal $principal -Trigger $startupTrigger, $repeatTrigger -Settings $settings
    Write-Host "[OK] scheduled task '$TaskName' registered (at boot + every 5 min as SYSTEM)" -ForegroundColor Green
}

# --- 5. firewall --------------------------------------------------------------
if (-not $SkipFirewall) {
    $firewall = Set-UsbShareFirewall -ConfigPath $ConfigPath
    Write-Host "[$($firewall.Action)] firewall: $($firewall.Message)"
}

Write-Host ''
Write-Host 'Done. Useful next steps:' -ForegroundColor Cyan
Write-Host "  cd $InstallDir"
Write-Host '  .\usb-share.ps1 list --json       # find your devices'' VidPid ids'
Write-Host "  notepad $ConfigPath"
Write-Host '  .\usb-share.ps1 doctor            # verify everything'
Write-Host "  .\usb-share.ps1 sync              # share the devices now"
