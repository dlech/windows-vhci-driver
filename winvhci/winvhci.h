/*++

Module Name:

    winvhci.h

Abstract:

    Shared declarations for winvhci, a virtual Bluetooth HCI controller.

    Topology (see docs/implementation-plan.md 3.1):

        ROOT\WINVHCI -- winvhci.sys FDO
                            |
                            +-- child PDO   HWID  winvhci\radio
                                            CID   MS_BTHX_BTHMINI
                                              ^
                                     BthMini.sys -> BthPort.sys

    The compatible ID is the whole trick: the in-box bth.inf binds BthMini and
    BthPort to any PDO that reports MS_BTHX_BTHMINI, so Windows treats our
    software-only child as a Bluetooth radio without us shipping any INF for it.

Environment:

    Kernel mode only.

--*/

#pragma once

#include <ntddk.h>
#include <wdf.h>
#include <bthxddi.h>

//
// Identifiers for the child radio PDO.
//
#define WINVHCI_RADIO_DEVICE_ID   L"winvhci\\radio"
#define WINVHCI_RADIO_HARDWARE_ID L"winvhci\\radio"
#define WINVHCI_RADIO_COMPAT_ID   L"MS_BTHX_BTHMINI"

//
// Capabilities reported to BthPort. See implementation-plan.md 3.6 - ScoSupport
// is the value most likely to be rejected, so it is the first thing to change
// if the stack refuses to come up.
//
#define WINVHCI_MAX_ACL_TRANSFER_IN 1021

//
// The BTHX read/write context is #pragma pack(1), so its header is 5 bytes
// (ULONG DataLen + UCHAR Type), not 8. Data[1] is a trailing array; the real
// payload length is DataLen.
//
#define WINVHCI_HCI_CONTEXT_HEADER_SIZE \
    FIELD_OFFSET(BTHX_HCI_READ_WRITE_CONTEXT, Data)

//
// How IOCTL_BTHX_READ_HCI actually lays its buffers out. MEASURED:
//
//   Type3InputBuffer -> ULONG requestedType    InputBufferLength  == 4
//   Irp->UserBuffer  -> BTHX_HCI_READ_WRITE_CONTEXT
//                         ULONG DataLen        OutputBufferLength == 5 + capacity
//                         UCHAR Type
//                         UCHAR Data[capacity]
//
// The two live in ONE allocation with the type word immediately before the
// context, so UserBuffer == Type3InputBuffer + 4. That adjacency is checked at
// runtime, because everything below writes through these pointers.
//
// The requested type is a BTHX_HCI_PACKET_TYPE value (4 = event, 2 = ACL), not
// a length, despite occupying the position a DataLen would.
//
// The capacities confirm the reading: subtracting the 5-byte context header
// gives exactly 257 for events (2-byte HCI event header + 255 max payload) and
// exactly MaxAclTransferInSize for ACL. An earlier version treated UserBuffer
// as pointing at the Type field, which yields 261 and 1025 - numbers that mean
// nothing - and wrote the type byte into DataLen's low byte, so the stack
// rejected the event and retried HCI_Reset.
//
#define WINVHCI_READ_TYPE_WORD_SIZE sizeof(ULONG)

//
// Largest HCI event: 2-byte header (code + parameter length) plus a parameter
// length that cannot exceed 255.
//
#define WINVHCI_MAX_EVENT_SIZE 257

//
// FDO context. For M1 this holds only what is needed to accept and park the
// stack's requests; the userspace-facing queues and backlog lists described in
// implementation-plan.md 3.3 arrive with M2.
//
typedef struct _WINVHCI_FDO_CONTEXT {

    WDFDEVICE   Device;

    //
    // BTHX requests are forwarded here from the child PDO's queue, so all
    // controller state lives on the FDO and the PDO stays a thin shim.
    //
    WDFQUEUE    BthxIoQueue;

    //
    // Two INDEPENDENT read channels, selected by the Type field of each
    // IOCTL_BTHX_READ_HCI. Merging them misroutes packets and stalls the stack
    // (implementation-plan.md 3.3).
    //
    WDFQUEUE    ReadEventQueue;     // Type == HciPacketEvent
    WDFQUEUE    ReadDataQueue;      // Type == HciPacketAclData

    WDFSPINLOCK Lock;               // guards the counters below

    ULONG       BthxVersion;        // as agreed via SET_VERSION

    //
    // Counters. M1's exit criterion is observational, so make the observations
    // cheap to read back.
    //
    ULONG       PdoRequestCount;
    ULONG       IoctlCount;
    ULONG       WriteHciCount;
    ULONG       PendedEventReads;
    ULONG       PendedDataReads;

} WINVHCI_FDO_CONTEXT, *PWINVHCI_FDO_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(WINVHCI_FDO_CONTEXT, WinVhciFdoGetContext)

//
// How the FDO's child list identifies a radio. Must begin with the framework's
// header; the framework copies and compares this by value.
//
typedef struct _WINVHCI_RADIO_IDENTIFICATION {
    WDF_CHILD_IDENTIFICATION_DESCRIPTION_HEADER Header;
    ULONG                                       RadioId;
} WINVHCI_RADIO_IDENTIFICATION, *PWINVHCI_RADIO_IDENTIFICATION;

//
// PDO context.
//
typedef struct _WINVHCI_PDO_CONTEXT {
    WDFDEVICE Fdo;
    ULONG     RadioId;
} WINVHCI_PDO_CONTEXT, *PWINVHCI_PDO_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(WINVHCI_PDO_CONTEXT, WinVhciPdoGetContext)

//
// driver.c
//
DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD          WinVhciEvtDeviceAdd;
EVT_WDF_OBJECT_CONTEXT_CLEANUP     WinVhciEvtDriverContextCleanup;

//
// fdo.c
//
//
// Bring-up breadcrumb: records a value under the FDO's device key. See the
// comment in fdo.c - this is scaffolding, not the eventual logging design.
//
VOID
WinVhciTraceUlong(
    _In_ WDFDEVICE Device,
    _In_ PCWSTR    Name,
    _In_ ULONG     Value
    );

NTSTATUS
WinVhciFdoCreateQueues(
    _In_ WDFDEVICE Device
    );

EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL WinVhciEvtBthxInternalDeviceControl;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL          WinVhciEvtBthxDeviceControl;
EVT_WDF_DEVICE_SELF_MANAGED_IO_CLEANUP      WinVhciEvtSelfManagedIoCleanup;

//
// pdo.c
//
EVT_WDF_CHILD_LIST_CREATE_DEVICE WinVhciEvtChildListCreateDevice;

NTSTATUS
WinVhciAddRadio(
    _In_ WDFDEVICE Fdo,
    _In_ ULONG     RadioId
    );
