# Windows VHCI — plan and status

What is built, and what is left. The design itself has moved to [design.md](design.md); the
controller-side requirements to [controller-requirements.md](controller-requirements.md); the
build and test environment to [development.md](development.md).

Target: ARM64 Windows 11 guest under QEMU on an ARM64 host. Build target is ARM64 throughout.

---

## 1. Scope

**In scope.** A virtual Bluetooth controller that Windows treats as a real local radio, driven
entirely by a userspace process, byte-compatible with Linux's `/dev/vhci` framing so existing
vhci clients port cheaply.

**Out of scope, permanently.** SCO (voice) and LE Audio isochronous streams — the BTHX
interface has no packet type for either. If these are ever needed the answer is a different
transport (a UdeCx-emulated USB dongle), not an extension of this one.

**Out of scope, for now.** Multiple simultaneous virtual radios; coexistence with a real radio
on the same machine; production code-signing.

**Explicitly not this project's job:** implementing a Bluetooth controller. Good emulators
already exist — [Bumble](https://google.github.io/bumble/) and
[RootCanal](https://github.com/google/rootcanal) — and the goal is to plug one in. The bridge
does that; `tools/vhcictl.ps1` is diagnostic scaffolding that must not grow into a controller
model.

## 2. Deliverables

| Component | State |
| --- | --- |
| `winvhci/` → `winvhci.sys` | **Built.** KMDF root-enumerated bus driver; the whole kernel-mode story. |
| `winvhci/winvhci.inx` → `.inf` | **Built.** Root-enumerated install, ships only our driver — the Bluetooth side is in-box. |
| `tools/vhcibridge.ps1` | **Built.** Byte pump between `\\.\WinVhci` and a TCP controller emulator. |
| `tools/bumble-controller.py` | **Built.** Bumble controller with the Windows-compatibility shim, plus an optional advertising peer. |
| `tools/vhcictl.ps1` | **Built.** Diagnostic client: dumps host→controller traffic, replays canned answers. |
| `tools/win-ble-test.ps1` | **Built.** Exercises the Windows Bluetooth APIs against the virtual radio. |

---

## 3. Milestones

### ✅ M0 — Toolchain and a test VM

VS 2026 + WDK 10.0.28000.2526 on the host; an ARM64 Windows 11 guest under QEMU with
testsigning on, HVCI off, snapshots, SSH, and a working deploy loop. VirtualBox was tried first
and abandoned. See [development.md](development.md).

### ✅ M1 — Prove the seam

Windows binds the in-box Bluetooth stack to a software-only PDO with no hardware anywhere:

```
Device winvhci\radio\1&79f5d87&4&1 was configured.
  Driver Name:        bth.inf
  Driver Section:     BthMini.NT
  Matching Device ID: MS_BTHX_BTHMINI
  Parent Device:      ROOT\SYSTEM\0001
```

and once the radio starts, the stack drives the transport:

```
winvhci: WRITE_HCI type 0x01 len 3 (#1)
winvhci:   command opcode 0x0c03 (OGF 0x03 OCF 0x003) plen 0   <-- HCI_Reset
```

This settled the go/no-go question for the whole approach: `MS_BTHX_BTHMINI` is the binding
point, the BTHX IOCTLs arrive as `IRP_MJ_INTERNAL_DEVICE_CONTROL`, and
`WdfRequestForwardToParentDeviceIoQueue` carries them from the radio stack to the FDO.

Worth remembering: **no `READ_HCI` is posted until the transport looks alive.** The stack issues
`WRITE_HCI` first, so M1 passing says nothing about whether the two-queue read model is right.

### ✅ M2 — The data path

A userspace client opens `\\.\WinVhci`, creates a radio with the control packet, receives the
stack's HCI commands as H4 frames, and injects events back:

```
CTRL ff 00 03 00                                     radio 3 created
CMD  0x0c03  OGF 0x03 OCF 0x003  HCI_Reset                       -> accepted
CMD  0x1009  OGF 0x04 OCF 0x009  Read_BD_ADDR                    -> accepted
CMD  0x1002  OGF 0x04 OCF 0x002  Read_Local_Supported_Commands   -> Unknown Command
   ... the stack restarts the sequence
```

That transcript was the specification for M3. Radio lifetime follows the handle: with no client
attached the Bluetooth Radio node does not exist at all.

### ✅ M3 — A convincing controller

Bumble drives the Windows stack through the bridge, Windows brings up its full stack on the
virtual radio, and a BLE device advertised from Python is discovered by a Windows API:

```
IsLowEnergySupported : True    IsClassicSupported : True
IsCentralRoleSupported : True  IsPeripheralRoleSupported : True
adapter address : F0:F1:F2:F3:F4:F5   Radio state : On

DeviceInformation.FindAllAsync (unpaired BLE)
  'Bumble'  BluetoothLE#BluetoothLEf0:f1:f2:f3:f4:f5-aa:bb:cc:dd:ee:ff
```

The three controller-side requirements this uncovered — dual-mode LMP features, advertising
commands in the supported-commands bitmask, and LE Supported States — are documented in
[controller-requirements.md](controller-requirements.md).

**GATT works too, which is what proves the ACL path.** Everything above runs on HCI commands,
events and advertising reports; a GATT operation is ATT over L2CAP over ACL, so it is the first
thing to exercise the driver's second read channel and the `MaxAclTransferInSize` it has
claimed since M1:

```
GATT service discovery (uncached)   status: Success
    7a9b0001-4c1d-4e2a-9f3b-1d2c3e4f5a6b   (the peer's service)
  read   17 bytes: 'hello from bumble'
  write  18 bytes: Success        -> arrives at the Python peer
```

`tools/win-ble-connect.ps1` runs this. Getting there needed three more controller-side fixes
and no driver changes at all: connection-time command handlers, an ACL routing fix in Bumble's
simulated link, and raw-byte Command Complete replies. All are in
[controller-requirements.md](controller-requirements.md).

**Not finished:**

- The **Settings Bluetooth toggle** has not been looked at; it needs the GUI.
- `BluetoothLEAdvertisementWatcher` is unverified. Windows PowerShell 5.1 cannot subscribe to
  WinRT events at all, so `tools/win-ble-scan.ps1` compiles the watcher as C# instead — but its
  `csc` invocation still fails on WinMD references for want of .NET Framework facades in the
  guest. `FindAllAsync` already demonstrates discovery, so this is a second opinion rather than
  a gap in the evidence.

### ⬜ M4 — Make it survivable

Nothing here has been done.

- Driver Verifier (standard + force IRQL checking + low resources) across a full M3 run.
- Code Analysis and Static Driver Verifier clean.
- Cancellation and teardown races: kill the userspace process mid-transfer, disable the device
  mid-transfer, sleep/resume, Airplane mode. The serialhcibus sample carries
  `GUID_DEVINTERFACE_BLUETOOTH_RADIO_ONOFF_VENDOR_SPECIFIC` handling for the last of these —
  add it only if the toggle actually misbehaves.
- Tighten the `\\.\WinVhci` DACL to Administrators + SYSTEM.
- Decide what to do with the registry breadcrumbs: the `WvScoSupport` / `WvMaxScoChannels` knobs
  earn their keep, the per-IOCTL trace writes are now redundant with DebugView.

**Exit:** an M3 session survives Verifier and the abuse list without a bugcheck.

### ⬜ M5 — Ergonomics

- Upstream `WindowsCompatController` to Bumble. None of it is specific to this project.
- A `pip`-installable client, and a Bumble transport that speaks to `\\.\WinVhci` directly so
  the bridge is not needed.
- Narrow down which LE Supported States bits Windows actually requires; the working value is
  empirical.
- BR/EDR beyond initialisation. The dual-mode LMP mask advertises capabilities Bumble cannot
  honour, so BR/EDR operations will fail if anything tries them. LE is the path that works.

---

## 4. Repository layout

```
winvhci/      driver.c    DriverEntry, EvtDeviceAdd
              fdo.c       BTHX contract, queues, rendezvous, registry breadcrumbs
              pdo.c       the radio PDO and IOCTL forwarding
              user.c      \\.\WinVhci - read/write, H4 framing, control packet
              winvhci.h   shared declarations and measured constants
              winvhci.inx winvhci.vcxproj

tools/        vhci-io.ps1           shared overlapped-I/O helper and H4 framing
              vhcibridge.ps1        \\.\WinVhci <-> TCP
              vhcictl.ps1           diagnostic client
              bumble-controller.py  Bumble + Windows-compatibility shim
              winrt-await.ps1       awaiting WinRT async ops from PowerShell
              win-ble-test.ps1      Windows Bluetooth API checks
              win-ble-connect.ps1   GATT connect, read and write - the ACL path
              win-ble-scan.ps1      event-driven watcher (NOT WORKING - see M3)

build/        qemu-*.ps1            create, run, snapshot, restart the guest
              guest-*.ps1           run inside the guest
              make-share-iso.ps1    first-time file channel for a fresh guest
              deploy-driver.sh      the iteration loop, over SSH

docs/         research.md, design.md, controller-requirements.md,
              development.md, implementation-plan.md
```

## 5. Risks

| Risk | Signal | State |
| --- | --- | --- |
| BthMini rejects a transport with no hardware resources | M1 fails; PDO gets an error code | **Settled** — it does not care. A root-enumerated PDO with no resources works. |
| `ScoSupportNone` rejected | radio never starts; the capabilities query is the last thing seen | **Settled** — it is rejected. Claim `ScoSupportHCIBypass` and never deliver audio. |
| Init sequence never completes | the stack stops sending commands, radio stays off | **Settled for LE** — see controller-requirements.md. Diff against a real-adapter ETW trace if it recurs. |
| ARM64 VirtualBox guest unstable under KD | `INTERNAL_POWER_ERROR` on a stock VM; no ACPI DBG2 table | **Settled** — VirtualBox unusable; moved to QEMU + WHPX. Live kernel debugging there is still unconfirmed. |
| Windows Update reboots the guest mid-test or changes the OS build | an unexplained reboot, or results stop reproducing | **Settled** — updates disabled in the guest; the build is pinned for the life of the project. |
| Test signing blocked in the guest | driver won't load | **Settled** — Secure Boot and HVCI both off. |
| Teardown races bugcheck the guest | a bugcheck when a client dies mid-transfer | **Open** — this is M4. |
