# Windows VHCI — implementation plan

Companion to [research.md](research.md), which establishes *why* this shape. This document is
*what to build*, in order. Nothing here is built yet.

Target: ARM64 Windows 11 guest in VirtualBox on this ARM64 host. Build target is ARM64
throughout.

---

## 1. Scope

**In scope.** A virtual Bluetooth controller that Windows treats as a real local radio, driven
entirely by a userspace process, byte-compatible with Linux's `/dev/vhci` framing so existing
vhci clients port cheaply.

**Out of scope, permanently.** SCO (voice) and LE Audio isochronous streams. The BTHX
interface has no packet type for either — see research §3.1. If these are ever needed the
answer is a different transport (UdeCx-emulated USB dongle), not an extension of this one.

**Out of scope, for now.** Multiple simultaneous virtual radios; coexistence with a real
radio on the same machine; production code-signing.

## 2. Deliverables

| Component | What it is |
| --- | --- |
| `winvhci.sys` | KMDF root-enumerated bus driver. The whole kernel-mode story. |
| `winvhci.inf` | Root-enumerated install. Ships only our driver — the Bluetooth side is in-box. |
| `vhcictl` | Small test client. Opens the device, dumps host→controller traffic, replays canned responses. |
| `bridge` (optional) | User-mode process re-exposing the device as a named pipe or TCP socket for tools that want a stream. |

## 3. Design

### 3.1 Device topology

One driver, two device objects:

```
 ROOT\WINVHCI  ──  winvhci.sys FDO ──── device interface ──→ userspace (\\.\WinVhci)
                        │
                        └── child PDO   HWID  winvhci\radio
                                        CID   MS_BTHX_BTHMINI
                                          ↑
                                   BthMini.sys → BthPort.sys → Windows Bluetooth
```

The FDO *is* the control device — a device interface created with
`WdfDeviceCreateDeviceInterface` on the FDO itself. No separate `WDFCONTROLDEVICE`; the
serialhcibus sample doesn't need one either and it only adds lifetime complexity.

The child PDO is created on demand, when userspace asks for a radio, via
`WdfChildListAddOrUpdateChildDescriptionAsPresent`. PnP then loads BthMini onto it. Removing
it from the child list makes the radio vanish from Device Manager. That is the exact lifetime
model of opening and closing `/dev/vhci`.

### 3.2 How much of the sample survives

The serialhcibus sample is ~6.6k lines, and most of it is UART-specific:

- **Gone: `WDK/device.c`** — UART init, baud rates, vendor power sequences.
- **Gone: `FdoFindConnectResources`** — walks `CmResourceTypeConnection` descriptors to find
  a serial controller. We are root-enumerated and have *no* hardware resources at all.
- **Gone: the H4 stream reassembler in `io.c`** (roughly lines 490–800). It exists to
  reconstruct packet boundaries from a UART byte stream. Userspace hands us whole,
  pre-framed packets.
- **Gone: the `RequestCompletePath` interlocked cancel/complete dance.** That protects
  requests forwarded *down* to a serial `IoTarget`. We have no lower target; WDF's manual
  queues handle cancellation for us.
- **Kept, closely: `pdo.c`** — PDO construction, ID assignment, `GUID_DEVICE_RESET_INTERFACE_STANDARD`,
  and the "forward BTHX IOCTLs to the parent FDO queue" pattern.
- **Kept, in spirit: the two-queue read model** — see below.

Net expectation: 1.5–2k lines of driver.

### 3.3 Queues — the part that must be right

Verified from the sample: the stack posts **two independent read channels**, distinguished by
the `Type` field in the `BTHX_HCI_READ_WRITE_CONTEXT` of each `IOCTL_BTHX_READ_HCI`. A single
merged read queue will misroute and stall.

```
Fdo.c:24   BTHX_VALID_WRITE_PACKET_TYPE  = Command | AclData     (host → controller)
Fdo.c:25   BTHX_VALID_READ_PACKET_TYPE   = Event   | AclData     (controller → host)
```

FDO context therefore holds:

| State | Purpose |
| --- | --- |
| `BthxReadEventQueue` (manual) | pended `READ_HCI` with `Type == HciPacketEvent` |
| `BthxReadDataQueue` (manual) | pended `READ_HCI` with `Type == HciPacketAclData` |
| `PendingEventList`, `PendingDataList` | controller→host backlog when no read is pended |
| `UserReadQueue` (manual) | pended userspace read |
| `HostToCtrlList` | host→controller backlog when userspace isn't reading |
| `QueueLock` (WDFSPINLOCK) | guards all six |

**Measured in M1 — where the read type actually lives.** The two-queue model is right, but the
selector is not where this section originally assumed. `IOCTL_BTHX_READ_HCI` splits one
contiguous `BTHX_HCI_READ_WRITE_CONTEXT` across the two METHOD_NEITHER pointers:

```
Type3InputBuffer   ->  ULONG requestedType          InputBufferLength  == 4
Type3InputBuffer+4 == Irp->UserBuffer
                   ->  BTHX_HCI_READ_WRITE_CONTEXT  OutputBufferLength == 5 + capacity
                         ULONG DataLen
                         UCHAR Type
                         UCHAR Data[capacity]
```

Two things are easy to get wrong here, and both were got wrong before being measured:

1. **The input buffer is not the context.** It is a bare ULONG holding the *requested packet
   type* (`4` = event, `2` = ACL) — not a length, despite sitting where a `DataLen` would. It
   is allocated immediately before the context, so `UserBuffer == Type3InputBuffer + 4`.

2. **`Irp->UserBuffer` is the whole context**, starting at `DataLen`. An intermediate version
   assumed it pointed at the `Type` field four bytes in. That reading is self-consistent enough
   to look right, and it survives contact with the routing logic, but it puts the type byte
   into `DataLen`'s low byte on the way out — so the stack silently rejects the event and
   retries the command forever.

The capacities are what settle it. Subtracting the 5-byte context header gives exactly **257**
for event reads (2-byte HCI event header + 255 maximum payload) and exactly **1021** for ACL
reads (`MaxAclTransferInSize`, the value we returned from `QUERY_CAPABILITIES`). The rejected
reading gives 261 and 1025, which correspond to nothing. When a layout guess produces
meaningful constants, it is probably right; when it produces arbitrary ones, it is probably
wrong.

Observed during bring-up:

| requested | capacity | channel |
| --- | --- | --- |
| `4` (`HciPacketEvent`) | 257 | event |
| `2` (`HciPacketAclData`) | 1021 | ACL |
| `2` (`HciPacketAclData`) | 1021 | ACL |

The stack posts one event read and two ACL reads, and replenishes a read as soon as one is
completed. Route on the requested type; the capacity is a useful cross-check, and a
disagreement means the assumption has broken.

To complete a read: fill `Type`, `DataLen` and `Data` in the context, and complete the request
with `Information = 5 + payload length`. `Data` carries the HCI packet *without* its H4 type
byte, since the type travels in `Type`.

This mattered concretely: an earlier build rejected the untyped-looking reads with
`STATUS_NOT_SUPPORTED`, which left nothing pended to receive `HCI_Reset`'s Command Complete and
stalled the radio at `CM_PROB_FAILED_POST_START`. Parking them correctly is what moved the
radio to `Status: OK` / `CM_PROB_NONE`.

**The rendezvous works.** With the layout right, completing one pended event read with a
Command Complete for `HCI_Reset` makes the stack accept the reply and move on to the next
command:

```
WRITE_HCI  opcode 0x0c03 (OGF 0x03 OCF 0x003)   HCI_Reset
  -> Command Complete, 6 bytes
WRITE_HCI  opcode 0x1009 (OGF 0x04 OCF 0x009)   Read_BD_ADDR
```

It then loops Reset -> Read_BD_ADDR every four seconds, because `Read_BD_ADDR` must return a
6-byte address and the in-driver stopgap answers every command with an empty Command Complete.
Answering it properly is M3's job, driven from userspace via M2 - not more canned replies in
the driver.

Both directions follow the sample's rendezvous rule, which is worth stating explicitly
because it is the invariant the whole driver rests on:

```
(request queue, packet list)
  (empty,  *)      → append packet to list
  (!empty, empty)  → dequeue request, complete it with the packet
  (!empty, !empty) → impossible; assert
```

Backlog lists are bounded. On overflow, drop and count — a virtual controller that blocks the
host stack is worse than one that loses a packet, and the counter tells us it happened.

### 3.4 Userspace interface — `ReadFile`/`WriteFile`, not IOCTLs

**Recommended:** make `\\.\WinVhci` behave byte-for-byte like `/dev/vhci`. Data path is
`IRP_MJ_READ` / `IRP_MJ_WRITE` (buffered I/O), and the control channel is in-band using the
H4 vendor packet type, exactly as Linux does it.

```
  WriteFile   (controller → host)   04 <event>  |  02 <acl>  |  FF <opcode>
  ReadFile    (host → controller)   01 <cmd>    |  02 <acl>  |  FF FF <opcode> <id_lo> <id_hi>
```

`FF <opcode>` creates the radio and the driver answers with `FF FF <opcode> <id_lo> <id_hi>`.
Opcode bits carry no meaning for us yet (Linux's external-config and raw-device quirks have no
Windows analogue), but reserving the byte keeps the wire format identical.

Why this over a custom IOCTL surface: a client is then `open` + `read` + `write`, so Bumble's
`vhci` transport and every other vhci tool is a path change rather than a rewrite, and the
optional bridge process becomes a ~50-line pipe pump.

Mechanics:

- `WdfDeviceInitSetIoType(WdfDeviceIoBuffered)`; max transfer 1025 bytes
  (`HCI_ACL_HEADER_SIZE 4 + HCI_MAX_ACL_PAYLOAD_SIZE 1021`), max event 257, max command 258.
- `WdfDeviceInitSetExclusive(TRUE)` — one controller at a time, mirroring vhci's `open_mutex`.
- `EvtDeviceFileCreate` / `EvtFileClose` own the radio lifetime: close tears down the PDO,
  purges both directions, and completes outstanding BTHX reads with `STATUS_DEVICE_REMOVED`.
- Clients open with `FILE_FLAG_OVERLAPPED` so read and write can be concurrent.

A small IOCTL side channel (`IOCTL_WINVHCI_GET_STATS`) stays useful for counters and drop
diagnostics. It is not on the data path.

### 3.5 Packet types — no translation needed

Confirmed by reading the installed `bthxddi.h` (WDK 10.0.28000.2526), the enum values
**are** the H4 packet-type bytes:

```c
typedef enum _BTHX_HCI_PACKET_TYPE {
    HciPacketCommand    = 0x01,
    HciPacketAclData    = 0x02,
    HciPacketEvent      = 0x04
} BTHX_HCI_PACKET_TYPE;
```

So the `Type` byte passes between userspace and the stack unchanged — no lookup table.
(The published DDI reference lists the enumerators without values, which makes them look
like a plain 0/1/2 sequence. They are not.)

The driver still validates: `0x03` SCO and `0x05` ISO are rejected with
`STATUS_NOT_SUPPORTED`, `0xFF` vendor is consumed as control and never forwarded, and
direction is enforced — Command only host→controller, Event only controller→host.

### 3.6 The IOCTLs are METHOD_NEITHER

Also from the header, and easy to get wrong:

```c
#define BTHX_CTL(id)  CTL_CODE(FILE_DEVICE_BLUETOOTH, (id), METHOD_NEITHER, FILE_ANY_ACCESS)
```

`METHOD_NEITHER` means no buffer mapping or probing is done for us: the input buffer arrives
as `Parameters.DeviceIoControl.Type3InputBuffer` and the output as `Irp->UserBuffer`. These
requests originate in kernel mode from `BthMini.sys`, so the pointers are kernel addresses
and are valid in any context — but the driver must still retrieve them the METHOD_NEITHER
way rather than assuming WDF's usual buffered-request accessors apply. The serialhcibus
sample is the reference for exactly how.

The header also supplies the version constant and a ready-made global to answer
`IOCTL_BTHX_GET_VERSION` with:

```c
#define BTHX_DDI_VERSION_1  0x00000001
__declspec(selectany) BTHX_VERSION Microsoft_BTHX_DDI_Version = { BTHX_DDI_VERSION_1 };
```

### 3.6 Capabilities

Answer `IOCTL_BTHX_QUERY_CAPABILITIES` with:

```c
MaxAclTransferInSize = 1021;
ScoSupport           = ScoSupportHCIBypass;   // ScoSupportNone is rejected - see below
MaxScoChannels       = 1;
IsDeviceIdleCapable  = FALSE;
IsDeviceWakeCapable  = FALSE;
```

**Settled by experiment (M1).** `ScoSupportNone` is *rejected*. Reporting it makes BthMini
complete the `GET_VERSION` / `SET_VERSION` / `QUERY_CAPABILITIES` handshake and then refuse to
start the radio with `CM_PROB_FAILED_START` and `STATUS_DEVICE_CONFIGURATION_ERROR`, retrying
the handshake about six times before giving up. Reporting `ScoSupportHCIBypass` with
`MaxScoChannels = 1` makes the radio start, after which the stack immediately begins driving
the transport with `IOCTL_BTHX_WRITE_HCI`.

So the documentation's "must specify `ScoSupportHCIBypass`" is real and enforced. The driver
claims it and never delivers sideband audio.

Both values remain registry knobs under `HKLM\SOFTWARE\winvhci` (`WvScoSupport`,
`WvMaxScoChannels`), which is what made this cheap to establish - a registry edit and a device
restart rather than a rebuild-sign-package-install cycle.

Idle/wake are `FALSE` initially - deliberately opting out of power management until the data
path works.

---

## 4. Milestones

### M0 — Toolchain and a test VM

Toolchain (**done**): VS 2026 Community 18.9 + WDK/SDK **10.0.28000.2526** installed via
winget, with the WDK VSIX and ARM64/x64 Spectre libs from Microsoft's own
`wdk-desktop.vsconfig`. `bthxddi.h` is present under `Windows Kits\10\Include\10.0.28000.0\km`
and has been read — see §3.5 and §3.6, which it corrected.

Three build gotchas, all now handled in `winvhci.vcxproj`:

- **Build with the ARM64 MSBuild**, `MSBuild\Current\Bin\arm64\MSBuild.exe`. The default
  `Bin\MSBuild.exe` is x86, and the WDK ships `infverif.dll` only for arm64 and x64 — an
  x86 MSBuild fails with "Unable to load DLL 'x86\InfVerif.dll'".
- **Don't redirect `OutDir` out of the project tree.** It breaks the step that stages files
  into the driver package folder.
- **Add the driver binary to `FilesToPackage` explicitly.** The WDK's `GetPackageFiles`
  target only auto-adds INF files; the `.sys` normally arrives from a separate "Package"
  project via `ProjectReference`. Without it inf2cat fails with "winvhci.sys ... is missing".

#### The VM: QEMU, after VirtualBox proved unusable

**VirtualBox cannot host Windows guests on a Windows-on-ARM host.** It bugchecks
`INTERNAL_POWER_ERROR` during install or on boot — a known defect spanning 7.2.0 to 7.2.6,
reproducible on a freshly created VM with no customisation. Its ARM firmware also publishes
no ACPI **DBG2** table, so Windows on ARM (which locates its debug UART exclusively through
DBG2) can never be kernel-debugged there. Both are missing platform support, not
misconfiguration. Abandoned.

**QEMU 11.1.0 works**, with `whpx` acceleration (verified: `-accel whpx` makes QEMU exit on
failure, and it starts clean). Launch with `build\qemu-run.ps1`. The hard-won device
choices, each of which cost real time:

| Need | Use | Why not the obvious choice |
| --- | --- | --- |
| Disk | `nvme` | ArmVirtQemu has **no AHCI driver**, so an `ich9-ahci` disk is invisible to firmware and it falls through to PXE. Windows has inbox `stornvme`. |
| Boot media | `scsi-cd` on `virtio-scsi-pci` | Over `usb-storage` the firmware sees a removable HARDDRIVE, hunts for `\EFI\BOOT\BOOTAA64.EFI`, finds ISO9660, and hangs. |
| Media for a *running* Windows | `usb-storage` | The opposite: Windows has inbox USB mass storage but no virtio-scsi driver. |
| Display | `ramfb` | `bochs-display` and `VGA` are never programmed by ArmVirtQemu (firmware console lost); `virtio-gpu-pci` renders under firmware then goes dark — no inbox driver. `-vga virtio` is rejected by the machine type. |
| Network | `virtio-net-pci` + **NetKVM** from virtio-win | Windows on ARM has no inbox driver for *any* NIC QEMU offers — `e1000e`, virtio-net and USB RNDIS all land in Device Manager as unknown devices. virtio-win ships ARM64 INFs; its guest-tools MSIs are x64/x86 only, so install with `pnputil`. |
| File channel | read-only **ISO** (`build\make-share-iso.ps1`) | `vvfat` read-write **crashes QEMU outright** when the guest writes to it (`cluster 0 used more than once`, assertion in `commit_direntries`), and `usb-storage` refuses read-only `vvfat`. |

Two more traps worth remembering:

- `-serial pipe:` on Windows **blocks the guest until a client connects** — the VM sits at
  ~0% CPU looking like a dead install. `qemu-run.ps1 -NoKd` avoids it.
- `hostfwd` binds the host port immediately, so a plain port check is a false positive for
  "guest is up". Probe with a real RDP X.224 handshake instead.

QEMU is driven from the host over QMP (`build\qemu-screenshot.ps1` for screenshots when the
guest cannot be queried from inside) and snapshots via `build\qemu-snapshot.ps1`
(`clean`, `netkvm`). Snapshots are offline — a live `savevm` fails because the removable
media do not support snapshots.

**UAC stays enabled in the guest**, so install and teardown scripts must be self-contained
and idempotent, runnable elevated in one step.

Diagnosis is **kernel crash dumps** (`MEMORY.DMP`, auto-reboot off) plus **DebugView**
with Capture Kernel, plus WPP/ETW later. DebugView needs the `Debug Print Filter` registry
values, or Windows discards `DbgPrint` output whenever no debugger is attached. Whether a
*live* debugger is available under QEMU is still open — its `virt` machine should publish a
DBG2 entry for its PL011, unlike VirtualBox; `build\guest-dbg2.ps1` settles it.

**Exit:** build on host → install in guest → `winvhci` shows Status OK in Device Manager and
its `KdPrint` lines appear in DebugView → snapshot.

### M1 — Prove the seam

Minimum driver that makes Windows believe there is a radio.

- Root-enumerated FDO; child PDO created unconditionally at start, HWID `winvhci\radio`,
  CID `MS_BTHX_BTHMINI`.
- PDO forwards BTHX IOCTLs to the FDO queue.
- Answer `GET_VERSION`, `SET_VERSION`, `QUERY_CAPABILITIES`.
- `WRITE_HCI`: log the opcode, complete success.
- `READ_HCI`: pend forever in the correct queue by `Type`.

**Exit:** Device Manager shows a **Bluetooth Radio** node with `BthMini` + `BthPort` loaded
on it, and WinDbg shows `WRITE_HCI` arriving carrying HCI_Reset (`0x0C03`). This is the
go/no-go for the entire approach, and it settles research open questions 1 and 3.

#### ✅ Achieved

The seam works. Windows binds the in-box stack to a software-only PDO with no hardware
anywhere:

```
Device winvhci\radio\1&79f5d87&4&1 was configured.
  Driver Name:        bth.inf
  Class GUID:         {e0cbf06c-cd8b-4647-bb8a-263b43f0f974}   (Bluetooth)
  Driver Section:     BthMini.NT
  Matching Device ID: MS_BTHX_BTHMINI
  Parent Device:      ROOT\SYSTEM\0001
```

and once the radio starts, the stack immediately drives the transport:

```
winvhci: WRITE_HCI type 0x01 len 3 (#1)
winvhci:   command opcode 0x0c03 (OGF 0x03 OCF 0x003) plen 0   <-- HCI_Reset
```

`MS_BTHX_BTHMINI` is confirmed as the binding point, the BTHX IOCTLs do arrive as
`IRP_MJ_INTERNAL_DEVICE_CONTROL`, and `WdfRequestForwardToParentDeviceIoQueue` carries them
from the radio stack to the FDO correctly.

The radio then sits at `CM_PROB_FAILED_POST_START`, which is the *correct* M1 outcome: the
driver swallows the command and never returns an event, so the stack times out waiting for
`HCI_Reset`'s Command Complete. Answering it is M2/M3.

Note that no `READ_HCI` was ever posted. The stack issues `WRITE_HCI` first and only pends
reads once the transport looks alive, so the two-queue read model in 3.3 stays untested until
M2 - do not assume it is right merely because M1 passed.

#### Diagnosis on this guest

`KdPrint` output is only visible through the **DebugView GUI** (`Dbgview64a.exe`, elevated,
Capture > Capture Kernel), which works reliably.

`dbgviewcli64a.exe` works fine over SSH as a detached process. Everything that looked like a
tool limitation was **capture contention**: only one process may hold the kernel capture at a
time, and a DebugView GUI instance (or a leaked earlier CLI instance) silently starves every
later capture, which then produces an empty log rather than an error.

`--status` is the thing to check first - it prints `running=`, `paused=`, `elevated=`, and a
`running=true` you did not start is the explanation for an empty log.

The working recipe, from the documented automation flags:

```powershell
C:\tools\dbgviewcli64a.exe --stop            # release any existing capture
Start-Process C:\tools\dbgviewcli64a.exe -ArgumentList `
    "--accepteula","--kernel","--duration","22","--log","C:\kd.log" -WindowStyle Hidden
```

Two details that matter:

- **Bound the run with `--duration`** and let it exit by itself. Killing it with `Stop-Process`
  loses the buffered log.
- **Do not pass `--no-win32`.** Kernel lines did not appear when Win32 capture was disabled,
  which is not documented behaviour but is reproducible here.

v5.02's CLI is explicitly designed for this kind of scripted use (`--duration`, `--max-lines`,
`--wait-for`, `--no-banner`, `--format csv`, `--status`); read
<https://learn.microsoft.com/sysinternals/downloads/debugview> before improvising.

Registry breadcrumbs under `HKLM\SOFTWARE\winvhci` remain useful for state that must survive a
crash or be read long after the fact, but they are no longer the only unattended channel.

Worth revisiting: QEMU's `virt` machine *does* publish an ACPI DBG2 table, so a live kernel
debugger over `-serial pipe:` should be possible here (it was not on VirtualBox). That would
supersede both mechanisms.

### M2 — The data path

- Device interface + `ReadFile`/`WriteFile` per §3.4, exclusive open, file-object lifetime.
- Both rendezvous paths and all six pieces of queue state.
- PDO creation moves behind the `FF <opcode>` control packet.
- `vhcictl`: opens the device, prints every host→controller packet with a decoded opcode.

**Exit:** `vhcictl` prints Windows' full init sequence as the stack tries to bring the radio
up. That transcript is the spec for M3.

#### ✅ Achieved

The seam is complete in both directions. A userspace client opens `\\.\WinVhci`, creates a
radio with the control packet, receives the Windows stack's HCI commands as H4 frames, and
injects events back:

```
CTRL ff 00 03 00                                     radio 3 created
CMD  0x0c03  OGF 0x03 OCF 0x003  HCI_Reset                       -> accepted
CMD  0x1009  OGF 0x04 OCF 0x009  Read_BD_ADDR                    -> accepted
CMD  0x1002  OGF 0x04 OCF 0x002  Read_Local_Supported_Commands   -> Unknown Command
CMD  0x1005  OGF 0x04 OCF 0x005  Read_Buffer_Size                -> Unknown Command
   ... the stack restarts the sequence
```

**This is the M3 specification.** The stack needs, in order: `HCI_Reset`, `Read_BD_ADDR`,
`Read_Local_Supported_Commands` (64-byte bitmask) and `Read_Buffer_Size` (ACL packet length,
SCO packet length, ACL packet count, SCO packet count). It re-runs the whole sequence when a
command is refused, so the loop stops as soon as all four are answered plausibly.

Confirming the lifetime change: with no client attached, the radio does not exist at all —
Device Manager shows only the `Virtual Bluetooth HCI Controller` FDO, and the Bluetooth Radio
node appears on the control packet and disappears when the handle closes.

#### Two traps worth remembering

- **A synchronous `ReadFile` on the client side is a mistake.** It blocks indefinitely once the
  stack goes quiet, so a bounded run never terminates and has to be killed - which also loses
  its buffered output. `vhcictl` uses overlapped reads with a wait timeout.

- **PowerShell's `-shl` shifts in the left operand's type.** `[byte]0x0c -shl 8` is `0`, not
  `0x0c00`, so `03 0c 00` decoded as opcode `0x0003` instead of `0x0c03`. The client then
  answered a Command Complete for an opcode the stack had never sent, the stack ignored it, and
  the symptom looked exactly like the driver failing to deliver events. Cast to `[int]` before
  shifting.

### M3 — A convincing controller

The driver is a pipe; this milestone is about what's on the other end.

- Point Bumble's controller emulation at the device through the bridge.
- Work through the init sequence until BthPort brings the radio up. Expect to need at least:
  Reset; Read Local Version / Supported Commands / Local Features / BD_ADDR / Buffer Size;
  Set Event Mask; and the LE command set.
- Capture a reference trace from a real adapter (Windows Bluetooth ETW → `btetlparse`) and
  diff against ours whenever the stack gives up without saying why.

**Exit:** Settings shows a working Bluetooth toggle; `BluetoothAdapter.GetDefaultAsync()`
returns our radio; a `BluetoothLEAdvertisementWatcher` sees advertisements injected from
userspace.

#### 🟡 Initialisation complete; API-level exit criteria still to verify

The stack initialises fully and reaches steady state. In a 20-second run there are **39
commands and zero unanswered**, covering 29 distinct opcodes:

```
reset/identity   HCI_Reset, Read_BD_ADDR, Read_Local_Version_Information,
                 Read_Local_Supported_Commands, Read_Local_Supported_Features,
                 Read_Buffer_Size
BR/EDR config    Set_Event_Mask, Write_Authentication_Enable, Write_Page_Timeout,
                 Write_Page_Scan_Activity, Write_Inquiry_Scan_Activity,
                 Write_Inquiry_Mode, Write_Class_of_Device, Write_Local_Name,
                 Write_Extended_Inquiry_Response, Host_Buffer_Size,
                 Write_Scan_Enable, Read_Inquiry_Response_Transmit_Power_Level
LE config        Write_LE_Host_Support, LE_Set_Event_Mask,
                 LE_Read_Local_Supported_Features, LE_Read_Buffer_Size,
                 LE_Read_White_List_Size, LE_Read_Supported_States,
                 LE_Read_Advertising_Channel_Tx_Power
LE advertising   LE_Set_Random_Address, LE_Set_Advertising_Parameters,
                 LE_Set_Advertising_Data, LE_Set_Advertise_Enable
```

Windows then builds its whole stack on top of the virtual radio:

```
Bluetooth Radio                        OK   WINVHCI\RADIO\...
Microsoft Bluetooth Enumerator         OK   BTH\MS_BTHBRB\...
Bluetooth Device (RFCOMM Protocol TDI) OK   BTH\MS_RFCOMM\...
bthserv                                Running
```

The enumerator and RFCOMM nodes only appear once BthPort has a radio it considers working, so
their presence is the real signal - not the radio node alone.

Most configuration commands return status only, so they are answered by shape from a table
rather than one at a time; only the parameter-returning commands need individual handling. Two
values must agree with what the driver told BthPort in `QUERY_CAPABILITIES`: the ACL packet
length in `Read_Buffer_Size` (1021) and, by extension, anything derived from it.

**Still to do for the stated exit criteria:** confirm the Settings toggle, that
`BluetoothAdapter.GetDefaultAsync()` returns this radio, and that a
`BluetoothLEAdvertisementWatcher` sees advertisements injected from userspace. Reaching
"initialisation completes" is necessary but not sufficient - none of those three has been
tested yet. Note also that `vhcictl` answers plausible constants rather than modelling a
controller; a real simulator on the other end is what M3 ultimately calls for.

### M4 — Make it survivable

- Driver Verifier (standard + force IRQL checking + low resources) across a full M3 run.
- Code Analysis and Static Driver Verifier clean.
- Cancellation and teardown races: kill the userspace process mid-transfer, disable the
  device mid-transfer, sleep/resume, Airplane mode. The sample carries
  `GUID_DEVINTERFACE_BLUETOOTH_RADIO_ONOFF_VENDOR_SPECIFIC` handling for the last of these —
  add only if the toggle actually misbehaves.
- Tighten the device interface DACL to Administrators + SYSTEM.

**Exit:** an M3 session survives Verifier and the abuse list without a bugcheck.

### M5 — Ergonomics (optional)

Bridge process exposing a named pipe or TCP socket; a `pip`-installable client; upstreaming
the transport to Bumble.

---

## 5. Repository layout

```
winvhci/            driver.c fdo.c pdo.c bthx.c queue.c
                    winvhci.h public.h winvhci.inx winvhci.vcxproj
tools/vhcictl/      test client
bridge/             optional pipe/TCP bridge
docs/               research.md, implementation-plan.md
```

`public.h` is shared verbatim between driver and userspace: device interface GUID, H4
constants, size limits, stats struct.

## 6. Risks

| Risk | Signal | Response |
| --- | --- | --- |
| BthMini rejects a transport with no hardware resources | M1 fails; PDO gets an error code | Give the PDO a dummy resource requirements list; failing that, fall back to the UdeCx USB path |
| `ScoSupportNone` rejected | radio never starts, capabilities query is the last thing we see | Registry knob to claim `ScoSupportHCIBypass` |
| Init sequence never completes | stack stops sending commands, radio stays off | Diff against a real-adapter ETW trace |
| ~~ARM64 VirtualBox guest unstable under KD~~ — **settled: VirtualBox unusable, moved to QEMU** | `INTERNAL_POWER_ERROR` on a stock VM; no ACPI DBG2 table | Migrated to QEMU + whpx. Live debugging still unconfirmed there; crash dumps + DebugView cover it meanwhile |
| Windows Update reboots the guest mid-test, or changes the OS build between runs | a run ends in an unexplained reboot, or results stop reproducing | Disable automatic updates in the guest and re-snapshot; pin the build for the life of the project |
| Test signing blocked in guest | driver won't load | Secure Boot and HVCI both off; keep an attached debugger, which relaxes load-time enforcement |

## 7. Sequencing note

M0 and M1 are cheap and answer the only question that can kill the project. Neither M2's
queue design nor M3's HCI work is worth starting before a **Bluetooth Radio** node appears in
the guest's Device Manager.
