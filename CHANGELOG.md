# Changelog

Notable changes to the driver, the `actions/install` action and the `winvhci`
Python package. The release workflow lifts the section for a tag into the
release notes, so an entry here is what a user downloading a release sees.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
where the public API means the action's inputs and outputs, the `winvhci`
package, the installer's switches and exit codes, the `\\.\WinVhci` protocol and
the supported runner images.

## [Unreleased]

### Changed

- **Windows Server runners are no longer supported.** Use a Windows client
  runner: `windows-11-arm` or `windows-11-vs2026-arm`. Microsoft does not
  document Bluetooth as supported on Server, and `windows-2025` still ships
  `bthport.sys` and `bthenum.sys` at the RTM 10.0.26100.1 while its user-mode
  Bluetooth binaries are serviced to .33296 — a GATT discovery fault reproduced
  19 times in 448 tests there and 0 times in 448 on the ARM64 client runner.
  The README has the detail. x64 is still built, signed and released; it just
  is not Bluetooth-tested in CI, because GitHub offers no Windows 11 x64 client
  runner.
- The smoke and consumer-action jobs run on ARM64 only, for the same reason.
- The release workflow follows the same policy: x64 packages are installed and
  uninstalled on `windows-2025` but not Bluetooth-tested, the ARM64 package is
  driven by Bumble on a Windows 11 client runner, and it is the **Release**
  build users download that gets installed, not the Debug one. The release
  notes say so instead of listing Server as a supported runner.

### Fixed

- **Driver:** a `READ_HCI` that arrived while a packet was being written could
  park behind that packet, leaving both waiting with nothing to bring them
  together; on the event channel, where BthPort keeps a single read
  outstanding, that stalled the radio until the stack gave up. The check and
  the park now happen under one lock, as they always did on the userspace side.
- **Driver:** a packet larger than the stack can receive (an event body over
  257 bytes, an ACL body over 1021 including its header) is refused at the
  write with `STATUS_INVALID_PARAMETER`. It used to be accepted and then either
  failed the stack's read with `STATUS_BUFFER_TOO_SMALL` or was queued and
  silently thrown away. `WRITE_HCI` likewise refuses a `DataLen` that exceeds
  its buffer or the largest packet a client can read.
- **Driver:** closing the device and reopening it quickly could leave the new
  radio permanently refusing writes: the old radio's shutdown notification,
  which arrives later on a PnP thread, cleared the started state of whichever
  radio was current. Start and stop now apply only to the radio they belong to.
- `VhciDevice` can be closed and opened again; every read on a reopened device
  used to return empty at once. Closing it from another thread while a read is
  blocked now ends that read quietly, as documented, instead of raising.
- `winvhci.bumble_compat` returns proper return parameters for commands the
  installed Bumble models as synchronous, so Bumble 0.0.234 no longer logs an
  ERROR on every `LE_Set_Data_Length` while the reply was in fact correct.
- `vhci-io.ps1` pins the read buffer for as long as the overlapped read is
  outstanding; a garbage-collection pass in between could move it and have the
  kernel write the packet over another object. A read or write that completed
  in the gap between its timeout and the cancel is reported as completed
  rather than lost, and the stats size-mismatch message can now actually
  appear.
- `install-winvhci.ps1` and `smoke.ps1` quote the paths they hand to
  `Start-Process`, so a package unpacked under a directory with a space in its
  name installs.
- `test-write-gating.ps1` waits for the radio to start rather than merely to
  be enumerated, so a slow bring-up no longer fails four asserts spuriously,
  and it checks oversized packets, the stats size contract and a back-to-back
  reopen. `abuse-teardown.ps1`'s ACL round ran only when the tools lived in
  `C:\tools` and passed even when no radio ever came up; it now finds
  `win-ble-connect.ps1` beside the bridge and fails when there was nothing to
  tear down. `test-radio-toggle.ps1` prints its result after a vanished radio
  instead of crashing on the next cycle. `vhcibridge.ps1` names an over-long
  frame instead of failing on the raw write and survives a write refused while
  the radio is off.
- Native commands under Windows PowerShell 5.1 are no longer run with `2>&1`,
  which is a terminating error there the moment the command writes to stderr;
  `smoke.ps1` in particular could abort before writing its summary.
- `deploy-driver.sh --capture` without a value no longer aborts the script;
  `probe-runner.ps1` prefers the x64 kit tools on an x64 machine instead of the
  x86 copies; `build-package.ps1` accepts an absolute `-OutDir`.

## [1.2.1] - 2026-09-07

### Fixed

- `vhci-io.ps1` can read the driver's counters again. v1.2.0 added
  `RadiosAlive` to `WINVHCI_STATS` and left the script's copy a field short, so
  the driver refused every request; `test-write-gating.ps1` and
  `vhcibridge.ps1 -Stats` both failed.
- A failure while opening or closing a transport no longer leaks the device
  handle. Because the device is exclusive, a leaked handle locked out every
  later open until the garbage collector reclaimed it.
- The "access denied" message now says the device may simply be open already,
  instead of blaming the DACL for what is usually a handle still in use.

## [1.2.0] - 2026-09-05

### Added

- `VhciStats.radios_alive` reports how many radio device nodes still exist.
  It stays non-zero until Windows finishes removing one, which can take much
  longer than closing the handle, so a client creating radios back to back can
  wait for it rather than guess.
- `winvhci.transport` honors `BUMBLE_SNOOPER`, as Bumble's own transports do,
  so HCI traffic can be captured to a btsnoop file.

### Fixed

- The radio no longer leaves a permanent devnode behind each time it is
  created. Windows now reuses one, so repeated use does not accumulate stale
  entries.

## [1.1.1] - 2026-09-05

### Fixed

- The `winvhci` package version is single-sourced from
  `winvhci.__version__`. v1.1.0 shipped distribution metadata saying 1.0.2.
- `winvhci.bumble_compat` no longer shadows HCI handlers Bumble implements
  itself. Five stubs stood in front of real implementations, four of which
  keep state the stubs discarded.

## [1.1.0] - 2026-09-05

### Changed

- Backlogs are unbounded and never drop, matching Linux `/dev/vhci`.

### Added

- `IOCTL_WINVHCI_GET_STATS`, exposed as `VhciDevice.stats()` and
  `vhcibridge.ps1 -Stats`, so packet loss is measurable rather than invisible.
- `tools/test-write-gating.ps1`, run by the smoke test.

### Fixed

- An event or ACL write sent before the radio is requested is now refused with
  `STATUS_DEVICE_NOT_READY`, mirroring Linux's `-ENODEV`. It used to be queued
  and then replayed into the new radio's bring-up.
- A control packet with a trailing tail, a reserved opcode bit, or an opcode
  bit selecting a quirk with no Windows analogue is now refused rather than
  silently ignored.
- Writes are refused once the radio's stack stops consuming, mirroring Linux's
  `-ENXIO`, and the stale backlog is dropped. They used to queue without limit
  against a radio whose bring-up had failed.
- `vhci-io.ps1` ignored its own write timeout and could block forever.
- `vhcibridge.ps1` mis-reported a burst larger than its 8 KB reassembly buffer
  as a malformed stream.

## [1.0.2] - 2026-09-05

### Fixed

- `apply_dual_mode` against Bumble 0.0.226, which stopped the radio coming up.

## [1.0.1] - 2026-09-05

### Fixed

- `winvhci.bumble_compat` and `winvhci.transport` failing to import against
  Bumble 0.0.226.

## [1.0.0] - 2026-09-05

First release.

### Added

- The driver: a virtual Bluetooth radio for Windows, driven from userspace over
  `\\.\WinVhci`. x64 and ARM64.
- `actions/install`, to install it on a hosted Windows runner with no VM and no
  secrets. Supported on `windows-2025` and `windows-11-vs2026-arm`, not
  `windows-2022`.
- The `winvhci` Python package: a client for the device and a
  [Bumble](https://google.github.io/bumble/) transport.
- `install-winvhci.ps1`, with `-Uninstall` and `-AllowInteractiveUsers`.

### Known limitations

- The driver is test-signed, so it needs test signing on, Secure Boot off and
  memory integrity off. It will not load on a machine in its default
  configuration.
- Driver Verifier cannot be armed on a hosted runner, so the teardown abuse
  suite runs under it only on a developer machine.

[Unreleased]: https://github.com/dlech/windows-vhci-driver/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/dlech/windows-vhci-driver/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/dlech/windows-vhci-driver/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/dlech/windows-vhci-driver/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/dlech/windows-vhci-driver/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/dlech/windows-vhci-driver/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/dlech/windows-vhci-driver/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/dlech/windows-vhci-driver/releases/tag/v1.0.0
