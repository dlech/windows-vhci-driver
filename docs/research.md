# Windows VHCI — architecture research

Goal: the Windows equivalent of Linux `drivers/bluetooth/hci_vhci.c` — a virtual Bluetooth
controller that appears to the OS as a real local radio, while a userspace process supplies
the HCI behaviour.

Status: research complete, no code written yet. Findings below were verified against the
live Windows 11 install on this machine (build 26200, ARM64) and against current Microsoft
docs and the WDK sample sources.

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
    HciPacketCommand, HciPacketAclData, HciPacketEvent
} BTHX_HCI_PACKET_TYPE;

typedef struct _BTHX_CAPABILITIES {
    ULONG            MaxAclTransferInSize;
    BTHX_SCO_SUPPORT ScoSupport;       // ScoSupportNone | ScoSupportHCI | ScoSupportHCIBypass
    ULONG            MaxScoChannels;
    BOOLEAN          IsDeviceIdleCapable;
    BOOLEAN          IsDeviceWakeCapable;
} BTHX_CAPABILITIES;
```

Note the shape of `READ_HCI`: the stack **posts** read IOCTLs down to us and we hold them
pending until a packet is available. That is Windows' inverted call model, and it maps
one-to-one onto the userspace side — a pended read from the stack is completed directly from
a packet handed to us by the userspace controller.

### 3.1 Known gaps vs. Linux vhci

- **No SCO or ISO packet type.** `BTHX_HCI_PACKET_TYPE` only has Command/ACL/Event. Real
  transports carry SCO out-of-band (`ScoSupportHCIBypass`, e.g. an I2S channel), and there
  is no ISO type at all, so LE Audio isochronous data has no path here. Docs say a transport
  "must specify `ScoSupportHCIBypass`", but `ScoSupportNone` exists in the enum and is the
  honest value for a virtual controller with no audio sideband. **Which of the two BthPort
  actually tolerates is the first thing to test.**
- **The controller must be convincing.** Linux's `hci_dev` is happy with a minimal command
  set. BthPort runs its own init sequence and will reject a radio that fails it. The
  userspace controller must implement enough of HCI (Reset, Read Local Version/Features/
  Supported Commands/BD_ADDR, Set Event Mask, buffer sizes, LE command set …) to get through.
  Bumble's controller emulation is the obvious thing to point at this. Expect an
  iterate-against-real-traces phase here.

---

## 4. Proposed architecture

```
 userspace controller (Python/Bumble, or anything)
        │  H4-framed HCI, same byte format as /dev/vhci
        │  \\.\WinVhci  — DeviceIoControl, inverted call
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

1. **Control device** (`\\.\WinVhci`, a device interface GUID) — what userspace opens. It
   carries the vhci-equivalent operations: create/destroy the radio, submit
   controller→host packets, and a pended "give me the next host→controller packet" IOCTL.
2. **Child PDO** — advertises `MS_BTHX_BTHMINI`, services the BTHX IOCTLs by forwarding to
   and from the control device's queues.

Creating the radio is explicit, like Linux's `FF <opcode>` vendor packet: userspace issues a
create IOCTL, the driver calls `WdfChildListAddOrUpdateChildDescriptionAsPresent`, and
Windows loads BthMini onto the new PDO. Closing the handle tears the PDO down, so the radio
disappears from Device Manager — the same lifetime model as closing `/dev/vhci`.

### 4.1 Userspace transport: why IOCTLs, not a named pipe

A kernel driver **cannot be a named pipe server** — `ZwCreateNamedPipeFile` is not exported
to kernel mode. A driver can only be a pipe *client*, connecting out to a pipe that
userspace created. That inverts the lifetime (userspace must exist first, reconnect logic,
awkward security) for no benefit.

So: **IOCTLs on a control device are the driver's interface**, and a small user-mode bridge
process re-exposes that as a named pipe or TCP socket for tools that want a stream. That
bridge is where the `/dev/vhci` H4 byte format lives, which makes existing vhci clients —
Bumble's `vhci` transport in particular — a thin port rather than a rewrite.

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

| Need | Choice | Notes |
| --- | --- | --- |
| Compiler/IDE | Visual Studio 2022 (≥17.0) | VS 2026 ("18") is also installed here; if the WDK VSIX lags, WDK 26100.6584 is the VS2022-compatible build |
| Driver framework | **KMDF** (WDF) | UMDF cannot do this — BthMini is kernel-mode and queries us with kernel IOCTLs |
| SDK/WDK | Windows Driver Kit 10.0.26100.x | **not currently installed** — only the SDK is present (`Include\10.0.26100.0` has no `km\`, no `bthxddi.h`). Install via VS Installer → Individual Components → Windows Driver Kit, or the NuGet WDK packages (10.0.26100.1+) |
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
both host and target. The driver must be built for whatever architecture the **test VM**
runs — and since VirtualBox does not emulate a foreign CPU, an ARM64 host means an ARM64
guest. Cross-compiling an x64 driver from this box is supported, but there would be nowhere
convenient to run it.

---

## 7. Development environment

A throwaway VM is mandatory: this driver will bugcheck the machine repeatedly during
bring-up, and a root-enumerated Bluetooth transport that misbehaves can take the real radio
stack with it.

Requirements for whatever VM we use:

- Snapshots (revert after every bugcheck).
- Secure Boot off, HVCI off, `testsigning on`.
- A kernel debugger transport. VirtualBox can map a guest COM port to a host named pipe,
  which WinDbg attaches to; that is the well-trodden path. KDNET is faster where the virtual
  NIC is supported.
- No physical Bluetooth radio passthrough needed — that is the point of the exercise.

Windows 11 **Home** on the host means Hyper-V Manager is not available, so VirtualBox (or
QEMU/WHPX) is the practical choice rather than a limitation to work around.

---

## 8. Open questions to resolve during bring-up

1. Does BthPort accept `ScoSupportNone`, or must we claim `ScoSupportHCIBypass` and then
   never deliver sideband audio?
2. What exactly does BthPort's init sequence demand of the controller before it will bring
   the radio up? (Capture from a real adapter, replay, diff.)
3. Does `BthMini` care that the transport has no `PrepareHardware` resources at all?
4. Does the radio survive suspend/resume and Airplane-mode toggles, or do we need the
   `GUID_DEVINTERFACE_BLUETOOTH_RADIO_ONOFF_VENDOR_SPECIFIC` handling the sample carries?
