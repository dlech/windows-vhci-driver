# Scan for BLE advertisements through the virtual radio.
#
# Separate from win-ble-test.ps1 because it cannot be done in PowerShell:
# Windows PowerShell 5.1 refuses to subscribe to WinRT events at all
# ("Windows PowerShell cannot subscribe to Windows RT events"), and
# BluetoothLEAdvertisementWatcher is entirely event-driven. So the watcher is
# compiled as C#, which has no such limitation - the same thing any real client
# (Bleak, a C# app) does.
#
# Run in the guest while vhcibridge.ps1 is connected to a Bumble controller
# started with --peer:
#
#     .\win-ble-scan.ps1 -Seconds 15
#
# STATUS: NOT WORKING YET. csc still rejects the WinMD references with
#
#     Windows.Foundation.winmd: error CS0012: The type 'System.Attribute' is
#     defined in an assembly that is not referenced.
#
# which needs the .NET Framework reference-assembly facades, and this guest has
# no "Reference Assemblies\Microsoft\Framework\.NETFramework" directory to take
# them from. Options if it is worth finishing: install the .NET Framework 4.x
# targeting pack in the guest, or reference the facades that ship under
# Microsoft.NET\Framework*\v4.0.30319\WPF or the Windows SDK.
#
# It is NOT needed to prove discovery works: win-ble-test.ps1 check 4 uses
# DeviceInformation.FindAllAsync, which needs no event handler, and it already
# discovers the advertising peer through the virtual radio. This script would
# only add a second, event-driven confirmation.
[CmdletBinding()]
param(
    [int]$Seconds = 15
)

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.Threading;
using Windows.Devices.Bluetooth.Advertisement;

public static class BleScan
{
    // Synchronous by design: the caller just wants "what did you see in N
    // seconds", and avoiding async keeps this callable straight from
    // PowerShell.
    public static List<string> Scan(int seconds)
    {
        var results = new List<string>();
        var seen = new HashSet<ulong>();

        var watcher = new BluetoothLEAdvertisementWatcher();
        // Active scanning also solicits scan responses, which is where a
        // device's name usually lives.
        watcher.ScanningMode = BluetoothLEScanningMode.Active;

        watcher.Received += (s, e) =>
        {
            lock (results)
            {
                if (seen.Add(e.BluetoothAddress))
                {
                    results.Add(string.Format(
                        "{0:X12}  name='{1}'  rssi={2}  type={3}",
                        e.BluetoothAddress,
                        e.Advertisement.LocalName,
                        e.RawSignalStrengthInDBm,
                        e.AdvertisementType));
                }
            }
        };

        watcher.Start();
        Thread.Sleep(seconds * 1000);
        watcher.Stop();

        lock (results) { return new List<string>(results); }
    }
}
'@

if (-not ('BleScan' -as [type])) {
    # Compile with csc.exe rather than Add-Type -ReferencedAssemblies.
    #
    # Add-Type resolves references via Assembly.Load, which cannot load a
    # .winmd: it fails with "The given assembly name or codebase was invalid
    # (0x80131047)". csc accepts WinMD with /reference, which is the supported
    # way for a desktop-framework assembly to consume WinRT types.
    $csc = 'C:\Windows\Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) {
        $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    }
    if (-not (Test-Path $csc)) { throw "no csc.exe found" }

    $winmd  = 'C:\Windows\System32\WinMetadata'
    $srcFile = Join-Path $env:TEMP 'BleScan.cs'
    $dllFile = Join-Path $env:TEMP 'BleScan.dll'
    Set-Content -Path $srcFile -Value $source -Encoding UTF8

    # WinMD types are expressed against the .NET Core-style contract
    # assemblies, so the framework facades must be referenced too or csc
    # reports "The type 'System.Attribute' is defined in an assembly that is
    # not referenced".
    $facades = Get-ChildItem 'C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework' -Recurse -Filter 'System.Runtime.dll' -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName

    $refs = @(
        (Join-Path $winmd 'Windows.Devices.winmd'),
        (Join-Path $winmd 'Windows.Foundation.winmd'),
        # Load it the way PowerShell can, then ask where it came from - a
        # strong-name Assembly::Load of this one fails here.
        (& {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime
            [AppDomain]::CurrentDomain.GetAssemblies() |
                Where-Object { $_.GetName().Name -eq 'System.Runtime.WindowsRuntime' } |
                Select-Object -First 1 -ExpandProperty Location
        })
    )
    if ($facades) { $refs += $facades }
    $args = @('/nologo', '/target:library', "/out:$dllFile") +
            ($refs | ForEach-Object { "/reference:$_" }) + @($srcFile)

    $out = & $csc @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "csc failed ($LASTEXITCODE)"
    }
    Add-Type -Path $dllFile
}

Write-Host "scanning for $Seconds seconds ..." -ForegroundColor Cyan
$found = [BleScan]::Scan($Seconds)

if ($found.Count -eq 0) {
    Write-Host 'NO ADVERTISEMENTS SEEN' -ForegroundColor Yellow
} else {
    Write-Host "saw $($found.Count) device(s):" -ForegroundColor Green
    foreach ($f in $found) { Write-Host "  $f" }
}
