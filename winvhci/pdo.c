/*++

Module Name:

    pdo.c

Abstract:

    The child radio PDO - a software-only device whose only purpose is to report
    the compatible ID MS_BTHX_BTHMINI, which makes the in-box bth.inf load
    BthMini.sys and BthPort.sys on top of it. That is the entire seam between
    this driver and the Windows Bluetooth stack.

    The PDO is deliberately a thin shim: it owns no controller state and simply
    forwards what BthMini sends to a queue on the parent FDO, so there is one
    place where transport state lives.

Environment:

    Kernel mode only.

--*/

#include "winvhci.h"
#include <ntstrsafe.h>

#ifdef ALLOC_PRAGMA
#pragma alloc_text (PAGE, WinVhciEvtChildListCreateDevice)
#pragma alloc_text (PAGE, WinVhciAddRadio)
#pragma alloc_text (PAGE, WinVhciRemoveRadios)
#endif

static NTSTATUS
WinVhciPdoEvtPrepareHardware(
    _In_ WDFDEVICE Device,
    _In_ WDFCMRESLIST ResourcesRaw,
    _In_ WDFCMRESLIST ResourcesTranslated
    )
/*++

Routine Description:

    Purely observational. A software PDO has no resources to prepare; the point
    is to record how far the radio stack actually gets, so "BthMini never sent
    us an IOCTL" can be told apart from "the PDO never started".

--*/
{
    UNREFERENCED_PARAMETER(Device);
    UNREFERENCED_PARAMETER(ResourcesRaw);
    UNREFERENCED_PARAMETER(ResourcesTranslated);

    KdPrint(("winvhci: pdo prepare hardware\n"));

    return STATUS_SUCCESS;
}

static NTSTATUS
WinVhciPdoEvtD0Entry(
    _In_ WDFDEVICE              Device,
    _In_ WDF_POWER_DEVICE_STATE PreviousState
    )
{
    PWINVHCI_PDO_CONTEXT pdoCtx = WinVhciPdoGetContext(Device);
    PWINVHCI_FDO_CONTEXT ctx    = WinVhciFdoGetContext(pdoCtx->Fdo);

    UNREFERENCED_PARAMETER(PreviousState);

    WdfSpinLockAcquire(ctx->Lock);
    ctx->RadioStarted = TRUE;
    WdfSpinLockRelease(ctx->Lock);

    KdPrint(("winvhci: pdo D0 entry\n"));

    return STATUS_SUCCESS;
}

static NTSTATUS
WinVhciPdoEvtD0Exit(
    _In_ WDFDEVICE              Device,
    _In_ WDF_POWER_DEVICE_STATE TargetState
    )
/*++

Routine Description:

    The radio's stack has stopped consuming. This is winvhci's HCI_UP going
    false, and it is what lets a write be refused instead of queued against
    nothing.

    MEASURED, with a radio whose controller never answered. BthPort sends
    HCI_Reset, retries once four seconds later, and at twelve seconds gives up:

        12.055626  READ_HCI CANCELED on the event queue
        12.055668  READ_HCI CANCELED on the acl queue
        12.055675  READ_HCI CANCELED on the acl queue
        12.056305  pdo SURPRISE REMOVAL
        12.056318  pdo SELF-MANAGED IO SUSPEND
        12.056324  pdo D0 EXIT, target state 5

    all of it two full seconds before the client's next write arrived. The
    driver was never in the dark; it simply had no D0Exit registered to hear
    it.

    "target state 5" is WdfPowerDeviceD3Final - the device leaving the working
    state D0 for good, rather than an ordinary powered-down D3 it could come
    back from. Any of the three callbacks above would catch this particular
    case, but D0Exit is the one that is ALSO right for a system sleep, where
    the stack equally stops consuming and there is a matching D0Entry to turn
    RadioStarted back on afterwards. Surprise removal has no such pairing.

    The backlogs are dropped here for the same reason Linux's vhci_flush and
    vhci_close_dev purge readq when the hdev goes down: whatever is queued was
    meant for a stack that is no longer there, and keeping it would replay
    stale packets into the next bring-up.

--*/
{
    PWINVHCI_PDO_CONTEXT pdoCtx = WinVhciPdoGetContext(Device);

    KdPrint(("winvhci: pdo D0 exit (target %d); the stack has stopped consuming\n",
             TargetState));

    WinVhciRadioStackDown(WinVhciFdoGetContext(pdoCtx->Fdo));

    return STATUS_SUCCESS;
}

static VOID
WinVhciPdoForwardToParent(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ ULONG      IoControlCode
    )
/*++

Routine Description:

    Hands the request to the FDO's BTHX queue.

    Everything is forwarded, not just the five known BTHX codes: if BthMini
    sends something unexpected, it should show up in one log with the others
    rather than being silently failed here. The FDO's default case names it.

--*/
{
    WDFDEVICE            pdo    = WdfIoQueueGetDevice(Queue);
    PWINVHCI_PDO_CONTEXT pdoCtx = WinVhciPdoGetContext(pdo);
    PWINVHCI_FDO_CONTEXT fdoCtx = WinVhciFdoGetContext(pdoCtx->Fdo);
    WDF_REQUEST_FORWARD_OPTIONS options;
    NTSTATUS                    status;

    //
    // IoControlCode is carried only so the failure path can name the request
    // that could not be forwarded. That is a KdPrint, so in a release build the
    // parameter genuinely is unreferenced.
    //
    UNREFERENCED_PARAMETER(IoControlCode);

    //
    // Count arrivals at the PDO separately from arrivals at the FDO queue, so
    // "BthMini never sent us anything" and "the forward across the stacks
    // failed" are distinguishable rather than both looking like silence.
    //
    fdoCtx->PdoRequestCount++;

    WDF_REQUEST_FORWARD_OPTIONS_INIT(&options);

    status = WdfRequestForwardToParentDeviceIoQueue(Request,
                                                    fdoCtx->BthxIoQueue,
                                                    &options);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: pdo forward of 0x%08x failed 0x%08x\n",
                 IoControlCode, status));
        WdfRequestComplete(Request, status);
    }
}

static VOID
WinVhciPdoEvtInternalDeviceControl(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
{
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    WinVhciPdoForwardToParent(Queue, Request, IoControlCode);
}

static VOID
WinVhciPdoEvtDeviceControl(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
{
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    WinVhciPdoForwardToParent(Queue, Request, IoControlCode);
}

NTSTATUS
WinVhciEvtChildListCreateDevice(
    _In_ WDFCHILDLIST                              ChildList,
    _In_ PWDF_CHILD_IDENTIFICATION_DESCRIPTION_HEADER IdentificationDescription,
    _In_ PWDFDEVICE_INIT                           ChildInit
    )
{
    PWINVHCI_RADIO_IDENTIFICATION id =
        CONTAINING_RECORD(IdentificationDescription,
                          WINVHCI_RADIO_IDENTIFICATION,
                          Header);

    WDF_OBJECT_ATTRIBUTES        attributes;
    WDF_DEVICE_PNP_CAPABILITIES  pnpCaps;
    WDF_PNPPOWER_EVENT_CALLBACKS pnpCallbacks;
    WDF_IO_QUEUE_CONFIG         queueConfig;
    WDFDEVICE                   pdo;
    PWINVHCI_PDO_CONTEXT        pdoCtx;
    WDFQUEUE                    queue;
    NTSTATUS                    status;

    DECLARE_CONST_UNICODE_STRING(deviceId,     WINVHCI_RADIO_DEVICE_ID);
    DECLARE_CONST_UNICODE_STRING(hardwareId,   WINVHCI_RADIO_HARDWARE_ID);
    DECLARE_CONST_UNICODE_STRING(compatibleId, WINVHCI_RADIO_COMPAT_ID);
    DECLARE_CONST_UNICODE_STRING(deviceText,   L"Virtual Bluetooth Radio");
    DECLARE_CONST_UNICODE_STRING(deviceLocale, L"winvhci");

    DECLARE_UNICODE_STRING_SIZE(instanceId, 16);

    PAGED_CODE();

    KdPrint(("winvhci: creating radio PDO, id %u\n", id->RadioId));

    status = WdfPdoInitAssignDeviceID(ChildInit, &deviceId);
    if (!NT_SUCCESS(status)) { goto Fail; }

    status = WdfPdoInitAddHardwareID(ChildInit, &hardwareId);
    if (!NT_SUCCESS(status)) { goto Fail; }

    //
    // The line that matters: bth.inf matches this compatible ID and loads
    // BthMini + BthPort onto the node.
    //
    status = WdfPdoInitAddCompatibleID(ChildInit, &compatibleId);
    if (!NT_SUCCESS(status)) { goto Fail; }

    status = RtlUnicodeStringPrintf(&instanceId, L"%u", id->RadioId);
    if (!NT_SUCCESS(status)) { goto Fail; }

    status = WdfPdoInitAssignInstanceID(ChildInit, &instanceId);
    if (!NT_SUCCESS(status)) { goto Fail; }

    status = WdfPdoInitAddDeviceText(ChildInit, &deviceText, &deviceLocale, 0x409);
    if (!NT_SUCCESS(status)) { goto Fail; }

    WdfPdoInitSetDefaultLocale(ChildInit, 0x409);

    //
    // Required before WdfRequestForwardToParentDeviceIoQueue may be used from
    // this PDO's queues. Without it the forward fails at runtime with
    // STATUS_INVALID_DEVICE_REQUEST, which is a confusing way to find out.
    //
    WdfPdoInitAllowForwardingRequestToParent(ChildInit);

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpCallbacks);
    pnpCallbacks.EvtDevicePrepareHardware = WinVhciPdoEvtPrepareHardware;
    pnpCallbacks.EvtDeviceD0Entry         = WinVhciPdoEvtD0Entry;
    pnpCallbacks.EvtDeviceD0Exit          = WinVhciPdoEvtD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(ChildInit, &pnpCallbacks);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, WINVHCI_PDO_CONTEXT);

    status = WdfDeviceCreate(&ChildInit, &attributes, &pdo);
    if (!NT_SUCCESS(status)) { goto Fail; }

    pdoCtx = WinVhciPdoGetContext(pdo);
    pdoCtx->Fdo     = WdfChildListGetDevice(ChildList);
    pdoCtx->RadioId = id->RadioId;

    WDF_DEVICE_PNP_CAPABILITIES_INIT(&pnpCaps);
    pnpCaps.Removable         = WdfTrue;
    pnpCaps.SurpriseRemovalOK = WdfTrue;
    WdfDeviceSetPnpCapabilities(pdo, &pnpCaps);

    //
    // Not power-managed, to match the FDO queue these requests are forwarded
    // into - see WinVhciFdoCreateQueues.
    //
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queueConfig, WdfIoQueueDispatchParallel);
    queueConfig.PowerManaged               = WdfFalse;
    queueConfig.EvtIoInternalDeviceControl = WinVhciPdoEvtInternalDeviceControl;
    queueConfig.EvtIoDeviceControl         = WinVhciPdoEvtDeviceControl;

    status = WdfIoQueueCreate(pdo, &queueConfig, WDF_NO_OBJECT_ATTRIBUTES, &queue);
    if (!NT_SUCCESS(status)) { goto Fail; }

    KdPrint(("winvhci: radio PDO %p created (%wZ / %wZ)\n",
             pdo, &hardwareId, &compatibleId));

    return STATUS_SUCCESS;

Fail:
    KdPrint(("winvhci: radio PDO creation failed 0x%08x\n", status));
    return status;
}

NTSTATUS
WinVhciAddRadio(
    _In_ WDFDEVICE Fdo,
    _In_ ULONG     RadioId
    )
/*++

Routine Description:

    Reports a radio as present, which makes PnP call
    WinVhciEvtChildListCreateDevice. Removing the description again is what
    makes the radio vanish - the same lifetime as closing /dev/vhci on Linux.

--*/
{
    WINVHCI_RADIO_IDENTIFICATION id;
    NTSTATUS                     status;

    PAGED_CODE();

    //
    // Zero first: the framework compares descriptions by value, so padding must
    // be deterministic or an identical radio can fail to match itself.
    //
    RtlZeroMemory(&id, sizeof(id));
    WDF_CHILD_IDENTIFICATION_DESCRIPTION_HEADER_INIT(&id.Header, sizeof(id));
    id.RadioId = RadioId;

    status = WdfChildListAddOrUpdateChildDescriptionAsPresent(
                 WdfFdoGetDefaultChildList(Fdo),
                 &id.Header,
                 NULL);

    KdPrint(("winvhci: AddRadio %u -> 0x%08x\n", RadioId, status));

    return status;
}

NTSTATUS
WinVhciRemoveRadios(
    _In_ WDFDEVICE Fdo
    )
/*++

Routine Description:

    Reports every radio as gone, which makes the Bluetooth stack tear down and
    the node vanish from Device Manager.

    Marking all children missing in one pass, rather than removing a remembered
    handle, keeps this correct if a client ever creates more than one radio, and
    is idempotent when there are none.

--*/
{
    WDFCHILDLIST list = WdfFdoGetDefaultChildList(Fdo);

    //
    // This function is in a paged segment, so it must not run above
    // PASSIVE_LEVEL. Its one caller is EvtFileClose, which qualifies - but it
    // reaches here just after releasing the FDO spinlock, and moving the call
    // inside that lock would be an easy and silent mistake. PAGED_CODE turns
    // that into an immediate assertion on a checked build rather than a page
    // fault at raised IRQL later.
    //
    PAGED_CODE();

    WdfChildListBeginScan(list);
    //
    // A scan that reports nothing present marks everything previously reported
    // as missing when it ends.
    //
    WdfChildListEndScan(list);

    KdPrint(("winvhci: all radios removed\n"));

    return STATUS_SUCCESS;
}
