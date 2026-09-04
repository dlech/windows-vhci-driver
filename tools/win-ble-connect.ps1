# Connect to the Bumble peer over GATT, through the virtual radio.
#
# This is the first thing in the project that moves ACL data. Everything proven
# before it - the BTHX handshake, the init sequence, discovery - is HCI commands,
# events and advertising reports. A GATT operation runs ATT over L2CAP over ACL,
# so it exercises the driver's second read channel and the
# MaxAclTransferInSize = 1021 it has been claiming since M1.
#
#     host:   python tools/bumble-controller.py --peer --dual-mode
#     guest:  .\vhcibridge.ps1 -RemoteHost 10.0.2.2 -Port 6402
#     guest:  .\win-ble-connect.ps1
#
# Steps:
#   1. find the peer with DeviceInformation.FindAllAsync (the proven path)
#   2. BluetoothLEDevice.FromIdAsync
#   3. GATT service discovery, uncached
#   4. read a characteristic, and check the value
#   5. write a characteristic
[CmdletBinding()]
param(
    # The peer's advertised address. Connecting by address rather than by
    # discovery is deliberate: DeviceInformation.FindAllAsync reads Windows'
    # device-enumeration cache, which a background scanner fills on its own
    # schedule, so it returns the peer only sometimes and a miss says nothing
    # about whether a connection would work.
    [string]$Address     = 'AA:BB:CC:DD:EE:FF',
    [ValidateSet('Random', 'Public')]
    [string]$AddressType = 'Random',
    [int]$Attempts = 4
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\winrt-await.ps1"

# The service the peer publishes. Must match bumble-controller.py.
$ServiceUuid = [guid]'7a9b0001-4c1d-4e2a-9f3b-1d2c3e4f5a6b'
$ReadUuid    = [guid]'7a9b0002-4c1d-4e2a-9f3b-1d2c3e4f5a6b'
$WriteUuid   = [guid]'7a9b0003-4c1d-4e2a-9f3b-1d2c3e4f5a6b'
$Expected    = 'hello from bumble'

# Force the WinRT projections to load.
$null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceService, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]

$Uncached = [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached
$GattOk   = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCommunicationStatus]::Success

$failed = $false
function Fail($message) {
    Write-Host "  FAIL: $message" -ForegroundColor Red
    $script:failed = $true
}

Write-Host '=== 1. locate the peer ===' -ForegroundColor Cyan
#
# Both ways of getting a BluetoothLEDevice go through Windows' device
# enumeration cache, which a background scanner fills on its own schedule. A
# single miss therefore says nothing about whether the radio or a connection
# works - it usually means the scanner has not got there yet. So retry, and
# treat a persistent miss as the failure rather than the first one.
#
$addrValue = [uint64]"0x$($Address -replace '[:-]','')"
$addrKind  = [Windows.Devices.Bluetooth.BluetoothAddressType]::$AddressType
$selector  = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($false)

$device = $null
for ($attempt = 1; $attempt -le $Attempts -and $null -eq $device; $attempt++) {
    $found = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)) `
                   ([Windows.Devices.Enumeration.DeviceInformationCollection]) 60000
    Write-Host "  attempt ${attempt}: $($found.Count) unpaired BLE device(s)"
    foreach ($d in $found) { Write-Host "      '$($d.Name)'  $($d.Id)" }

    $peer = $found | Where-Object { $_.Id -like "*$($Address.ToLower())*" } | Select-Object -First 1
    if ($peer) {
        $device = Await ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromIdAsync($peer.Id)) `
                        ([Windows.Devices.Bluetooth.BluetoothLEDevice]) 30000
    }
    if ($null -eq $device) {
        # Second route to the same object, for when the enumeration cache has
        # the address but not a DeviceInformation entry yet.
        $device = Await ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($addrValue, $addrKind)) `
                        ([Windows.Devices.Bluetooth.BluetoothLEDevice]) 30000
    }
    if ($null -eq $device -and $attempt -lt $Attempts) { Start-Sleep -Seconds 5 }
}

if ($null -eq $device) {
    Fail "could not get a BluetoothLEDevice for $Address after $Attempts attempts"
    exit 1
}
$addr = ('{0:X12}' -f $device.BluetoothAddress) -replace '(..)(?=.)', '$1:'
Write-Host "  name           : $($device.Name)"
Write-Host "  address        : $addr  ($($device.BluetoothAddressType))"
Write-Host "  connectionStatus: $($device.ConnectionStatus)"

Write-Host ''
Write-Host '=== 2. GATT service discovery (uncached) ===' -ForegroundColor Cyan
#
# Uncached matters. A cached result can be served from Windows' own store
# without a single packet crossing the transport, which would prove nothing at
# all about the ACL path this script exists to test.
#
$svcResult = Await ($device.GetGattServicesAsync($Uncached)) `
                   ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult]) 30000
Write-Host "  status   : $($svcResult.Status)"
if ($svcResult.Status -ne $GattOk) {
    Fail "service discovery failed: $($svcResult.Status)"
    exit 1
}
Write-Host "  services : $($svcResult.Services.Count)" -ForegroundColor Green
foreach ($s in $svcResult.Services) { Write-Host "    $($s.Uuid)" }

$service = $svcResult.Services | Where-Object { $_.Uuid -eq $ServiceUuid } | Select-Object -First 1
if ($null -eq $service) {
    Fail "the peer's service $ServiceUuid was not discovered"
    exit 1
}

Write-Host ''
Write-Host '=== 3. characteristics ===' -ForegroundColor Cyan
$chrResult = Await ($service.GetCharacteristicsAsync($Uncached)) `
                   ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult]) 30000
if ($chrResult.Status -ne $GattOk) {
    Fail "characteristic discovery failed: $($chrResult.Status)"
    exit 1
}
foreach ($c in $chrResult.Characteristics) {
    Write-Host "    $($c.Uuid)  [$($c.CharacteristicProperties)]"
}

$readChar  = $chrResult.Characteristics | Where-Object { $_.Uuid -eq $ReadUuid }  | Select-Object -First 1
$writeChar = $chrResult.Characteristics | Where-Object { $_.Uuid -eq $WriteUuid } | Select-Object -First 1

Write-Host ''
Write-Host '=== 4. read ===' -ForegroundColor Cyan
if ($null -eq $readChar) {
    Fail "readable characteristic $ReadUuid not found"
} else {
    $read = Await ($readChar.ReadValueAsync($Uncached)) `
                  ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult]) 30000
    if ($read.Status -ne $GattOk) {
        Fail "read failed: $($read.Status)"
    } else {
        $bytes = Get-BufferBytes $read.Value
        $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
        Write-Host "  $($bytes.Count) bytes: '$text'" -ForegroundColor Green
        if ($text -ne $Expected) { Fail "expected '$Expected', got '$text'" }
    }
}

Write-Host ''
Write-Host '=== 5. write ===' -ForegroundColor Cyan
if ($null -eq $writeChar) {
    Fail "writable characteristic $WriteUuid not found"
} else {
    $payload = [System.Text.Encoding]::UTF8.GetBytes("hello from windows")
    # Through reflection, because WriteValueAsync takes an IBuffer - see the
    # note in winrt-await.ps1.
    $op      = Invoke-WithBuffer $writeChar 'WriteValueAsync' (New-Buffer $payload)
    $status  = Await $op ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCommunicationStatus]) 30000
    Write-Host "  wrote $($payload.Count) bytes: $status"
    if ($status -ne $GattOk) { Fail "write failed: $status" }
    else { Write-Host '  (check the controller output for the matching line)' -ForegroundColor Green }
}

$device.Dispose()

Write-Host ''
if ($failed) {
    Write-Host 'RESULT: FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: GATT over ACL works through the virtual radio' -ForegroundColor Green
