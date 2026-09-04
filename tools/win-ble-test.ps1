# Exercise the Windows Bluetooth APIs against the virtual radio.
#
# This is M3's real exit criterion: not "the stack initialises" but "an ordinary
# Windows application sees a working adapter and discovers a device". Run it in
# the guest while vhcibridge.ps1 is connected to a Bumble controller that has an
# advertising peer:
#
#     host:   python tools/bumble-controller.py --peer --dual-mode
#     guest:  .\vhcibridge.ps1 -RemoteHost 10.0.2.2 -Port 6402
#     guest:  .\win-ble-test.ps1
#
# Checks, in order:
#   1. BluetoothAdapter.GetDefaultAsync()      - does Windows have an adapter?
#   2. Radio state                             - is it on?
#   3. BluetoothLEAdvertisementWatcher         - does it see the peer?
[CmdletBinding()]
param(
    [int]$ScanSeconds = 20
)

$ErrorActionPreference = 'Stop'

# WinRT async methods return IAsyncOperation, which PowerShell cannot await
# directly. AsTask() from System.Runtime.WindowsRuntime converts them, but it is
# generic and has several overloads, so the right one has to be picked by
# reflection.
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await {
    param($Operation, $ResultType, [int]$TimeoutMs = 15000)
    $method = $asTaskGeneric.MakeGenericMethod($ResultType)
    $task   = $method.Invoke($null, @($Operation))
    # A BLE DeviceInformation.FindAllAsync actually performs a scan, so it
    # needs far longer than a property read; callers pass their own timeout.
    if (-not $task.Wait($TimeoutMs)) { throw "WinRT operation timed out after ${TimeoutMs}ms" }
    return $task.Result
}

# Force the WinRT projections to load.
$null = [Windows.Devices.Bluetooth.BluetoothAdapter, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]

Write-Host '=== 1. BluetoothAdapter.GetDefaultAsync() ===' -ForegroundColor Cyan
$adapter = Await ([Windows.Devices.Bluetooth.BluetoothAdapter]::GetDefaultAsync()) ([Windows.Devices.Bluetooth.BluetoothAdapter])
if ($null -eq $adapter) {
    Write-Host 'NO ADAPTER from GetDefaultAsync()' -ForegroundColor Red
    Write-Host ''
    Write-Host '--- what does WinRT see at all? ---' -ForegroundColor Cyan

    # PnP can show a healthy radio while WinRT still reports nothing, so ask the
    # WinRT layer directly rather than inferring from Device Manager.
    try {
        $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
        $sel = [Windows.Devices.Bluetooth.BluetoothAdapter]::GetDeviceSelector()
        Write-Host "  adapter selector: $sel"
        $adapters = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
        Write-Host "  adapters found  : $($adapters.Count)"
        foreach ($a in $adapters) { Write-Host "    '$($a.Name)'  $($a.Id)" }
    } catch {
        Write-Host "  adapter enumeration failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        $access = Await ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus])
        Write-Host "  Radio.RequestAccessAsync: $access"
        $radios = Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
        Write-Host "  radios found    : $($radios.Count)"
        foreach ($r in $radios) { Write-Host "    $($r.Kind)  '$($r.Name)'  state=$($r.State)" }
    } catch {
        Write-Host "  radio enumeration failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    exit 1
}

$addr = ('{0:X12}' -f $adapter.BluetoothAddress) -replace '(..)(?=.)', '$1:'
Write-Host "  adapter address        : $addr" -ForegroundColor Green
Write-Host "  IsLowEnergySupported   : $($adapter.IsLowEnergySupported)"
Write-Host "  IsClassicSupported     : $($adapter.IsClassicSupported)"
Write-Host "  IsCentralRoleSupported : $($adapter.IsCentralRoleSupported)"
Write-Host "  IsPeripheralRoleSupported: $($adapter.IsPeripheralRoleSupported)"
Write-Host "  DeviceId               : $($adapter.DeviceId)"

Write-Host ''
Write-Host '=== 2. Radio state ===' -ForegroundColor Cyan
try {
    $radio = Await ($adapter.GetRadioAsync()) ([Windows.Devices.Radios.Radio])
    Write-Host "  name  : $($radio.Name)"
    Write-Host "  kind  : $($radio.Kind)"
    Write-Host "  state : $($radio.State)" -ForegroundColor Green
} catch {
    Write-Host "  radio query failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host "=== 3. BluetoothLEAdvertisementWatcher ($ScanSeconds s) ===" -ForegroundColor Cyan

$watcher = New-Object Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
$watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active

# Collect from the event handler into a synchronised list; the callback runs on
# a different thread.
$script:seen = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

# Windows PowerShell 5.1 cannot subscribe to WinRT events at all -
# Register-ObjectEvent fails with "cannot subscribe to Windows RT events" for
# any TypedEventHandler. So this check is best-effort, and must not abort the
# script: the event-free discovery check below is the one that actually matters
# here. (A real client - Bleak, or any C#/C++ app - has no such limitation.)
$subscription = $null
try {
$subscription = Register-ObjectEvent -InputObject $watcher -EventName Received -Action {
    $args0 = $EventArgs
    $a = ('{0:X12}' -f $args0.BluetoothAddress) -replace '(..)(?=.)', '$1:'
    [void]$script:seen.Add([pscustomobject]@{
        Address   = $a
        Name      = $args0.Advertisement.LocalName
        Rssi      = $args0.RawSignalStrengthInDBm
        Type      = $args0.AdvertisementType
    })
}

    try {
        $watcher.Start()
        Write-Host "  watcher status: $($watcher.Status)"
        $deadline = (Get-Date).AddSeconds($ScanSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if ($script:seen.Count -gt 0) { break }   # first hit is enough
        }
        Start-Sleep -Seconds 2
        $watcher.Stop()
    } finally {
        if ($subscription) {
            Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Host "  watcher unavailable from PowerShell: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host '  (this is a PowerShell limitation, not a driver problem - see check 4)' -ForegroundColor DarkGray
}

if ($script:seen.Count -eq 0) {
    Write-Host '  NO ADVERTISEMENTS SEEN' -ForegroundColor Yellow
} else {
    Write-Host "  saw $($script:seen.Count) advertisement(s):" -ForegroundColor Green
    $script:seen | Group-Object Address | ForEach-Object {
        $first = $_.Group[0]
        Write-Host ("    {0}  name='{1}'  rssi={2}  type={3}  x{4}" -f `
            $first.Address, $first.Name, $first.Rssi, $first.Type, $_.Count)
    }
}

Write-Host ''
Write-Host '=== 4. DeviceInformation.FindAllAsync (no event handler) ===' -ForegroundColor Cyan
#
# A second, independent check. Register-ObjectEvent on a WinRT TypedEventHandler
# is unreliable in Windows PowerShell 5.1, so a silent watcher above does not by
# itself prove nothing was discovered. This path is a plain async call that
# returns a collection, with no event subscription involved - if it lists the
# peer, discovery works regardless of what the watcher did.
#
try {
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $selector = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($false)
    $found = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)) ([Windows.Devices.Enumeration.DeviceInformationCollection]) 60000
    if ($found.Count -eq 0) {
        Write-Host '  no unpaired BLE devices known to Windows' -ForegroundColor Yellow
    } else {
        Write-Host "  $($found.Count) unpaired BLE device(s):" -ForegroundColor Green
        foreach ($d in $found) {
            Write-Host ("    '{0}'  {1}" -f $d.Name, $d.Id)
        }
    }
} catch {
    Write-Host "  FindAllAsync failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
