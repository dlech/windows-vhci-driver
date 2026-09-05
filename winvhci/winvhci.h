/*++

Module Name:

    winvhci.h

Abstract:

    Shared declarations for winvhci, a virtual Bluetooth HCI controller.

    Topology (see docs/design.md, "Topology"):

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
// Capabilities reported to BthPort. See docs/design.md, "Capabilities" -
// ScoSupport is the value most likely to be rejected, so it is the first thing
// to change if the stack refuses to come up.
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
// H4 packet type bytes, as used on the userspace wire. These are the same
// values as BTHX_HCI_PACKET_TYPE for the three types the DDI supports, which is
// why no translation table is needed (docs/design.md, "Packet types").
//
#define WINVHCI_H4_COMMAND 0x01
#define WINVHCI_H4_ACL     0x02
#define WINVHCI_H4_SCO     0x03
#define WINVHCI_H4_EVENT   0x04
#define WINVHCI_H4_ISO     0x05
#define WINVHCI_H4_VENDOR  0xFF

//
// Largest userspace transfer: one H4 type byte plus the biggest packet body,
// which is an ACL header plus MaxAclTransferInSize.
//
#define WINVHCI_MAX_BODY      (4 + WINVHCI_MAX_ACL_TRANSFER_IN)
#define WINVHCI_MAX_H4_PACKET (1 + WINVHCI_MAX_BODY)

//
// Backlog policy. The two directions are NOT symmetric, because the producer
// differs and only one of them can be told to wait.
//
// userspace -> stack: BACKPRESSURE. The producer is a userspace simulator
//   holding \\.\WinVhci, so its WRITE can be pended until the stack drains a
//   slot. That is honest - the writer learns the controller is behind - and it
//   is also the only safe answer, because an unbounded queue fed by userspace
//   is a non-paged pool exhaustion primitive available to anyone who can open
//   the device. WINVHCI_MAX_BACKLOG is the depth at which writes start waiting.
//
// stack -> userspace: UNBOUNDED. The producer is BthPort, which cannot be told
//   to wait: the packets are HCI commands and ACL data it has already handed
//   off, and discarding one silently breaks bring-up in a way nothing can
//   recover from or even report. So this direction is never bounded, and never
//   drops while a client is attached. It drops only when NO client holds the
//   device, where the alternative is an unbounded list nobody will ever read.
//
// This replaced a single bound of 64 on both directions, where overflow dropped
// and counted. The count was unreadable from userspace, so the loss was
// invisible: a discarded advertising report just looked like a device that
// would not be discovered.
//
#define WINVHCI_MAX_BACKLOG 64

//
// Statistics, readable from userspace so a test can assert the driver lost
// nothing rather than inferring it from behaviour.
//
//     DeviceIoControl(h, IOCTL_WINVHCI_GET_STATS, NULL, 0,
//                     &stats, sizeof(stats), &returned, NULL);
//
#define IOCTL_WINVHCI_GET_STATS \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_ACCESS)

typedef struct _WINVHCI_STATS {
    ULONG Size;                 // sizeof(WINVHCI_STATS), for versioning

    //
    // Packets discarded. Any non-zero value is a defect or a client that went
    // away mid-flight; nothing in normal operation should increment these.
    //
    ULONG DropsNoClient;        // stack -> userspace with no handle open
    ULONG DropsAllocFailed;     // ExAllocatePool2 returned NULL

    //
    // Current and peak queue depths. The peaks are what say whether
    // WINVHCI_MAX_BACKLOG is anywhere near being reached in practice.
    //
    ULONG HostToCtrlCount;
    ULONG HostToCtrlPeak;
    ULONG PendingEventCount;
    ULONG PendingEventPeak;
    ULONG PendingDataCount;
    ULONG PendingDataPeak;

    //
    // Totals moved in each direction. These are the denominators: without
    // them a flat WritesPended is ambiguous between "userspace sent nothing"
    // and "userspace sent plenty and the stack kept up", which is not a
    // distinction a test should have to guess at.
    //
    ULONG WritesTotal;          // H4 packets accepted from userspace
    ULONG QueuedToUserTotal;    // packets queued stack -> userspace

    //
    // How many userspace writes have been pended for backpressure, and how
    // many are waiting now. A rising total with a healthy stack is normal;
    // a permanently non-zero Waiting means the stack stopped draining.
    //
    ULONG WritesPended;
    ULONG WritesWaiting;
} WINVHCI_STATS, *PWINVHCI_STATS;

#define WINVHCI_POOL_TAG 'ihvW'

//
// One queued HCI packet, body only - the type travels alongside it.
//
typedef struct _WINVHCI_PACKET {
    LIST_ENTRY Link;
    UCHAR      Type;
    ULONG      Length;
    _Field_size_bytes_(Length) UCHAR Data[ANYSIZE_ARRAY];
} WINVHCI_PACKET, *PWINVHCI_PACKET;

//
// FDO context.
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
    // (docs/design.md, "Queues and the rendezvous").
    //
    WDFQUEUE    ReadEventQueue;     // Type == HciPacketEvent
    WDFQUEUE    ReadDataQueue;      // Type == HciPacketAclData

    //
    // The userspace side of the seam: \\.\WinVhci, opened exclusively by one
    // simulator at a time (docs/design.md, "Userspace interface").
    //
    WDFQUEUE      UserReadQueue;    // manual: pended ReadFile
    WDFFILEOBJECT Owner;            // the one open handle, or NULL

    //
    // Userspace writes pended for backpressure, waiting for the stack to drain
    // a slot off PendingEventList or PendingDataList. Manual dispatch: nothing
    // completes these but WinVhciDrainWriteWaiters.
    //
    WDFQUEUE      WriteWaitQueue;

    //
    // Backlogs, for whichever side of a rendezvous arrives first.
    //
    LIST_ENTRY  HostToCtrlList;     // stack -> userspace, UNBOUNDED
    LIST_ENTRY  PendingEventList;   // userspace -> stack, events
    LIST_ENTRY  PendingDataList;    // userspace -> stack, ACL

    ULONG       HostToCtrlCount;
    ULONG       PendingEventCount;
    ULONG       PendingDataCount;

    //
    // Peaks, so a test can see how close the bounded direction came to
    // blocking rather than only whether it did.
    //
    ULONG       HostToCtrlPeak;
    ULONG       PendingEventPeak;
    ULONG       PendingDataPeak;

    //
    // Losses, split by cause because they mean completely different things: a
    // client that vanished mid-flight is expected, a failed allocation is not.
    // Neither should ever be non-zero because a queue was full - that is what
    // backpressure and the unbounded direction exist to prevent.
    //
    ULONG       DropsNoClient;
    ULONG       DropsAllocFailed;

    //
    // Totals, so the counters above have a denominator.
    //
    ULONG       WritesTotal;        // H4 packets accepted from userspace
    ULONG       QueuedToUserTotal;  // packets queued stack -> userspace

    ULONG       WritesPended;       // cumulative
    ULONG       WritesWaiting;      // currently on WriteWaitQueue

    BOOLEAN     RadioPresent;
    ULONG       NextRadioId;

    WDFSPINLOCK Lock;               // guards every field above and below

    ULONG       BthxVersion;        // as agreed via SET_VERSION

    //
    // Test-only allocation fault injection, set from HKLM\SOFTWARE\winvhci
    // (WvFailAllocOneIn) at device add. Zero disables it.
    //
    // This exists because Driver Verifier's low resources simulation cannot
    // reach the driver's two allocation sites - both allocate while holding
    // Lock, and at 100% injection probability Verifier failed none of them.
    // Both counters below are guarded by Lock, like everything else here.
    //
    ULONG       FailAllocOneIn;
    ULONG       AllocSeq;

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
// TRUE when the test knob says this allocation should be failed. The caller
// must hold Lock, which every allocation site already does.
//
FORCEINLINE
BOOLEAN
WinVhciTestFailAlloc(
    _Inout_ PWINVHCI_FDO_CONTEXT Ctx
    )
{
    if (Ctx->FailAllocOneIn == 0) {
        return FALSE;
    }
    Ctx->AllocSeq++;
    return (BOOLEAN)((Ctx->AllocSeq % Ctx->FailAllocOneIn) == 0);
}

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
NTSTATUS
WinVhciFdoCreateQueues(
    _In_ WDFDEVICE Device
    );

EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL WinVhciEvtBthxInternalDeviceControl;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL          WinVhciEvtBthxDeviceControl;
EVT_WDF_DEVICE_SELF_MANAGED_IO_CLEANUP      WinVhciEvtSelfManagedIoCleanup;

//
// Hands a controller-to-host packet to whichever BTHX read is pended, or parks
// it on the matching backlog list. Called from the userspace write path.
//
NTSTATUS
WinVhciDeliverToStack(
    _In_ PWINVHCI_FDO_CONTEXT Ctx,
    _In_ UCHAR                Type,
    _In_reads_bytes_(Length) const UCHAR *Body,
    _In_ ULONG                Length
    );

//
// Takes a queued controller-to-host packet of the given type, if one is
// waiting. Called from the BTHX read path so a read that arrives after its
// packet still completes immediately. Caller owns the returned packet.
//
PWINVHCI_PACKET
WinVhciTakePendingForStack(
    _In_ PWINVHCI_FDO_CONTEXT Ctx,
    _In_ UCHAR                Type
    );

//
// user.c - the \\.\WinVhci interface
//
NTSTATUS
WinVhciUserInitDevice(
    _In_ PWDFDEVICE_INIT DeviceInit
    );

NTSTATUS
WinVhciUserCreateQueues(
    _In_ WDFDEVICE Device
    );

VOID
WinVhciQueueToUser(
    _In_ PWINVHCI_FDO_CONTEXT Ctx,
    _In_ UCHAR                Type,
    _In_reads_bytes_(Length) const UCHAR *Body,
    _In_ ULONG                Length
    );

VOID
WinVhciPurgeBacklogs(
    _In_ PWINVHCI_FDO_CONTEXT Ctx
    );

//
// Release one userspace write that was pended for backpressure. Called after a
// slot is freed on the bounded userspace -> stack direction, with the FDO lock
// NOT held.
//
VOID
WinVhciDrainWriteWaiters(
    _In_ PWINVHCI_FDO_CONTEXT Ctx
    );

EVT_WDF_DEVICE_FILE_CREATE      WinVhciEvtDeviceFileCreate;
EVT_WDF_FILE_CLOSE              WinVhciEvtFileClose;
EVT_WDF_IO_QUEUE_IO_READ        WinVhciEvtIoRead;
EVT_WDF_IO_QUEUE_IO_WRITE       WinVhciEvtIoWrite;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL WinVhciEvtIoDeviceControl;

//
// pdo.c
//
EVT_WDF_CHILD_LIST_CREATE_DEVICE WinVhciEvtChildListCreateDevice;

NTSTATUS
WinVhciAddRadio(
    _In_ WDFDEVICE Fdo,
    _In_ ULONG     RadioId
    );

NTSTATUS
WinVhciRemoveRadios(
    _In_ WDFDEVICE Fdo
    );
