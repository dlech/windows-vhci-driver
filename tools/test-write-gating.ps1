# Prove the driver admits or refuses a write, and never quietly absorbs one.
#
#     .\test-write-gating.ps1
#
# Run elevated, in the guest or on any machine with the driver installed. No
# controller emulator is needed.
#
# WHAT THIS IS CHECKING, AND WHY IT IS THE INTERESTING PROPERTY
#
# The driver's backlogs are unbounded, exactly like Linux's /dev/vhci, where
# hci_recv_frame appends to hdev->rx_q with no capacity check, no drop and no
# blocking. An unbounded queue is only safe if nothing inadmissible ever gets
# into it, so the admission check is what carries the weight - and Linux has
# one:
#
#     case HCI_EVENT_PKT:
#     case HCI_ACLDATA_PKT:
#     ...
#             if (!data->hdev) {
#                     kfree_skb(skb);
#                     return -ENODEV;
#             }
#
# winvhci did NOT have it. A client that wrote before asking for its radio had
# its packets queued against a stack that did not exist, and they were then
# replayed into the bring-up of a radio that had not been created when they
# were sent. Measured, not theorised: 200 pre-radio advertising reports were
# all delivered the instant the radio appeared. STATUS_DEVICE_NOT_READY is the
# equivalent of -ENODEV, and this locks it in.
#
# So the shape of the test is: refuse, then admit, then flood.
#
#   1. With no radio, an event write and an ACL write are both REFUSED with
#      ERROR_NOT_READY - not queued, not dropped, and counted as refused.
#   2. Ask for a radio. It appears.
#   3. The same writes now SUCCEED.
#   4. A second radio request is refused, matching Linux's -EBADFD.
#   5. A malformed control packet is refused the way Linux refuses it: a
#      trailing tail, a reserved opcode bit, or a quirk bit with no Windows
#      analogue. winvhci used to accept all four and ignore them.
#   6. Flooding events loses nothing, and WritesTotal accounts for exactly
#      what was sent.
#   7. A packet larger than the stack's read buffer can carry - 257 bytes for
#      an event, 1021 for ACL - is refused at the write, where the sender can
#      be told, rather than accepted and then failed against the stack's read.
#   8. Closing and reopening back to back gives a second radio that stays
#      writable: the first radio's shutdown, which arrives asynchronously, must
#      not take the new one down with it.
#
# HISTORY WORTH KNOWING BEFORE CHANGING THIS
#
# An earlier version of this file tested BACKPRESSURE - a bounded backlog that
# pended a write instead of dropping it. It passed, and it was the wrong
# design: the only state that ever reached the bound was "no radio, so nothing
# is draining", because a settled Bluetooth stack always has a read pended and
# 30,000 advertising reports at full speed never took the depth above zero.
# Pending a write that has nowhere to go is not backpressure, it is a slower
# failure. Refusing it up front is the answer, and it is the reference
# implementation's answer.

[CmdletBinding()]
param(
    [int]    $Packets   = 500,
    [int]    $SettleSec = 20,
    [string]$Device     = '\\.\WinVhci'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vhci-io.ps1')

# STATUS_DEVICE_NOT_READY surfaces to Win32 as ERROR_NOT_READY,
# STATUS_INVALID_PARAMETER as ERROR_INVALID_PARAMETER and
# STATUS_BUFFER_TOO_SMALL as ERROR_INSUFFICIENT_BUFFER.
$ERROR_NOT_READY           = 21
$ERROR_INVALID_PARAMETER   = 87
$ERROR_INSUFFICIENT_BUFFER = 122

# Controller -> host packets have a ceiling set by the stack's read buffers:
# an event is at most 2 header bytes + 255 parameter bytes, and an ACL
# packet at most MaxAclTransferInSize, which INCLUDES its 4-byte header.
$MAX_EVENT_BODY = 257
$MAX_ACL_BODY   = 1021

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

# Returns the Win32 error a write failed with, or 0 if it succeeded.
function Try-Write([byte[]]$Frame) {
    try {
        [VhciIo]::Write($Frame, $Frame.Length)
        return 0
    } catch [System.ComponentModel.Win32Exception] {
        return $_.Exception.NativeErrorCode
    } catch {
        Write-Host "    unexpected: $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Yellow
        return -1
    }
}

# HCI_LE_Advertising_Report, byte for byte as Bumble encodes it. The address is
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

# An ACL frame on handle 1, 4 bytes of payload. Exercises the driver's second
# read channel, which is a separate backlog with a separate admission path.
$acl = [byte[]]@(0x02, 0x01, 0x00, 0x04, 0x00, 0xDE, 0xAD, 0xBE, 0xEF)

# PRECONDITION: no radio may exist. Closing the handle destroys it, but PnP
# teardown is not instant - it unloads BthPort's whole stack above the node -
# so a run started too soon after another would find a radio still draining.
Write-Host 'waiting for any previous radio to go away' -ForegroundColor Cyan
$gone = (Get-Date).AddSeconds($SettleSec * 2)
while ((Get-Date) -lt $gone) {
    $stale = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'WINVHCI\RADIO*' -and $_.Problem -ne 'CM_PROB_PHANTOM' }
    if (-not $stale) { break }
    Start-Sleep -Seconds 1
}
if ($stale) {
    Write-Host "  a radio is still present: $($stale.InstanceId) $($stale.Status) $($stale.Problem)" -ForegroundColor Red
    exit 2
}

Write-Host "opening $Device" -ForegroundColor Cyan
[VhciIo]::Open($Device)

try {
    $before = [VhciIo]::GetStats()
    Format-VhciStats $before | ForEach-Object { Write-Host $_ }

    # The size-mismatch contract vhci-io.ps1's GetStats relies on: a buffer
    # shorter than WINVHCI_STATS is refused outright with
    # ERROR_INSUFFICIENT_BUFFER, and Win32 reports ZERO bytes returned for
    # it - the driver puts the size it needs in the request's Information
    # field, but an error status never carries that back to user mode. A
    # message that waited for a non-zero count there could never appear,
    # which is how the v1.2.0 struct change reached users as a bare "failed".
    $probeReturned = [uint32]0
    $probeErr = [VhciIo]::ProbeStatsSize(4, [ref]$probeReturned)
    Assert 'a stats buffer that is too small is refused with ERROR_INSUFFICIENT_BUFFER' `
           ($probeErr -eq $ERROR_INSUFFICIENT_BUFFER) "got $probeErr"
    Assert 'and reports zero bytes returned, so the error code is the only signal' `
           ($probeReturned -eq 0) "returned $probeReturned"

    Write-Host ''
    Write-Host 'before a radio exists:' -ForegroundColor Cyan
    $eventErr = Try-Write $adv
    $aclErr   = Try-Write $acl
    $refused  = [VhciIo]::GetStats()

    Assert 'an event write is refused with ERROR_NOT_READY' ($eventErr -eq $ERROR_NOT_READY) `
           "got $eventErr, expected $ERROR_NOT_READY (STATUS_DEVICE_NOT_READY, Linux's -ENODEV)"
    Assert 'an ACL write is refused with ERROR_NOT_READY' ($aclErr -eq $ERROR_NOT_READY) `
           "got $aclErr, expected $ERROR_NOT_READY"
    Assert 'both refusals were counted' `
           ($refused.WritesNoRadio - $before.WritesNoRadio -eq 2) `
           "WritesNoRadio moved by $($refused.WritesNoRadio - $before.WritesNoRadio), expected 2"
    Assert 'nothing was queued' `
           ($refused.WritesTotal -eq $before.WritesTotal -and
            $refused.PendingEventCount -eq 0 -and $refused.PendingDataCount -eq 0) `
           "WritesTotal moved by $($refused.WritesTotal - $before.WritesTotal), event depth $($refused.PendingEventCount), acl depth $($refused.PendingDataCount)"
    Assert 'nothing was dropped' `
           ($refused.DropsNoClient -eq $before.DropsNoClient -and
            $refused.DropsAllocFailed -eq $before.DropsAllocFailed) `
           "drops moved to $($refused.DropsNoClient)/$($refused.DropsAllocFailed)"

    Write-Host ''
    Write-Host 'asking for a radio' -ForegroundColor Cyan
    [VhciIo]::Write([byte[]]@(0xFF, 0x00), 2)
    # Wait for the radio to be STARTED, not merely enumerated. Writes are
    # admitted from the PDO's D0Entry, which follows IRP_MN_START_DEVICE; the
    # devnode is visible to Get-PnpDevice before its driver has even loaded,
    # and on a first-time INF match that gap is seconds. Firing the writes on
    # mere presence made the admitted-phase asserts below fail spuriously.
    $appeared = $false
    $by = (Get-Date).AddSeconds($SettleSec)
    while ((Get-Date) -lt $by) {
        $r = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceId -like 'WINVHCI\RADIO*' -and $_.Problem -ne 'CM_PROB_PHANTOM' } |
                Select-Object -First 1
        if ($r -and $r.Status -eq 'OK') { $appeared = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Assert 'the radio appeared and started' $appeared `
           "no WINVHCI\RADIO node reached Status OK within $SettleSec s"

    Write-Host ''
    Write-Host 'once a radio exists:' -ForegroundColor Cyan
    $admitted = [VhciIo]::GetStats()
    $eventErr2 = Try-Write $adv
    $aclErr2   = Try-Write $acl

    Assert 'an event write is admitted' ($eventErr2 -eq 0) "failed with $eventErr2"
    Assert 'an ACL write is admitted'   ($aclErr2   -eq 0) "failed with $aclErr2"

    # Matches Linux's __vhci_create_device: if (data->hdev) return -EBADFD.
    # Not a new behaviour - this locks in one the driver already had.
    $secondRadio = Try-Write ([byte[]]@(0xFF, 0x00))
    Assert 'a second radio request is refused' ($secondRadio -ne 0) `
           'a duplicate FF 00 succeeded; Linux answers -EBADFD'

    Write-Host ''
    Write-Host 'packets the stack could never receive:' -ForegroundColor Cyan
    # One byte over each limit. The driver used to accept both: handed to a
    # pended read, the oversized packet failed THAT request - the stack's,
    # not the writer's - with STATUS_BUFFER_TOO_SMALL; parked on the backlog,
    # the write succeeded and the packet was thrown away later when a read
    # arrived. The only place the sender can be told is the write itself.
    $bigEvent = New-Object byte[] (1 + $MAX_EVENT_BODY + 1)
    $bigEvent[0] = 0x04; $bigEvent[1] = 0x3E; $bigEvent[2] = 0xFF
    $bigAcl = New-Object byte[] (1 + $MAX_ACL_BODY + 1)
    $bigAcl[0] = 0x02; $bigAcl[1] = 0x01
    $sized = [VhciIo]::GetStats()
    $bigEventErr = Try-Write $bigEvent
    $bigAclErr   = Try-Write $bigAcl
    $sizedAfter  = [VhciIo]::GetStats()
    Assert "an event with a $($MAX_EVENT_BODY + 1)-byte body is refused with ERROR_INVALID_PARAMETER" `
           ($bigEventErr -eq $ERROR_INVALID_PARAMETER) "got $bigEventErr"
    Assert "an ACL packet with a $($MAX_ACL_BODY + 1)-byte body is refused with ERROR_INVALID_PARAMETER" `
           ($bigAclErr -eq $ERROR_INVALID_PARAMETER) "got $bigAclErr"
    Assert 'neither oversized packet was counted as written or queued' `
           ($sizedAfter.WritesTotal -eq $sized.WritesTotal -and
            $sizedAfter.PendingEventCount -eq 0 -and $sizedAfter.PendingDataCount -eq 0) `
           "WritesTotal moved by $($sizedAfter.WritesTotal - $sized.WritesTotal), event depth $($sizedAfter.PendingEventCount), acl depth $($sizedAfter.PendingDataCount)"

    Write-Host ''
    Write-Host 'control packet validation, as Linux validates it:' -ForegroundColor Cyan

    # Linux requires the vendor packet to be exactly two bytes: vhci_get_user
    # pulls the type and the opcode, then rejects anything left over with
    #     if (skb->len > 0) { kfree_skb(skb); return -EINVAL; }
    # winvhci accepted a trailing tail and ignored it, so a client's framing
    # bug looked like it worked.
    Assert 'a control packet with a trailing tail is refused' `
           ((Try-Write ([byte[]]@(0xFF, 0x00, 0xDE, 0xAD))) -ne 0) `
           'FF 00 DE AD was accepted; Linux answers -EINVAL'

    # __vhci_create_device: /* bits 2-5 are reserved (must be zero) */
    #                       if (opcode & 0x3c) return -EINVAL;
    Assert 'a reserved opcode bit is refused' `
           ((Try-Write ([byte[]]@(0xFF, 0x04))) -ne 0) `
           'opcode 0x04 was accepted; bits 2-5 are reserved'

    # Bits 6 and 7 select HCI_QUIRK_EXTERNAL_CONFIG and HCI_QUIRK_RAW_DEVICE.
    # Neither has a Windows analogue, so they are refused rather than ignored -
    # a client that asks for a raw device should not silently get a cooked one.
    Assert 'the external-config opcode bit is refused' `
           ((Try-Write ([byte[]]@(0xFF, 0x40))) -ne 0) `
           'opcode 0x40 was accepted; there is no BTHX external configuration'
    Assert 'the raw-device opcode bit is refused' `
           ((Try-Write ([byte[]]@(0xFF, 0x80))) -ne 0) `
           'opcode 0x80 was accepted; there is no BTHX raw device'

    Write-Host ''
    Write-Host "flooding $Packets events" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $failed = 0
    for ($i = 0; $i -lt $Packets; $i++) {
        if ((Try-Write $adv) -ne 0) { $failed++ }
    }
    $sw.Stop()
    Write-Host ("  {0} writes in {1:N1}s ({2:N0}/s)" -f `
                $Packets, $sw.Elapsed.TotalSeconds, ($Packets / $sw.Elapsed.TotalSeconds))

    $after = [VhciIo]::GetStats()
    Format-VhciStats $after | ForEach-Object { Write-Host $_ }

    Write-Host ''
    Assert 'no write failed under load' ($failed -eq 0) "$failed of $Packets failed"
    Assert 'the driver accounted for every packet' `
           ($after.WritesTotal - $admitted.WritesTotal -eq $Packets + 2) `
           "driver counted $($after.WritesTotal - $admitted.WritesTotal), expected $($Packets + 2)"
    Assert 'still nothing dropped' `
           ($after.DropsNoClient -eq $before.DropsNoClient -and
            $after.DropsAllocFailed -eq $before.DropsAllocFailed) `
           "drops moved to $($after.DropsNoClient)/$($after.DropsAllocFailed)"
    Assert 'no further write was refused' `
           ($after.WritesNoRadio -eq $refused.WritesNoRadio) `
           "WritesNoRadio rose to $($after.WritesNoRadio) after the radio existed"

    # ---------------------------------------------------------------------
    # And once the STACK gives up, not just before the radio exists.
    #
    # There is no controller behind this radio, so BthPort sends HCI_Reset,
    # retries once, and abandons it about twelve seconds in - measured:
    #
    #     4.047549   command opcode 0x0c03   <-- HCI_Reset
    #     8.055532   command opcode 0x0c03   <-- HCI_Reset, retry
    #    12.055968   pdo D0 exit (target 5); the stack has stopped consuming
    #
    # RadioPresent is still TRUE at that point - the client has not withdrawn
    # anything - so without the D0Exit hook these writes were all admitted and
    # queued against nothing, 300 deep and unbounded when last measured. This
    # is Linux's second gate, hci_recv_frame refusing with -ENXIO unless HCI_UP
    # or HCI_INIT is set.
    #
    # It doubles as the thing that makes the phases above honest: everything
    # before here has to finish inside that twelve-second window, so if this
    # assertion ever starts failing the first suspect is that the earlier
    # phases got slow enough to straddle it.
    Write-Host ''
    Write-Host 'once the stack gives up on the radio:' -ForegroundColor Cyan
    $gaveUp = $false
    $by = (Get-Date).AddSeconds($SettleSec * 2)
    while ((Get-Date) -lt $by) {
        Start-Sleep -Seconds 2
        $r = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like 'WINVHCI\RADIO*' -and $_.Problem -ne 'CM_PROB_PHANTOM' }
        if ($r -and $r.Status -eq 'Error') { $gaveUp = $true; break }
    }
    Assert 'the radio fails without a controller answering it' $gaveUp `
           'it never reached Status=Error, so the rest of this phase proves nothing'

    if ($gaveUp) {
        $downBefore = [VhciIo]::GetStats()
        $downErr = Try-Write $adv
        $down = [VhciIo]::GetStats()

        Assert 'a write into the failed radio is refused' ($downErr -eq $ERROR_NOT_READY) `
               "got $downErr, expected $ERROR_NOT_READY - it was admitted and queued against nothing"
        Assert 'that refusal was counted' `
               ($down.WritesNoRadio - $downBefore.WritesNoRadio -eq 1) `
               "WritesNoRadio moved by $($down.WritesNoRadio - $downBefore.WritesNoRadio)"
        Assert 'the stale backlog was dropped when the stack went down' `
               ($down.PendingEventCount -eq 0 -and $down.PendingDataCount -eq 0) `
               "event depth $($down.PendingEventCount), acl depth $($down.PendingDataCount) - these would be replayed into the next radio"
    }

    # ---------------------------------------------------------------------
    # Close and reopen back to back.
    #
    # The first radio is now being torn down, and its stack's shutdown - the
    # PDO's D0Exit - arrives on a PnP thread some time after the handle
    # closes. The driver used to keep a single "radio started" flag for the
    # whole device, so if a client reopened and asked for a new radio inside
    # that window, the OLD radio's D0Exit cleared the NEW radio's flag and
    # every write from then on was refused with ERROR_NOT_READY, with no
    # D0Entry ever coming to undo it. The flag is per radio now. This round
    # is a best-effort detector - the ordering depends on PnP timing - but
    # it is the shape of the client that hit it, so it stays.
    #
    # There is still no controller, so BthPort gives up on this radio about
    # twelve seconds after it starts, and the writes below have to finish
    # well inside that: admission is reached a second or two in, and the
    # steady writing lasts five.
    Write-Host ''
    Write-Host 'closing and reopening back to back:' -ForegroundColor Cyan
    [VhciIo]::Close()
    [VhciIo]::Open($Device)
    [VhciIo]::Write([byte[]]@(0xFF, 0x00), 2)

    $firstAdmitted = $false
    $by = (Get-Date).AddSeconds($SettleSec)
    while ((Get-Date) -lt $by) {
        if ((Try-Write $adv) -eq 0) { $firstAdmitted = $true; break }
        Start-Sleep -Milliseconds 200
    }
    Assert 'the second radio admits writes' $firstAdmitted `
           "no write was admitted within $SettleSec s of reopening"

    if ($firstAdmitted) {
        $again = [VhciIo]::GetStats()
        $refusedLater = 0
        $by = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $by) {
            if ((Try-Write $adv) -ne 0) { $refusedLater++ }
            Start-Sleep -Milliseconds 100
        }
        $againAfter = [VhciIo]::GetStats()
        Assert 'the first radio going away did not take the second one down' `
               ($refusedLater -eq 0 -and $againAfter.WritesNoRadio -eq $again.WritesNoRadio) `
               "$refusedLater write(s) refused after admission; WritesNoRadio moved by $($againAfter.WritesNoRadio - $again.WritesNoRadio)"
    }
}
finally {
    [VhciIo]::Close()
    Write-Host 'closed (radio removed)' -ForegroundColor Cyan
}

Write-Host ''
if ($ok) {
    Write-Host 'RESULT: writes are admitted or refused, never quietly absorbed' -ForegroundColor Green
    exit 0
}
Write-Host 'RESULT: a write was mishandled' -ForegroundColor Red
exit 1
