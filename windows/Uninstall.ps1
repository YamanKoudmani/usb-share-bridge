# Removes USB Share Bridge artifacts (scheduled task, firewall rule, files).
# Leaves usbipd-win and any bound devices untouched (unbind manually with
# 'usbipd unbind --busid <id>' if you want).

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'USBShare'),
    [string]$ConfigPath = (Join-Path $env:ProgramData 'USBShare\config.json'),
    [switch]$RemoveFiles
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsbShare.psm1') -Force
$TaskName = 'USB Share Bridge Sync'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[OK] scheduled task '$TaskName' removed."
} else {
    Write-Host "[--] scheduled task not found."
}

$rule = Get-NetFirewallRule -DisplayName 'USB Share Bridge (usbipd)' -ErrorAction SilentlyContinue
if ($rule) {
    $rule | Remove-NetFirewallRule
    Write-Host "[OK] scoped firewall rule removed."
} else {
    Write-Host "[--] scoped firewall rule not found."
}

if (Remove-UsbShareShortcut) {
    Write-Host "[OK] Start Menu shortcut removed."
} else {
    Write-Host "[--] Start Menu shortcut not found."
}

if ($RemoveFiles) {
    foreach ($dir in $InstallDir, (Split-Path -Parent $ConfigPath)) {
        if ((Test-Path -LiteralPath $dir) -and ($dir -like "$env:ProgramFiles*" -or $dir -like "$env:ProgramData*")) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Host "[OK] removed $dir"
        }
    }
} else {
    Write-Host "[--] files kept at $InstallDir and $(Split-Path -Parent $ConfigPath) (use -RemoveFiles to delete)."
}
