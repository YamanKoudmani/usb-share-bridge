# USB Share Bridge CLI.
# Usage: usb-share.ps1 <list|sync|status|watch|firewall|doctor|help> [options]

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'sync', 'status', 'watch', 'firewall', 'doctor', 'help')]
    [string]$Command = 'status',

    [switch]$Json,
    [switch]$DryRun,
    [switch]$RemoveFirewall,
    [int]$IntervalSeconds = 0,
    [string]$ConfigPath,
    [string]$UsbipdPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsbShare.psm1') -Force

switch ($Command) {
    'list' {
        $devices = Get-UsbDeviceList -UsbipdPath $UsbipdPath
        if ($Json) {
            $devices | ConvertTo-Json -Depth 3
        } else {
            $devices |
                Format-Table BusId, VidPid, State, Description, Permission -AutoSize |
                Out-String -Width 220 | Write-Host
            Write-Host "Tip: use the VidPid column as the 'id' in config.json - it survives replugging."
        }
    }
    'sync' {
        $results = Sync-UsbShare -ConfigPath $ConfigPath -UsbipdPath $UsbipdPath -DryRun:$DryRun
        $failed = @($results | Where-Object { $_.Result -in 'missing', 'error' })
        if ($failed.Count -gt 0) { exit 1 }
    }
    'watch' {
        Watch-UsbShare -ConfigPath $ConfigPath -UsbipdPath $UsbipdPath -IntervalSeconds $IntervalSeconds
    }
    'firewall' {
        $result = Set-UsbShareFirewall -ConfigPath $ConfigPath -Remove:$RemoveFirewall
        Write-Host "[$($result.Action)] $($result.Message)"
    }
    'status' {
        $status = Get-UsbShareStatus -ConfigPath $ConfigPath -UsbipdPath $UsbipdPath
        if ($Json) {
            $status | ConvertTo-Json -Depth 4
        } else {
            Write-Host "usbipd      : $(if ($status.Usbipd) { $status.Usbipd } else { 'NOT FOUND - install usbipd-win' })"
            Write-Host "version     : $(if ($status.UsbipdVersion) { $status.UsbipdVersion } else { 'unknown' })"
            Write-Host "admin       : $(if ($status.IsAdmin) { 'yes' } else { 'no (bind will fail)' })"
            Write-Host "service     : $($status.Service)"
            Write-Host "config      : $(if ($status.ConfigPath) { $status.ConfigPath } else { 'NOT FOUND' })"
            Write-Host "firewall    : $($status.FirewallRule)"
            if ($status.Devices.Count -gt 0) {
                Write-Host "devices:"
                $status.Devices |
                    Format-Table Device, Match, BusId, State -AutoSize |
                    Out-String -Width 200 | Write-Host
            }
        }
    }
    'doctor' {
        $problems = @()
        $usbipd = Find-Usbipd -Path $UsbipdPath
        if (-not $usbipd) {
            $problems += 'usbipd.exe not found. Install it first: winget install --interactive --exact usbipd.usbipd-win'
        } else {
            Write-Host "[OK] usbipd found: $usbipd ($(Get-UsbipdVersion -UsbipdPath $usbipd))"
        }
        if (-not (Test-UsbShareAdmin)) {
            $problems += 'not elevated - binding devices requires an Administrator session.'
        } else {
            Write-Host '[OK] running elevated'
        }
        try {
            $config = Get-UsbShareConfig -Path $ConfigPath
            Write-Host "[OK] config: $($config.Path) ($($config.Devices.Count) device(s))"
            if ($config.AllowedClients.Count -eq 0) {
                $problems += 'allowedClients is empty - the scoped firewall rule was NOT created. Add the HAOS VM IP.'
            } else {
                Write-Host "[OK] allowedClients: $($config.AllowedClients -join ', ')"
            }
        } catch {
            $problems += "config problem: $($_.Exception.Message)"
        }
        if ($usbipd) {
            try {
                $devices = Get-UsbDeviceList -UsbipdPath $usbipd
                Write-Host "[OK] usbipd list returned $($devices.Count) device(s)"
            } catch {
                $problems += "usbipd list failed: $($_.Exception.Message)"
            }
        }
        if ($problems.Count -gt 0) {
            Write-Host ''
            foreach ($p in $problems) { Write-Host "[PROBLEM] $p" }
            exit 1
        }
        Write-Host ''
        Write-Host 'All checks passed.'
    }
    'help' {
        Write-Host 'Usage: usb-share.ps1 <command> [options]'
        Write-Host ''
        Write-Host '  list                        Show USB devices and their share state'
        Write-Host '  list --json                 Same, as JSON (copy VidPid into config)'
        Write-Host '  sync [--dry-run]            Bind (share) all devices from config.json'
        Write-Host '  watch [--interval N]        Foreground watchdog loop'
        Write-Host '  firewall                    Create/refresh the scoped firewall rule'
        Write-Host '  firewall -RemoveFirewall    Remove the scoped firewall rule'
        Write-Host '  status [--json]             One-shot health snapshot'
        Write-Host '  doctor                      Full environment check'
        Write-Host ''
        Write-Host "Options: -ConfigPath <file.json>   default: $env:ProgramData\USBShare\config.json"
        Write-Host '         -UsbipdPath <exe>         default: auto-detect'
    }
}
