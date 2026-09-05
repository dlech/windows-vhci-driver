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

    //
    // Userspace-facing configuration - I/O type, exclusivity and the file
    // object callbacks - must also be set on the DEVICE_INIT.
    //
    status = WinVhciUserInitDevice(DeviceInit);
    if (!NT_SUCCESS(status)) {
        return status;
    }

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

    status = WinVhciFdoCreateQueues(device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    status = WinVhciUserCreateQueues(device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    //
    // No radio is created here. From M2 on, the controller's lifetime is the
    // userspace handle's lifetime: it appears when a client writes the
    // FF <opcode> control packet and disappears when the handle closes, exactly
    // as opening and closing /dev/vhci works on Linux.
    //
    // M1 created one unconditionally, which meant Windows always saw a radio
    // that nothing was driving.
    //
    KdPrint(("winvhci: FDO %p ready, waiting for a userspace client\n", device));

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
