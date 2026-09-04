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
