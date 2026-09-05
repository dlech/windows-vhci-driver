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

[Unreleased]: https://github.com/dlech/windows-vhci-driver/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/dlech/windows-vhci-driver/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/dlech/windows-vhci-driver/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/dlech/windows-vhci-driver/releases/tag/v1.0.0
