# windows-vhci-driver

A virtual Bluetooth HCI controller for Windows — the equivalent of Linux's `/dev/vhci`
(`drivers/bluetooth/hci_vhci.c`).

A userspace process supplies the controller behaviour; Windows sees a real local Bluetooth
radio, with the whole in-box stack above it operating normally.

**Status: working.** Windows brings its full Bluetooth stack up on the virtual radio, reports a
fully capable dual-mode adapter, and discovers a BLE device advertised from a Python process:

```
IsLowEnergySupported : True    IsClassicSupported : True
IsCentralRoleSupported : True  IsPeripheralRoleSupported : True

DeviceInformation.FindAllAsync (unpaired BLE)
  'Bumble'  BluetoothLE#BluetoothLEf0:f1:f2:f3:f4:f5-aa:bb:cc:dd:ee:ff
```

That last line is the whole chain: a BLE device advertised by a `bumble.device.Device`, across
Bumble's simulated RF link, out through its virtual controller, over TCP, through
`vhcibridge.ps1`, into `\\.\WinVhci`, up through `winvhci.sys` and `BthMini`/`BthPort`, and
discovered by a Windows API — with no Bluetooth hardware anywhere.

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
guest:  .\win-ble-test.ps1
```

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
