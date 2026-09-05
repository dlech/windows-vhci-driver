# Prove the driver applies backpressure to userspace instead of dropping.
#
#     .\test-backpressure.ps1
#
# Run elevated, in the guest or on any machine with the driver installed. No
# controller emulator is needed, which is the point: this exercises the
# mechanism directly rather than hoping a load test happens to reach it.
#
# WHY IT LOOKS LIKE THIS
#
# Advertising reports are HCI EVENTS, so they travel controller -> host:
# userspace writes them and the driver hands them to whatever IOCTL_BTHX_READ_HCI
# requests BthPort has pending. The obvious test - attach a real controller and
# flood it - does not work, and it is worth saying why so nobody rebuilds it.
# A settled Bluetooth stack ALWAYS has a read pended, so 30,000 reports at full
# speed went straight through with the backlog never once exceeding zero. The
# backlog only fills when the stack is not reading, and the deterministic way to
# arrange that is to write events BEFORE asking for a radio: with no radio there
# is no BthPort, and nothing can drain.
#
# WHAT THE OLD DRIVER DID
#
# At a depth of WINVHCI_MAX_BACKLOG (64) it discarded the packet and failed the
# write with STATUS_INSUFFICIENT_RESOURCES. Both halves were bad. The loss was
# invisible - a dropped advertising report looks exactly like a device that was
# never advertising - and the failure was visible in the wrong place, because a
# Bumble sink pump treats a write exception as fatal and stops sending forever.
#
# WHAT IT DOES NOW, AND WHAT THIS CHECKS
#
#   1. Open the device, but do not ask for a radio. Nothing can drain.
#   2. Issue enough overlapped writes to exceed the backlog. The writes are
#      NOT waited on - waiting is exactly what a pended write prevents.
#   3. The first 64 complete; the rest are still in flight. Assert that none
#      FAILED, that the driver counts them as pended, and that nothing was
#      dropped.
#   4. Ask for a radio. BthPort attaches and starts reading.
#   5. Every pended write now completes. Assert that all of them did, that
#      WritesWaiting is back to zero, and that WritesTotal accounts for every
#      packet sent.

[CmdletBinding()]
param(
    # Comfortably more than WINVHCI_MAX_BACKLOG (64), so the overflow is not a
    # boundary case, but small enough that a failure prints legibly.
    [int]    $Packets    = 200,
    [int]    $SettleSec  = 20,
    [string]$Device      = '\\.\WinVhci'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vhci-io.ps1')

$MAX_BACKLOG = 64      # WINVHCI_MAX_BACKLOG in winvhci/winvhci.h

$script:ok = $true
function Assert([string]$Name, [bool]$Cond, [string]$Detail = '') {
    if ($Cond) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
        $script:ok = $false
    }
}

# HCI_LE_Advertising_Report, built the way Bumble encodes it. The address is
# little-endian on the wire; a hand-written version of this frame had it
# reversed, which a test that only counts packets would never notice.
$adv = [byte[]]@(
    0x04,                                # H4 type: event
    0x3E, 0x0C, 0x02, 0x01,              # LE meta, param len, adv report, 1 report
    0x00, 0x00,                          # event type ADV_IND, public address
    0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA,  # address AA:BB:CC:DD:EE:FF
    0x00,                                # advertising data length
    0xC4                                 # RSSI -60
)

Write-Host "opening $Device (no radio yet, so nothing can drain)" -ForegroundColor Cyan
[VhciIo]::Open($Device)

$writes = @()
try {
    $before = [VhciIo]::GetStats()
    Format-VhciStats $before | ForEach-Object { Write-Host $_ }

    Write-Host "issuing $Packets overlapped writes without waiting" -ForegroundColor Cyan
    $failed = 0
    for ($i = 0; $i -lt $Packets; $i++) {
        try   { $writes += [VhciIo]::BeginWrite($adv, $adv.Length) }
        catch { $failed++; if ($failed -le 3) { Write-Host "    write rejected: $($_.Exception.Message)" -ForegroundColor Yellow } }
    }

    $mid = [VhciIo]::GetStats()
    Format-VhciStats $mid | ForEach-Object { Write-Host $_ }

    Write-Host ''
    Write-Host 'with nothing draining:' -ForegroundColor Cyan
    Assert 'no write was rejected' ($failed -eq 0) `
           "$failed writes failed. Backpressure must pend a write, never fail it"
    Assert 'the backlog filled to its bound' ($mid.PendingEventPeak -ge $MAX_BACKLOG) `
           "event peak reached $($mid.PendingEventPeak), expected at least $MAX_BACKLOG"
    Assert 'writes past the bound were pended' `
           ($mid.WritesPended - $before.WritesPended -ge $Packets - $MAX_BACKLOG) `
           "only $($mid.WritesPended - $before.WritesPended) writes pended"
    Assert 'writes are waiting right now' ($mid.WritesWaiting -gt 0) `
           'nothing is pended, so this run did not reach backpressure at all'
    Assert 'nothing was dropped' `
           ($mid.DropsNoClient -eq $before.DropsNoClient -and
            $mid.DropsAllocFailed -eq $before.DropsAllocFailed) `
           "drops went from $($before.DropsNoClient)/$($before.DropsAllocFailed) to $($mid.DropsNoClient)/$($mid.DropsAllocFailed)"

    Write-Host ''
    Write-Host 'asking for a radio, so the Bluetooth stack starts reading' -ForegroundColor Cyan
    [VhciIo]::Write([byte[]]@(0xFF, 0x00), 2)

    # The radio has to be created, bth.inf has to bind, and BthPort has to
    # start pending reads before anything drains, so give it real time.
    $deadline = (Get-Date).AddSeconds($SettleSec)
    do {
        Start-Sleep -Milliseconds 500
        $now = [VhciIo]::GetStats()
    } while ($now.WritesWaiting -gt 0 -and (Get-Date) -lt $deadline)

    $completed = 0
    $stillPending = 0
    foreach ($w in $writes) {
        if ([VhciIo]::EndWrite($w, 2000)) { $completed++ } else { $stillPending++ }
    }
    $writes = @()

    $after = [VhciIo]::GetStats()
    Format-VhciStats $after | ForEach-Object { Write-Host $_ }

    Write-Host ''
    Write-Host 'after the stack attached:' -ForegroundColor Cyan
    Assert 'every write completed' ($completed -eq $Packets) `
           "$completed of $Packets completed, $stillPending still pending"
    Assert 'no write is left waiting' ($after.WritesWaiting -eq 0) `
           "$($after.WritesWaiting) writes are still pended, so the stack never drained them"
    Assert 'the driver accounted for every packet' `
           ($after.WritesTotal - $before.WritesTotal -eq $Packets) `
           "driver counted $($after.WritesTotal - $before.WritesTotal) packets, $Packets were sent"
    Assert 'still nothing dropped' `
           ($after.DropsNoClient -eq $before.DropsNoClient -and
            $after.DropsAllocFailed -eq $before.DropsAllocFailed) `
           "drops went from $($before.DropsNoClient)/$($before.DropsAllocFailed) to $($after.DropsNoClient)/$($after.DropsAllocFailed)"
}
finally {
    # Abandon anything still in flight before the handle closes, or the driver
    # could touch an OVERLAPPED this script has already freed.
    foreach ($w in $writes) { [VhciIo]::CancelWrite($w) }
    [VhciIo]::Close()
    Write-Host 'closed (radio removed)' -ForegroundColor Cyan
}

Write-Host ''
if ($ok) {
    Write-Host 'RESULT: backpressure engaged and nothing was lost' -ForegroundColor Green
    exit 0
}
Write-Host 'RESULT: loss or rejection detected' -ForegroundColor Red
exit 1
