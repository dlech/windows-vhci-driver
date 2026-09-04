# Windows VHCI — design

How `winvhci.sys` is built, and the parts of the BTHX contract that had to be measured rather
than read. Everything here describes code that exists and runs.

Companion documents: [research.md](research.md) is the prior art and the argument for this
shape; [controller-requirements.md](controller-requirements.md) is what the userspace side must
do to satisfy Windows; [development.md](development.md) is how to build, deploy and debug it.

---

## Topology

One driver, two device objects, plus a symbolic link for userspace:

```
 ROOT\WINVHCI  ──  winvhci.sys FDO ──── \\.\WinVhci ──→ userspace controller
                        │
                        └── child PDO   HWID  winvhci\radio
                                        CID   MS_BTHX_BTHMINI
                                          ↑
                                   BthMini.sys → BthPort.sys → Windows Bluetooth
```

The FDO *is* the control device. Userspace reaches it through the symbolic link
`\DosDevices\WinVhci`, created with `WdfDeviceCreateSymbolicLink` — a fixed path, not a device
interface GUID, so a client is `CreateFile(L"\\\\.\\WinVhci", ...)` with nothing to enumerate
first. There is no separate `WDFCONTROLDEVICE`; the serialhcibus sample does not need one
either and it only adds lifetime complexity.

The child PDO is created on demand and destroyed with the handle that asked for it. PnP loads
BthMini onto it via `WdfChildListAddOrUpdateChildDescriptionAsPresent`; removing it from the
child list makes the radio vanish from Device Manager. That is the exact lifetime model of
opening and closing `/dev/vhci`, and it is observable: with no client attached, Device Manager
shows only the `Virtual Bluetooth HCI Controller` FDO.

All controller state lives on the FDO. The PDO is a thin shim that forwards BTHX IOCTLs to the
parent with `WdfRequestForwardToParentDeviceIoQueue`, enabled by
`WdfPdoInitAllowForwardingRequestToParent` at PDO-init time.

### What survived from the sample

The WDK's `bluetooth/serialhcibus` sample is ~6.6k lines and most of it is UART-specific.
Deleted: `WDK/device.c` (baud rates, vendor power sequences), `FdoFindConnectResources` (we are
root-enumerated and have *no* hardware resources), the H4 stream reassembler in `io.c`
(userspace hands us whole pre-framed packets), and the `RequestCompletePath` interlocked
cancel/complete dance (that protects requests forwarded *down* to a serial `IoTarget`; we have
no lower target, and WDF's manual queues handle cancellation).

Kept closely: `pdo.c`'s PDO construction and forwarding pattern, and the two-queue read model.
The result is about 1.8k lines across `driver.c`, `fdo.c`, `pdo.c` and `user.c`, comment-heavy
because most of what is written down here was measured rather than read.

---

## Queues and the rendezvous

The stack posts **two independent read channels**, and a single merged read queue misroutes
packets and stalls. From the sample:

```
BTHX_VALID_WRITE_PACKET_TYPE  = Command | AclData     (host → controller)
BTHX_VALID_READ_PACKET_TYPE   = Event   | AclData     (controller → host)
```

FDO context state, all guarded by one `WDFSPINLOCK`:

| State | Purpose |
| --- | --- |
| `ReadEventQueue` (manual) | pended `READ_HCI` requesting `HciPacketEvent` |
| `ReadDataQueue` (manual) | pended `READ_HCI` requesting `HciPacketAclData` |
| `PendingEventList`, `PendingDataList` | controller→host backlog when no read is pended |
| `UserReadQueue` (manual) | pended userspace `ReadFile` |
| `HostToCtrlList` | host→controller backlog when userspace isn't reading |

Both directions follow one rule, and it is the invariant the whole driver rests on:

```
(request queue, packet list)
  (empty,  *)      → append packet to list
  (!empty, empty)  → dequeue request, complete it with the packet
  (!empty, !empty) → impossible; assert
```

Backlogs are bounded at `WINVHCI_MAX_BACKLOG` (64). On overflow the driver drops and counts —
a virtual controller that blocks the host stack is worse than one that loses a packet, and the
counter records that it happened.

Observed during bring-up: the stack posts **one** event read and **two** ACL reads, and
replenishes a read as soon as one is completed.

Both channels are exercised. The event channel carries the whole initialisation sequence and
advertising reports; the ACL channel carries ATT, which a GATT read or write from a Windows
application drives end to end.

---

## The BTHX contract, as measured

### The IOCTLs are METHOD_NEITHER

```c
#define BTHX_CTL(id)  CTL_CODE(FILE_DEVICE_BLUETOOTH, (id), METHOD_NEITHER, FILE_ANY_ACCESS)
```

No buffer mapping or probing is done for us: input arrives as
`Parameters.DeviceIoControl.Type3InputBuffer`, output as `Irp->UserBuffer`. These requests
originate in kernel mode from `BthMini.sys`, so the pointers are kernel addresses valid in any
context — but they must still be retrieved the METHOD_NEITHER way rather than through WDF's
buffered-request accessors.

`bthxddi.h` also supplies the version constant and a ready-made global to answer
`IOCTL_BTHX_GET_VERSION` with:

```c
#define BTHX_DDI_VERSION_1  0x00000001
__declspec(selectany) BTHX_VERSION Microsoft_BTHX_DDI_Version = { BTHX_DDI_VERSION_1 };
```

### Where the read type actually lives

`IOCTL_BTHX_READ_HCI` splits one contiguous allocation across the two METHOD_NEITHER pointers:

```
Type3InputBuffer   ->  ULONG requestedType          InputBufferLength  == 4
Type3InputBuffer+4 == Irp->UserBuffer
                   ->  BTHX_HCI_READ_WRITE_CONTEXT  OutputBufferLength == 5 + capacity
                         ULONG DataLen
                         UCHAR Type
                         UCHAR Data[capacity]
```

Two things are easy to get wrong here, and both were got wrong before being measured:

1. **The input buffer is not the context.** It is a bare `ULONG` holding the *requested packet
   type* (`4` = event, `2` = ACL) — not a length, despite sitting where a `DataLen` would. It is
   allocated immediately before the context, so `UserBuffer == Type3InputBuffer + 4`. The driver
   checks that adjacency at runtime, because everything downstream writes through these
   pointers.

2. **`Irp->UserBuffer` is the whole context**, starting at `DataLen`. An intermediate version
   assumed it pointed at the `Type` field four bytes in. That reading is self-consistent enough
   to look right and survives contact with the routing logic, but it puts the type byte into
   `DataLen`'s low byte on the way out — so the stack silently rejects the event and retries the
   command forever.

The capacities settle it. Subtracting the 5-byte header gives exactly **257** for event reads
(2-byte HCI event header + 255 maximum payload) and exactly **1021** for ACL reads
(`MaxAclTransferInSize`, the value returned from `QUERY_CAPABILITIES`). The rejected reading
gives 261 and 1025, which correspond to nothing.

> When a layout guess produces meaningful constants it is probably right; when it produces
> arbitrary ones it is probably wrong.

This mattered concretely. An earlier build rejected the untyped-looking reads with
`STATUS_NOT_SUPPORTED`, which left nothing pended to receive `HCI_Reset`'s Command Complete and
stalled the radio at `CM_PROB_FAILED_POST_START`. Parking them correctly is what moved it to
`Status: OK` / `CM_PROB_NONE`.

To complete a read: fill `Type`, `DataLen` and `Data`, and complete the request with
`Information = 5 + payload length`. `Data` carries the HCI packet *without* its H4 type byte,
since the type travels in `Type`. The driver routes on the requested type and cross-checks the
capacity; a disagreement means the assumption has broken.

### Capabilities

`IOCTL_BTHX_QUERY_CAPABILITIES` is answered with:

```c
MaxAclTransferInSize = 1021;
ScoSupport           = ScoSupportHCIBypass;   // ScoSupportNone is rejected
MaxScoChannels       = 1;
IsDeviceIdleCapable  = FALSE;
IsDeviceWakeCapable  = FALSE;
```

**`ScoSupportNone` is rejected.** Reporting it makes BthMini complete the
`GET_VERSION` / `SET_VERSION` / `QUERY_CAPABILITIES` handshake and then refuse to start the
radio with `CM_PROB_FAILED_START` and `STATUS_DEVICE_CONFIGURATION_ERROR`, retrying the
handshake about six times before giving up. `ScoSupportHCIBypass` with `MaxScoChannels = 1`
makes the radio start, after which the stack immediately begins driving the transport. So the
documentation's "must specify `ScoSupportHCIBypass`" is real and enforced: the driver claims it
and never delivers sideband audio.

Both values are registry knobs under `HKLM\SOFTWARE\winvhci` (`WvScoSupport`,
`WvMaxScoChannels`), which is what made this cheap to establish — a registry edit and a device
restart rather than a rebuild-sign-package-install cycle. Idle and wake are `FALSE`: power
management is deliberately opted out of.

---

## Userspace interface

`\\.\WinVhci` behaves byte-for-byte like `/dev/vhci`. The data path is `IRP_MJ_READ` /
`IRP_MJ_WRITE` with buffered I/O, and the control channel is in-band using the H4 vendor packet
type, exactly as Linux does it:

```
  WriteFile   (controller → host)   04 <event>  |  02 <acl>  |  FF <opcode>
  ReadFile    (host → controller)   01 <cmd>    |  02 <acl>  |  FF FF <opcode> <id_lo> <id_hi>
```

`FF <opcode>` creates the radio; the driver answers with `FF FF <opcode> <id_lo> <id_hi>` where
`id` is the assigned radio number. The opcode bits carry no meaning here — Linux's
external-config and raw-device quirks have no Windows analogue — but reserving the byte keeps
the wire format identical.

Why this rather than a custom IOCTL surface: a client is then `open` + `read` + `write`, so
Bumble's `vhci` transport and every other vhci tool is a path change rather than a rewrite, and
a bridge process is a byte pump.

Mechanics:

- `WdfDeviceInitSetIoType(WdfDeviceIoBuffered)`; the largest transfer is
  `WINVHCI_MAX_H4_PACKET` = 1 type byte + 4-byte ACL header + 1021.
- `WdfDeviceInitSetExclusive(TRUE)` — one controller at a time, mirroring vhci's `open_mutex`.
- `EvtDeviceFileCreate` / `EvtFileClose` own the radio lifetime: close tears down the PDO,
  purges both directions, and completes outstanding BTHX reads.
- Clients open with `FILE_FLAG_OVERLAPPED`. This is not optional in practice: a synchronous
  `ReadFile` blocks indefinitely once the stack goes quiet, so a bounded run never terminates
  and has to be killed — which also loses its buffered output.

There is no statistics IOCTL. Counters live in the FDO context and are exposed through the
registry breadcrumbs described in [development.md](development.md).

---

## Packet types

Confirmed by reading the installed `bthxddi.h` (WDK 10.0.28000.2526), the enum values **are**
the H4 packet-type bytes:

```c
typedef enum _BTHX_HCI_PACKET_TYPE {
    HciPacketCommand    = 0x01,
    HciPacketAclData    = 0x02,
    HciPacketEvent      = 0x04
} BTHX_HCI_PACKET_TYPE;
```

So the type byte passes between userspace and the stack unchanged — no lookup table. (The
published DDI reference lists the enumerators without values, which makes them look like a
plain 0/1/2 sequence. They are not.)

The driver still validates. `0x03` SCO and `0x05` ISO are rejected with `STATUS_NOT_SUPPORTED`,
`0xFF` vendor is consumed as control and never forwarded, and direction is enforced: Command
only host→controller, Event only controller→host.

**No SCO and no LE Audio isochronous data, permanently.** `BTHX_HCI_PACKET_TYPE` has no packet
type for either. Real transports carry SCO out of band (that is what `ScoSupportHCIBypass`
means), and there is no ISO type at all. If these are ever needed the answer is a different
transport — a UdeCx-emulated USB dongle — not an extension of this one.
