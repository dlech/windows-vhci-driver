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

    //
    // TargetState is carried only so the trace can name the state being
    // entered. That is a KdPrint, which compiles to nothing in a release
    // build, so there the parameter genuinely is unreferenced.
    //
    UNREFERENCED_PARAMETER(TargetState);

    KdPrint(("winvhci: pdo D0 exit (target %d); the stack has stopped consuming\n",
             TargetState));

    WinVhciRadioStackDown(WinVhciFdoGetContext(pdoCtx->Fdo));

    return STATUS_SUCCESS;
}

VOID
WinVhciPdoEvtCleanup(
    _In_ WDFOBJECT Object
    )
/*++

Routine Description:

    The radio PDO is being destroyed. This is the moment the devnode is really
    gone, as distinct from D0Exit above, which fires when the stack stops
    consuming, and from EvtFileClose, which fires when the client lets go.

    Those three are seconds to tens of seconds apart, and conflating them is
    what made the Bluetooth radio appear to linger: PnP reported the devnode OK
    and WinRT reported RadioState.ON for over thirty seconds after a close,
    because the stack goes on retrying a radio it believes has gone out of
    range. Only this callback marks the end of that.

    Not paged: object cleanup can run at DISPATCH_LEVEL, and it must not touch
    anything pageable. The interlocked decrement is all it does.

--*/
{
    PWINVHCI_PDO_CONTEXT pdoCtx = WinVhciPdoGetContext((WDFDEVICE)Object);
    LONG                 left;

    left = InterlockedDecrement(&WinVhciFdoGetContext(pdoCtx->Fdo)->RadiosAlive);

    KdPrint(("winvhci: pdo destroyed, radio %u; %d still alive\n",
             pdoCtx->RadioId, left));
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

    //
    // A CONSTANT instance ID, deliberately - see WinVhciEvtChildListCreateDevice
    // below for why it is not the radio id.
    //
    DECLARE_CONST_UNICODE_STRING(instanceId, L"0");

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

    //
    // The instance ID is a constant, NOT the radio id, because Windows creates
    // one permanent devnode per distinct instance ID and never reclaims it.
    // Using the radio id left a registry entry behind for every radio ever
    // created - measured at 1428 on the test guest, and they take about fifteen
    // minutes to purge with pnputil. The driver cannot clean them up itself:
    // marking a child missing (WinVhciRemoveRadios) removes the device from the
    // active tree, but the Enum key persisting is deliberate Windows behavior
    // for every device, and deleting it is a user-mode, elevated operation. So
    // the accumulation has to be prevented here rather than cleaned up later.
    //
    // Reusing an ID reuses the devnode, which is measured, not assumed: opening
    // a radio whose instance ID already existed left the devnode count
    // unchanged.
    //
    // A constant cannot collide. DEVICE_CAPABILITIES.UniqueID is FALSE (nothing
    // sets it), so PnP itself makes the device instance ID unique - it is what
    // turns our "0" into WINVHCI\RADIO\1&79f5d87&1a&0. A real adapter is out of
    // reach regardless, being in the USB, PCI or BTHENUM namespace rather than
    // ours. And only one radio exists at a time in any case: the control device
    // is exclusive.
    //
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

    //
    // Runs when the framework destroys this object, which is after PnP has
    // finished removing the devnode - NOT when the client closed its handle.
    // That gap is the whole point: it is where the Bluetooth stack is still
    // retrying a radio it thinks went out of range, and it has been measured at
    // over thirty seconds.
    //
    attributes.EvtCleanupCallback = WinVhciPdoEvtCleanup;

    status = WdfDeviceCreate(&ChildInit, &attributes, &pdo);
    if (!NT_SUCCESS(status)) { goto Fail; }

    pdoCtx = WinVhciPdoGetContext(pdo);
    pdoCtx->Fdo     = WdfChildListGetDevice(ChildList);
    pdoCtx->RadioId = id->RadioId;

    //
    // Counted only once the object exists, so the cleanup callback that
    // decrements is guaranteed to have been registered on something real.
    //
    InterlockedIncrement(&WinVhciFdoGetContext(pdoCtx->Fdo)->RadiosAlive);

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
