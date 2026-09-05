# Development environment

How to build `winvhci.sys`, get it into a test guest, and see what it is doing. Everything here
has been used; the traps listed are ones that were actually hit.

---

## Host toolchain

Visual Studio 2026 Community 18.9 with the WDK/SDK **10.0.28000.2526**, installed via winget
with the WDK VSIX and the ARM64/x64 Spectre-mitigated libraries, using Microsoft's own
`build/wdk-desktop.vsconfig`. `bthxddi.h` lands under
`Windows Kits\10\Include\10.0.28000.0\km`.

KMDF is not optional: BthMini is kernel-mode and queries the transport with kernel IOCTLs, so
UMDF cannot do this.

The host is ARM64 (Snapdragon, Windows 11 Home 26200), which is why `bth.inf`'s models section
here is `NTarm64`, and why the guest is ARM64 too — QEMU could emulate a foreign CPU, but
matching the host lets it use WHPX acceleration.

### Three build gotchas, all handled in `winvhci.vcxproj`

- **Build with the ARM64 MSBuild**, `MSBuild\Current\Bin\arm64\MSBuild.exe`. The default
  `Bin\MSBuild.exe` is x86, and the WDK ships `infverif.dll` only for arm64 and x64, so an x86
  MSBuild fails with "Unable to load DLL 'x86\InfVerif.dll'".
- **Don't redirect `OutDir` out of the project tree.** It breaks the step that stages files
  into the driver package folder.
- **Add the driver binary to `FilesToPackage` explicitly.** The WDK's `GetPackageFiles` target
  only auto-adds INF files; the `.sys` normally arrives from a separate "Package" project via
  `ProjectReference`. Without it, inf2cat fails with "winvhci.sys ... is missing".

`DriverVer` is time-stamped (`<TimeStamp>*</TimeStamp>`) so that every build produces a new
version. That is not cosmetic — see the stale-binary trap below.

---

## The test guest: QEMU

**VirtualBox cannot host Windows guests on a Windows-on-ARM host.** It bugchecks
`INTERNAL_POWER_ERROR` during install or on boot — a defect spanning at least 7.2.0 to 7.2.6,
reproducible on a freshly created VM with no customisation. Its ARM firmware also publishes no
ACPI **DBG2** table, and Windows on ARM locates its debug UART exclusively through DBG2, so it
can never be kernel-debugged there. Both are missing platform support, not misconfiguration.
Abandoned.

**QEMU 11.1.0 with `-accel whpx` works.** Launch with `build/qemu-run.ps1`. The device choices
each cost real time:

| Need | Use | Why not the obvious choice |
| --- | --- | --- |
| Disk | `nvme` | ArmVirtQemu has **no AHCI driver**, so an `ich9-ahci` disk is invisible to firmware and it falls through to PXE. Windows has inbox `stornvme`. |
| Boot media | `scsi-cd` on `virtio-scsi-pci` | Over `usb-storage` the firmware sees a removable HARDDRIVE, hunts for `\EFI\BOOT\BOOTAA64.EFI`, finds ISO9660, and hangs. |
| Media for a *running* Windows | `usb-storage` | The opposite: Windows has inbox USB mass storage but no virtio-scsi driver. |
| Display | `ramfb` | `bochs-display` and `VGA` are never programmed by ArmVirtQemu (firmware console lost); `virtio-gpu-pci` renders under firmware then goes dark — no inbox driver. `-vga virtio` is rejected by the machine type. |
| Network | `virtio-net-pci` + **NetKVM** from virtio-win | Windows on ARM has no inbox driver for *any* NIC QEMU offers — `e1000e`, virtio-net and USB RNDIS all land in Device Manager as unknown devices. virtio-win ships ARM64 INFs; its guest-tools MSIs are x64/x86 only, so install with `pnputil`. |
| File channel | read-only **ISO** (`build/make-share-iso.ps1`) | `vvfat` read-write **crashes QEMU outright** when the guest writes to it (`cluster 0 used more than once`, an assertion in `commit_direntries`), and `usb-storage` refuses a read-only `vvfat`. |

Two more traps:

- `-serial pipe:` on Windows **blocks the guest until a client connects** — the VM sits at ~0%
  CPU looking like a dead install. `qemu-run.ps1 -NoKd` avoids it.
- `hostfwd` binds the host port immediately, so a plain TCP connect is a false positive for
  "the guest is up". Probe with a real RDP X.224 handshake, or an SSH banner.

### Guest state

Secure Boot is off automatically — the plain `edk2-aarch64-code.fd` firmware has no Secure Boot
support at all. `build/guest-setup.ps1` does the rest: `testsigning on`, HVCI off, auto-reboot
off, crash dumps on, `Debug Print Filter` values set (without them Windows discards `DbgPrint`
output whenever no debugger is attached), and Windows Update disabled so the guest does not
change build or reboot mid-test.

**UAC stays enabled in the guest.** This costs nothing: Windows OpenSSH gives an administrator a
full unfiltered token, so an SSH session is already elevated and no UAC interaction is involved.
Install and teardown scripts are self-contained and idempotent so they can run in one step over
SSH.

Snapshots are offline, via `build/qemu-snapshot.ps1` — a live `savevm` fails because the
removable media do not support snapshots. Take one before any change to the guest and after any
milestone worth returning to.

---

## The build → guest loop

```sh
export SSH_ASKPASS=/path/to/helper   # echoes the guest password
build/deploy-driver.sh               # build, copy, purge, install, restart the device
build/deploy-driver.sh --capture 20  # ... and capture a kernel trace around a restart
```

This is over SSH deliberately. The share ISO is only readable at boot and QEMU holds it open
while running, so using it for iteration costs a full shutdown, ISO rebuild and boot per
change. The ISO stays useful for first-time bring-up of a fresh guest, when there is no SSH yet
(`build/make-share-iso.ps1`, then `guest-setup.ps1` and `guest-install-driver.ps1` from the
mounted disc).

### The stale-binary trap

`pnputil` identifies a driver package by its INF version, not its contents. A rebuilt package
with an unchanged `DriverVer` is reported as "already imported" and the **old binary is served**
— three consecutive installs once ran the first build while the source said otherwise. Two
things prevent it: the time-based `DriverVer` above, and purging the driver store before every
install.

Purging means parsing `pnputil /enum-drivers` output, where the published `oemNN.inf` name
precedes the original name it maps to:

```powershell
$p = $null
pnputil /enum-drivers | ForEach-Object {
    if     ($_ -match '^\s*Published Name:\s*(oem\d+\.inf)')      { $p = $Matches[1] }
    elseif ($_ -match '^\s*Original Name:\s*winvhci\.inf' -and $p) { $p; $p = $null }
} | Sort-Object -Unique | ForEach-Object { pnputil /delete-driver $_ /uninstall /force }
```

Reading those two fields in the wrong order silently deletes nothing.

### Reboots are usually avoidable

Installing a new build over an old one updates the files and the service image path, but
Windows keeps the already-loaded `winvhci.sys` in memory — `setupapi.dev.log` says "Service
image path changed. Restart required for any devices using this service." A `devcon restart
root\winvhci` after a driver-store purge is normally enough. `build/qemu-restart.ps1` does a
clean ACPI shutdown and relaunch when a real reboot is unavoidable.

---

## Seeing what the driver is doing

### DebugView

`KdPrint` output is read with Sysinternals DebugView. Both the GUI (`Dbgview64a.exe`, elevated,
Capture ▸ Capture Kernel) and the CLI (`dbgviewcli64a.exe`) work, and the CLI works fine over
SSH as a detached process.

**Only one process may hold the kernel capture at a time.** A DebugView GUI instance, or a
leaked earlier CLI instance, silently starves every later capture, which then produces an empty
log rather than an error. This looked for a while like a broken tool and was not.

```powershell
C:\tools\dbgviewcli64a.exe --status   # running=, paused=, elevated=
C:\tools\dbgviewcli64a.exe --stop     # release an existing capture
Start-Process C:\tools\dbgviewcli64a.exe -ArgumentList `
    '--accepteula','--kernel','--duration','22','--log','C:\kd.log' -WindowStyle Hidden
```

- **Bound the run with `--duration`** and let it exit by itself. Killing it with `Stop-Process`
  loses the buffered log.
- **Do not pass `--no-win32`.** Kernel lines do not appear when Win32 capture is disabled. That
  is not documented behaviour but it is reproducible here.
- Capture around a **device restart**, not around the install. `pnputil` and `devcon` can take
  longer than the capture window; a restart reproduces the whole interesting sequence — unload,
  `DriverEntry`, `EvtDeviceAdd`, PDO creation, the BTHX handshake, `HCI_Reset` — in under a
  second.

The CLI is explicitly designed for scripted use (`--duration`, `--max-lines`, `--wait-for`,
`--no-banner`, `--format csv`, `--status`); read
<https://learn.microsoft.com/sysinternals/downloads/debugview> before improvising.

### Registry knobs

`HKLM\SOFTWARE\winvhci` holds values the driver *reads* at device add:

| Value | Effect |
| --- | --- |
| `WvScoSupport` | `BTHX_SCO_SUPPORT` to report — 0 None, 1 HCI, 2 HCIBypass |
| `WvMaxScoChannels` | `MaxScoChannels` to report |
| `WvFailAllocOneIn` | fail every Nth packet allocation; 0 (default) disables |

These earn their keep: a registry edit and a device restart, rather than a
rebuild-sign-package-install cycle, is what made the `ScoSupport` question cheap to settle.

`WdfDeviceOpenRegistryKey(PLUGPLAY_REGKEY_DEVICE)` reads and writes *nothing* here, even from
`EvtDeviceAdd` — the devnode's "Device Parameters" key is not reliably available that early — so
the code uses the absolute path `\Registry\Machine\SOFTWARE\winvhci` instead.

**The write-side breadcrumbs are gone.** During bring-up the driver also recorded a counter and
a last-seen value per request under the same key, because `KdPrint` output could not yet be
captured. They cost a registry write per request, which is far too expensive once the data path
carries real traffic, and DebugView gives a better transcript with ordering and timestamps. If
you need state that survives a crash, prefer a crash dump.

### Driver Verifier

```powershell
verifier /standard /driver winvhci.sys   # then reboot
verifier /query                          # pool stats, per-module
verifier /reset                          # then reboot
```

`/standard` here means special pool, force IRQL checking, pool tracking, I/O verification,
deadlock detection, DMA checking, security checks, miscellaneous checks and DDI compliance.

**Verifier changes behaviour, so run a control before believing a failure is yours.** Its first
run here stopped the radio from starting at all, and the useful step was not reading the trace
harder but re-running the *same binary* with Verifier off — which worked, and immediately
partitioned the problem. (It was a real defect: see design.md on taking both METHOD_NEITHER
pointers from the IRP stack location.)

`tools/abuse-teardown.ps1` drives the teardown races: repeated rounds of killing the client
outright while the stack is driving the transport, one round that kills it with ACL traffic in
flight mid-GATT, and a device restart under a live client.

**Low resources simulation does not reach this driver.** With randomized fault injection at
probability 10000 — 100% — and no delay, Verifier deliberately failed *none* of the driver's
allocations:

```
Pool Allocations Attempted:              24
Pool Allocations Failed Deliberately:     0
```

It still tracks them, it just will not fail them, and the likely reason is that both allocation
sites call `ExAllocatePool2` while holding the FDO spinlock, at DISPATCH_LEVEL. So the
out-of-memory paths cannot be exercised this way. `WvFailAllocOneIn` under
`HKLM\SOFTWARE\winvhci` fails every Nth packet allocation instead, and is the only way those
paths run at all. Zero, the default, disables it.

### Reading a bugcheck in this guest

**A bugcheck is invisible from the host.** `qemu-screenshot.ps1` returns black once Windows has
taken over the display, so a bugcheck screen looks exactly like a hung VM, and recovering the
VM before reading the dump destroys the evidence. Three things make it legible:

- Set `AutoReboot = 1` in `HKLM\SYSTEM\CurrentControlSet\Control\CrashControl`. The guest then
  restarts by itself and records the stop code where it can be read back:

  ```powershell
  Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001} -MaxEvents 5
  # The bugcheck was: 0x000000c4 (0x0000000000000062, ...)
  ```

- With `AutoReboot = 1`, a machine that sits there spinning instead of restarting is probably
  *not* bugchecked. That distinction is what separated a real driver defect from the QEMU reset
  hang below.

- Ask the monitor where the guest actually is. Sampling twice and comparing is the useful part:
  an unchanging PC on several CPUs is a spin, not slow progress.

  ```powershell
  # via QMP human-monitor-command
  info registers -a     # PC per vCPU
  info cpus
  ```

### QEMU hangs on a guest-initiated reboot

A guest **restart** hangs this VM: the guest finishes shutting down, parks its application
processors, asks for a reset that never takes effect, and the remaining CPUs spin forever at
~350% CPU with no SSH. The monitor shows it plainly — two CPUs pinned at the same kernel PC
across samples, the other two already at `PC=0`.

A guest **shutdown** is fine and exits QEMU cleanly, which fits the two being different PSCI
calls on ARM64: `SYSTEM_OFF` works, `SYSTEM_RESET` does not. This is a known class of QEMU
problem rather than anything specific to this project — Windows guests hanging on reboot with
every vCPU pegged are reported at
[#1490853](https://bugs.launchpad.net/qemu/+bug/1490853) and
[#2064914](https://bugs.launchpad.net/ubuntu/+source/qemu/+bug/2064914), with an aarch64
high-CPU case at [#1826401](https://bugs.launchpad.net/qemu/+bug/1826401).

`qemu-run.ps1` passes **`-no-reboot`**, which turns the reset into a clean QEMU exit so the
wrapper can just relaunch. Without it the symptom is indistinguishable from a driver hang, and
telling the two apart costs real time.

**Allow ~10 seconds for a radio to disappear.** The driver's own teardown is immediate —
`EvtFileClose` and `all radios removed` are microseconds apart — but `Get-PnpDevice` keeps
reporting the radio for a consistent ~8.4 s afterwards while Windows removes the device stack
above it, including BthPort's enumerator and RFCOMM children. A shorter check reports a stale
radio that is not stale.

### Kernel debugger

Unconfirmed. QEMU's `virt` machine *does* publish an ACPI DBG2 table (unlike VirtualBox), so a
live debugger over `-serial pipe:` should be possible; `build/guest-dbg2.ps1` dumps the table
from inside the guest to find the right `busparams` index. Crash dumps plus DebugView have
covered everything so far.

---

## Running the whole thing

```sh
host:   python tools/bumble-controller.py --peer --dual-mode
guest:  .\vhcibridge.ps1 -RemoteHost 10.0.2.2 -Port 6402
guest:  .\win-ble-test.ps1
```

`10.0.2.2` is the host's loopback as seen from QEMU's slirp network.

Bumble on ARM64 needs `--no-deps` and then a minimal dependency set installed by hand: `grpcio`
and older `cryptography` releases have no ARM64 wheels, and neither is needed for controller
emulation.
