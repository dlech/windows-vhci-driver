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
// KdPrint output is unreadable on this test VM: there is no live kernel
// debugger attached, and DebugView's kernel capture does not work here (it
// never installs its Dbgv helper driver, so it captures nothing at all).
// Rather than fly blind, record progress as values under the device's own
// registry key, which any SSH session can read back:
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
// This is diagnostic scaffolding for bring-up, not a permanent logging design.
// It costs a registry write per request, which is far too expensive once the
// data path carries real traffic - it should go once tracing works.
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

    TRUE if the value was present, in which case *Value holds it.

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
    PVOID                  inBuf;
    PVOID                  outBuf;
    NTSTATUS               status = STATUS_INVALID_DEVICE_REQUEST;
    ULONG_PTR              info   = 0;

    WDF_REQUEST_PARAMETERS_INIT(&params);
    WdfRequestGetParameters(Request, &params);

    irp    = WdfRequestWdmGetIrp(Request);
    inBuf  = params.Parameters.DeviceIoControl.Type3InputBuffer;
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
        // M1 swallows host->controller traffic. M2 hands it to userspace.
        //
        info   = w->DataLen;
        status = STATUS_SUCCESS;
        break;
    }

    case IOCTL_BTHX_READ_HCI: {

        PBTHX_HCI_READ_WRITE_CONTEXT r = (PBTHX_HCI_READ_WRITE_CONTEXT)outBuf;
        WDFQUEUE                     target;

        if (r == NULL || OutputBufferLength < WINVHCI_HCI_CONTEXT_HEADER_SIZE) {
            KdPrint(("winvhci: READ_HCI bad buffer (out %p len %u)\n",
                     outBuf, (ULONG)OutputBufferLength));
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        //
        // The caller pre-sets Type to say WHICH channel it is reading. These are
        // two independent streams and must be parked separately.
        //
        switch (r->Type) {
        case HciPacketEvent:
            target = ctx->ReadEventQueue;
            break;
        case HciPacketAclData:
            target = ctx->ReadDataQueue;
            break;
        default:
            KdPrint(("winvhci: READ_HCI unsupported type 0x%02x\n", r->Type));
            status = STATUS_NOT_SUPPORTED;
            target = NULL;
            break;
        }

        if (target == NULL) {
            break;
        }

        status = WdfRequestForwardToIoQueue(Request, target);
        if (!NT_SUCCESS(status)) {
            KdPrint(("winvhci: READ_HCI forward failed 0x%08x\n", status));
            break;
        }

        WdfSpinLockAcquire(ctx->Lock);
        if (r->Type == HciPacketEvent) {
            ctx->PendedEventReads++;
        } else {
            ctx->PendedDataReads++;
        }
        WdfSpinLockRelease(ctx->Lock);

        WinVhciTraceUlong(device, L"WvReadEvent", ctx->PendedEventReads);
        WinVhciTraceUlong(device, L"WvReadAcl",   ctx->PendedDataReads);

        KdPrint(("winvhci: READ_HCI type 0x%02x pended (evt %u, acl %u)\n",
                 r->Type, ctx->PendedEventReads, ctx->PendedDataReads));

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
