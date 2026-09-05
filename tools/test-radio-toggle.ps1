# Turn the virtual radio off and on through the Windows radio manager.
#
# This is the Airplane-mode path. The serialhcibus sample carries
# GUID_DEVINTERFACE_BLUETOOTH_RADIO_ONOFF_VENDOR_SPECIFIC handling for it, and
# the plan was to add that only if the toggle actually misbehaves - so this
# script is how we find out. Windows.Devices.Radios.Radio.SetStateAsync is what
# the Settings toggle and Airplane mode drive underneath.
#
# Run in the guest with the bridge connected and the radio up.
[CmdletBinding()]
param(
    [int]$Cycles = 2,
    [int]$SettleSec = 6
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\winrt-await.ps1"

$null = [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.BluetoothAdapter, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]

$access = Await ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) `
                ([Windows.Devices.Radios.RadioAccessStatus]) 15000
Write-Host "Radio.RequestAccessAsync: $access"
if ("$access" -ne 'Allowed') {
    Write-Host 'FAIL: no access to the radio manager' -ForegroundColor Red
    exit 1
}

$radios = Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) `
                ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]]) 15000
$bt = $radios | Where-Object { "$($_.Kind)" -eq 'Bluetooth' } | Select-Object -First 1
if ($null -eq $bt) {
    Write-Host 'FAIL: no Bluetooth radio listed' -ForegroundColor Red
    exit 1
}
Write-Host "radio: '$($bt.Name)'  state=$($bt.State)"

$failed = $false
for ($i = 1; $i -le $Cycles; $i++) {
    Write-Host ''
    Write-Host "=== cycle $i/$Cycles ===" -ForegroundColor Cyan

    foreach ($target in @('Off', 'On')) {
        $want = [Windows.Devices.Radios.RadioState]::$target
        $r = Await ($bt.SetStateAsync($want)) ([Windows.Devices.Radios.RadioAccessStatus]) 30000
        Start-Sleep -Seconds $SettleSec

        # Re-read through a fresh enumeration: the Radio object caches State.
        $now = Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) `
                     ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]]) 15000
        $bt  = $now | Where-Object { "$($_.Kind)" -eq 'Bluetooth' } | Select-Object -First 1

        if ($null -eq $bt) {
            Write-Host "  set $target -> $r, but the radio vanished" -ForegroundColor Red
            $failed = $true
            break
        }
        $ok = ("$($bt.State)" -eq $target)
        Write-Host ("  set {0,-3} -> {1,-8} state now {2}" -f $target, $r, $bt.State) `
                   -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
        if (-not $ok) { $failed = $true }
    }
}

Write-Host ''
Write-Host '=== adapter still usable? ===' -ForegroundColor Cyan
$adapter = Await ([Windows.Devices.Bluetooth.BluetoothAdapter]::GetDefaultAsync()) `
                 ([Windows.Devices.Bluetooth.BluetoothAdapter]) 20000
if ($null -eq $adapter) {
    Write-Host '  FAIL: no adapter after toggling' -ForegroundColor Red
    $failed = $true
} else {
    $addr = ('{0:X12}' -f $adapter.BluetoothAddress) -replace '(..)(?=.)', '$1:'
    Write-Host "  adapter $addr  LE=$($adapter.IsLowEnergySupported)" -ForegroundColor Green
}

Write-Host ''
if ($failed) { Write-Host 'RESULT: FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: radio toggles off and on cleanly' -ForegroundColor Green
