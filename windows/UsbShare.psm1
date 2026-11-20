# USB Share Bridge - Windows management app around usbipd-win.
# Requires usbipd-win (https://github.com/dorssel/usbipd-win) on the machine.

Set-StrictMode -Version Latest

$script:FirewallRuleName = 'USB Share Bridge (usbipd)'
$script:UsbIpPort = 3240

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-UsbShareAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-Usbipd {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    $candidates = @()
    if ($Path) { $candidates += $Path }
    $cmd = Get-Command 'usbipd.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += (Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe')
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { $candidates += (Join-Path $pf86 'usbipd-win\usbipd.exe') }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Invoke-UsbipdCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UsbipdPath,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    $output = & $UsbipdPath @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output -join "`n")
    }
}

function Get-UsbipdVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UsbipdPath
    )
    $result = Invoke-UsbipdCommand -UsbipdPath $UsbipdPath -Arguments @('--version')
    if ($result.ExitCode -ne 0) { return "unknown ($($result.Output))" }
    return $result.Output.Trim()
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-UsbShareConfigPath {
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) { return (Resolve-Path -LiteralPath $Path).Path }
    if ($env:USBSHARE_CONFIG) { return $env:USBSHARE_CONFIG }

    $candidates = @(
        (Join-Path $env:ProgramData 'USBShare\config.json'),
        (Join-Path $PSScriptRoot 'config.json')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-UsbShareConfig {
    <#
    .SYNOPSIS
    Loads and validates the USB Share Bridge configuration.

    .OUTPUTS
    PSCustomObject with Devices (id/busid/description), AllowedClients and
    WatchIntervalSeconds.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$AllowMissing
    )

    $resolved = Get-UsbShareConfigPath -Path $Path
    if (-not $resolved) {
        if ($AllowMissing) { return $null }
        throw "No config found. Copy config.example.json to C:\ProgramData\USBShare\config.json and edit it, or pass -ConfigPath."
    }

    $raw = Get-Content -LiteralPath $resolved -Raw
    $config = $null
    try {
        $config = $raw | ConvertFrom-Json
    } catch {
        throw "Config file '$resolved' is not valid JSON: $($_.Exception.Message)"
    }

    $vidPidPattern = '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$'
    $busIdPattern  = '^\d[\d.\-]*$'

    if (-not $config.devices) {
        throw "Config file '$resolved' has no 'devices' array."
    }

    $devices = @()
    $index = 0
    foreach ($device in $config.devices) {
        $index++
        $id = $null
        if ($device.PSObject.Properties['id'] -and $device.id) { $id = ([string]$device.id).Trim() }
        $busid = $null
        if ($device.PSObject.Properties['busid'] -and $device.busid) { $busid = ([string]$device.busid).Trim() }
        $description = "Device $index"
        if ($device.PSObject.Properties['description'] -and $device.description) { $description = [string]$device.description }

        if (-not $id -and -not $busid) {
            throw "Config device #$index ($description) has neither 'id' (VID:PID) nor 'busid'."
        }
        if ($id -and $id -notmatch $vidPidPattern) {
            throw "Config device #$index ($description) has invalid id '$id' - expected VID:PID like 0bda:2838."
        }
        if ($busid -and $busid -notmatch $busIdPattern) {
            throw "Config device #$index ($description) has invalid busid '$busid' - expected e.g. 1-3."
        }
        if ($id -and $busid) {
            throw "Config device #$index ($description) has both 'id' and 'busid' - use one (prefer 'id', it survives replugging)."
        }
        $devices += [pscustomobject]@{
            Id          = $id
            BusId       = $busid
            Description = $description
        }
    }

    $allowedClients = @()
    if ($config.PSObject.Properties['allowedClients'] -and $config.allowedClients) {
        $allowedClients = @($config.allowedClients | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }

    $watchInterval = 300
    if ($config.PSObject.Properties['watchIntervalSeconds'] -and $config.watchIntervalSeconds) {
        $watchInterval = [int]$config.watchIntervalSeconds
    }
    if ($watchInterval -lt 30) { $watchInterval = 30 }

    return [pscustomobject]@{
        Path                = $resolved
        Devices             = $devices
        AllowedClients      = $allowedClients
        WatchIntervalSeconds = $watchInterval
    }
}

# ---------------------------------------------------------------------------
# Device list (usbipd list)
# ---------------------------------------------------------------------------

function Get-UsbDeviceList {
    <#
    .SYNOPSIS
    Runs 'usbipd list' and parses the table into structured objects.

    .OUTPUTS
    PSCustomObjects with BusId, VidPid, Description, State, Permission,
    Section (Connected/Persisted).
    #>
    [CmdletBinding()]
    param(
        [string]$UsbipdPath
    )

    $usbipd = Find-Usbipd -Path $UsbipdPath
    if (-not $usbipd) {
        throw "usbipd.exe not found. Install usbipd-win first (see https://github.com/dorssel/usbipd-win)."
    }

    $result = Invoke-UsbipdCommand -UsbipdPath $usbipd -Arguments @('list')
    if ($result.ExitCode -ne 0) {
        throw "usbipd list failed (exit $($result.ExitCode)): $($result.Output)"
    }

    $rowPattern = '^\s*(\d[\d.\-]*)\s+([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})\s+(.+?)\s+(Not shared|Shared|Attached|Persisted)\s*(.*)$'
    $section = 'Connected'
    $devices = @()

    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^\s*Connected:') { $section = 'Connected'; continue }
        if ($line -match '^\s*Persisted:') { $section = 'Persisted'; continue }
        if ($line -match $rowPattern) {
            $devices += [pscustomobject]@{
                BusId       = $Matches[1]
                VidPid      = $Matches[2].ToLowerInvariant()
                Description = $Matches[3].Trim()
                State       = $Matches[4]
                Permission  = $Matches[5].Trim()
                Section     = $section
            }
        }
    }
    return ,$devices
}

function Resolve-UsbShareDevice {
    <#
    .SYNOPSIS
    Matches one config device entry to the current usbipd device list.

    .OUTPUTS
    PSCustomObject with Match (vidpid/busid/none) and Device (list entry).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject]$ConfigDevice,
        [Parameter(Mandatory)] [pscustomobject[]]$DeviceList
    )

    if ($ConfigDevice.BusId) {
        $hit = $DeviceList | Where-Object { $_.BusId -eq $ConfigDevice.BusId } | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ Match = 'busid'; Device = $hit } }
    }
    if ($ConfigDevice.Id) {
        $hit = $DeviceList | Where-Object { $_.VidPid -ieq $ConfigDevice.Id } | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ Match = 'vidpid'; Device = $hit } }
    }
    return [pscustomobject]@{ Match = 'none'; Device = $null }
}

# ---------------------------------------------------------------------------
# Sync (bind configured devices, idempotent)
# ---------------------------------------------------------------------------

function Sync-UsbShare {
    <#
    .SYNOPSIS
    Ensures every configured device is shared (bound) in usbipd.

    .OUTPUTS
    One result object per configured device:
    Device, BusId, Match, State, Action, Result, Message.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$UsbipdPath,
        [switch]$DryRun,
        [switch]$AssumeElevated,
        [switch]$Quiet
    )

    $config = Get-UsbShareConfig -Path $ConfigPath
    $usbipd = Find-Usbipd -Path $UsbipdPath
    if (-not $usbipd) {
        throw "usbipd.exe not found. Install usbipd-win first (see https://github.com/dorssel/usbipd-win)."
    }

    $deviceList = Get-UsbDeviceList -UsbipdPath $usbipd
    $isAdmin = $(if ($AssumeElevated) { $true } else { Test-UsbShareAdmin })

    $results = @()
    foreach ($configured in $config.Devices) {
        $resolution = Resolve-UsbShareDevice -ConfigDevice $configured -DeviceList $deviceList
        $result = [pscustomobject]@{
            Device  = $configured.Description
            BusId   = $null
            Match   = $resolution.Match
            State   = $null
            Action  = 'none'
            Result  = 'ok'
            Message = ''
        }

        if ($resolution.Match -eq 'none') {
            $result.Result = 'missing'
            $result.Message = "Not found on this machine (unplugged?). Run 'usb-share.ps1 list' to check."
            $results += $result
            continue
        }

        $live = $resolution.Device
        $result.BusId = $live.BusId
        $result.State = $live.State

        switch ($live.State) {
            'Not shared' {
                $result.Action = 'bind'
                if ($DryRun) {
                    $result.Result = 'dry-run'
                    $result.Message = "Would run: usbipd bind --busid $($live.BusId)"
                } else {
                    if (-not $isAdmin) {
                        $result.Result = 'error'
                        $result.Message = 'Binding requires an elevated session. Re-run as Administrator.'
                    } else {
                        $bind = Invoke-UsbipdCommand -UsbipdPath $usbipd -Arguments @('bind', '--busid', $live.BusId)
                        if ($bind.ExitCode -eq 0) {
                            $result.Result = 'bound'
                            $result.Message = "usbipd bind --busid $($live.BusId) -> shared"
                        } else {
                            $result.Result = 'error'
                            $result.Message = "usbipd bind failed (exit $($bind.ExitCode)): $($bind.Output)"
                        }
                    }
                }
            }
            'Shared' {
                $result.Message = 'Already shared; nothing to do.'
            }
            'Attached' {
                $result.Message = 'Already shared and attached by a client.'
            }
            default {
                $result.Message = "State '$($live.State)' requires no action."
            }
        }
        $results += $result
    }

    if (-not $Quiet) {
        foreach ($r in $results) {
            $line = "[{0}] {1}{2}: {3}" -f $r.Result.ToUpperInvariant(), $r.Device,
                $(if ($r.BusId) { " (bus $($r.BusId))" } else { '' }), $r.Message
            Write-Host $line
        }
    }
    return ,$results
}

function Watch-UsbShare {
    <#
    .SYNOPSIS
    Foreground watchdog: runs Sync on an interval until interrupted (Ctrl+C).
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$UsbipdPath,
        [int]$IntervalSeconds = 0
    )

    $config = Get-UsbShareConfig -Path $ConfigPath
    $interval = if ($IntervalSeconds -gt 0) { $IntervalSeconds } else { $config.WatchIntervalSeconds }

    Write-Host "Watching every $interval seconds. Press Ctrl+C to stop."
    while ($true) {
        try {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Write-Host ""
            Write-Host "=== sync @ $timestamp ==="
            $null = Sync-UsbShare -ConfigPath $config.Path -UsbipdPath $UsbipdPath -Quiet
        } catch {
            Write-Warning "Sync failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $interval
    }
}

# ---------------------------------------------------------------------------
# Firewall scoping
# ---------------------------------------------------------------------------

function Set-UsbShareFirewall {
    <#
    .SYNOPSIS
    Creates (or removes) an inbound firewall rule for USB/IP port 3240,
    scoped to the configured allowed client IPs.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$Remove
    )

    $existing = Get-NetFirewallRule -DisplayName $script:FirewallRuleName -ErrorAction SilentlyContinue
    if ($existing) {
        $existing | Remove-NetFirewallRule
    }

    if ($Remove) {
        return [pscustomobject]@{
            Action = 'removed'
            Message = "Firewall rule '$($script:FirewallRuleName)' removed."
        }
    }

    $config = Get-UsbShareConfig -Path $ConfigPath
    if ($config.AllowedClients.Count -eq 0) {
        return [pscustomobject]@{
            Action = 'skipped'
            Message = "No allowedClients configured; no scoped rule created. Windows Firewall default rules continue to apply."
        }
    }

    $null = New-NetFirewallRule -DisplayName $script:FirewallRuleName `
        -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $script:UsbIpPort -RemoteAddress $config.AllowedClients `
        -Profile Any -Description 'Scoped USB/IP server access for USB Share Bridge'

    return [pscustomobject]@{
        Action = 'created'
        Message = "Inbound TCP $($script:UsbIpPort) allowed only from: $($config.AllowedClients -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Status / doctor
# ---------------------------------------------------------------------------

function Get-UsbShareStatus {
    <#
    .SYNOPSIS
    Returns a health snapshot: usbipd presence/version, admin, service,
    config, firewall rule, and per-device state.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$UsbipdPath
    )

    $usbipd = Find-Usbipd -Path $UsbipdPath
    $status = [ordered]@{
        Usbipd        = $null
        UsbipdVersion = $null
        IsAdmin       = Test-UsbShareAdmin
        Service       = $null
        ConfigPath    = $null
        Devices       = @()
        FirewallRule  = $null
    }

    if ($usbipd) {
        $status.Usbipd = $usbipd
        $status.UsbipdVersion = Get-UsbipdVersion -UsbipdPath $usbipd
        $service = Get-Service -Name 'usbipd' -ErrorAction SilentlyContinue
        if ($service) { $status.Service = "$($service.Status) (startup: $($service.StartType))" }
        else { $status.Service = 'not found (expected on usbipd-win 4.x+)' }
    }

    $config = Get-UsbShareConfig -Path $ConfigPath -AllowMissing
    if ($config) {
        $status.ConfigPath = $config.Path
        if ($usbipd) {
            $deviceList = Get-UsbDeviceList -UsbipdPath $usbipd
            foreach ($configured in $config.Devices) {
                $resolution = Resolve-UsbShareDevice -ConfigDevice $configured -DeviceList $deviceList
                $status.Devices += [pscustomobject]@{
                    Device  = $configured.Description
                    Match   = $resolution.Match
                    BusId   = $(if ($resolution.Device) { $resolution.Device.BusId } else { $null })
                    State   = $(if ($resolution.Device) { $resolution.Device.State } else { 'not found' })
                }
            }
        }
    }

    $rule = Get-NetFirewallRule -DisplayName $script:FirewallRuleName -ErrorAction SilentlyContinue
    if ($rule) {
        $addresses = ($rule | Get-NetFirewallAddressFilter).RemoteAddress -join ', '
        $status.FirewallRule = "enabled, scope: $addresses"
    } else {
        $status.FirewallRule = 'no scoped rule (set allowedClients and run: usb-share.ps1 firewall)'
    }

    return [pscustomobject]$status
}

Export-ModuleMember -Function `
    Test-UsbShareAdmin,
    Find-Usbipd,
    Get-UsbipdVersion,
    Get-UsbShareConfigPath,
    Get-UsbShareConfig,
    Get-UsbDeviceList,
    Resolve-UsbShareDevice,
    Sync-UsbShare,
    Watch-UsbShare,
    Set-UsbShareFirewall,
    Get-UsbShareStatus
