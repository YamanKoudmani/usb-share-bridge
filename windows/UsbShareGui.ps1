# USB Share Bridge GUI.
# Lists USB devices with checkboxes; checked = shared with the HAOS VM.
# Requires elevation (self-elevates). Run with -SelfCheck for a headless
# construction test used by the test suite.

[CmdletBinding()]
param(
    [switch]$SelfCheck,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsbShare.psm1') -Force

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

if (-not $SelfCheck -and -not (Test-UsbShareAdmin)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', "`"$PSCommandPath`"")
    if ($ConfigPath) { $arguments += @('-ConfigPath', "`"$ConfigPath`"") }
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList ($arguments -join ' ')
    exit
}

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------

$script:UsbipdPath = Find-Usbipd

function Get-GuiConfigPath {
    if ($ConfigPath) { return $ConfigPath }
    $resolved = Get-UsbShareConfigPath
    if ($resolved) { return $resolved }
    return (Join-Path $env:ProgramData 'USBShare\config.json')
}

function Write-GuiLog {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $logTextBox.AppendText("[$timestamp] $Message`r`n")
    Write-Host "[$timestamp] $Message"
}

# ---------------------------------------------------------------------------
# Form
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'USB Share Bridge'
$form.Size = New-Object System.Drawing.Size(840, 660)
$form.MinimumSize = New-Object System.Drawing.Size(700, 520)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$introLabel = New-Object System.Windows.Forms.Label
$introLabel.Text = 'Select the USB devices to share with your HAOS VM (checked = shared). Changes apply immediately and survive reboots.'
$introLabel.Location = New-Object System.Drawing.Point(12, 12)
$introLabel.Size = New-Object System.Drawing.Size(800, 20)
$introLabel.Anchor = 'Top,Left,Right'
$form.Controls.Add($introLabel)

$serverLabel = New-Object System.Windows.Forms.Label
$serverLabel.Text = 'Allowed client IP(s):'
$serverLabel.Location = New-Object System.Drawing.Point(12, 40)
$serverLabel.Size = New-Object System.Drawing.Size(110, 20)
$form.Controls.Add($serverLabel)

$serverTextBox = New-Object System.Windows.Forms.TextBox
$serverTextBox.Location = New-Object System.Drawing.Point(126, 37)
$serverTextBox.Size = New-Object System.Drawing.Size(300, 23)
$serverTextBox.Anchor = 'Top,Left'
$form.Controls.Add($serverTextBox)

$serverToolTip = New-Object System.Windows.Forms.ToolTip
$serverToolTip.SetToolTip($serverTextBox, 'HAOS VM IP (or Tailscale/WireGuard IP). Scopes the firewall rule for TCP 3240. Comma-separate multiple IPs.')

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Location = New-Object System.Drawing.Point(436, 36)
$refreshButton.Size = New-Object System.Drawing.Size(90, 26)
$refreshButton.Anchor = 'Top,Left'
$form.Controls.Add($refreshButton)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = 'Save && Apply'
$applyButton.Location = New-Object System.Drawing.Point(532, 36)
$applyButton.Size = New-Object System.Drawing.Size(130, 26)
$applyButton.Anchor = 'Top,Left'
$form.Controls.Add($applyButton)

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Install usbipd-win'
$installButton.Location = New-Object System.Drawing.Point(668, 36)
$installButton.Size = New-Object System.Drawing.Size(150, 26)
$installButton.Anchor = 'Top,Left'
$form.Controls.Add($installButton)

$listView = New-Object System.Windows.Forms.ListView
$listView.View = 'Details'
$listView.CheckBoxes = $true
$listView.FullRowSelect = $true
$listView.HideSelection = $true
$listView.ShowItemToolTips = $true
$listView.Location = New-Object System.Drawing.Point(12, 70)
$listView.Size = New-Object System.Drawing.Size(806, 340)
$listView.Anchor = 'Top,Left,Right,Bottom'
foreach ($column in @(
    @{ Name = 'Bus ID'; Width = 70 },
    @{ Name = 'VID:PID'; Width = 90 },
    @{ Name = 'Manufacturer'; Width = 180 },
    @{ Name = 'Device'; Width = 240 },
    @{ Name = 'State'; Width = 140 }
)) {
    $null = $listView.Columns.Add($column.Name)
    $listView.Columns[$listView.Columns.Count - 1].Width = $column.Width
}
$form.Controls.Add($listView)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready.'
$statusLabel.Location = New-Object System.Drawing.Point(12, 418)
$statusLabel.Size = New-Object System.Drawing.Size(660, 20)
$statusLabel.Anchor = 'Left,Right,Bottom'
$form.Controls.Add($statusLabel)

$taskButton = New-Object System.Windows.Forms.Button
$taskButton.Text = 'Register auto-share task'
$taskButton.Location = New-Object System.Drawing.Point(578, 414)
$taskButton.Size = New-Object System.Drawing.Size(140, 26)
$taskButton.Anchor = 'Right,Bottom'
$form.Controls.Add($taskButton)

$autoStartCheckBox = New-Object System.Windows.Forms.CheckBox
$autoStartCheckBox.Text = 'Start with Windows'
$autoStartCheckBox.Location = New-Object System.Drawing.Point(340, 418)
$autoStartCheckBox.Size = New-Object System.Drawing.Size(220, 20)
$autoStartCheckBox.Anchor = 'Right,Bottom'
$autoStartCheckBox.TabIndex = 1
$form.Controls.Add($autoStartCheckBox)

$autoStartToolTip = New-Object System.Windows.Forms.ToolTip
$autoStartToolTip.SetToolTip($autoStartCheckBox, 'Launch this GUI automatically at Windows logon (elevated, no UAC prompt). Device sharing already survives reboot via the auto-share task; this only controls the window itself.')

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Activity log'
$logLabel.Location = New-Object System.Drawing.Point(12, 444)
$logLabel.Size = New-Object System.Drawing.Size(200, 18)
$logLabel.Anchor = 'Left,Bottom'
$form.Controls.Add($logLabel)

$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Multiline = $true
$logTextBox.ReadOnly = $true
$logTextBox.ScrollBars = 'Vertical'
$logTextBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logTextBox.Location = New-Object System.Drawing.Point(12, 464)
$logTextBox.Size = New-Object System.Drawing.Size(806, 150)
$logTextBox.Anchor = 'Left,Right,Bottom'
$form.Controls.Add($logTextBox)

# ---------------------------------------------------------------------------
# Behavior
# ---------------------------------------------------------------------------

function Get-CurrentConfigSafe {
    try {
        return (Get-UsbShareConfig -Path (Get-GuiConfigPath) -AllowMissing)
    } catch {
        Write-GuiLog "Config problem: $($_.Exception.Message)"
        return $null
    }
}

function Update-UsbipdPresence {
    $script:UsbipdPath = Find-Usbipd
    if ($script:UsbipdPath) {
        $installButton.Enabled = $false
        $installButton.Visible = $false
        $applyButton.Enabled = $true
        $listView.Enabled = $true
        $statusLabel.Text = "usbipd-win: $script:UsbipdPath"
    } else {
        $installButton.Enabled = $true
        $installButton.Visible = $true
        $applyButton.Enabled = $false
        $listView.Enabled = $false
        $listView.Items.Clear()
        $statusLabel.Text = 'usbipd-win is not installed - click "Install usbipd-win".'
    }
}

function Update-DeviceList {
    $listView.Items.Clear()
    if (-not $script:UsbipdPath) { return }

    try {
        $devices = Get-UsbDeviceList -UsbipdPath $script:UsbipdPath
    } catch {
        Write-GuiLog "Could not list USB devices: $($_.Exception.Message)"
        return
    }

    $config = Get-CurrentConfigSafe
    foreach ($device in $devices) {
        $item = New-Object System.Windows.Forms.ListViewItem($device.BusId)
        $null = $item.SubItems.Add($device.VidPid)
        $manufacturer = if ($device.Manufacturer) { $device.Manufacturer } else { '' }
        $null = $item.SubItems.Add($manufacturer)
        $null = $item.SubItems.Add($device.Description)
        $null = $item.SubItems.Add($device.State)

        $toolLines = @("Bus ID: $($device.BusId)   VID:PID: $($device.VidPid)")
        if ($device.Manufacturer) { $toolLines += "Manufacturer: $($device.Manufacturer)" }
        if ($device.PnpName) { $toolLines += "Windows reports: $($device.PnpName)" }
        if ($device.UsbipdDescription) { $toolLines += "usbipd reports: $($device.UsbipdDescription)" }
        if ($device.UsbIdsVendor -or $device.UsbIdsProduct) {
            $idsText = @($device.UsbIdsVendor, $device.UsbIdsProduct) | Where-Object { $_ }
            $toolLines += "usb.ids: $($idsText -join ' - ')"
        }
        $item.ToolTipText = $toolLines -join "`r`n"

        $item.Checked = $false
        if ($config) {
            foreach ($configured in $config.Devices) {
                $isMatch = $false
                if ($configured.Id -and $configured.Id -ieq $device.VidPid) { $isMatch = $true }
                if ($configured.BusId -and $configured.BusId -eq $device.BusId) { $isMatch = $true }
                if ($isMatch) {
                    $item.Checked = $true
                    if ($device.State -eq 'Not shared') {
                        # Configured but not shared yet (e.g. fresh reboot);
                        # Save & Apply or the scheduled task will fix it.
                    }
                    break
                }
            }
        }
        $null = $listView.Items.Add($item)
    }

    $statusLabel.Text = "$($devices.Count) USB device(s) listed; checked = shared with the HAOS VM."
    if ($devices.Count -eq 0) {
        Write-GuiLog 'No USB devices reported by usbipd. Plug a device in and click Refresh.'
    }
}

$form.Add_Shown({
    Update-UsbipdPresence
    Update-DeviceList
    $config = Get-CurrentConfigSafe
    if ($config) {
        $serverTextBox.Text = ($config.AllowedClients -join ', ')
        if ($config.AllowedClients.Count -eq 0) {
            Write-GuiLog 'Tip: enter the HAOS VM IP under "Allowed client IP(s)" so the firewall rule only accepts that machine.'
        }
    } else {
        Write-GuiLog 'No config yet - check the devices you want to share, enter the HAOS VM IP, then click Save && Apply.'
    }
    Write-GuiLog "Elevated: $(if (Test-UsbShareAdmin) { 'yes' } else { 'NO - bind/unbind will fail' })"
    try {
        $script:SuppressAutoStartEvents = $true
        $autoStartCheckBox.Checked = Test-UsbGuiAutoStart
    } catch {
        Write-GuiLog "Could not read autostart state: $($_.Exception.Message)"
    } finally {
        $script:SuppressAutoStartEvents = $false
    }
})

$refreshButton.Add_Click({
    Update-UsbipdPresence
    Update-DeviceList
})

$applyButton.Add_Click({
    $listView.Enabled = $false
    $applyButton.Enabled = $false
    try {
        $targetPath = Get-GuiConfigPath
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir)) {
            $null = New-Item -ItemType Directory -Force -Path $targetDir
        }

        # Build the device list from the checkboxes. Prefer VID:PID (stable
        # across replugs); if two identical devices are checked, pin the
        # extra one by bus ID so it stays distinguishable.
        $devices = @()
        $seenVidPid = @{}
        foreach ($item in $listView.Items) {
            if (-not $item.Checked) { continue }
            $vidpid = $item.SubItems[1].Text
            $busid = $item.Text
            $description = $item.SubItems[3].Text
            if (-not $seenVidPid.ContainsKey($vidpid)) {
                $seenVidPid[$vidpid] = $true
                $devices += [pscustomobject][ordered]@{ id = $vidpid; description = $description }
            } else {
                $devices += [pscustomobject][ordered]@{ busid = $busid; description = $description }
            }
        }

        $allowedClients = @(
            $serverTextBox.Text -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )

        $watchInterval = 300
        $existing = Get-CurrentConfigSafe
        if ($existing -and $existing.WatchIntervalSeconds) { $watchInterval = $existing.WatchIntervalSeconds }

        $configObject = [pscustomobject][ordered]@{
            devices = $devices
            allowedClients = $allowedClients
            watchIntervalSeconds = $watchInterval
        }
        $configObject | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $targetPath -Encoding UTF8
        Write-GuiLog "Saved selection to $targetPath ($($devices.Count) device(s))."

        Write-GuiLog 'Applying share state (bind new, unbind deselected)...'
        $results = Sync-UsbShare -ConfigPath $targetPath -UnbindRemoved -AssumeElevated -Quiet
        foreach ($result in $results) {
            $tone = switch ($result.Result) {
                'ok' { 'share: ' }
                'bound' { 'share: ' }
                'unbound' { 'unshare: ' }
                'dry-run' { 'dry-run: ' }
                'missing' { 'MISSING: ' }
                default { 'ERROR: ' }
            }
            Write-GuiLog "$tone$($result.Device)$(if ($result.BusId) { ' (bus ' + $result.BusId + ')' }) - $($result.Message)"
        }

        if ($allowedClients.Count -gt 0) {
            $firewall = Set-UsbShareFirewall -ConfigPath $targetPath
            Write-GuiLog "Firewall: $($firewall.Message)"
        } else {
            Write-GuiLog 'Firewall: no allowed client IPs set - scoped rule NOT created.'
        }

        Update-DeviceList
        $statusLabel.Text = 'Applied. Devices stay shared across reboots (scheduled task).'
        Write-GuiLog 'Done. On HAOS: install/refresh the USB Share Bridge add-on and set the same devices.'
    } catch {
        Write-GuiLog "Apply failed: $($_.Exception.Message)"
        $statusLabel.Text = 'Apply failed - see log.'
    } finally {
        $listView.Enabled = ($null -ne $script:UsbipdPath)
        $applyButton.Enabled = ($null -ne $script:UsbipdPath)
    }
})

$installButton.Add_Click({
    $installButton.Enabled = $false
    try {
        Write-GuiLog 'Installing usbipd-win via winget (a console window will open; follow its prompts)...'
        $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
        if (-not $winget) {
            Write-GuiLog 'winget not found. Install manually: https://github.com/dorssel/usbipd-win/releases'
            return
        }
        Start-Process -FilePath $winget.Source -ArgumentList 'install', '--interactive', '--exact', 'dorssel.usbipd-win' -Wait
        Update-UsbipdPresence
        Update-DeviceList
        if ($script:UsbipdPath) {
            Write-GuiLog "usbipd-win installed: $script:UsbipdPath"
        } else {
            Write-GuiLog 'usbipd.exe still not found - did the winget install complete?'
        }
    } finally {
        $installButton.Enabled = $true
    }
})

$taskButton.Add_Click({
    try {
        $taskName = Register-UsbShareScheduledTask -InstallDir $PSScriptRoot
        Write-GuiLog "Scheduled task '$taskName' registered - devices re-share at boot and every 5 minutes."
    } catch {
        Write-GuiLog "Could not register scheduled task: $($_.Exception.Message)"
    }
})

$autoStartCheckBox.Add_CheckedChanged({
    if ($script:SuppressAutoStartEvents) { return }
    try {
        if ($autoStartCheckBox.Checked) {
            $null = Enable-UsbGuiAutoStart -TargetScript $PSCommandPath
            Write-GuiLog 'GUI will now start automatically at Windows logon (elevated, no UAC prompt).'
        } else {
            $null = Disable-UsbGuiAutoStart
            Write-GuiLog 'GUI will no longer start automatically at logon. Device sharing still survives reboot.'
        }
    } catch {
        Write-GuiLog "Could not update autostart: $($_.Exception.Message)"
        $script:SuppressAutoStartEvents = $true
        try { $autoStartCheckBox.Checked = Test-UsbGuiAutoStart } catch { }
        $script:SuppressAutoStartEvents = $false
    }
})

# ---------------------------------------------------------------------------
# Run / self-check
# ---------------------------------------------------------------------------

if ($SelfCheck) {
    # Exercise construction and the load path without showing a window.
    Update-UsbipdPresence
    if ($script:UsbipdPath) { Update-DeviceList }
    $form.Dispose()
    Write-Host 'GUI self-check passed.'
    exit 0
}

$null = $form.ShowDialog()
$form.Dispose()
