r"""Run a Bumble virtual Bluetooth controller and expose it over TCP.

(Raw string: this docstring contains Windows paths, and without the r prefix
Python turns the backslash in ".\vhcibridge.ps1" into a vertical tab.)

This is the other end of the seam. The winvhci driver and vhcibridge.ps1 carry
HCI packets; this supplies a controller to talk to, so that no controller has to
be written in this project.

    python tools/bumble-controller.py                 # listen on 127.0.0.1:6402
    python tools/bumble-controller.py --peer          # ...plus a peer that advertises

Then, inside the guest:

    .\vhcibridge.ps1 -RemoteHost 10.0.2.2 -Port 6402

Binding to loopback is deliberate and sufficient: QEMU's slirp maps the guest's
10.0.2.2 to the host's loopback, so the guest reaches this without the socket
being exposed on any real interface.

Installing Bumble on Windows on ARM needs care - its full dependency set drags
in grpcio and an older cryptography, neither of which has an ARM64 wheel, and
both then fail to compile. Install with --no-deps and add only what is imported;
grpcio (the gRPC bridge) and libusb-package (USB transport) are not needed here.
"""

import argparse
import asyncio
import logging
import sys

from bumble import hci
from bumble.device import Device
from bumble.gatt import Characteristic, Service
from bumble.host import Host

from bumble.transport import open_transport

# The Windows compatibility shims used to live in this file. They moved into the
# winvhci package because a consumer's own test suite needs them just as much as
# this script does, and a second copy would be the one that rots. See
# python/winvhci/bumble_compat.py for why each handler exists.
from winvhci.bumble_compat import (  # noqa: E402
    WindowsCompatController,
    WindowsCompatLink,
    apply_dual_mode,
)


# A GATT service for the peer to publish, so that Windows has something to
# connect to and read rather than merely something to see.
#
# This is the first thing in the project that moves ACL data. Everything up to
# discovery is HCI commands, events and advertising reports; a GATT operation
# runs ATT over L2CAP over ACL, which exercises the driver's second read channel
# and its MaxAclTransferInSize claim for the first time.
#
# The UUIDs are arbitrary but deliberately related, so they are recognisable in
# a trace.
PEER_SERVICE_UUID = "7a9b0001-4c1d-4e2a-9f3b-1d2c3e4f5a6b"
PEER_READ_UUID    = "7a9b0002-4c1d-4e2a-9f3b-1d2c3e4f5a6b"
PEER_WRITE_UUID   = "7a9b0003-4c1d-4e2a-9f3b-1d2c3e4f5a6b"
PEER_NOTIFY_UUID  = "7a9b0004-4c1d-4e2a-9f3b-1d2c3e4f5a6b"

PEER_READ_VALUE = b"hello from bumble"


def build_peer_service() -> Service:
    """One service with a readable, a writable and a notifiable characteristic.

    Deliberately plain: the point is to exercise the transport, not to model a
    device. A read proves ATT responses come back up through the driver, a write
    proves the host-to-controller ACL direction, and the notify characteristic
    gives a client something to subscribe to.
    """
    read_char = Characteristic(
        PEER_READ_UUID,
        Characteristic.Properties.READ,
        Characteristic.READABLE,
        PEER_READ_VALUE,
    )
    write_char = Characteristic(
        PEER_WRITE_UUID,
        Characteristic.Properties.WRITE | Characteristic.Properties.WRITE_WITHOUT_RESPONSE,
        Characteristic.WRITEABLE,
        b"",
    )
    notify_char = Characteristic(
        PEER_NOTIFY_UUID,
        Characteristic.Properties.READ | Characteristic.Properties.NOTIFY,
        Characteristic.READABLE,
        b"\x00",
    )

    def on_write(connection, value):
        print(f"peer: characteristic write from {connection.peer_address}: {value!r}",
              flush=True)

    write_char.on("write", on_write)

    return Service(PEER_SERVICE_UUID, [read_char, write_char, notify_char])


async def run(
    host: str,
    port: int,
    with_peer: bool,
    address: str,
    peer_address: str,
    peer_name: str,
    dual_mode: bool,
    peer_address_type: str = "random",
) -> None:
    # A LocalLink is Bumble's simulated radio medium. Controllers attached to
    # the same link can see each other, which is how a peer device becomes
    # discoverable to Windows without any real radio.
    link = WindowsCompatLink()

    spec = f"tcp-server:{host}:{port}"
    print(f"listening for an HCI client on {spec}", flush=True)

    peer_device = None
    if with_peer:
        # A second controller on the same LocalLink, which is Bumble's simulated
        # RF medium - the same arrangement Bleak's VHCI integration tests use.
        #
        # A bare Controller is not enough: with no host attached it never
        # advertises, so there is nothing for Windows to discover. It needs a
        # Device driving it.
        peer_controller = WindowsCompatController(
            "peer", link=link, public_address=peer_address
        )
        peer_device = Device(
            name=peer_name,
            address=hci.Address(peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS),
            host=Host(peer_controller, peer_controller),
        )
        # Standard services (GAP, GATT) plus ours, so the peer looks like an
        # ordinary device rather than one with a single orphan service.
        peer_device.add_default_services()
        peer_device.add_service(build_peer_service())

        await peer_device.power_on()
        # Which address the peer advertises from, PUBLIC or RANDOM.
        #
        # RANDOM is Bumble's default and is what Windows discovered during M3.
        # PUBLIC looks more correct on paper - aa:bb:cc:dd:ee:ff is not a
        # well-formed random static address, whose top two bits would have to be
        # set - but it is worth being able to switch, because the two differ in
        # what Windows will then try to connect to.
        #
        # auto_restart, because a connection stops advertising and the peer
        # should become discoverable again after a disconnect.
        own_address_type = (
            hci.OwnAddressType.PUBLIC
            if peer_address_type == "public"
            else hci.OwnAddressType.RANDOM
        )
        await peer_device.start_advertising(
            own_address_type=own_address_type,
            auto_restart=True,
        )
        print(
            f"peer '{peer_name}' at {peer_address} advertising on the link",
            flush=True,
        )
        print(f"  service {PEER_SERVICE_UUID}", flush=True)
        print(f"    read   {PEER_READ_UUID}  = {PEER_READ_VALUE!r}", flush=True)
        print(f"    write  {PEER_WRITE_UUID}", flush=True)
        print(f"    notify {PEER_NOTIFY_UUID}", flush=True)

    async with await open_transport(spec) as transport:
        source, sink = transport.source, transport.sink
        controller = WindowsCompatController(
            "winvhci",
            host_source=source,
            host_sink=sink,
            link=link,
            # An explicit address matters: without one the controller reports
            # 00:00:00:00:00:00 to Read_BD_ADDR, and an all-zero address is not
            # a plausible identity for a host stack to build on.
            public_address=address,
        )
        if dual_mode:
            apply_dual_mode(controller)
            print("advertising BR/EDR + LE (BR_EDR_NOT_SUPPORTED cleared)", flush=True)

        print(f"controller ready: {controller.name}", flush=True)
        print(f"  lmp_features = 0x{int(controller.lmp_features):016x}", flush=True)
        print("waiting for HCI traffic (Ctrl+C to stop)", flush=True)

        # Nothing else to do; the controller drives itself from the transport.
        await asyncio.Event().wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6402)
    parser.add_argument(
        "--peer",
        action="store_true",
        help="also attach a second controller to the link, so there is a device to discover",
    )
    parser.add_argument(
        "--address",
        default="F0:F1:F2:F3:F4:F5",
        help="public BD_ADDR for the controller Windows talks to",
    )
    parser.add_argument(
        "--peer-address",
        default="AA:BB:CC:DD:EE:FF",
        help="public BD_ADDR for the discoverable peer, with --peer",
    )
    parser.add_argument(
        "--peer-name",
        default="BumblePeer",
        help="advertised name for the discoverable peer, with --peer",
    )
    parser.add_argument(
        "--dual-mode",
        action="store_true",
        help="clear BR_EDR_NOT_SUPPORTED, so the controller claims BR/EDR as well as LE",
    )
    parser.add_argument(
        "--peer-address-type",
        choices=("random", "public"),
        default="random",
        help="address type the peer advertises from, with --peer",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        asyncio.run(
            run(
                args.host,
                args.port,
                args.peer,
                args.address,
                args.peer_address,
                args.peer_name,
                args.dual_mode,
                args.peer_address_type,
            )
        )
    except KeyboardInterrupt:
        print("stopped", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
