/*++

Module Name:

    fdo.c

Abstract:

    The BTHX transport contract: the IOCTLs BthMini.sys sends down to a
    Bluetooth transport driver, answered on the FDO.

    All five BTHX IOCTLs are METHOD_NEITHER (see bthxddi.h), so the framework
    neither maps nor probes buffers for us. The input buffer arrives as
    Parameters.DeviceIoControl.Type3InputBuffer and the output as the WDM IRP's
    UserBuffer. WDF's usual WdfRequestRetrieveInputBuffer/OutputBuffer helpers
    do not work for these and will fail with STATUS_INVALID_DEVICE_REQUEST.

    These requests originate in kernel mode from BthMini, so the pointers are
    kernel addresses valid in any context - but that is a fact to VERIFY, not to
    assume, hence the RequestorMode check below.

Environment:

    Kernel mode only.

--*/

#include "winvhci.h"

//
// HCI_Reset. The stack sends this first when bringing a radio up, so seeing it
// arrive is M1's proof that BthMini bound to us and is driving the transport.
//
#define HCI_OPCODE_RESET 0x0C03

//
// Breadcrumbs.
//
// Durable state that outlives a capture session, recorded under a registry key
// any SSH session can read back:
//
//   HKLM\SOFTWARE\winvhci
//
// An absolute path, deliberately, rather than the device's own key: an earlier
// version used WdfDeviceOpenRegistryKey(PLUGPLAY_REGKEY_DEVICE), which wrote
// nothing at all - not even from EvtDeviceAdd, which certainly runs. The
// devnode's "Device Parameters" key is not reliably available that early, and a
// tracing mechanism that fails silently in the exact conditions you want to
// trace is worse than none. This path always exists or can be created.
//
// KdPrint via DebugView is the better channel for a live transcript (see
// docs/development.md), so these breadcrumbs are for state that must survive a
// crash or be readable long after the fact.
//
// Diagnostic scaffolding for bring-up, not a permanent logging design: it costs
// a registry write per request, far too expensive once the data path carries
// real traffic.
//
VOID
WinVhciTraceUlong(
    _In_ WDFDEVICE Device,
    _In_ PCWSTR    Name,
    _In_ ULONG     Value
    )
{
    WDFKEY         key;
    UNICODE_STRING name;
    NTSTATUS       status;

    DECLARE_CONST_UNICODE_STRING(path, L"\\Registry\\Machine\\SOFTWARE\\winvhci");

    UNREFERENCED_PARAMETER(Device);

    //
    // Registry access requires PASSIVE_LEVEL. Silently skipping at raised IRQL
    // is correct here: losing a breadcrumb must never change driver behaviour.
    //
    if (KeGetCurrentIrql() != PASSIVE_LEVEL) {
        return;
    }

    status = WdfRegistryCreateKey(NULL,
                                  &path,
                                  KEY_WRITE,
                                  REG_OPTION_NON_VOLATILE,
                                  NULL,
                                  WDF_NO_OBJECT_ATTRIBUTES,
                                  &key);
    if (!NT_SUCCESS(status)) {
        return;
    }

    RtlInitUnicodeString(&name, Name);
    (VOID)WdfRegistryAssignULong(key, &name, Value);

    WdfRegistryClose(key);
}

_Success_(return != FALSE)
static BOOLEAN
WinVhciReadUlong(
    _In_  WDFDEVICE Device,
    _In_  PCWSTR    Name,
    _Out_ ULONG    *Value
    )
/*++

Routine Description:

    Reads a tuning knob from the device key, so values whose correctness is
    genuinely uncertain can be changed with a registry edit and a device
    restart instead of a rebuild-sign-repackage-reinstall cycle.

Return Value:

    TRUE if the value was present, in which case *Value holds it. On FALSE
    *Value is untouched, which is why callers seed it with the default they
    want first - hence _Success_(return != FALSE) rather than a plain _Out_.

--*/
{
    WDFKEY         key;
    UNICODE_STRING name;
    ULONG          v;
    NTSTATUS       status;

    DECLARE_CONST_UNICODE_STRING(path, L"\\Registry\\Machine\\SOFTWARE\\winvhci");

    UNREFERENCED_PARAMETER(Device);

    if (KeGetCurrentIrql() != PASSIVE_LEVEL) {
        return FALSE;
    }

    status = WdfRegistryOpenKey(NULL,
                                &path,
                                KEY_READ,
                                WDF_NO_OBJECT_ATTRIBUTES,
                                &key);
    if (!NT_SUCCESS(status)) {
        return FALSE;
    }

    RtlInitUnicodeString(&name, Name);
    status = WdfRegistryQueryULong(key, &name, &v);

    WdfRegistryClose(key);

    if (!NT_SUCCESS(status)) {
        return FALSE;
    }

    *Value = v;
    return TRUE;
}

static VOID
WinVhciLogHciPacket(
    _In_ UCHAR                Type,
    _In_reads_bytes_opt_(Len) const UCHAR *Data,
    _In_ ULONG                Len
    )
{
    if (Data == NULL) {
        return;
    }

    if (Type == HciPacketCommand && Len >= 3) {
        //
        // HCI command header: opcode (little endian), then parameter length.
        // Opcode splits into a 6-bit group field and a 10-bit command field.
        //
        USHORT opcode = (USHORT)(Data[0] | (Data[1] << 8));

        KdPrint(("winvhci:   command opcode 0x%04x (OGF 0x%02x OCF 0x%03x) plen %u%s\n",
                 opcode,
                 (USHORT)(opcode >> 10),
                 (USHORT)(opcode & 0x03FF),
                 Data[2],
                 (opcode == HCI_OPCODE_RESET) ? "   <-- HCI_Reset" : ""));
    } else if (Len >= 4) {
        KdPrint(("winvhci:   first bytes %02x %02x %02x %02x\n",
                 Data[0], Data[1], Data[2], Data[3]));
    }
}

static NTSTATUS
WinVhciCompleteRead(
    _In_ WDFREQUEST Request,
    _In_ UCHAR      Type,
    _In_reads_bytes_(Length) const UCHAR *Body,
    _In_ ULONG      Length
    )
/*++

Routine Description:

    Completes one pended IOCTL_BTHX_READ_HCI with a controller-to-host packet.

    Body is the HCI packet WITHOUT its H4 type byte; the type travels in the
    context's Type field. See winvhci.h for the buffer layout, which is not the
    obvious one.

--*/
{
    PIRP                         irp;
    PIO_STACK_LOCATION           stack;
    PBTHX_HCI_READ_WRITE_CONTEXT out;
    ULONG                        capacity;

    //
    // Buffer and length both from the IRP's current stack location - see the
    // note in WinVhciBthxDispatch about why mixing that with WDF's captured
    // parameters breaks under Driver Verifier.
    //
    irp   = WdfRequestWdmGetIrp(Request);
    stack = IoGetCurrentIrpStackLocation(irp);
    out   = (PBTHX_HCI_READ_WRITE_CONTEXT)irp->UserBuffer;

    // FIELD_OFFSET is signed, and the stack location's length is a ULONG, so
    // the comparison needs the cast to stay unsigned.
    if (out == NULL ||
        stack->Parameters.DeviceIoControl.OutputBufferLength <
            (ULONG)WINVHCI_HCI_CONTEXT_HEADER_SIZE) {
        WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
        return STATUS_INVALID_PARAMETER;
    }

    capacity = stack->Parameters.DeviceIoControl.OutputBufferLength -
               (ULONG)WINVHCI_HCI_CONTEXT_HEADER_SIZE;
    if (capacity < Length) {
        KdPrint(("winvhci: packet too big for read buffer (%u > %u)\n", Length, capacity));
        WdfRequestComplete(Request, STATUS_BUFFER_TOO_SMALL);
        return STATUS_BUFFER_TOO_SMALL;
    }

    out->Type    = Type;
    out->DataLen = Length;
    if (Length != 0) {
        RtlCopyMemory(out->Data, Body, Length);
    }

    WdfRequestCompleteWithInformation(Request,
                                      STATUS_SUCCESS,
                                      WINVHCI_HCI_CONTEXT_HEADER_SIZE + Length);

    return STATUS_SUCCESS;
}

NTSTATUS
WinVhciDeliverToStack(
    _In_ PWINVHCI_FDO_CONTEXT Ctx,
    _In_ UCHAR                Type,
    _In_reads_bytes_(Length) const UCHAR *Body,
    _In_ ULONG                Length
    )
/*++

Routine Description:

    The controller-to-host half of the rendezvous: hand the packet to a pended
    BTHX read if there is one, otherwise queue it on the matching backlog.

    Called from the userspace write path, so this is where a simulator's events
    and ACL data enter the Windows Bluetooth stack.

--*/
{
    WDFQUEUE    queue;
    PLIST_ENTRY head;
    PULONG      count;
    WDFREQUEST  request = NULL;
    NTSTATUS    status;

    if (Type == WINVHCI_H4_ACL) {
        queue = Ctx->ReadDataQueue;
        head  = &Ctx->PendingDataList;
        count = &Ctx->PendingDataCount;
    } else {
        queue = Ctx->ReadEventQueue;
        head  = &Ctx->PendingEventList;
        count = &Ctx->PendingEventCount;
    }

    WdfSpinLockAcquire(Ctx->Lock);

    //
    // Only take a pended read if nothing is already queued ahead of this
    // packet, or packets would be delivered out of order.
    //
    if (*count == 0) {
        status = WdfIoQueueRetrieveNextRequest(queue, &request);
        if (!NT_SUCCESS(status)) {
            request = NULL;
        }
    }

    if (request == NULL) {
        PWINVHCI_PACKET p;

        if (*count >= WINVHCI_MAX_BACKLOG) {
            Ctx->DropCount++;
            WdfSpinLockRelease(Ctx->Lock);
            KdPrint(("winvhci: stack backlog full, dropped type 0x%02x\n", Type));
            return STATUS_INSUFFICIENT_RESOURCES;
        }

        p = (PWINVHCI_PACKET)ExAllocatePool2(
                POOL_FLAG_NON_PAGED,
                FIELD_OFFSET(WINVHCI_PACKET, Data) + Length,
                WINVHCI_POOL_TAG);
        if (p == NULL) {
            Ctx->DropCount++;
            WdfSpinLockRelease(Ctx->Lock);
            return STATUS_INSUFFICIENT_RESOURCES;
        }

        p->Type   = Type;
        p->Length = Length;
        if (Length != 0) {
            RtlCopyMemory(p->Data, Body, Length);
        }

        InsertTailList(head, &p->Link);
        (*count)++;
        WdfSpinLockRelease(Ctx->Lock);

        KdPrint(("winvhci: no read pended for type 0x%02x, queued (%u waiting)\n",
                 Type, *count));
        return STATUS_SUCCESS;
    }

    WdfSpinLockRelease(Ctx->Lock);

    KdPrint(("winvhci: delivering type 0x%02x, %u bytes to the stack\n", Type, Length));

    return WinVhciCompleteRead(request, Type, Body, Length);
}

static VOID
WinVhciBthxDispatch(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
{
    WDFDEVICE              device = WdfIoQueueGetDevice(Queue);
    PWINVHCI_FDO_CONTEXT   ctx    = WinVhciFdoGetContext(device);
    WDF_REQUEST_PARAMETERS params;
    PIRP                   irp;
    PIO_STACK_LOCATION     stack;
    PVOID                  inBuf;
    PVOID                  outBuf;
    NTSTATUS               status = STATUS_INVALID_DEVICE_REQUEST;
    ULONG_PTR              info   = 0;

    WDF_REQUEST_PARAMETERS_INIT(&params);
    WdfRequestGetParameters(Request, &params);

    irp    = WdfRequestWdmGetIrp(Request);
    stack  = IoGetCurrentIrpStackLocation(irp);

    //
    // BOTH buffers come from the SAME place: the IRP's current stack location.
    //
    // This function used to mix its sources - the input pointer from WDF's
    // captured WDF_REQUEST_PARAMETERS, the output pointer from the raw IRP.
    // The two agree in ordinary operation, so it worked for three milestones.
    // They stop agreeing under Driver Verifier: Type3InputBuffer in the
    // captured parameters comes back NULL while irp->UserBuffer is still
    // correct, so SET_VERSION failed STATUS_INVALID_PARAMETER and the radio
    // never started at all.
    //
    // For a METHOD_NEITHER IOCTL the stack location is the authoritative
    // source for both pointers, and it is already what the read path uses for
    // its output buffer. The lengths still come from the queue callback's own
    // arguments, which are part of the documented WDF contract.
    //
    if (params.Parameters.DeviceIoControl.Type3InputBuffer !=
        stack->Parameters.DeviceIoControl.Type3InputBuffer) {
        KdPrint(("winvhci: Type3InputBuffer differs: wdf %p irp %p (ioctl 0x%08x)\n",
                 params.Parameters.DeviceIoControl.Type3InputBuffer,
                 stack->Parameters.DeviceIoControl.Type3InputBuffer,
                 IoControlCode));
    }

    inBuf  = stack->Parameters.DeviceIoControl.Type3InputBuffer;
    outBuf = irp->UserBuffer;

    //
    // METHOD_NEITHER hands us raw pointers with no probing. From kernel mode
    // that is safe; from user mode it would be an arbitrary-pointer bug, and
    // nothing in the BTHX contract expects a user-mode caller.
    //
    if (irp->RequestorMode != KernelMode) {
        KdPrint(("winvhci: rejecting user-mode BTHX ioctl 0x%08x\n", IoControlCode));
        WdfRequestComplete(Request, STATUS_ACCESS_DENIED);
        return;
    }

    //
    // Record that a request arrived at all, before deciding anything about it.
    // "Did BthMini ever call us?" is the first question to answer, and a
    // breadcrumb written only on the success paths cannot answer it.
    //
    WdfSpinLockAcquire(ctx->Lock);
    ctx->IoctlCount++;
    WdfSpinLockRelease(ctx->Lock);

    WinVhciTraceUlong(device, L"WvIoctlCount", ctx->IoctlCount);
    WinVhciTraceUlong(device, L"WvLastIoctl",  IoControlCode);

    switch (IoControlCode) {

    case IOCTL_BTHX_GET_VERSION:

        if (outBuf == NULL || OutputBufferLength < sizeof(BTHX_VERSION)) {
            KdPrint(("winvhci: GET_VERSION bad buffer (out %p len %u)\n",
                     outBuf, (ULONG)OutputBufferLength));
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        *(PBTHX_VERSION)outBuf = Microsoft_BTHX_DDI_Version;
        info   = sizeof(BTHX_VERSION);
        status = STATUS_SUCCESS;

        WinVhciTraceUlong(device, L"WvGetVersion", Microsoft_BTHX_DDI_Version.Version);

        KdPrint(("winvhci: GET_VERSION -> %u\n", Microsoft_BTHX_DDI_Version.Version));
        break;

    case IOCTL_BTHX_SET_VERSION:

        if (inBuf == NULL || InputBufferLength < sizeof(BTHX_VERSION)) {
            KdPrint(("winvhci: SET_VERSION bad buffer (in %p len %u)\n",
                     inBuf, (ULONG)InputBufferLength));
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        ctx->BthxVersion = ((PBTHX_VERSION)inBuf)->Version;
        status = STATUS_SUCCESS;

        WinVhciTraceUlong(device, L"WvSetVersion", ctx->BthxVersion);

        KdPrint(("winvhci: SET_VERSION <- %u\n", ctx->BthxVersion));
        break;

    case IOCTL_BTHX_QUERY_CAPABILITIES: {

        PBTHX_CAPABILITIES caps = (PBTHX_CAPABILITIES)outBuf;

        if (caps == NULL || OutputBufferLength < sizeof(BTHX_CAPABILITIES)) {
            KdPrint(("winvhci: QUERY_CAPABILITIES bad buffer (out %p len %u)\n",
                     outBuf, (ULONG)OutputBufferLength));
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        //
        // MEASURED, not guessed: ScoSupportNone is REJECTED by the stack.
        //
        // Reporting ScoSupportNone makes BthMini answer GET_VERSION,
        // SET_VERSION and QUERY_CAPABILITIES, then refuse to start the radio
        // with CM_PROB_FAILED_START / STATUS_DEVICE_CONFIGURATION_ERROR,
        // retrying the handshake several times before giving up. Reporting
        // ScoSupportHCIBypass with one channel makes the radio start and the
        // stack immediately begin driving the transport with IOCTL_BTHX_WRITE_HCI.
        //
        // So the documentation's claim that a transport "must specify
        // ScoSupportHCIBypass" is real and enforced. We claim it and never
        // deliver sideband audio, which is the same bargain the docs imply.
        //
        // Both values stay registry knobs, because that is what made this
        // cheap to establish: a registry edit plus a device restart, instead
        // of a rebuild-sign-package-install cycle.
        //
        //   HKLM\SOFTWARE\winvhci
        //     WvScoSupport     REG_DWORD  0 = None, 1 = HCI, 2 = HCIBypass
        //     WvMaxScoChannels REG_DWORD
        //
        ULONG scoSupport = (ULONG)ScoSupportHCIBypass;
        ULONG maxSco     = 1;

        (VOID)WinVhciReadUlong(device, L"WvScoSupport",     &scoSupport);
        (VOID)WinVhciReadUlong(device, L"WvMaxScoChannels", &maxSco);

        RtlZeroMemory(caps, sizeof(*caps));
        caps->MaxAclTransferInSize = WINVHCI_MAX_ACL_TRANSFER_IN;
        caps->ScoSupport           = (BTHX_SCO_SUPPORT)scoSupport;
        caps->MaxScoChannels       = maxSco;
        //
        // Opt out of power management until the data path works.
        //
        caps->IsDeviceIdleCapable = FALSE;
        caps->IsDeviceWakeCapable = FALSE;

        info   = sizeof(BTHX_CAPABILITIES);
        status = STATUS_SUCCESS;

        WinVhciTraceUlong(device, L"WvQueryCapsSco", scoSupport);

        KdPrint(("winvhci: QUERY_CAPABILITIES -> maxAclIn %u sco %u chans %u\n",
                 WINVHCI_MAX_ACL_TRANSFER_IN, scoSupport, maxSco));
        break;
    }

    case IOCTL_BTHX_WRITE_HCI: {

        PBTHX_HCI_READ_WRITE_CONTEXT w = (PBTHX_HCI_READ_WRITE_CONTEXT)inBuf;

        if (w == NULL || InputBufferLength < WINVHCI_HCI_CONTEXT_HEADER_SIZE) {
            KdPrint(("winvhci: WRITE_HCI bad buffer (in %p len %u)\n",
                     inBuf, (ULONG)InputBufferLength));
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        WdfSpinLockAcquire(ctx->Lock);
        ctx->WriteHciCount++;
        WdfSpinLockRelease(ctx->Lock);

        WinVhciTraceUlong(device, L"WvWriteHci",  ctx->WriteHciCount);
        WinVhciTraceUlong(device, L"WvWriteType", w->Type);

        KdPrint(("winvhci: WRITE_HCI type 0x%02x len %u (#%u)\n",
                 w->Type, w->DataLen, ctx->WriteHciCount));

        WinVhciLogHciPacket(w->Type, w->Data, w->DataLen);

        //
        // Hand it to userspace. The driver has no opinion about HCI semantics:
        // the simulator on the other side of \\.\WinVhci decides what, if
        // anything, to reply. (M1 answered commands here with a canned empty
        // Command Complete, purely to see the stack advance; that is gone.)
        //
        WinVhciQueueToUser(ctx, w->Type, w->Data, w->DataLen);

        info   = w->DataLen;
        status = STATUS_SUCCESS;
        break;
    }

    case IOCTL_BTHX_READ_HCI: {

        //
        // MEASURED layout - see WINVHCI_READ_TYPE_WORD_SIZE in winvhci.h. The
        // context is ONE contiguous struct starting at Type3InputBuffer, and
        // UserBuffer points at its Type field, four bytes in. An earlier build
        // cast UserBuffer to the whole struct, so it read Data[3] as Type,
        // saw 0x00, and rejected every read the stack posted with
        // STATUS_NOT_SUPPORTED - which is what left nothing pended to carry
        // HCI_Reset's Command Complete and stalled the radio at
        // CM_PROB_FAILED_POST_START.
        //
        PBTHX_HCI_READ_WRITE_CONTEXT r = (PBTHX_HCI_READ_WRITE_CONTEXT)inBuf;
        WDFQUEUE                     target;
        ULONG                        capacity;

        if (r == NULL || InputBufferLength < sizeof(ULONG) ||
            outBuf == NULL || OutputBufferLength < WINVHCI_HCI_CONTEXT_HEADER_SIZE) {
            KdPrint(("winvhci: READ_HCI bad buffers (in %p/%u out %p/%u)\n",
                     inBuf, (ULONG)InputBufferLength,
                     outBuf, (ULONG)OutputBufferLength));
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        //
        // Assert the layout rather than trust it: if a future Windows passes
        // the two buffers independently, everything below silently corrupts
        // memory. Fail loudly instead.
        //
        if ((PUCHAR)outBuf != (PUCHAR)inBuf + WINVHCI_READ_TYPE_WORD_SIZE) {
            KdPrint(("winvhci: READ_HCI UNEXPECTED LAYOUT: out %p != in %p + %u\n",
                     outBuf, inBuf, (ULONG)WINVHCI_READ_TYPE_WORD_SIZE));
            WinVhciTraceUlong(device, L"WvReadLayoutBad", 1);
            status = STATUS_INVALID_DEVICE_REQUEST;
            break;
        }

        //
        // MEASURED: the ULONG at Type3InputBuffer - the DataLen field's
        // position - carries the REQUESTED PACKET TYPE on the way in, not a
        // length. Observed values are exactly 4 (HciPacketEvent) and 2
        // (HciPacketAclData), and they line up perfectly with the buffer sizes
        // the stack posts:
        //
        //     requested 4  capacity 261    -> event
        //     requested 2  capacity 1025   -> ACL   (= 4 + MaxAclTransferInSize)
        //
        // So the two-queue model was right that Type selects the channel; the
        // type is simply in the input buffer rather than the output one. See
        // docs/design.md, "Where the read type actually lives".
        //
        // Route on the explicit request, and keep the capacity as a
        // cross-check: if the two ever disagree, the assumption has broken and
        // that is worth seeing rather than silently misrouting a stream.
        //
        capacity = (ULONG)OutputBufferLength - WINVHCI_HCI_CONTEXT_HEADER_SIZE;

        switch (r->DataLen) {
        case HciPacketEvent:
            target = ctx->ReadEventQueue;
            break;
        case HciPacketAclData:
            target = ctx->ReadDataQueue;
            break;
        default:
            //
            // Unknown request: fall back to sizing, which is at least
            // self-consistent, and complain.
            //
            KdPrint(("winvhci: READ_HCI unexpected requested type %u, "
                     "falling back to capacity\n", r->DataLen));
            WinVhciTraceUlong(device, L"WvReadOddType", r->DataLen);
            target = (capacity >= WINVHCI_MAX_ACL_TRANSFER_IN) ? ctx->ReadDataQueue
                                                             : ctx->ReadEventQueue;
            break;
        }

        if ((target == ctx->ReadDataQueue) != (capacity >= WINVHCI_MAX_ACL_TRANSFER_IN)) {
            KdPrint(("winvhci: READ_HCI type/capacity DISAGREE (type %u capacity %u)\n",
                     r->DataLen, capacity));
            WinVhciTraceUlong(device, L"WvReadMismatch", capacity);
        }

        KdPrint(("winvhci: READ_HCI request type %u capacity %u -> %s queue\n",
                 r->DataLen, capacity,
                 (target == ctx->ReadDataQueue) ? "acl" : "event"));

        //
        // The other half of the rendezvous: if userspace already produced a
        // packet of this type, this read completes immediately rather than
        // parking behind a packet that is sitting right there.
        //
        {
            UCHAR           wantType = (target == ctx->ReadDataQueue) ? WINVHCI_H4_ACL
                                                                     : WINVHCI_H4_EVENT;
            PWINVHCI_PACKET queued   = WinVhciTakePendingForStack(ctx, wantType);

            if (queued != NULL) {
                KdPrint(("winvhci: READ_HCI satisfied from backlog, type 0x%02x %u bytes\n",
                         queued->Type, queued->Length));
                status = WinVhciCompleteRead(Request, queued->Type, queued->Data, queued->Length);
                ExFreePoolWithTag(queued, WINVHCI_POOL_TAG);
                return;
            }
        }

        status = WdfRequestForwardToIoQueue(Request, target);
        if (!NT_SUCCESS(status)) {
            KdPrint(("winvhci: READ_HCI forward failed 0x%08x\n", status));
            break;
        }

        WdfSpinLockAcquire(ctx->Lock);
        if (target == ctx->ReadDataQueue) {
            ctx->PendedDataReads++;
        } else {
            ctx->PendedEventReads++;
        }
        WdfSpinLockRelease(ctx->Lock);

        WinVhciTraceUlong(device, L"WvReadEvent", ctx->PendedEventReads);
        WinVhciTraceUlong(device, L"WvReadAcl",   ctx->PendedDataReads);

        KdPrint(("winvhci: READ_HCI pended (evt %u, acl %u)\n",
                 ctx->PendedEventReads, ctx->PendedDataReads));

        //
        // Parked. Ownership has passed to the manual queue - do NOT complete.
        //
        return;
    }

    default:
        WinVhciTraceUlong(device, L"WvUnknownIoctl", IoControlCode);
        KdPrint(("winvhci: unhandled ioctl 0x%08x\n", IoControlCode));
        break;
    }

    //
    // The status we hand back is the thing BthMini reacts to, so record it -
    // a device that fails to start with STATUS_DEVICE_CONFIGURATION_ERROR
    // looks identical from outside whether we returned it or BthMini decided
    // it on its own.
    //
    WinVhciTraceUlong(device, L"WvLastStatus", (ULONG)status);

    WdfRequestCompleteWithInformation(Request, status, info);
}

VOID
WinVhciEvtBthxInternalDeviceControl(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
{
    WinVhciBthxDispatch(Queue, Request, OutputBufferLength, InputBufferLength, IoControlCode);
}

VOID
WinVhciEvtBthxDeviceControl(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
/*++

Routine Description:

    bthxddi.h calls these "kernel-level (internal) IOCTLs", which says they
    arrive as IRP_MJ_INTERNAL_DEVICE_CONTROL - but that is a comment, not a
    guarantee. Handling the non-internal major code identically costs nothing
    and removes an entire class of silent no-op.

--*/
{
    WinVhciBthxDispatch(Queue, Request, OutputBufferLength, InputBufferLength, IoControlCode);
}

NTSTATUS
WinVhciFdoCreateQueues(
    _In_ WDFDEVICE Device
    )
/*++

Routine Description:

    Creates the queue that receives BTHX requests forwarded up from the radio
    PDO, plus the two manual queues that park pending reads.

    Every queue here is explicitly NON power-managed. Two reasons, both of which
    bite in practice:

      - IOCTL_BTHX_READ_HCI is parked indefinitely by design. In a
        power-managed queue the framework waits for outstanding requests before
        allowing a power transition, so a parked read would stall shutdown -
        exactly the class of hang that has already cost this project hours.

      - Requests forwarded across device stacks with
        WdfRequestForwardToParentDeviceIoQueue must not be subject to two
        independent power state machines.

--*/
{
    PWINVHCI_FDO_CONTEXT ctx = WinVhciFdoGetContext(Device);
    WDF_IO_QUEUE_CONFIG  config;
    NTSTATUS             status;

    WDF_IO_QUEUE_CONFIG_INIT(&config, WdfIoQueueDispatchParallel);
    config.PowerManaged                    = WdfFalse;
    config.EvtIoInternalDeviceControl      = WinVhciEvtBthxInternalDeviceControl;
    config.EvtIoDeviceControl              = WinVhciEvtBthxDeviceControl;

    status = WdfIoQueueCreate(Device, &config, WDF_NO_OBJECT_ATTRIBUTES, &ctx->BthxIoQueue);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: BthxIoQueue create failed 0x%08x\n", status));
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT(&config, WdfIoQueueDispatchManual);
    config.PowerManaged = WdfFalse;

    status = WdfIoQueueCreate(Device, &config, WDF_NO_OBJECT_ATTRIBUTES, &ctx->ReadEventQueue);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: ReadEventQueue create failed 0x%08x\n", status));
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT(&config, WdfIoQueueDispatchManual);
    config.PowerManaged = WdfFalse;

    status = WdfIoQueueCreate(Device, &config, WDF_NO_OBJECT_ATTRIBUTES, &ctx->ReadDataQueue);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: ReadDataQueue create failed 0x%08x\n", status));
        return status;
    }

    KdPrint(("winvhci: queues created\n"));

    return STATUS_SUCCESS;
}

VOID
WinVhciEvtSelfManagedIoCleanup(
    _In_ WDFDEVICE Device
    )
/*++

Routine Description:

    Release the indefinitely-parked reads on the way out. Because the manual
    queues are not power-managed, nothing else will do this for us, and a
    request still owned by a queue at device teardown is a leak at best.

--*/
{
    PWINVHCI_FDO_CONTEXT ctx = WinVhciFdoGetContext(Device);

    KdPrint(("winvhci: cleanup - writes %u, pended reads evt %u acl %u\n",
             ctx->WriteHciCount, ctx->PendedEventReads, ctx->PendedDataReads));

    if (ctx->ReadEventQueue != NULL) {
        WdfIoQueuePurgeSynchronously(ctx->ReadEventQueue);
    }
    if (ctx->ReadDataQueue != NULL) {
        WdfIoQueuePurgeSynchronously(ctx->ReadDataQueue);
    }
}
