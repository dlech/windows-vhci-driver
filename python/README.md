# winvhci

Userspace client for the [winvhci](https://github.com/dlech/windows-vhci-driver)
virtual Bluetooth HCI controller, and a [Bumble](https://google.github.io/bumble/)
transport built on it.

With the driver installed, Windows presents a real local Bluetooth radio whose
controller behaviour comes from this process. The whole in-box stack runs above
it: WinRT `BluetoothAdapter`, advertisement scanning, GATT.

```python
from bumble.controller import Controller
from bumble.device import Device
from winvhci.transport import open_winvhci_transport

async with await open_winvhci_transport() as transport:
    controller = Controller(
        'winvhci', host_source=transport.source, host_sink=transport.sink)
    # Windows now has a radio. Advertise a peer, and it will find it.
```

## The radio's lifetime is the handle's lifetime

This is the design, not an implementation detail. The driver creates the radio
PDO when the control packet is written and destroys it when the device handle
closes — so the radio exists exactly as long as the `async with` block, and a
crashed test cannot leave a stale radio behind. It is also why this package
exists rather than a separate bridge process: if the handle lived elsewhere, a
test fixture could not deterministically take the radio away.

## Requirements

Windows, and the driver installed. See the repository for
`build/install-winvhci.ps1`, which checks each prerequisite (test signing on,
Secure Boot off, memory integrity off) and refuses rather than half-installing.

**Access rights.** By default the device DACL allows SYSTEM and Administrators
only, because whoever holds the handle is the whole radio — they can feed
arbitrary HCI to the local Bluetooth stack. So either run elevated, or install
with `-AllowInteractiveUsers` on a development machine. Note that an *unelevated*
shell of an administrator account is not sufficient: UAC leaves the
Administrators SID deny-only in that token, and the open fails with access
denied.

## Two modules

`winvhci.device` is the device on its own and imports nothing but `ctypes`, so
it can be used without Bumble:

```python
from winvhci import VhciDevice

with VhciDevice() as device:
    device.write(bytes([0xFF, 0x00]))   # ask for a radio
    while True:
        packet = device.read()          # one complete H4 frame, or b'' when closed
        if not packet:
            break
```

`winvhci.transport` adapts that to Bumble and is imported separately, which
matters on Windows on ARM: Bumble's full dependency set pulls in `grpcio` and
`cryptography`, and when neither publishes an arm64 wheel both try to compile
from source. Install Bumble with `--no-deps` plus what is actually imported.

## Relationship to Bumble's own vhci transport

Bumble already ships `bumble/transport/vhci.py` for Linux's `/dev/vhci`, and
this driver's control protocol was modelled on it: the same `FF 00` request, and
a reply that Bumble's vendor-packet filter already tolerates. So the protocol
handling here is deliberately a near-copy. What could not be reused is the layer
below it — `open_file_transport` relies on asyncio's Unix file-descriptor
readers, and a Windows device handle is neither a socket nor a pipe, so reads
and writes are overlapped and run on threads.

If you would rather express the transport as a spec string,
`winvhci.transport.install_transport_scheme()` teaches `open_transport` about
`winvhci:`. It patches a private function, because Bumble dispatches schemes
through a hardcoded chain with no registry, so calling
`open_winvhci_transport()` directly is preferred.
