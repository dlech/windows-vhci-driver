# Windows VHCI — architecture research

Goal: the Windows equivalent of Linux `drivers/bluetooth/hci_vhci.c` — a virtual Bluetooth
controller that appears to the OS as a real local radio, while a userspace process supplies
the HCI behaviour.

This is the **pre-implementation record**: why the project has the shape it does, and what was
established before any code existed. Findings below were verified against the live Windows 11
install on this machine (build 26200, ARM64) and against current Microsoft docs and the WDK
sample sources.

The driver now exists and works. Where implementation corrected or settled something, this
document says so inline and points at [design.md](design.md) (how it was actually built) or
[controller-requirements.md](controller-requirements.md) (what Windows demands of the
controller). §8 lists the open questions and their answers.

---

## 1. Reference: how Linux does it

`hci_vhci.c` (verified against current mainline) registers a **misc device** `/dev/vhci`
(minor 137). Framing on the character device is plain **H4** — one packet-type byte followed
by the HCI payload.

| Direction | Packet types |
| --- | --- |
| Userspace **writes** (controller → host) | `0x04` Event, `0x02` ACL, `0x03` SCO, `0x05` ISO, `0xFF` vendor/control |
| Userspace **reads** (host → controller) | `0x01` Command, `0x02` ACL, `0x03` SCO, `0x05` ISO |

Control channel is in-band, using the vendor packet type:

- Userspace writes `FF <opcode>` to instantiate the `hci_dev`. Bit 6 of the opcode requests
  `HCI_QUIRK_EXTERNAL_CONFIG`, bit 7 requests `HCI_QUIRK_RAW_DEVICE`, bits 2–5 are reserved.
- The kernel replies on the read side with `FF FF <opcode> <id_lo> <id_hi>`, where `id` is
  the assigned `hciN` index.
- If userspace never sends the control packet, a delayed work item creates the device with
  opcode `0x00` anyway.

The important structural point: **the entire adapter is a character device**, and the kernel
side is ~700 lines because Linux's `hci_dev` abstraction is the only thing it must satisfy.
Windows has no equivalent single-file escape hatch, but it does have a documented
extensibility seam — see below.

---

## 2. The Windows Bluetooth stack, and where we can cut in

Top to bottom:

```
  WinRT / Win32 Bluetooth APIs        (bthprops, BluetoothAPIs.dll)
  profile & bus drivers               (bthenum.sys, bthleenum.sys, hidbth, rfcomm, bthpan, …)
  BthPort.sys                         core stack: HCI, L2CAP, SDP, SCO
  ─────────── extensibility seam ───────────
  BthMini.sys                         "Bluetooth Extensibility Miniport Driver"
  <transport bus driver>              BTHX IOCTL contract  ← WE WRITE THIS
  <hardware>                          UART / SDIO / etc.
```

Historically the only transport was `BthUsb.sys` (USB dongles). Since Windows 8 there is a
documented **Bluetooth Extensibility Transport** interface for non-USB radios, exposed by
`BthMini.sys`, whose contract lives in `bthxddi.h`.

### 2.1 The binding mechanism — verified on this machine

`C:\Windows\INF\bth.inf` on this install (DriverVer `10.0.26100.8972`) contains:

```inf
[ControlFlags]
BasicDriverOk=MS_BTHX_BTHMINI,\
    ...

[Microsoft.NTarm64]
%BthMini.DeviceDesc% = BthMini, MS_BTHX_BTHMINI
```

with strings `BthMini.DeviceDesc = "Bluetooth Radio"` and
`BthMini_CopyFilesOnly.DeviceDesc = "Bluetooth Extensibility Miniport Driver"`.

**This is the whole trick.** Any PDO that reports the compatible ID `MS_BTHX_BTHMINI` gets
`BthMini.sys` + `BthPort.sys` loaded onto it by the in-box `bth.inf`, and from that point
the entire Windows Bluetooth stack — pairing UI, WinRT `BluetoothLEDevice`, RFCOMM sockets,
`bthenum` child devices — operates on it. We do not have to write, ship, or sign anything
above the transport.

The WDK sample `bluetooth/serialhcibus` confirms the contract from the other side:

```c
// Windows-driver-samples/bluetooth/serialhcibus/WDK/device.h
#define BT_PDO_HARDWARE_IDS     L"SerialBusWdk\\UART_H4"
#define BT_PDO_COMPATIBLE_IDS   L"MS_BTHX_BTHMINI"
#define BT_PDO_DEVICE_LOCATION  L"Serial HCI Bus - Bluetooth Function"
```

### 2.2 Root enumeration works — no fake hardware needed

The sample's own INF documents its test install as:

```
devcon install SerialBusWdk.inf SerialBusWdk_RootEnum
```

i.e. the bus driver is installed as a **root-enumerated software device** (`Class=System`),
and it then creates the Bluetooth child PDO itself. That is exactly the shape we need: no
ACPI node, no UART, no emulated hardware. The sample's `FdoFindConnectResources` walks
`CmResourceTypeConnection` descriptors to find its UART — for us that code is deleted, not
replaced.

---

## 3. The BTHX contract we must implement

All five IOCTLs arrive on our child PDO from `BthMini.sys`. From `bthxddi.h`:

| IOCTL | Purpose |
| --- | --- |
| `IOCTL_BTHX_GET_VERSION` | report the interface version we support |
| `IOCTL_BTHX_SET_VERSION` | stack tells us the version it will use |
| `IOCTL_BTHX_QUERY_CAPABILITIES` | fill in `BTHX_CAPABILITIES` |
| `IOCTL_BTHX_WRITE_HCI` | host → controller: HCI **commands** and **ACL** out |
| `IOCTL_BTHX_READ_HCI` | controller → host: HCI **events** and **ACL** in |

```c
typedef struct _BTHX_HCI_READ_WRITE_CONTEXT {
    ULONG DataLen;
    UCHAR Type;        // BTHX_HCI_PACKET_TYPE
    UCHAR Data[1];
} BTHX_HCI_READ_WRITE_CONTEXT;   // 1-byte packed

typedef enum _BTHX_HCI_PACKET_TYPE {
    HciPacketCommand = 0x01, HciPacketAclData = 0x02, HciPacketEvent = 0x04
} BTHX_HCI_PACKET_TYPE;

typedef struct _BTHX_CAPABILITIES {
    ULONG            MaxAclTransferInSize;
    BTHX_SCO_SUPPORT ScoSupport;       // ScoSupportNone | ScoSupportHCI | ScoSupportHCIBypass
    ULONG            MaxScoChannels;
    BOOLEAN          IsDeviceIdleCapable;
    BOOLEAN          IsDeviceWakeCapable;
} BTHX_CAPABILITIES;
```

The enumerator values are shown above as the header actually defines them. The published DDI
reference lists them without values, which makes them look like a plain 0/1/2 sequence; they
are in fact the H4 packet-type bytes, so no translation table is needed.

Note the shape of `READ_HCI`: the stack **posts** read IOCTLs down to us and we hold them
pending until a packet is available. That is Windows' inverted call model, and it maps
one-to-one onto the userspace side — a pended read from the stack is completed directly from
a packet handed to us by the userspace controller.

How `READ_HCI` splits that context across its two METHOD_NEITHER pointers is not obvious from
the header and had to be measured — see [design.md](design.md), "Where the read type actually
lives".

### 3.1 Known gaps vs. Linux vhci

- **No SCO or ISO packet type.** `BTHX_HCI_PACKET_TYPE` only has Command/ACL/Event. Real
  transports carry SCO out-of-band (`ScoSupportHCIBypass`, e.g. an I2S channel), and there
  is no ISO type at all, so LE Audio isochronous data has no path here. Docs say a transport
  "must specify `ScoSupportHCIBypass`", but `ScoSupportNone` exists in the enum and is the
  honest value for a virtual controller with no audio sideband. **Settled by experiment:
  `ScoSupportNone` is rejected** — the radio refuses to start with `CM_PROB_FAILED_START`. The
  documentation's requirement is real and enforced.
- **The controller must be convincing.** Linux's `hci_dev` is happy with a minimal command
  set. BthPort runs its own init sequence and will reject a radio that fails it. This turned
  out to be the single hardest part of the project, and Windows is markedly stricter than
  BlueZ in ways that produce no error message at all — see
  [controller-requirements.md](controller-requirements.md).

---

## 4. Proposed architecture

```
 userspace controller (Python/Bumble, or anything)
        │  H4-framed HCI, same byte format as /dev/vhci
        │  \\.\WinVhci  — ReadFile / WriteFile
 ┌──────┴───────────────────────────────────────────┐
 │  winvhci.sys   (KMDF, root-enumerated bus)       │
 │   • FDO: control device object for userspace     │
 │   • PDO: compatible ID MS_BTHX_BTHMINI           │
 │          handles IOCTL_BTHX_*                    │
 └──────┬───────────────────────────────────────────┘
        │  BTHX IOCTLs
   BthMini.sys → BthPort.sys → the rest of Windows Bluetooth
```

Two device objects in one driver:

1. **Control device** (`\\.\WinVhci`) — what userspace opens. It carries the vhci-equivalent
   operations: create the radio, submit controller→host packets, and receive host→controller
   packets.
2. **Child PDO** — advertises `MS_BTHX_BTHMINI`, services the BTHX IOCTLs by forwarding to
   and from the control device's queues.

Creating the radio is explicit, exactly like Linux's `FF <opcode>` vendor packet: userspace
writes the control packet, the driver calls
`WdfChildListAddOrUpdateChildDescriptionAsPresent`, and Windows loads BthMini onto the new PDO.
Closing the handle tears the PDO down, so the radio disappears from Device Manager — the same
lifetime model as closing `/dev/vhci`.

**As built** the control device is reached through a fixed symbolic link rather than a device
interface GUID, so a client is a plain `CreateFile` with nothing to enumerate first.

### 4.1 Userspace transport: why not a named pipe

A kernel driver **cannot be a named pipe server** — `ZwCreateNamedPipeFile` is not exported
to kernel mode. A driver can only be a pipe *client*, connecting out to a pipe that
userspace created. That inverts the lifetime (userspace must exist first, reconnect logic,
awkward security) for no benefit.

So the driver owns a control device that userspace opens directly, and a small user-mode bridge
process re-exposes it as a TCP socket for tools that want a stream.

**Revised during M2.** This section originally proposed a custom IOCTL surface for the data
path, with the H4 byte format living in the bridge. The driver does `IRP_MJ_READ` /
`IRP_MJ_WRITE` with H4 framing instead, so `\\.\WinVhci` *is* `/dev/vhci` at the byte level:
a client is `open` + `read` + `write`, existing vhci clients are a path change rather than a
rewrite, and the bridge collapses to a byte pump. See [design.md](design.md), "Userspace
interface".

---

## 5. Alternatives considered

**Emulated USB Bluetooth dongle via UdeCx.** Write a UDE (USB Device Emulation) client
driver presenting a virtual USB device with class `E0/01/01`, so the in-box `BthUsb.sys`
binds to it. This is how `usbip-win2` works, and it would exercise the *same* transport path
real dongles use. Rejected as the primary approach: strictly more work (full USB descriptor
set, endpoint/URB emulation, isochronous endpoints for SCO) to reach the same HCI seam that
BTHX gives us directly. Worth revisiting only if BthMini turns out to reject a
software-only transport, or if SCO/ISO becomes a requirement — the USB path does carry
SCO over isochronous endpoints, which BTHX cannot express.

**Usermode-only fake.** Shimming the WinRT/Win32 Bluetooth APIs. Rejected: it does not
produce a real adapter, so nothing below the API layer (pairing, bthenum, RFCOMM sockets,
other processes) sees it.

---

## 6. Toolchain

What was chosen, and why. [development.md](development.md) has the versions actually in use and
the build gotchas that came out of it.

| Need | Choice | Notes |
| --- | --- | --- |
| Compiler/IDE | Visual Studio 2026 Community | VS 2022 (≥17.0) also works; if the WDK VSIX lags, WDK 26100.6584 is the VS2022-compatible build |
| Driver framework | **KMDF** (WDF) | UMDF cannot do this — BthMini is kernel-mode and queries us with kernel IOCTLs |
| SDK/WDK | Windows Driver Kit 10.0.28000.2526 | the SDK alone is not enough: `bthxddi.h` is in the WDK's `km\` include directory |
| Spectre libs | MSVC v143 ARM64/ARM64EC **and** x64/x86 Spectre-mitigated libs | required by the WDK build, easy to forget |
| Install/enumerate | `pnputil` (in-box) or `devcon` (WDK) | root-enumerated install, e.g. `devcon install winvhci.inf ROOT\WINVHCI` |
| Test signing | `bcdedit /set testsigning on`, self-signed test cert | Secure Boot must be off; HVCI/memory integrity must be off |
| Debugging | WinDbg + KDNET or serial-over-named-pipe | `bcdedit /debug on` also disables load-time signature enforcement while attached |
| Tracing | WPP / TraceView, or `KdPrint` to start | the WDK sample is WPP-based (`DoTrace`) |
| Static analysis | Code Analysis + Static Driver Verifier; Driver Verifier at runtime | catch IRQL/pool/cancel-race bugs before they bugcheck |
| Reference sources | `Windows-driver-samples/bluetooth/serialhcibus` | ~6.6k lines; `pdo.c`, `io.c`, `Fdo.c` are directly reusable, `WDK/device.c` (UART specifics) is not |

Sample is already fetched to the scratchpad via sparse checkout:
`git clone --filter=blob:none --sparse …/Windows-driver-samples && git sparse-checkout set bluetooth/serialhcibus`
(note: its sources are UTF-16LE).

### 6.1 Architecture note

This development host is **ARM64** (Snapdragon, Windows 11 Home 26200), which is why
`bth.inf`'s models section here is `NTarm64`. WDK 10.0.26100.1+ supports ARM64 natively as
both host and target. The driver must be built for whatever architecture the **test VM** runs,
and the VM is ARM64 so that it can use hardware acceleration. Cross-compiling an x64 driver
from this box is supported, but there would be nowhere convenient to run it.

---

## 7. Development environment

A throwaway VM is mandatory: this driver will bugcheck the machine repeatedly during
bring-up, and a root-enumerated Bluetooth transport that misbehaves can take the real radio
stack with it.

Requirements for whatever VM we use:

- Snapshots (revert after every bugcheck).
- Secure Boot off, HVCI off, `testsigning on`.
- A kernel debugger transport: a guest COM port mapped to a host named pipe, which WinDbg
  attaches to. On ARM64 this additionally requires the firmware to publish an ACPI DBG2 table.
- No physical Bluetooth radio passthrough needed — that is the point of the exercise.

Windows 11 **Home** on the host means Hyper-V Manager is not available, so this is VirtualBox
or QEMU/WHPX rather than a limitation to work around. **VirtualBox turned out to be unusable
on a Windows-on-ARM host** — it bugchecks a stock Windows guest, and its ARM firmware publishes
no DBG2 table, so kernel debugging is impossible there. The project runs on QEMU + WHPX; see
[development.md](development.md).

---

## 8. Open questions, and how they turned out

1. **Does BthPort accept `ScoSupportNone`, or must we claim `ScoSupportHCIBypass`?** —
   *Answered: `ScoSupportHCIBypass` is required.* `ScoSupportNone` completes the transport
   handshake and then refuses to start the radio with `CM_PROB_FAILED_START`. The driver claims
   HCI bypass and never delivers sideband audio.

2. **What does BthPort's init sequence demand of the controller?** — *Answered, and it was the
   hardest part of the project.* 29 distinct opcodes, a dual-mode LMP feature mask, and two
   silent rejection modes that produce no error at all. See
   [controller-requirements.md](controller-requirements.md).

3. **Does `BthMini` care that the transport has no `PrepareHardware` resources?** — *Answered:
   no.* A root-enumerated PDO with no hardware resources whatsoever is bound and driven
   normally.

4. **Does the radio survive suspend/resume and Airplane-mode toggles?** — *Still open.* The
   driver opts out of power management entirely (`IsDeviceIdleCapable` and `IsDeviceWakeCapable`
   are both `FALSE`) and the sample's
   `GUID_DEVINTERFACE_BLUETOOTH_RADIO_ONOFF_VENDOR_SPECIFIC` handling has not been added. This
   is M4 work.
