# Take / list / revert qcow2 snapshots of the guest disk.
#
# These are offline snapshots: the VM must be shut down. A live `savevm` is not
# possible here because the vvfat file-channel disk does not support snapshots.
#
#   .\qemu-snapshot.ps1 -List
#   .\qemu-snapshot.ps1 -Take clean
#   .\qemu-snapshot.ps1 -Revert clean
#
# Reverting is how we recover after a bugcheck during driver bring-up.

[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName='Take')]   [string]$Take,
    [Parameter(ParameterSetName='Revert')] [string]$Revert,
    [Parameter(ParameterSetName='Delete')] [string]$Delete,
    [Parameter(ParameterSetName='List')]   [switch]$List,
    [string]$VmDir = 'C:\Users\extra\qemu-vms\winvhci',
    [string]$Disk  = 'win11.qcow2',
    [int]   $ShutdownTimeoutSec = 180
)

$ErrorActionPreference = 'Stop'
$qemuImg = Join-Path ${env:ProgramFiles} 'qemu\qemu-img.exe'
$diskPath = Join-Path $VmDir $Disk
if (-not (Test-Path $diskPath)) { throw "Disk not found: $diskPath" }

function Stop-Guest {
    $p = Get-Process -Name 'qemu-system-aarch64' -ErrorAction SilentlyContinue
    if (-not $p) { return }

    Write-Host 'Guest is running - sending ACPI shutdown...' -ForegroundColor Cyan
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', 55556)
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
        Write-Warning "QMP shutdown request failed: $($_.Exception.Message)"
    }

    $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSec)
    while ((Get-Process -Name 'qemu-system-aarch64' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
    }
    $p = Get-Process -Name 'qemu-system-aarch64' -ErrorAction SilentlyContinue
    if ($p) {
        Write-Warning 'Guest did not shut down in time; killing QEMU. The snapshot will be crash-consistent.'
        $p | Stop-Process -Force
        Start-Sleep -Seconds 3
    } else {
        Write-Host 'Guest shut down cleanly.' -ForegroundColor Green
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Take' {
        Stop-Guest
        & $qemuImg snapshot -c $Take $diskPath
        if ($LASTEXITCODE -ne 0) { throw "snapshot -c failed ($LASTEXITCODE)" }
        Write-Host "Snapshot '$Take' created." -ForegroundColor Green
    }
    'Revert' {
        Stop-Guest
        & $qemuImg snapshot -a $Revert $diskPath
        if ($LASTEXITCODE -ne 0) { throw "snapshot -a failed ($LASTEXITCODE)" }
        Write-Host "Reverted to '$Revert'." -ForegroundColor Green
    }
    'Delete' {
        Stop-Guest
        & $qemuImg snapshot -d $Delete $diskPath
        Write-Host "Deleted '$Delete'." -ForegroundColor Green
    }
    default { }
}

Write-Host ''
& $qemuImg snapshot -l $diskPath
