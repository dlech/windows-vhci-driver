# Changelog

Notable changes to the driver, the `actions/install` action and the `winvhci`
Python package. The release workflow reads the section for a tag out of this
file and puts it in the release notes, so an entry here is what a user
downloading a release actually sees.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Note that "public API" for versioning purposes means the things outside this
repository depend on: the action's inputs and outputs, the `winvhci` package,
the installer's switches and exit codes, the device protocol on `\\.\WinVhci`,
and the set of supported runner images.

## [Unreleased]

## [1.0.0] - 2026-09-05

First release.

### Added

- **The driver.** A KMDF root-enumerated bus driver presenting a virtual
  Bluetooth radio to Windows. Userspace supplies the controller behaviour over
  `\\.\WinVhci`; Windows loads its in-box `bth.inf` stack on top and reports a
  fully capable dual-mode adapter, discovers advertising peers and connects to
  them over GATT. x64 and ARM64.

- **`actions/install`**, a GitHub Action that installs the driver on a hosted
  Windows runner with no VM and no secrets, and asserts the device reaches
  `Status OK`. It installs the driver only, and deliberately does not create a
  radio: the radio's lifetime is the device handle's lifetime, so the test
  process has to own it for teardown to be deterministic.

  Supported on `windows-2025` and `windows-11-vs2026-arm`. Not `windows-2022` —
  the driver loads, but `Radio.RequestAccessAsync` returns `DeniedByUser` and
  the user-mode Bluetooth services are absent.

- **The `winvhci` Python package.** `winvhci.device` is a ctypes-only client for
  the device; `winvhci.transport` plugs it into [Bumble](https://google.github.io/bumble/)
  as a transport, close to a copy of Bumble's own Linux `vhci` transport because
  the control protocol was modelled on `/dev/vhci`. `winvhci.bumble_compat`
  carries the compatibility shims Windows needs — a stock Bumble controller does
  not get the Windows stack through bring-up.

- **`install-winvhci.ps1`** for installing on a real machine. It names each
  prerequisite and refuses rather than half-installing, and `-Uninstall` removes
  everything it added. `-AllowInteractiveUsers` relaxes the device DACL for a
  development machine.

### Security

- The device DACL allows SYSTEM and Administrators only. Whoever can open
  `\\.\WinVhci` can inject arbitrary HCI into the local Bluetooth stack, so
  unelevated access is opt-in through `-AllowInteractiveUsers` and off by
  default.

### Known limitations

- **The driver is test-signed.** It will not load on a Windows machine in its
  default configuration; it needs test signing on, Secure Boot off and memory
  integrity off. Windows silently ignores test signing while Secure Boot is on.
  Attestation signing, which would remove all of that, is a separate track.

- Driver Verifier cannot be armed on a hosted runner — enabling it needs a
  reboot — so the teardown abuse suite runs unverified in CI and under Verifier
  only on a developer machine.

[Unreleased]: https://github.com/dlech/windows-vhci-driver/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/dlech/windows-vhci-driver/releases/tag/v1.0.0
