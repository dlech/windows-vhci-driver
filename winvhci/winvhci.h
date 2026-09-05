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
// Backlog policy, deliberately the same as Linux's /dev/vhci: UNBOUNDED ONCE
// ADMITTED, REJECTED UP FRONT WHEN INADMISSIBLE. This driver's control
// protocol was modelled on that one, so its flow control should not be a
// surprise to a client written against it.
//
// Both directions are unbounded lists, never dropping while there is somewhere
// to deliver. That mirrors hci_vhci.c exactly: the controller -> host
// direction lands in hdev->rx_q via hci_recv_frame and the host -> controller
// direction in data->readq, and neither has a capacity check, a drop threshold
// or any blocking - packets accumulate without restriction.
//
// The admission checks are what keep that honest, and Linux has two:
//
//   if (!data->hdev) { kfree_skb(skb); return -ENODEV; }   // vhci_get_user
//
// and, deeper in, hci_recv_frame refuses with -ENXIO unless HCI_UP or HCI_INIT
// is set. So a packet is either deliverable and queued without limit, or
// refused immediately and by name. WinVhciDispatchWrite implements the first
// of those as STATUS_DEVICE_NOT_READY.
//
// TWO REJECTED DESIGNS, both of which this code has actually had:
//
//   A bound of 64 with a silent drop on overflow. The count was unreadable
//   from userspace, so the loss was invisible - a discarded advertising report
//   just looked like a device that would not be discovered.
//
//   A bound of 64 with BACKPRESSURE on overflow, pending the write until the
//   stack drained a slot. Non-lossy, and it measurably worked, but it answered
//   the wrong question. The only state that ever reached the bound was "no
//   radio, so nothing is draining" - a settled stack always has a read pended,
//   and 30,000 advertising reports at full speed never took the depth above
//   zero. Pending a write that has nowhere to go is not backpressure, it is a
//   slower failure; and queueing pre-radio packets meant they were replayed
//   into the bring-up of a radio that did not exist when they were sent, which
//   is precisely what -ENODEV exists to make unrepresentable.
//
// THE COST, stated plainly: an unbounded queue fed by userspace is a non-paged
// pool exhaustion primitive for whoever holds the handle. Linux carries the
// identical exposure on hdev->rx_q, and winvhci.inx restricts the device to
// SYSTEM and Administrators, so the client is already privileged. If that ever
// needs bounding, bound it with a hard failure and a counter, not by pending -
// see above for why.
//

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
    // Current and peak queue depths. Both directions are unbounded, so these
    // are informational - they say how much a client or the stack actually let
    // build up, not how close anything came to a limit.
    //
    ULONG HostToCtrlCount;
    ULONG HostToCtrlPeak;
    ULONG PendingEventCount;
    ULONG PendingEventPeak;
    ULONG PendingDataCount;
    ULONG PendingDataPeak;

    //
    // Totals moved in each direction, and the denominators for everything
    // above. Without them a depth of zero is ambiguous between "nothing was
    // sent" and "everything was sent and the far side kept up", which is not a
    // distinction a test should have to guess at.
    //
    ULONG WritesTotal;          // H4 packets accepted from userspace
    ULONG QueuedToUserTotal;    // packets queued stack -> userspace

    //
    // Writes refused because no radio existed yet - the
    // STATUS_DEVICE_NOT_READY path that mirrors Linux's -ENODEV. A client that
    // asks for its radio before sending anything, as Bumble's vhci transport
    // does, never increments this.
    //
    ULONG WritesNoRadio;
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
    // Backlogs, for whichever side of a rendezvous arrives first.
    //
    LIST_ENTRY  HostToCtrlList;     // stack -> userspace, UNBOUNDED
    LIST_ENTRY  PendingEventList;   // userspace -> stack, events
    LIST_ENTRY  PendingDataList;    // userspace -> stack, ACL

    ULONG       HostToCtrlCount;
    ULONG       PendingEventCount;
    ULONG       PendingDataCount;

    //
    // Peaks, so a test can see how much actually built up. Neither direction
    // is bounded, so these are diagnostics rather than headroom.
    //
    ULONG       HostToCtrlPeak;
    ULONG       PendingEventPeak;
    ULONG       PendingDataPeak;

    //
    // Losses, split by cause because they mean completely different things: a
    // client that vanished mid-flight is expected, a failed allocation is not.
    // Neither can ever be non-zero because a queue was full - nothing here is
    // bounded.
    //
    ULONG       DropsNoClient;
    ULONG       DropsAllocFailed;

    //
    // Totals, so the counters above have a denominator.
    //
    ULONG       WritesTotal;        // H4 packets accepted from userspace
    ULONG       QueuedToUserTotal;  // packets queued stack -> userspace
    ULONG       WritesNoRadio;      // refused, no radio existed yet

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
