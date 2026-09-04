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
    PWINVHCI_PDO_CONTEXT pdoCtx = WinVhciPdoGetContext(Device);

    UNREFERENCED_PARAMETER(ResourcesRaw);
    UNREFERENCED_PARAMETER(ResourcesTranslated);

    WinVhciTraceUlong(pdoCtx->Fdo, L"WvPdoPrepareHw", 1);
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

    UNREFERENCED_PARAMETER(PreviousState);

    WinVhciTraceUlong(pdoCtx->Fdo, L"WvPdoD0Entry", 1);
    KdPrint(("winvhci: pdo D0 entry\n"));

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
    // Count arrivals at the PDO separately from arrivals at the FDO queue, so
    // "BthMini never sent us anything" and "the forward across the stacks
    // failed" are distinguishable rather than both looking like silence.
    //
    fdoCtx->PdoRequestCount++;
    WinVhciTraceUlong(pdoCtx->Fdo, L"WvPdoRequests", fdoCtx->PdoRequestCount);
    WinVhciTraceUlong(pdoCtx->Fdo, L"WvPdoLastIoctl", IoControlCode);

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
