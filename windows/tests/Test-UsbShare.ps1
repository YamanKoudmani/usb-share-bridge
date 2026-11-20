# Hardware-free tests for UsbShare.psm1, run against a fake usbipd binary.
# Usage: powershell -File tests\Test-UsbShare.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path (Split-Path -Parent $here) 'UsbShare.psm1'
$fakeUsbipd = Join-Path $here 'bin\usbipd.cmd'
$bindLog = Join-Path $here 'bin\bind-log.txt'
$unbindLog = Join-Path $here 'bin\unbind-log.txt'

Import-Module $modulePath -Force

$script:Failures = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:Failures++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
    }
}

if (Test-Path -LiteralPath $bindLog) { Remove-Item -LiteralPath $bindLog -Force }
if (Test-Path -LiteralPath $unbindLog) { Remove-Item -LiteralPath $unbindLog -Force }

Write-Host '== list parsing =='
$devices = Get-UsbDeviceList -UsbipdPath $fakeUsbipd
Assert-True ($devices.Count -eq 3) 'list returns 3 devices'
$sdr = $devices | Where-Object { $_.VidPid -eq '0bda:2838' }
Assert-True ($null -ne $sdr) 'RTL-SDR found by VidPid'
Assert-True ($sdr.BusId -eq '1-1') 'RTL-SDR busid is 1-1'
Assert-True ($sdr.State -eq 'Not shared') 'RTL-SDR state parsed as Not shared'
Assert-True ($sdr.Description -like '*RTL-SDR Blog V3*') 'description parsed'
$zstick = $devices | Where-Object { $_.VidPid -eq '0658:0200' }
Assert-True ($zstick.State -eq 'Attached') 'Z-Stick state parsed as Attached'
$json = $devices | ConvertTo-Json -Depth 3
Assert-True ($json -match '0bda:2838') 'list serializes to JSON'

Write-Host '== config + dry-run sync plan =='
$configFile = Join-Path $env:TEMP "usbshare-test-config.json"
@'
{
  "devices": [
    { "id": "0bda:2838", "description": "RTL-SDR" },
    { "busid": "2-2", "description": "CP210x serial" },
    { "id": "1234:5678", "description": "Ghost device" }
  ],
  "allowedClients": ["192.168.1.50"]
}
'@ | Set-Content -LiteralPath $configFile -Encoding UTF8

$plan = Sync-UsbShare -ConfigPath $configFile -UsbipdPath $fakeUsbipd -DryRun -Quiet
Assert-True ($plan.Count -eq 3) 'plan has one result per configured device'
$sdrPlan = $plan | Where-Object { $_.Device -eq 'RTL-SDR' }
Assert-True ($sdrPlan.Action -eq 'bind' -and $sdrPlan.Result -eq 'dry-run') 'RTL-SDR planned as bind (dry-run)'
Assert-True ($sdrPlan.Message -like '*usbipd bind --busid 1-1*') 'plan message names the resolved bus id'
$cpPlan = $plan | Where-Object { $_.Device -eq 'CP210x serial' }
Assert-True ($cpPlan.Action -eq 'none' -and $cpPlan.Result -eq 'ok') 'already-shared device is a no-op'
$ghost = $plan | Where-Object { $_.Device -eq 'Ghost device' }
Assert-True ($ghost.Result -eq 'missing') 'unknown VID:PID reported as missing'
Assert-True (-not (Test-Path -LiteralPath $bindLog)) 'dry-run executed nothing'

Write-Host '== real sync against fake binary =='
$null = Sync-UsbShare -ConfigPath $configFile -UsbipdPath $fakeUsbipd -Quiet -AssumeElevated
$bindCalls = @()
if (Test-Path -LiteralPath $bindLog) {
    $bindCalls = @(Get-Content -LiteralPath $bindLog)
}
Assert-True ($bindCalls.Count -eq 1) 'one bind executed'
Assert-True ($bindCalls[0] -match '--busid 1-1') 'bind targeted resolved bus id 1-1'

Write-Host '== config validation =='
$badConfig = Join-Path $env:TEMP 'usbshare-test-bad.json'
'{ "devices": [ { "id": "zzz" } ] }' | Set-Content -LiteralPath $badConfig -Encoding UTF8
$threw = $false
try { $null = Get-UsbShareConfig -Path $badConfig } catch { $threw = $true }
Assert-True $threw 'invalid VID:PID rejected with an error'

Write-Host '== starter config =='
$exampleConfigPath = Join-Path (Split-Path -Parent $modulePath) 'config.example.json'
$example = Get-UsbShareConfig -Path $exampleConfigPath
Assert-True ($example.Devices.Count -eq 0) 'starter config ships with an empty device list'
Assert-True ($example.AllowedClients.Count -eq 0) 'starter config ships with no allowed clients'

Write-Host '== device naming enrichment =='
$idsSdr = Get-UsbIdsName -VidPid '0bda:2838'
Assert-True ($null -ne $idsSdr) 'usb.ids resolves 0bda:2838'
Assert-True ($idsSdr.Vendor -like 'Realtek*') 'usb.ids: 0bda is Realtek'
Assert-True ($idsSdr.Product -like 'RTL2838*') 'usb.ids: 0bda:2838 product resolves'
$idsMtk = Get-UsbIdsName -VidPid '0e8d:7902'
Assert-True ($idsMtk.Vendor -like 'MediaTek*') 'usb.ids: 0e8d is MediaTek'
Assert-True (-not $idsMtk.Product) 'usb.ids: 0e8d:7902 has no product name (vendor still known)'
$best1 = Select-UsbDeviceDescription -UsbipdDescription 'Bulk-In, Interface' -PnpName 'Realtek RTL2832UHIDIR'
Assert-True ($best1 -eq 'Realtek RTL2832UHIDIR') 'Windows name beats generic usbipd string'
$best2 = Select-UsbDeviceDescription -UsbipdDescription 'MediaTek Bluetooth Adapter' -PnpName 'USB Device'
Assert-True ($best2 -eq 'MediaTek Bluetooth Adapter') 'usbipd description beats generic Windows name'
$best3 = Select-UsbDeviceDescription -UsbipdDescription 'USB' -PnpName 'USB Input Device' -UsbIdsProduct 'NS1066'
Assert-True ($best3 -eq 'NS1066') 'usb.ids product beats all-generic names'
$enriched = Get-UsbDeviceList -UsbipdPath $fakeUsbipd
$sdrEnriched = $enriched | Where-Object { $_.VidPid -eq '0bda:2838' }
Assert-True ([bool]$sdrEnriched.Manufacturer) 'device rows carry a manufacturer'
Assert-True ($sdrEnriched.PSObject.Properties.Name -contains 'UsbipdDescription') 'raw usbipd description preserved as its own field'

Write-Host '== GUI autostart helpers =='
Assert-True (-not (Test-UsbGuiAutoStart)) 'GUI autostart task absent by default on a clean system'

Write-Host '== unbind removed devices (GUI deselect) =='
$selectionConfig = Join-Path $env:TEMP 'usbshare-test-selection.json'
@'
{
  "devices": [
    { "id": "10c4:ea60", "description": "CP210x serial" }
  ],
  "allowedClients": []
}
'@ | Set-Content -LiteralPath $selectionConfig -Encoding UTF8
$null = Sync-UsbShare -ConfigPath $selectionConfig -UsbipdPath $fakeUsbipd -Quiet -AssumeElevated -UnbindRemoved
$unbindCalls = @()
if (Test-Path -LiteralPath $unbindLog) { $unbindCalls = @(Get-Content -LiteralPath $unbindLog) }
$unbindTargeted = @($unbindCalls | Where-Object { $_ -match '--busid 1-3' })
$unbindSkipped = @($unbindCalls | Where-Object { $_ -match '--busid 1-1' })
Assert-True ($unbindTargeted.Count -ge 1) 'attached-but-deselected device is unbound'
Assert-True ($unbindCalls.Count -ge 2) 'attached device is detached before unbind'
Assert-True ($unbindSkipped.Count -eq 0) 'not-shared deselected device is left alone'
$bindCalls2 = if (Test-Path -LiteralPath $bindLog) { @(Get-Content -LiteralPath $bindLog) } else { @() }
Assert-True ($bindCalls2.Count -eq 1) 'no extra bind executed during unbind pass'

Remove-Item -LiteralPath $configFile, $badConfig, $selectionConfig -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $configFile, $badConfig -Force -ErrorAction SilentlyContinue
if ($script:Failures -gt 0) {
    Write-Host ''
    Write-Host "$($script:Failures) test(s) FAILED." -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'All tests passed.' -ForegroundColor Green
