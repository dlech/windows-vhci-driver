# Shared helper for awaiting WinRT async operations from Windows PowerShell.
#
# Dot-source this from a client script:
#     . "$PSScriptRoot\winrt-await.ps1"
#
# WinRT async methods return IAsyncOperation, which PowerShell cannot await
# directly. AsTask() from System.Runtime.WindowsRuntime converts one to a Task,
# but it is generic and has several overloads, so the right one has to be picked
# by reflection.
#
# Note the limitation this does NOT solve: Windows PowerShell 5.1 cannot
# subscribe to WinRT *events* at all ("cannot subscribe to Windows RT events"),
# so anything event-driven - BluetoothLEAdvertisementWatcher, GATT value-changed
# notifications - needs C# or another language. Async operations are fine.

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await {
    param($Operation, $ResultType, [int]$TimeoutMs = 15000)

    $method = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $task   = $method.Invoke($null, @($Operation))

    # Callers pass their own timeout because these differ by orders of
    # magnitude: a property read returns at once, while a BLE
    # DeviceInformation.FindAllAsync actually performs a scan.
    if (-not $task.Wait($TimeoutMs)) {
        throw "WinRT operation timed out after ${TimeoutMs}ms"
    }
    return $task.Result
}

$null = [Windows.Storage.Streams.IBuffer, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Security.Cryptography.CryptographicBuffer, Windows.Security.Cryptography, ContentType = WindowsRuntime]

# PowerShell 5.1 cannot BIND an IBuffer to a method parameter, even though it
# recognises the object as one. A GATT read's Value satisfies
#
#     $value -is [Windows.Storage.Streams.IBuffer]      ->  True
#
# and yet every call taking an IBuffer - DataReader.FromBuffer,
# CryptographicBuffer.CopyToByteArray, EncodeToHexString, and
# GattCharacteristic.WriteValueAsync - fails the same way:
#
#     Cannot convert the "System.__ComObject" value of type "System.__ComObject"
#     to type "Windows.Storage.Streams.IBuffer"
#
# `-as [IBuffer]` also yields $null. The limitation is in PowerShell's parameter
# binder, not in the projection: invoking the very same method through
# reflection marshals the argument correctly. So anything taking an IBuffer has
# to go through Invoke.
$script:BufferToArray = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions].GetMethod(
    'ToArray', [Type[]]@([Windows.Storage.Streams.IBuffer]))

# Read an IBuffer (what GATT reads return) into a byte array.
function Get-BufferBytes {
    param($Buffer)

    if ($null -eq $Buffer) { return , @() }
    return , $script:BufferToArray.Invoke($null, @($Buffer))
}

# Build an IBuffer from a byte array (what GATT writes take).
# CreateFromByteArray takes a byte[], not an IBuffer, so it binds normally.
function New-Buffer {
    param([byte[]]$Bytes)

    return [Windows.Security.Cryptography.CryptographicBuffer]::CreateFromByteArray($Bytes)
}

# Call a method that takes an IBuffer argument, via reflection.
function Invoke-WithBuffer {
    param($Target, [string]$Method, $Buffer)

    $info = $Target.GetType().GetMethod($Method, [Type[]]@([Windows.Storage.Streams.IBuffer]))
    if ($null -eq $info) { throw "no $Method(IBuffer) on $($Target.GetType().FullName)" }
    return $info.Invoke($Target, @($Buffer))
}
