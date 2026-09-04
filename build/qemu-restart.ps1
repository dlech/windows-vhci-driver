# Cleanly restart the guest.
#
# Needed more often than it looks: installing a new build of the driver over an
# old one updates the files and the service image path, but Windows keeps the
# ALREADY LOADED winvhci.sys in memory ("Service image path changed. Restart
# required for any devices using this service." in setupapi.dev.log). Without a
# reboot you are testing the previous binary while reading the new source, which
# is a spectacularly confusing way to debug.
[CmdletBinding()]
param(
    [int]$MonitorPort        = 55556,
    [int]$ShutdownTimeoutSec = 180,
    [switch]$NoKd
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if (Get-Process -Name 'qemu-system-aarch64' -ErrorAction SilentlyContinue) {
    Write-Host 'Sending ACPI shutdown...' -ForegroundColor Cyan
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $MonitorPort)
        $s = $c.GetStream()
        $r = New-Object System.IO.StreamReader($s)
        $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true
        $null = $r.ReadLine()
        $w.WriteLine('{"execute":"qmp_capabilities"}')
        while ($true) { $l = $r.ReadLine(); if ($l -match '"(return|error)"') { break } }
        $w.WriteLine('{"execute":"system_powerdown"}')
        while ($true) { $l = $r.ReadLine(); if ($l -match '"(return|error)"') { break } }
        $c.Close()
    } catch {
        Write-Warning "QMP shutdown failed: $($_.Exception.Message)"
    }

    $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSec)
    while ((Get-Process -Name 'qemu-system-aarch64' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
    }
    Get-Process -Name 'qemu-system-aarch64' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
}

$runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'qemu-run.ps1'))
if ($NoKd) { $runArgs += '-NoKd' }

Start-Process powershell -ArgumentList $runArgs -WindowStyle Minimized
Start-Sleep -Seconds 8

if (Get-Process -Name 'qemu-system-aarch64' -ErrorAction SilentlyContinue) {
    Write-Host 'Guest restarting.' -ForegroundColor Green
} else {
    throw 'QEMU failed to start'
}
