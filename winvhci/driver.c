/*++

Module Name:

    driver.c

Abstract:

    winvhci - a virtual Bluetooth HCI controller for Windows.

    M0 scaffold: a root-enumerated KMDF driver that does nothing but load and
    announce itself. Its only job right now is to prove the build, sign,
    install and kernel-debug loop works end to end before any Bluetooth code
    goes in. The BTHX transport and the child radio PDO arrive in M1.

Environment:

    Kernel mode only.

--*/

#include <ntddk.h>
#include <wdf.h>

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD WinVhciEvtDeviceAdd;
EVT_WDF_OBJECT_CONTEXT_CLEANUP WinVhciEvtDriverContextCleanup;

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

    Called by the framework when the root enumerator reports our device. For M0
    this creates the bare FDO and stops. M1 adds the userspace control interface
    here and the MS_BTHX_BTHMINI child PDO underneath it.

--*/
{
    WDFDEVICE device;
    NTSTATUS  status;

    UNREFERENCED_PARAMETER(Driver);

    PAGED_CODE();

    KdPrint(("winvhci: EvtDeviceAdd\n"));

    status = WdfDeviceCreate(&DeviceInit, WDF_NO_OBJECT_ATTRIBUTES, &device);

    if (!NT_SUCCESS(status)) {
        KdPrint(("winvhci: WdfDeviceCreate failed 0x%08x\n", status));
        return status;
    }

    KdPrint(("winvhci: device created, FDO %p\n", device));

    return status;
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
