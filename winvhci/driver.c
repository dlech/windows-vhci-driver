/*++

Module Name:

    driver.c

Abstract:

    winvhci - a virtual Bluetooth HCI controller for Windows.

    DriverEntry and FDO creation. The FDO is root-enumerated and owns a child
    list holding exactly one radio PDO (M1 creates it unconditionally at start;
    M2 moves creation behind the userspace FF-opcode control packet, matching
    the lifetime of opening /dev/vhci on Linux).

Environment:

    Kernel mode only.

--*/

#include "winvhci.h"

#ifdef ALLOC_PRAGMA
#pragma alloc_text (INIT, DriverEntry)
#pragma alloc_text (PAGE, WinVhciEvtDeviceAdd)
#pragma alloc_text (PAGE, WinVhciEvtDriverContextCleanup)
#endif

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    WDF_DRIVER_CONFIG     config;
    WDF_OBJECT_ATTRIBUTES attributes;
    NTSTATUS              status;

    KdPrint(("winvhci: DriverEntry, registry path %wZ\n", RegistryPath));

    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.EvtCleanupCallback = WinVhciEvtDriverContextCleanup;

    WDF_DRIVER_CONFIG_INIT(&config, WinVhciEvtDeviceAdd);

    status = WdfDriverCreate(DriverObject,
                             RegistryPath,
                             &attributes,
                             &config,
                             WDF_NO_HANDLE);

    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: WdfDriverCreate failed 0x%08x\n", status));
        return status;
    }

    KdPrint(("winvhci: DriverEntry succeeded\n"));

    return status;
}

NTSTATUS
WinVhciEvtDeviceAdd(
    _In_    WDFDRIVER       Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
    )
/*++

Routine Description:

    Creates the FDO for ROOT\WINVHCI, its BTHX queues, and the one radio child.

--*/
{
    WDF_CHILD_LIST_CONFIG        childConfig;
    WDF_OBJECT_ATTRIBUTES        attributes;
    WDF_PNPPOWER_EVENT_CALLBACKS pnpCallbacks;
    WDFDEVICE                    device;
    PWINVHCI_FDO_CONTEXT         fdoContext;
    NTSTATUS                     status;

    UNREFERENCED_PARAMETER(Driver);

    PAGED_CODE();

    KdPrint(("winvhci: EvtDeviceAdd\n"));

    //
    // The child list must be configured on the DEVICE_INIT, before the device
    // exists, because the framework attaches it during WdfDeviceCreate.
    //
    WDF_CHILD_LIST_CONFIG_INIT(&childConfig,
                               sizeof(WINVHCI_RADIO_IDENTIFICATION),
                               WinVhciEvtChildListCreateDevice);

    WdfFdoInitSetDefaultChildListConfig(DeviceInit,
                                        &childConfig,
                                        WDF_NO_OBJECT_ATTRIBUTES);

    //
    // Read requests from BthMini are parked indefinitely, so they must be
    // released explicitly rather than left to block a power transition. See
    // WinVhciEvtSelfManagedIoCleanup.
    //
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpCallbacks);
    pnpCallbacks.EvtDeviceSelfManagedIoCleanup = WinVhciEvtSelfManagedIoCleanup;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnpCallbacks);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, WINVHCI_FDO_CONTEXT);

    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: WdfDeviceCreate failed 0x%08x\n", status));
        return status;
    }

    fdoContext = WinVhciFdoGetContext(device);
    RtlZeroMemory(fdoContext, sizeof(*fdoContext));
    fdoContext->Device = device;

    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = device;
    status = WdfSpinLockCreate(&attributes, &fdoContext->Lock);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: WdfSpinLockCreate failed 0x%08x\n", status));
        return status;
    }

    //
    // First breadcrumb, written from a callback that certainly runs. If this
    // value is absent from the device key, the tracing mechanism itself is
    // broken and no conclusion may be drawn from the absence of the others.
    //
    WinVhciTraceUlong(device, L"WvDeviceAdd", 1);

    status = WinVhciFdoCreateQueues(device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    //
    // M1: one radio, always present. Failing to add it is not fatal to the FDO
    // itself - the device still loads, and the missing child is the symptom
    // worth seeing in Device Manager rather than a load failure that hides it.
    //
    status = WinVhciAddRadio(device, 1);
    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: WinVhciAddRadio failed 0x%08x\n", status));
    }

    KdPrint(("winvhci: FDO %p ready\n", device));

    return STATUS_SUCCESS;
}

VOID
WinVhciEvtDriverContextCleanup(
    _In_ WDFOBJECT DriverObject
    )
{
    UNREFERENCED_PARAMETER(DriverObject);
    PAGED_CODE();
    KdPrint(("winvhci: driver unloading\n"));
}
