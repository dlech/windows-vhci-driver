/*++

Module Name:

    user.c

Abstract:

    The userspace side of the seam: \\.\WinVhci, which behaves like Linux's
    /dev/vhci so that a simulator written against vhci is a path change rather
    than a rewrite (docs/design.md, "Userspace interface").

        WriteFile   controller -> host    04 <event> | 02 <acl> | FF <opcode>
        ReadFile    host -> controller    01 <cmd>   | 02 <acl> | FF FF <opcode> <id_lo> <id_hi>

    The first byte of every transfer is the H4 packet type. No translation is
    needed between H4 and BTHX_HCI_PACKET_TYPE because the values coincide
    (docs/design.md, "Packet types").

    Both directions obey the same rendezvous rule:

        (request queue, packet list)
          (empty,  *)      -> append the packet to the list
          (!empty, empty)  -> dequeue the request and complete it
          (!empty, !empty) -> impossible

    Backlogs are bounded and drop on overflow: a virtual controller that blocks
    the host Bluetooth stack is far worse than one that loses a packet, and the
    drop counter says when it happened.

Environment:

    Kernel mode only.

--*/

#include "winvhci.h"

//
// The radio's lifetime is the handle's lifetime, exactly as opening and closing
// /dev/vhci creates and destroys a controller on Linux.
//
DECLARE_CONST_UNICODE_STRING(WinVhciSymbolicLink, L"\\DosDevices\\WinVhci");

static PWINVHCI_PACKET
WinVhciAllocPacket(
    _In_ UCHAR Type,
    _In_reads_bytes_(Length) const UCHAR *Body,
    _In_ ULONG Length
    )
{
    PWINVHCI_PACKET p = (PWINVHCI_PACKET)ExAllocatePool2(
        POOL_FLAG_NON_PAGED,
        FIELD_OFFSET(WINVHCI_PACKET, Data) + Length,
        WINVHCI_POOL_TAG);

    if (p == NULL) {
        return NULL;
    }

    p->Type   = Type;
    p->Length = Length;
    if (Length != 0) {
        RtlCopyMemory(p->Data, Body, Length);
    }

    return p;
}

static VOID
WinVhciFreeList(
    _Inout_ PLIST_ENTRY Head,
    _Inout_ ULONG      *Count
    )
{
    while (!IsListEmpty(Head)) {
        PLIST_ENTRY e = RemoveHeadList(Head);
        ExFreePoolWithTag(CONTAINING_RECORD(e, WINVHCI_PACKET, Link), WINVHCI_POOL_TAG);
    }
    *Count = 0;
}

VOID
WinVhciRadioStackDown(
    _In_ PWINVHCI_FDO_CONTEXT Ctx
    )
/*++

Routine Description:

    The radio PDO has left D0, so the Bluetooth stack above it has stopped
    consuming. Called from the PDO's EvtDeviceD0Exit.

    Clearing RadioStarted is what makes the next write fail with
    STATUS_DEVICE_NOT_READY instead of queueing against nothing - winvhci's
    equivalent of hci_recv_frame refusing with -ENXIO when HCI_UP is clear.

    The two userspace -> stack backlogs go with it, for the reason Linux's
    vhci_flush and vhci_close_dev purge readq when the hdev goes down: what is
    queued was meant for a stack that is gone, and keeping it would replay
    stale packets into the next bring-up.

    HostToCtrlList is deliberately NOT dropped. It runs the other way - it
    holds packets the stack already handed us for the client to read - and the
    client is still there and still entitled to them.

--*/
{
    WdfSpinLockAcquire(Ctx->Lock);
    Ctx->RadioStarted = FALSE;
    WinVhciFreeList(&Ctx->PendingEventList, &Ctx->PendingEventCount);
    WinVhciFreeList(&Ctx->PendingDataList,  &Ctx->PendingDataCount);
    WdfSpinLockRelease(Ctx->Lock);
}

VOID
WinVhciPurgeBacklogs(
    _In_ PWINVHCI_FDO_CONTEXT Ctx
    )
{
    //
    // Freeing the lists is not optional. A packet still on one of these when
    // the device goes away is what BugCheck 0xC4
    // (DRIVER_VERIFIER_DETECTED_VIOLATION) is for, and this driver has already
    // been bitten once by that shape of bug - packets queued for a client that
    // had gone, surviving until unload.
    //
    WdfSpinLockAcquire(Ctx->Lock);
    WinVhciFreeList(&Ctx->HostToCtrlList,   &Ctx->HostToCtrlCount);
    WinVhciFreeList(&Ctx->PendingEventList, &Ctx->PendingEventCount);
    WinVhciFreeList(&Ctx->PendingDataList,  &Ctx->PendingDataCount);
    WdfSpinLockRelease(Ctx->Lock);
}

// ---------------------------------------------------------------------------
// stack -> userspace
// ---------------------------------------------------------------------------

VOID
WinVhciQueueToUser(
    _In_ PWINVHCI_FDO_CONTEXT Ctx,
    _In_ UCHAR                Type,
    _In_reads_bytes_(Length) const UCHAR *Body,
    _In_ ULONG                Length
    )
/*++

Routine Description:

    Hands a host-to-controller packet to a pended ReadFile, or queues it.

    Called from the BTHX write path, so this is where HCI commands the Windows
    stack emits become bytes a simulator can read.

--*/
{
    WDFREQUEST request = NULL;
    PVOID      buffer;
    size_t     bufferLength;
    NTSTATUS   status;

    WdfSpinLockAcquire(Ctx->Lock);

    //
    // With no client there is nobody to ever read this, so drop it rather than
    // queue it.
    //
    // This is not merely tidy. When a client dies, EvtFileClose purges the
    // backlogs - but the Bluetooth stack goes on issuing WRITE_HCI for the
    // several seconds it takes PnP to tear the radio down, and every one of
    // those used to allocate a packet onto a list no reader would ever drain.
    // Those allocations survived until the driver unloaded, where Driver
    // Verifier caught them:
    //
    //   BugCheck 0xC4 (DRIVER_VERIFIER_DETECTED_VIOLATION), 0x62
    //   "driver has forgotten to free its pool allocations prior to unloading"
    //
    // It only ever fired on device removal or shutdown, never in normal
    // operation, which is what made it look like the VM hanging rather than a
    // driver defect.
    //
    if (Ctx->Owner == NULL) {
        Ctx->DropsNoClient++;
        WdfSpinLockRelease(Ctx->Lock);
        return;
    }

    //
    // Rendezvous: a waiting reader takes the packet directly; otherwise it goes
    // on the backlog. Retrieving the request under the lock keeps the two
    // decisions atomic with respect to each other.
    //
    if (Ctx->HostToCtrlCount == 0) {
        status = WdfIoQueueRetrieveNextRequest(Ctx->UserReadQueue, &request);
        if (!NT_SUCCESS(status)) {
            request = NULL;
        }
    }

    if (request == NULL) {
        PWINVHCI_PACKET p;

        //
        // NOT bounded, deliberately. The producer here is BthPort, which
        // cannot be told to wait - these are HCI commands and ACL data it has
        // already handed off - and discarding one silently breaks bring-up
        // with nothing to recover from and no way to report it. This used to
        // drop at a depth of 64 and count into a counter userspace could not
        // read, so the loss looked like a device that would not initialise.
        //
        // A client that stops reading therefore grows this list. That is the
        // client's own memory footprint to answer for, it is bounded in
        // practice by how much the stack will send before it needs an answer,
        // and it is visible: HostToCtrlPeak says exactly how deep it went.
        //
        p = WinVhciTestFailAlloc(Ctx)
                ? NULL
                : WinVhciAllocPacket(Type, Body, Length);
        if (p == NULL) {
            //
            // The one remaining loss on this path, and unavoidable: there is
            // no way to pend a packet we cannot allocate. Counted separately
            // from a vanished client because this one is a real problem.
            //
            Ctx->DropsAllocFailed++;
            WdfSpinLockRelease(Ctx->Lock);
            KdPrint(("winvhci: host->user alloc failed, lost type 0x%02x (%u lost)\n",
                     Type, Ctx->DropsAllocFailed));
            return;
        }

        InsertTailList(&Ctx->HostToCtrlList, &p->Link);
        Ctx->HostToCtrlCount++;
        Ctx->QueuedToUserTotal++;
        if (Ctx->HostToCtrlCount > Ctx->HostToCtrlPeak) {
            Ctx->HostToCtrlPeak = Ctx->HostToCtrlCount;
        }
        WdfSpinLockRelease(Ctx->Lock);
        return;
    }

    WdfSpinLockRelease(Ctx->Lock);

    //
    // Complete outside the lock.
    //
    status = WdfRequestRetrieveOutputBuffer(request, 1, &buffer, &bufferLength);
    if (!NT_SUCCESS(status) || bufferLength < (size_t)Length + 1) {
        KdPrint(("winvhci: reader buffer too small (%Iu < %u)\n", bufferLength, Length + 1));
        WdfRequestComplete(request, STATUS_BUFFER_TOO_SMALL);
        return;
    }

    ((PUCHAR)buffer)[0] = Type;
    if (Length != 0) {
        RtlCopyMemory((PUCHAR)buffer + 1, Body, Length);
    }

    WdfRequestCompleteWithInformation(request, STATUS_SUCCESS, (ULONG_PTR)Length + 1);
}

VOID
WinVhciEvtIoRead(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     Length
    )
{
    WDFDEVICE            device = WdfIoQueueGetDevice(Queue);
    PWINVHCI_FDO_CONTEXT ctx    = WinVhciFdoGetContext(device);
    PWINVHCI_PACKET      p      = NULL;
    PVOID                buffer;
    size_t               bufferLength;
    NTSTATUS             status;

    if (Length < WINVHCI_MAX_H4_PACKET) {
        //
        // Refuse short reads rather than truncate: a client that cannot hold
        // the largest packet would silently corrupt the stream later.
        //
        KdPrint(("winvhci: read buffer %Iu too small, need %u\n",
                 Length, WINVHCI_MAX_H4_PACKET));
        WdfRequestComplete(Request, STATUS_BUFFER_TOO_SMALL);
        return;
    }

    WdfSpinLockAcquire(ctx->Lock);

    if (!IsListEmpty(&ctx->HostToCtrlList)) {
        p = CONTAINING_RECORD(RemoveHeadList(&ctx->HostToCtrlList), WINVHCI_PACKET, Link);
        ctx->HostToCtrlCount--;
    } else {
        //
        // Nothing waiting: park the read. A manual queue takes ownership, so
        // cancellation is the framework's problem rather than ours.
        //
        status = WdfRequestForwardToIoQueue(Request, ctx->UserReadQueue);
        WdfSpinLockRelease(ctx->Lock);
        if (!NT_SUCCESS(status)) {
            WdfRequestComplete(Request, status);
        }
        return;
    }

    WdfSpinLockRelease(ctx->Lock);

    status = WdfRequestRetrieveOutputBuffer(Request, 1, &buffer, &bufferLength);
    if (NT_SUCCESS(status) && bufferLength >= (size_t)p->Length + 1) {
        ((PUCHAR)buffer)[0] = p->Type;
        if (p->Length != 0) {
            RtlCopyMemory((PUCHAR)buffer + 1, p->Data, p->Length);
        }
        WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, (ULONG_PTR)p->Length + 1);
    } else {
        WdfRequestComplete(Request, NT_SUCCESS(status) ? STATUS_BUFFER_TOO_SMALL : status);
    }

    ExFreePoolWithTag(p, WINVHCI_POOL_TAG);
}

// ---------------------------------------------------------------------------
// userspace -> stack
// ---------------------------------------------------------------------------

PWINVHCI_PACKET
WinVhciTakePendingForStack(
    _In_ PWINVHCI_FDO_CONTEXT Ctx,
    _In_ UCHAR                Type
    )
{
    PWINVHCI_PACKET p    = NULL;
    PLIST_ENTRY     head = (Type == WINVHCI_H4_ACL) ? &Ctx->PendingDataList
                                                    : &Ctx->PendingEventList;
    PULONG          count = (Type == WINVHCI_H4_ACL) ? &Ctx->PendingDataCount
                                                     : &Ctx->PendingEventCount;

    WdfSpinLockAcquire(Ctx->Lock);
    if (!IsListEmpty(head)) {
        p = CONTAINING_RECORD(RemoveHeadList(head), WINVHCI_PACKET, Link);
        (*count)--;
    }
    WdfSpinLockRelease(Ctx->Lock);

    return p;
}

static NTSTATUS
WinVhciHandleControl(
    _In_ PWINVHCI_FDO_CONTEXT Ctx,
    _In_reads_bytes_(Length) const UCHAR *Body,
    _In_ ULONG                Length
    )
/*++

Routine Description:

    Handles the in-band control packet, FF <opcode>, which creates the radio -
    the same wire protocol Linux's vhci uses, so the reply format matches too:

        FF FF <opcode> <id_lo> <id_hi>

    The opcode's bits carry no meaning here yet (Linux's external-config and
    raw-device quirks have no Windows analogue), but reserving the byte keeps
    the format identical.

--*/
{
    UCHAR    reply[5];
    ULONG    radioId;
    UCHAR    opcode;
    NTSTATUS status;

    //
    // EXACTLY one body byte. Linux is strict about this and it costs nothing
    // to match: vhci_get_user pulls the type and the opcode, then
    //
    //     if (skb->len > 0) { kfree_skb(skb); return -EINVAL; }
    //
    // so FF 00 DE AD is an error there. Accepting it here and ignoring the
    // tail would let a client's framing bug look like it worked.
    //
    if (Length != 1) {
        KdPrint(("winvhci: control packet is %u body bytes, expected 1\n", Length));
        return STATUS_INVALID_PARAMETER;
    }

    opcode = Body[0];

    //
    // Opcode bits, per __vhci_create_device:
    //
    //     /* bits 2-5 are reserved (must be zero) */
    //     if (opcode & 0x3c)
    //             return -EINVAL;
    //     /* bit 6 is for external configuration */
    //     if (opcode & 0x40) hci_set_quirk(hdev, HCI_QUIRK_EXTERNAL_CONFIG);
    //     /* bit 7 is for raw device */
    //     if (opcode & 0x80) hci_set_quirk(hdev, HCI_QUIRK_RAW_DEVICE);
    //
    // Bits 0-1 are neither validated nor used on Linux either - a legacy
    // device type - and are echoed back in the reply, so they pass through.
    //
    if ((opcode & 0x3C) != 0) {
        KdPrint(("winvhci: control: reserved opcode bits set (0x%02x)\n", opcode));
        return STATUS_INVALID_PARAMETER;
    }

    //
    // The two quirk bits are REFUSED rather than ignored. Neither has a
    // Windows analogue - there is no BTHX equivalent of external
    // configuration or of a raw device - and silently ignoring them would
    // hand a client that asked for a raw device an ordinary one with no
    // indication that its request went nowhere. Refusing says so.
    //
    if ((opcode & 0xC0) != 0) {
        KdPrint(("winvhci: control: opcode 0x%02x asks for a quirk with no "
                 "Windows analogue\n", opcode));
        return STATUS_NOT_SUPPORTED;
    }

    WdfSpinLockAcquire(Ctx->Lock);
    if (Ctx->RadioPresent) {
        WdfSpinLockRelease(Ctx->Lock);
        KdPrint(("winvhci: control: radio already present\n"));
        return STATUS_INVALID_DEVICE_STATE;
    }
    radioId = Ctx->NextRadioId++;
    Ctx->RadioPresent = TRUE;
    WdfSpinLockRelease(Ctx->Lock);

    status = WinVhciAddRadio(Ctx->Device, radioId);
    if (!NT_SUCCESS(status)) {
        WdfSpinLockAcquire(Ctx->Lock);
        Ctx->RadioPresent = FALSE;
        WdfSpinLockRelease(Ctx->Lock);
        KdPrint(("winvhci: control: AddRadio failed 0x%08x\n", status));
        return status;
    }

    KdPrint(("winvhci: control: opcode 0x%02x created radio %u\n", opcode, radioId));

    reply[0] = WINVHCI_H4_VENDOR;
    reply[1] = WINVHCI_H4_VENDOR;
    reply[2] = opcode;
    reply[3] = (UCHAR)(radioId & 0xFF);
    reply[4] = (UCHAR)((radioId >> 8) & 0xFF);

    //
    // The reply goes back the way everything else does, as a readable packet.
    // Body excludes the leading type byte, which QueueToUser prepends.
    //
    WinVhciQueueToUser(Ctx, reply[0], &reply[1], sizeof(reply) - 1);

    return STATUS_SUCCESS;
}

static VOID
WinVhciDispatchWrite(
    _In_ PWINVHCI_FDO_CONTEXT ctx,
    _In_ WDFREQUEST           Request
    )
/*++

Routine Description:

    One userspace write, from the queue callback OR from the backpressure
    drain. Both go through here so a re-released write is handled identically
    to a fresh one - including being pended again, if the stack has filled the
    backlog back up in the meantime.

    The transfer length is taken from the request rather than passed in,
    because the drain path has only the request.

--*/
{
    WDF_REQUEST_PARAMETERS params;
    PUCHAR                 buffer;
    size_t                 bufferLength;
    size_t                 Length;
    UCHAR                  type;
    NTSTATUS               status;

    WDF_REQUEST_PARAMETERS_INIT(&params);
    WdfRequestGetParameters(Request, &params);
    Length = params.Parameters.Write.Length;

    if (Length < 2 || Length > WINVHCI_MAX_H4_PACKET) {
        WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
        return;
    }

    status = WdfRequestRetrieveInputBuffer(Request, 2, (PVOID *)&buffer, &bufferLength);
    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }

    type = buffer[0];

    switch (type) {
    case WINVHCI_H4_VENDOR:
        status = WinVhciHandleControl(ctx, buffer + 1, (ULONG)bufferLength - 1);
        break;

    case WINVHCI_H4_EVENT:
    case WINVHCI_H4_ACL:
        //
        // ADMISSION CHECK, and the reason the backlogs below can be unbounded.
        // This is Linux's, from vhci_get_user:
        //
        //     case HCI_EVENT_PKT:
        //     case HCI_ACLDATA_PKT:
        //     case HCI_SCODATA_PKT:
        //     case HCI_ISODATA_PKT:
        //             if (!data->hdev) {
        //                     kfree_skb(skb);
        //                     return -ENODEV;
        //             }
        //
        // Without it, a client that writes before asking for its radio gets
        // its packets queued against a stack that does not exist, and they are
        // then replayed into the bring-up of a radio that had not been created
        // when they were sent. That was measured, not imagined: 200 pre-radio
        // advertising reports were all delivered the instant the radio
        // appeared.
        //
        // Linux checks TWICE, and so does this. The second check is the one
        // that was missing longest:
        //
        //     hci_recv_frame() -> if (!hdev || (!test_bit(HCI_UP, &hdev->flags)
        //                             && !test_bit(HCI_INIT, &hdev->flags)))
        //                                 return -ENXIO;
        //
        // RadioPresent answers "has the client asked for a radio". It stays
        // TRUE through a failed bring-up, so on its own it admits writes into
        // a radio whose stack has given up - measured at 300 packets queued
        // with nothing draining, and unbounded because nothing bounds it.
        // RadioStarted answers "is that radio's stack actually consuming",
        // and the PDO's EvtDeviceD0Exit clears it.
        //
        // Under the lock, because unlike RadioPresent this one is changed by
        // PnP on another thread entirely.
        //
        {
            BOOLEAN ready;

            WdfSpinLockAcquire(ctx->Lock);
            ready = ctx->RadioPresent && ctx->RadioStarted;
            if (!ready) {
                ctx->WritesNoRadio++;
            }
            WdfSpinLockRelease(ctx->Lock);

            if (!ready) {
                KdPrint(("winvhci: type 0x%02x refused, no radio is up "
                         "(present %d, started %d)\n",
                         type, ctx->RadioPresent, ctx->RadioStarted));
                status = STATUS_DEVICE_NOT_READY;
                break;
            }
        }

        status = WinVhciDeliverToStack(ctx, type, buffer + 1, (ULONG)bufferLength - 1);
        break;

    case WINVHCI_H4_COMMAND:
        //
        // Commands travel host -> controller. A simulator sending one is
        // confused about which end it is; say so rather than quietly dropping
        // it (docs/design.md, "Packet types" - direction is enforced).
        //
        KdPrint(("winvhci: userspace sent a COMMAND packet; wrong direction\n"));
        status = STATUS_INVALID_PARAMETER;
        break;

    case WINVHCI_H4_SCO:
    case WINVHCI_H4_ISO:
        //
        // The BTHX DDI has no packet type for either, so there is nothing to
        // forward them as.
        //
        status = STATUS_NOT_SUPPORTED;
        break;

    default:
        KdPrint(("winvhci: unknown H4 type 0x%02x from userspace\n", type));
        status = STATUS_INVALID_PARAMETER;
        break;
    }

    //
    // Every path above either succeeded or failed outright. A write is never
    // pended: the backlogs are unbounded, so there is nothing to wait for.
    //
    // Report the whole transfer as consumed on success, so a client's write
    // loop does not have to reason about the type byte.
    //
    WdfRequestCompleteWithInformation(Request,
                                      status,
                                      NT_SUCCESS(status) ? Length : 0);
}

VOID
WinVhciEvtIoWrite(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     Length
    )
{
    UNREFERENCED_PARAMETER(Length);   // taken from the request instead

    WinVhciDispatchWrite(WinVhciFdoGetContext(WdfIoQueueGetDevice(Queue)), Request);
}

VOID
WinVhciEvtIoDeviceControl(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
/*++

Routine Description:

    IOCTL_WINVHCI_GET_STATS, so a test can assert the driver lost nothing
    instead of inferring it from behaviour. Before this existed the counters
    were incremented and then only printed with KdPrint, which is compiled out
    of a Release build and discarded anyway when no debugger is attached - so a
    lost packet was indistinguishable from a device that would not initialise.

--*/
{
    WDFDEVICE            device = WdfIoQueueGetDevice(Queue);
    PWINVHCI_FDO_CONTEXT ctx    = WinVhciFdoGetContext(device);
    PWINVHCI_STATS       out;
    size_t               outLength;
    NTSTATUS             status;

    UNREFERENCED_PARAMETER(InputBufferLength);

    if (IoControlCode != IOCTL_WINVHCI_GET_STATS) {
        WdfRequestComplete(Request, STATUS_INVALID_DEVICE_REQUEST);
        return;
    }

    if (OutputBufferLength < sizeof(WINVHCI_STATS)) {
        //
        // Report what is needed, so a caller built against an older header
        // learns the size rather than guessing.
        //
        WdfRequestCompleteWithInformation(Request,
                                          STATUS_BUFFER_TOO_SMALL,
                                          sizeof(WINVHCI_STATS));
        return;
    }

    status = WdfRequestRetrieveOutputBuffer(Request,
                                            sizeof(WINVHCI_STATS),
                                            (PVOID *)&out,
                                            &outLength);
    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }

    RtlZeroMemory(out, sizeof(*out));
    out->Size = sizeof(WINVHCI_STATS);

    //
    // Under the lock, so the snapshot is internally consistent: a caller
    // comparing a count against its peak should never see the count exceed it.
    //
    WdfSpinLockAcquire(ctx->Lock);
    out->DropsNoClient     = ctx->DropsNoClient;
    out->DropsAllocFailed  = ctx->DropsAllocFailed;
    out->HostToCtrlCount   = ctx->HostToCtrlCount;
    out->HostToCtrlPeak    = ctx->HostToCtrlPeak;
    out->PendingEventCount = ctx->PendingEventCount;
    out->PendingEventPeak  = ctx->PendingEventPeak;
    out->PendingDataCount  = ctx->PendingDataCount;
    out->PendingDataPeak   = ctx->PendingDataPeak;
    out->WritesTotal       = ctx->WritesTotal;
    out->QueuedToUserTotal = ctx->QueuedToUserTotal;
    out->WritesNoRadio     = ctx->WritesNoRadio;
    WdfSpinLockRelease(ctx->Lock);

    WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, sizeof(WINVHCI_STATS));
}

// ---------------------------------------------------------------------------
// handle lifetime
// ---------------------------------------------------------------------------

VOID
WinVhciEvtDeviceFileCreate(
    _In_ WDFDEVICE     Device,
    _In_ WDFREQUEST    Request,
    _In_ WDFFILEOBJECT FileObject
    )
{
    PWINVHCI_FDO_CONTEXT ctx = WinVhciFdoGetContext(Device);

    //
    // WdfDeviceInitSetExclusive already keeps this to one handle; recording the
    // owner lets the close path tell "our" handle from any other.
    //
    WdfSpinLockAcquire(ctx->Lock);
    ctx->Owner = FileObject;
    WdfSpinLockRelease(ctx->Lock);

    KdPrint(("winvhci: userspace opened the control device\n"));

    WdfRequestComplete(Request, STATUS_SUCCESS);
}

VOID
WinVhciEvtFileClose(
    _In_ WDFFILEOBJECT FileObject
    )
/*++

Routine Description:

    Closing the handle tears the radio down, which is the whole point of
    modelling the lifetime on /dev/vhci: no client, no controller.

--*/
{
    WDFDEVICE            device = WdfFileObjectGetDevice(FileObject);
    PWINVHCI_FDO_CONTEXT ctx    = WinVhciFdoGetContext(device);
    BOOLEAN              hadRadio;

    WdfSpinLockAcquire(ctx->Lock);
    hadRadio          = ctx->RadioPresent;
    ctx->RadioPresent = FALSE;
    ctx->Owner        = NULL;
    WdfSpinLockRelease(ctx->Lock);

    KdPrint(("winvhci: userspace closed the control device (radio %s)\n",
             hadRadio ? "removed" : "was absent"));

    if (hadRadio) {
        (VOID)WinVhciRemoveRadios(device);
    }

    //
    // Release anything the stack is still waiting on, then drop the backlogs.
    // Outstanding BTHX reads must not survive the client that was supposed to
    // answer them.
    //
    // Purging SYNCHRONOUSLY is safe here, which is worth stating because the
    // general rule says otherwise. Purging a queue synchronously from
    // EvtFileClose deadlocks when the queue holds requests owned by the file
    // object being closed: the framework's cleanup for that file object is
    // already waiting for them, so the purge waits on something that cannot
    // finish until this callback returns. These two queues hold BTHX IOCTLs
    // forwarded from BthMini - kernel-mode requests on a different file
    // object, which nothing in this close path waits for - so they drain and
    // return.
    //
    // Learned by doing it wrong on a queue of userspace writes, where the
    // symptom looked nothing like a queue problem: the close never finished,
    // so Owner stayed set and the radio stayed alive, and the next CreateFile
    // on an exclusive device failed with ERROR_ACCESS_DENIED - which reads as
    // a permissions problem, not as a driver that never let go.
    //
    WdfIoQueuePurgeSynchronously(ctx->ReadEventQueue);
    WdfIoQueuePurgeSynchronously(ctx->ReadDataQueue);
    WdfIoQueueStart(ctx->ReadEventQueue);
    WdfIoQueueStart(ctx->ReadDataQueue);

    WinVhciPurgeBacklogs(ctx);
}

// ---------------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------------

NTSTATUS
WinVhciUserInitDevice(
    _In_ PWDFDEVICE_INIT DeviceInit
    )
{
    WDF_FILEOBJECT_CONFIG fileConfig;

    //
    // Buffered I/O: transfers are small and the framework's copy is not worth
    // avoiding, while direct I/O would mean probing and locking user pages for
    // every packet.
    //
    WdfDeviceInitSetIoType(DeviceInit, WdfDeviceIoBuffered);

    //
    // One controller at a time, mirroring vhci's open_mutex.
    //
    WdfDeviceInitSetExclusive(DeviceInit, TRUE);

    WDF_FILEOBJECT_CONFIG_INIT(&fileConfig,
                               WinVhciEvtDeviceFileCreate,
                               WinVhciEvtFileClose,
                               WDF_NO_EVENT_CALLBACK);   // no cleanup callback

    WdfDeviceInitSetFileObjectConfig(DeviceInit, &fileConfig, WDF_NO_OBJECT_ATTRIBUTES);

    return STATUS_SUCCESS;
}

NTSTATUS
WinVhciUserCreateQueues(
    _In_ WDFDEVICE Device
    )
{
    PWINVHCI_FDO_CONTEXT ctx = WinVhciFdoGetContext(Device);
    WDF_IO_QUEUE_CONFIG  config;
    WDFQUEUE             defaultQueue;
    NTSTATUS             status;

    InitializeListHead(&ctx->HostToCtrlList);
    InitializeListHead(&ctx->PendingEventList);
    InitializeListHead(&ctx->PendingDataList);
    ctx->NextRadioId = 1;

    //
    // Default queue: userspace ReadFile/WriteFile. Not power-managed, to match
    // the BTHX queues it rendezvouses with.
    //
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&config, WdfIoQueueDispatchParallel);
    config.PowerManaged = WdfFalse;
    config.EvtIoRead          = WinVhciEvtIoRead;
    config.EvtIoWrite         = WinVhciEvtIoWrite;
    config.EvtIoDeviceControl = WinVhciEvtIoDeviceControl;

    status = WdfIoQueueCreate(Device, &config, WDF_NO_OBJECT_ATTRIBUTES, &defaultQueue);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: default queue create failed 0x%08x\n", status));
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT(&config, WdfIoQueueDispatchManual);
    config.PowerManaged = WdfFalse;

    status = WdfIoQueueCreate(Device, &config, WDF_NO_OBJECT_ATTRIBUTES, &ctx->UserReadQueue);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: UserReadQueue create failed 0x%08x\n", status));
        return status;
    }

    status = WdfDeviceCreateSymbolicLink(Device, &WinVhciSymbolicLink);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: symbolic link create failed 0x%08x\n", status));
        return status;
    }

    KdPrint(("winvhci: userspace interface ready at \\\\.\\WinVhci\n"));

    return STATUS_SUCCESS;
}
