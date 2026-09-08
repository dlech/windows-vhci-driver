# windows-vhci-driver

A virtual Bluetooth HCI controller for Windows — the equivalent of Linux's `/dev/vhci`
(`drivers/bluetooth/hci_vhci.c`).

A userspace process supplies the controller behaviour; Windows sees a real local Bluetooth
radio, with the whole in-box stack above it operating normally.

**Status: working.** Windows brings its full Bluetooth stack up on the virtual radio, reports a
fully capable dual-mode adapter, discovers a BLE device advertised from a Python process, and
connects to it over GATT:

```
IsLowEnergySupported : True    IsClassicSupported : True
IsCentralRoleSupported : True  IsPeripheralRoleSupported : True

GATT service discovery (uncached)   status: Success
  read   17 bytes: 'hello from bumble'
  write  18 bytes: Success
```

Those last two lines are the whole chain: a characteristic on a `bumble.device.Device`, read and
written by a Windows application, across Bumble's simulated RF link, out through its virtual
controller, over TCP, through `vhcibridge.ps1`, into `\\.\WinVhci`, up through `winvhci.sys`
and `BthMini`/`BthPort` — with no Bluetooth hardware anywhere.

## How it works

Windows binds the in-box `BthMini.sys` + `BthPort.sys` to any device reporting the compatible
ID `MS_BTHX_BTHMINI`. So this is a single root-enumerated KMDF bus driver that creates such a
child device, answers the five `bthxddi.h` IOCTLs, and bridges HCI packets to userspace over
`\\.\WinVhci` in the same H4 framing `/dev/vhci` uses:

```
  WriteFile   (controller → host)   04 <event>  |  02 <acl>  |  FF <opcode>
  ReadFile    (host → controller)   01 <cmd>    |  02 <acl>  |  FF FF <opcode> <id_lo> <id_hi>
```

Implementing a controller is **not** this project's job — Bumble and RootCanal already do that
well. `tools/vhcibridge.ps1` connects one to the driver.

No SCO and no LE Audio isochronous data: the Bluetooth extensibility transport interface has no
packet type for either.

## Running it

Build and deploy to the test guest (see [docs/development.md](docs/development.md) for how the
guest is set up):

```sh
export SSH_ASKPASS=/path/to/helper
build/deploy-driver.sh
```

Then, with the driver installed:

```
host:   python tools/bumble-controller.py --peer --dual-mode
guest:  .\vhcibridge.ps1 -RemoteHost 10.0.2.2 -Port 6402
guest:  .\win-ble-test.ps1        # adapter capabilities and discovery
guest:  .\win-ble-connect.ps1     # GATT connect, read and write
```

The bridge must stay running for as long as the radio is wanted: closing the handle to
`\\.\WinVhci` removes the radio, exactly as closing `/dev/vhci` does on Linux.

## Using it from CI

A Windows job on GitHub Actions can install the driver and get a working Bluetooth radio with
no VM and no secrets — GitHub's Windows runner images enable test signing at image build time,
so a test-signed driver loads directly:

```yaml
    - uses: dlech/windows-vhci-driver/actions/install@v1.0.0
      with:
        version: v1.0.0
    - run: pytest tests/test_bluetooth.py
```

There is deliberately no floating `v1` tag to track. This repository pins every action it uses
by commit SHA and lets Dependabot move the pin, and publishing a mutable tag it would not
itself consume would be inconsistent — so pin the action ref, and keep it equal to `version:`,
which is what the release was tested as.

### Supported runners

Use a **Windows client** runner: `windows-11-arm` or `windows-11-vs2026-arm`. On GitHub these
are the only Windows client images, and they are free for public repositories.

**Windows Server runners are not supported.** The driver loads on them and the Bluetooth stack
appears to work, which is misleading. Microsoft does not document Bluetooth as supported there
— the [Bluetooth developer FAQ][faq] says LE functionality "is in OneCore and should be
available on most recent devices", then adds the caveat that "some Windows Server Editions
don't support Bluetooth", naming none and saying nothing either way about Server 2025.

More concretely, `windows-2025` ships Bluetooth bugs that have since been fixed elsewhere. Its
OS is serviced to 10.0.26100.33296 and its user-mode Bluetooth binaries with it, but
`bthport.sys` and `bthenum.sys` — the two Bluetooth *kernel* drivers — are still at
10.0.26100.1, the original RTM build, 33295 revisions behind everything around them:

| | `windows-2025` | `windows-11-vs2026-arm` |
| --- | --- | --- |
| Edition | Server 2025 Datacenter | Windows 11 Enterprise |
| `bthport.sys` | **10.0.26100.1** | 10.0.26100.8655 |
| `bthenum.sys` | **10.0.26100.1** | 10.0.26100.8655 |
| `bthmini.sys` | 10.0.26100.33296 | 10.0.26100.8972 |
| `BluetoothApis.dll` | 10.0.26100.33158 | 10.0.26100.8972 |

An intermittent GATT discovery failure — `GetGattServicesAsync` returning
`ERROR_FILE_NOT_FOUND` after completing the whole discovery correctly on air — occurred 19
times in 448 tests on `windows-2025` and 0 times in 448 on `windows-11-vs2026-arm`, with the
same commit, driver and tests. Days went into investigating it before the platform was the
suspect. Do not spend that time again.

`windows-2022` is not supported either, for an unrelated reason: `Radio.RequestAccessAsync`
returns `DeniedByUser` and the user-mode Bluetooth services are absent, so WinRT Bluetooth
cannot be used even though the driver loads.

The x64 package is built, signed and released, because real users run x64 — but CI cannot
Bluetooth-test it, since GitHub offers no Windows 11 x64 client runner. That gap is stated
rather than hidden.

[faq]: https://learn.microsoft.com/en-us/windows/apps/develop/devices-sensors/bluetooth-dev-faq

The action installs the driver and stops there — it deliberately does not create a radio,
because the radio's lifetime is a device handle's lifetime and the test process has to own it
for teardown to be deterministic. The [`winvhci`](python/) Python package opens the device and
plugs it into [Bumble](https://google.github.io/bumble/):

```python
from winvhci.bumble_compat import WindowsCompatController, WindowsCompatLink, apply_dual_mode
from winvhci.transport import open_winvhci_transport

async with await open_winvhci_transport() as transport:
    controller = WindowsCompatController(
        'winvhci', host_source=transport.source, host_sink=transport.sink,
        link=WindowsCompatLink(), public_address='F0:F1:F2:F3:F4:F5')
    apply_dual_mode(controller)
    # Windows now has a radio, for as long as this block runs.
```

`WindowsCompatController` is not optional: a stock Bumble controller does not get Windows
through bring-up, for three separate reasons recorded in
[python/winvhci/bumble_compat.py](python/winvhci/bumble_compat.py).

To install on a real machine instead, [build/install-winvhci.ps1](build/install-winvhci.ps1)
checks each prerequisite by name and refuses rather than half-installing, and `-Uninstall`
removes everything it added. By default only SYSTEM and Administrators may open the device,
since whoever holds it can inject arbitrary HCI into the local Bluetooth stack;
`-AllowInteractiveUsers` relaxes that for a development machine.

## Documentation

- [docs/research.md](docs/research.md) — how the Windows Bluetooth stack is put together, where
  it can be extended, and why this is possible without emulating any hardware.
- [docs/design.md](docs/design.md) — how the driver is built, and the parts of the BTHX contract
  that had to be measured rather than read.
- [docs/controller-requirements.md](docs/controller-requirements.md) — what Windows demands of
  the controller at the far end of the pipe. Stricter than BlueZ, and undocumented.
- [docs/development.md](docs/development.md) — toolchain, the QEMU test guest, the build loop,
  and how to see what the driver is doing.
- [docs/implementation-plan.md](docs/implementation-plan.md) — what is built and what is left.

## License

MIT — see [LICENSE](LICENSE).
