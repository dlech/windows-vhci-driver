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
WinVhciPurgeBacklogs(
    _In_ PWINVHCI_FDO_CONTEXT Ctx
    )
{
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
        Ctx->DropCount++;
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

        if (Ctx->HostToCtrlCount >= WINVHCI_MAX_BACKLOG) {
            Ctx->DropCount++;
            WdfSpinLockRelease(Ctx->Lock);
            KdPrint(("winvhci: host->user backlog full, dropped type 0x%02x (%u dropped)\n",
                     Type, Ctx->DropCount));
            return;
        }

        p = WinVhciTestFailAlloc(Ctx)
                ? NULL
                : WinVhciAllocPacket(Type, Body, Length);
        if (p == NULL) {
            Ctx->DropCount++;
            WdfSpinLockRelease(Ctx->Lock);
            return;
        }

        InsertTailList(&Ctx->HostToCtrlList, &p->Link);
        Ctx->HostToCtrlCount++;
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

    if (Length < 1) {
        return STATUS_INVALID_PARAMETER;
    }

    opcode = Body[0];

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

VOID
WinVhciEvtIoWrite(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     Length
    )
{
    WDFDEVICE            device = WdfIoQueueGetDevice(Queue);
    PWINVHCI_FDO_CONTEXT ctx    = WinVhciFdoGetContext(device);
    PUCHAR               buffer;
    size_t               bufferLength;
    UCHAR                type;
    NTSTATUS             status;

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
    // Report the whole transfer as consumed on success, so a client's write
    // loop does not have to reason about the type byte.
    //
    WdfRequestCompleteWithInformation(Request,
                                      status,
                                      NT_SUCCESS(status) ? Length : 0);
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
    config.EvtIoRead    = WinVhciEvtIoRead;
    config.EvtIoWrite   = WinVhciEvtIoWrite;

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
