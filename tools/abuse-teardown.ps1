# Teardown and cancellation abuse for winvhci. Run in the guest, ideally with
# Driver Verifier enabled on winvhci.sys.
#
#     .\abuse-teardown.ps1 -Rounds 5
#
# What this is for. The radio's lifetime is tied to a file handle, so a client
# dying abruptly is the NORMAL case, not an edge case - and when it dies the
# driver has to complete BTHX reads the Bluetooth stack has pended, purge both
# backlogs, and tear the PDO down, all while the stack may still be issuing
# WRITE_HCI. That is the race most likely to bugcheck, and none of it is
# exercised by a well-behaved session.
#
# Each round:
#   1. start the bridge, wait for the radio to reach OK
#   2. let the stack drive the transport for a moment
#   3. kill the bridge WITHOUT letting it close anything cleanly
#   4. check the radio is gone and the machine is still alive
[CmdletBinding()]
param(
    [int]$Rounds     = 5,
    [string]$Bridge  = 'C:\tools\vhcibridge.ps1',
    [string]$RemoteHost = '10.0.2.2',
    [int]$Port       = 6402,
    [int]$SettleSec  = 20,
    # How long the radio is allowed to take to disappear after the client dies.
    # Tearing the node down means unloading BthPort's whole stack above it - the
    # enumerator and RFCOMM nodes too - so this is not instant.
    [int]$TeardownSec = 20,
    # How to restart the device for the final round. Defaults to devcon, which
    # is what a WDK machine has; CI passes build\ci\vhci-devnode.ps1 instead,
    # because devcon may not be redistributed and is absent from some runner
    # images entirely.
    [string]$Devnode,
    [string]$Devcon = 'C:\winvhci\devcon.exe'
)

$ErrorActionPreference = 'Stop'

function Get-Radio {
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'WINVHCI\RADIO*' -and $_.Problem -ne 'CM_PROB_PHANTOM' } |
        Select-Object -First 1
}

$failures = 0

for ($i = 1; $i -le $Rounds; $i++) {
    Write-Host "=== round $i/$Rounds ===" -ForegroundColor Cyan

    $p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-ExecutionPolicy','Bypass','-File',$Bridge,
        '-RemoteHost',$RemoteHost,'-Port',$Port
    ) -RedirectStandardOutput "C:\abuse-$i.log" -RedirectStandardError "C:\abuse-$i.err"

    # Wait for the stack to bring the radio up, so the kill lands while BTHX
    # reads are pended and the stack is actively driving the transport.
    $deadline = (Get-Date).AddSeconds($SettleSec)
    $radio = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        $radio = Get-Radio
        if ($radio -and $radio.Status -eq 'OK') { break }
    }

    if (-not $radio) {
        Write-Host '  radio never appeared' -ForegroundColor Yellow
    } else {
        Write-Host "  radio: $($radio.Status)"
    }

    # No graceful shutdown: kill the process outright, so the handle is closed
    # by the kernel with I/O still outstanding.
    Write-Host "  killing bridge (pid $($p.Id)) mid-flight"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue

    $t0 = Get-Date
    $deadline = $t0.AddSeconds($TeardownSec)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-Radio
    } while ($after -and (Get-Date) -lt $deadline)

    $elapsed = ((Get-Date) - $t0).TotalSeconds
    if ($after) {
        Write-Host ("  FAIL: radio still present {0:N1}s after client death: {1}" -f $elapsed, $after.Status) -ForegroundColor Red
        $failures++
    } else {
        Write-Host ("  radio gone after {0:N1}s" -f $elapsed) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== kill the client with ACL in flight ===' -ForegroundColor Cyan
#
# The rounds above kill during initialisation, which is HCI commands and events
# only. This one kills in the middle of a GATT session, so ATT traffic is moving
# over ACL and the ACL read queue and its backlog are the ones being torn down.
#
if (Test-Path 'C:\tools\win-ble-connect.ps1') {
    $p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-ExecutionPolicy','Bypass','-File',$Bridge,
        '-RemoteHost',$RemoteHost,'-Port',$Port
    ) -RedirectStandardOutput 'C:\abuse-acl.log' -RedirectStandardError 'C:\abuse-acl.err'
    Start-Sleep -Seconds $SettleSec

    $gatt = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-ExecutionPolicy','Bypass','-File','C:\tools\win-ble-connect.ps1'
    ) -RedirectStandardOutput 'C:\abuse-gatt.log' -RedirectStandardError 'C:\abuse-gatt.err'

    # Long enough to be inside service discovery / a characteristic read.
    Start-Sleep -Seconds 12
    Write-Host '  killing bridge during GATT traffic'
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    Stop-Process -Id $gatt.Id -Force -ErrorAction SilentlyContinue

    $t0 = Get-Date
    $deadline = $t0.AddSeconds($TeardownSec)
    do { Start-Sleep -Milliseconds 500; $after = Get-Radio } while ($after -and (Get-Date) -lt $deadline)
    if ($after) {
        Write-Host '  FAIL: radio survived the client' -ForegroundColor Red
        $failures++
    } else {
        Write-Host '  radio gone; machine alive' -ForegroundColor Green
    }
} else {
    Write-Host '  skipped: win-ble-connect.ps1 not present' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '=== device restart with a client attached ===' -ForegroundColor Cyan
$p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-ExecutionPolicy','Bypass','-File',$Bridge,
    '-RemoteHost',$RemoteHost,'-Port',$Port
) -RedirectStandardOutput 'C:\abuse-dis.log' -RedirectStandardError 'C:\abuse-dis.err'
Start-Sleep -Seconds $SettleSec

# Pull the FDO out from under a live client: the child PDO and every pended
# request have to be torn down while userspace still holds the handle.
if ($Devnode) {
    & $Devnode -Restart | Out-Null
} else {
    & $Devcon restart 'root\winvhci' | Out-Null
}
Start-Sleep -Seconds 6
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Write-Host '  survived a device restart under a live client' -ForegroundColor Green

Write-Host ''
if ($failures -gt 0) {
    Write-Host "RESULT: $failures round(s) left a stale radio" -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: no bugcheck, no stale radios' -ForegroundColor Green
