# USB Share Bridge - Windows management app around usbipd-win.
# Requires usbipd-win (https://github.com/dorssel/usbipd-win) on the machine.

Set-StrictMode -Version Latest

$script:FirewallRuleName = 'USB Share Bridge (usbipd)'
$script:UsbIpPort = 3240
$script:GuiTaskName = 'USB Share Bridge GUI'
$script:UsbIdsPath = Join-Path $PSScriptRoot 'usb.ids'
$script:UsbIdsCache = $null

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

    if ($null -eq $config.devices) {
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

function Test-UsbGenericDeviceName {
    <#
    .SYNOPSIS
    True for placeholder names like "USB Device" or "Bulk-In, Interface"
    that carry no information about what the device actually is.
    #>
    [CmdletBinding()]
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    $trimmed = $Name.Trim()
    $genericNames = @(
        'USB Device', 'USB', 'USB Input Device', 'USB Composite Device',
        'Composite USB Device', 'Unknown USB Device', 'USB Serial Device'
    )
    if ($genericNames -contains $trimmed) { return $true }
    if ($trimmed -match '^(Bulk[- ]In|Interface|Unknown)') { return $true }
    return $false
}

function Select-UsbDeviceDescription {
    <#
    .SYNOPSIS
    Picks the most informative description for a USB device.
    Priority: a non-generic Windows (PnP) name, then the usbipd string,
    then the usb.ids product name; anything beats nothing.
    #>
    [CmdletBinding()]
    param(
        [string]$UsbipdDescription,
        [string]$PnpName,
        [string]$UsbIdsProduct
    )

    if ($PnpName -and -not (Test-UsbGenericDeviceName $PnpName)) { return $PnpName }
    if ($UsbipdDescription -and -not (Test-UsbGenericDeviceName $UsbipdDescription)) { return $UsbipdDescription }
    if ($UsbIdsProduct -and -not (Test-UsbGenericDeviceName $UsbIdsProduct)) { return $UsbIdsProduct }
    foreach ($candidate in @($PnpName, $UsbipdDescription, $UsbIdsProduct)) {
        if ($candidate) { return $candidate }
    }
    return 'Unknown USB device'
}

function Get-UsbIdsDatabase {
    <#
    .SYNOPSIS
    Parses the bundled usb.ids database (same public database used by
    Linux) into vendor/product hashtables. Cached after first load.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:UsbIdsCache) { return $script:UsbIdsCache }
    $vendors = @{}
    $products = @{}
    $currentVendor = $null

    if (Test-Path -LiteralPath $script:UsbIdsPath -PathType Leaf) {
        foreach ($line in [System.IO.File]::ReadLines($script:UsbIdsPath)) {
            if ($line -eq '') { continue }
            if ($line.StartsWith('#')) { continue }
            if ($line.Length -lt 4) { continue }
            if ($line.StartsWith("`t`t")) { continue }
            if ($line[0] -eq "`t") {
                $trimmed = $line.TrimStart()
                if ($trimmed.Length -ge 4 -and $currentVendor) {
                    $products["$currentVendor/$($trimmed.Substring(0, 4))"] = $trimmed.Substring(4).Trim()
                }
            } else {
                $currentVendor = $line.Substring(0, 4).ToLowerInvariant()
                $vendors[$currentVendor] = $line.Substring(4).Trim()
            }
        }
    }

    $script:UsbIdsCache = @{ Vendors = $vendors; Products = $products }
    return $script:UsbIdsCache
}

function Get-UsbIdsName {
    <#
    .SYNOPSIS
    Resolves a VID:PID against the bundled usb.ids database.
    Returns $null, or an object with Vendor and Product (either may be
    $null when the database lacks that entry).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VidPid
    )

    $parts = $VidPid.ToLowerInvariant() -split ':'
    if ($parts.Count -ne 2) { return $null }
    $db = Get-UsbIdsDatabase
    $vendor = $db.Vendors[$parts[0]]
    $product = $db.Products["$($parts[0])/$($parts[1])"]
    if (-not $vendor -and -not $product) { return $null }
    return [pscustomobject]@{ Vendor = $vendor; Product = $product }
}

function Get-UsbPnpInfo {
    <#
    .SYNOPSIS
    Maps VID:PID to Windows' own PnP knowledge (friendly name and
    manufacturer) via WMI. Harmless read-only; returns an empty map if
    WMI is unavailable.
    #>
    [CmdletBinding()]
    param()

    $map = @{}
    try {
        $entities = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop
    } catch {
        return $map
    }

    foreach ($entity in $entities) {
        if (-not $entity.PNPDeviceID) { continue }
        if ($entity.PNPDeviceID -notmatch '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }
        $key = "$($Matches[1]):$($Matches[2])".ToLowerInvariant()
        $name = [string]$entity.Name
        $entry = [pscustomobject]@{
            Name         = $name
            Manufacturer = [string]$entity.Manufacturer
            InstanceId   = $entity.PNPDeviceID
        }
        $existing = $map[$key]
        if (-not $existing) {
            $map[$key] = $entry
        } elseif ((Test-UsbGenericDeviceName $existing.Name) -and -not (Test-UsbGenericDeviceName $name)) {
            # Prefer the more descriptive entry when a VID:PID has several.
            $map[$key] = $entry
        }
    }
    return $map
}

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
    $pnpMap = Get-UsbPnpInfo

    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^\s*Connected:') { $section = 'Connected'; continue }
        if ($line -match '^\s*Persisted:') { $section = 'Persisted'; continue }
        if ($line -match $rowPattern) {
            $busId = $Matches[1]
            $vidPid = $Matches[2].ToLowerInvariant()
            $rawDescription = $Matches[3].Trim()
            $state = $Matches[4]
            $permission = $Matches[5].Trim()

            $pnp = $pnpMap[$vidPid]
            $ids = Get-UsbIdsName -VidPid $vidPid
            $manufacturer = $null
            if ($pnp -and $pnp.Manufacturer) { $manufacturer = $pnp.Manufacturer }
            elseif ($ids -and $ids.Vendor) { $manufacturer = $ids.Vendor }
            $description = Select-UsbDeviceDescription `
                -UsbipdDescription $rawDescription `
                -PnpName $(if ($pnp) { $pnp.Name } else { $null }) `
                -UsbIdsProduct $(if ($ids) { $ids.Product } else { $null })

            $devices += [pscustomobject]@{
                BusId             = $busId
                VidPid            = $vidPid
                Description       = $description
                UsbipdDescription = $rawDescription
                Manufacturer      = $manufacturer
                PnpName           = $(if ($pnp) { $pnp.Name } else { $null })
                UsbIdsVendor      = $(if ($ids) { $ids.Vendor } else { $null })
                UsbIdsProduct     = $(if ($ids) { $ids.Product } else { $null })
                State             = $state
                Permission        = $permission
                Section           = $section
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
        [switch]$UnbindRemoved,
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
    $matchedBusIds = @{}
    foreach ($configured in $config.Devices) {
        $resolution = Resolve-UsbShareDevice -ConfigDevice $configured -DeviceList $deviceList
        if ($resolution.Device) { $matchedBusIds[$resolution.Device.BusId] = $true }
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

    if ($UnbindRemoved) {
        # Uncheck in the GUI == remove from config == stop sharing it here.
        foreach ($live in $deviceList) {
            if ($matchedBusIds.ContainsKey($live.BusId)) { continue }
            if ($live.State -notin @('Shared', 'Attached')) { continue }

            $result = [pscustomobject]@{
                Device  = $live.Description
                BusId   = $live.BusId
                Match   = 'none'
                State   = $live.State
                Action  = 'unbind'
                Result  = 'ok'
                Message = ''
            }
            if ($DryRun) {
                $result.Result = 'dry-run'
                $result.Message = "Would unbind (stop sharing) bus $($live.BusId)"
            } elseif (-not $isAdmin) {
                $result.Result = 'error'
                $result.Message = 'Unbinding requires an elevated session. Re-run as Administrator.'
            } else {
                if ($live.State -eq 'Attached') {
                    # A client (e.g. the HAOS add-on) is using the device.
                    # Detach it first so the unbind can succeed.
                    $null = Invoke-UsbipdCommand -UsbipdPath $usbipd -Arguments @('detach', '--busid', $live.BusId)
                }
                $unbind = Invoke-UsbipdCommand -UsbipdPath $usbipd -Arguments @('unbind', '--busid', $live.BusId)
                if ($unbind.ExitCode -eq 0) {
                    $result.Result = 'unbound'
                    $result.Message = "usbipd unbind --busid $($live.BusId) -> no longer shared"
                } else {
                    $result.Result = 'error'
                    $result.Message = "usbipd unbind failed (exit $($unbind.ExitCode)): $($unbind.Output)"
                }
            }
            $results += $result
        }
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
# Setup actions (shared by Install.ps1 and the GUI)
# ---------------------------------------------------------------------------

function Install-UsbipdWin {
    <#
    .SYNOPSIS
    Installs usbipd-win via winget and returns the resolved usbipd path.
    Returns $null when winget is unavailable or the install fails.
    #>
    [CmdletBinding()]
    param([switch]$Interactive)

    $before = Find-Usbipd
    if ($before) { return $before }

    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Warning 'winget not available; install usbipd-win manually: https://github.com/dorssel/usbipd-win/releases'
        return $null
    }

    $arguments = @()
    if ($Interactive) { $arguments += '--interactive' }
    $arguments += @('--exact', 'dorssel.usbipd-win')
    & $winget.Source install @arguments
    $installed = Find-Usbipd
    if (-not $installed) {
        Write-Warning 'winget finished but usbipd.exe was not found. Try: winget source update, then re-run.'
    }
    return $installed
}

function Register-UsbShareScheduledTask {
    <#
    .SYNOPSIS
    Registers the SYSTEM scheduled task that keeps configured devices
    shared at boot and every 5 minutes. Requires elevation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstallDir
    )

    $taskName = 'USB Share Bridge Sync'
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }

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

    $null = Register-ScheduledTask -TaskName $taskName -Action $action `
        -Principal $principal -Trigger $startupTrigger, $repeatTrigger -Settings $settings
    return $taskName
}

function New-UsbShareShortcut {
    <#
    .SYNOPSIS
    Creates a Start Menu shortcut that launches the GUI (elevated prompt
    appears unless already elevated).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TargetScript,
        [string]$ShortcutPath = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\USB Share Bridge.lnk')
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -File `"$TargetScript`""
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetScript
    $shortcut.Description = 'USB Share Bridge - select USB devices to share with HAOS'
    $shortcut.IconLocation = "$([Environment]::SystemDirectory)\shell32.dll,-16739"
    $shortcut.Save()
    return $ShortcutPath
}

function Remove-UsbShareShortcut {
    [CmdletBinding()]
    param(
        [string]$ShortcutPath = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\USB Share Bridge.lnk')
    )
    if (Test-Path -LiteralPath $ShortcutPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# GUI autostart (logon task, elevated run-level => no UAC prompt per login)
# ---------------------------------------------------------------------------

function Test-UsbGuiAutoStart {
    <#
    .SYNOPSIS
    Returns true when the GUI is registered to start at Windows logon.
    #>
    [CmdletBinding()]
    param()

    $task = Get-ScheduledTask -TaskName $script:GuiTaskName -ErrorAction SilentlyContinue
    return ($null -ne $task)
}

function Enable-UsbGuiAutoStart {
    <#
    .SYNOPSIS
    Registers a logon scheduled task that launches the GUI elevated.
    Requires an elevated session and an administrator account (a task
    with RunLevel Highest cannot silently elevate a standard account).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TargetScript
    )

    $user = "$env:USERDOMAIN\$env:USERNAME"
    $existing = Get-ScheduledTask -TaskName $script:GuiTaskName -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $script:GuiTaskName -Confirm:$false }

    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument (
        '-NoProfile -ExecutionPolicy Bypass -Sta -File "{0}"' -f $TargetScript
    )
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

    $null = Register-ScheduledTask -TaskName $script:GuiTaskName -Action $action `
        -Principal $principal -Trigger $trigger -Settings $settings
    return $script:GuiTaskName
}

function Disable-UsbGuiAutoStart {
    <#
    .SYNOPSIS
    Removes the GUI logon task. Returns true when a task was removed.
    #>
    [CmdletBinding()]
    param()

    $existing = Get-ScheduledTask -TaskName $script:GuiTaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $script:GuiTaskName -Confirm:$false
        return $true
    }
    return $false
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
    Test-UsbGenericDeviceName,
    Select-UsbDeviceDescription,
    Get-UsbIdsName,
    Get-UsbPnpInfo,
    Resolve-UsbShareDevice,
    Sync-UsbShare,
    Install-UsbipdWin,
    Register-UsbShareScheduledTask,
    New-UsbShareShortcut,
    Remove-UsbShareShortcut,
    Watch-UsbShare,
    Set-UsbShareFirewall,
    Get-UsbShareStatus,
    Test-UsbGuiAutoStart,
    Enable-UsbGuiAutoStart,
    Disable-UsbGuiAutoStart
