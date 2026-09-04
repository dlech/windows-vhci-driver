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
from bumble.controller import Controller
from bumble.link import LocalLink

from bumble.transport import open_transport


class WindowsCompatController(Controller):
    """Bumble's controller plus the BR/EDR configuration commands Windows sends.

    Bumble targets LE and implements 48 commands, but not a handful of BR/EDR
    configuration ones. Windows' BthPort sends those during bring-up, and a
    single "Unknown HCI Command" reply makes it restart its whole initialisation
    sequence, forever.

    Every command class below already exists in bumble.hci - only the handlers
    are missing - and each is a pure configuration setter whose reply is a
    status byte. So this is a compatibility shim, not a controller: it stores
    nothing and decides nothing. It is the kind of gap that belongs upstream in
    Bumble rather than here.
    """

    def on_hci_write_authentication_enable_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_page_timeout_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_page_scan_activity_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_inquiry_scan_activity_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_inquiry_mode_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_scan_enable_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_local_name_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_simple_pairing_mode_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_secure_connections_host_support_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_connection_accept_timeout_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_page_scan_type_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_voice_setting_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_write_synchronous_flow_control_enable_command(self, _command):
        return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    def on_hci_read_inquiry_response_transmit_power_level_command(self, _command):
        return hci.HCI_Read_Inquiry_Response_Transmit_Power_Level_ReturnParameters(
            status=hci.HCI_ErrorCode.SUCCESS, tx_power=0
        )


# A realistic dual-mode LMP feature mask, page 0, as reported by a commodity
# BR/EDR + LE adapter. Little-endian octets:
#
#     bf fe cf fe db ff 7b 87
#
# Octet 4 = 0xdb has LE_SUPPORTED set (bit 6) and BR_EDR_NOT_SUPPORTED clear
# (bit 5), so this is a dual-mode controller with the usual BR/EDR feature set.
DUAL_MODE_LMP_FEATURES = 0x877BFFDBFECFFEBF


def apply_dual_mode(controller: Controller) -> None:
    """Report a realistic dual-mode LMP feature mask.

    Bumble's controller defaults to LE-only: BR_EDR_NOT_SUPPORTED set and every
    BR/EDR feature octet zero. Windows' BthPort stops dead after
    Read_Local_Supported_Features when it sees that - no further commands, no
    retry.

    Merely clearing BR_EDR_NOT_SUPPORTED is not enough; that was tried and the
    stack still stopped in exactly the same place. The relevant difference
    appears to be that all the BR/EDR feature octets are zero, i.e. a controller
    claiming BR/EDR while supporting none of its mandatory features. A
    hand-answered controller reporting this mask got the stack through its
    whole initialisation, so it is the value to compare against.

    This is a diagnostic override, not a claim Bumble can honour: it advertises
    BR/EDR features Bumble does not implement, so BR/EDR operations will fail
    later. It is here to isolate WHY the stack stops.
    """
    controller.lmp_features = DUAL_MODE_LMP_FEATURES


async def run(
    host: str,
    port: int,
    with_peer: bool,
    address: str,
    peer_address: str,
    dual_mode: bool,
) -> None:
    # A LocalLink is Bumble's simulated radio medium. Controllers attached to
    # the same link can see each other, which is how a peer device becomes
    # discoverable to Windows without any real radio.
    link = LocalLink()

    spec = f"tcp-server:{host}:{port}"
    print(f"listening for an HCI client on {spec}", flush=True)

    peer = None
    if with_peer:
        # A second controller on the same link, with no HCI host attached. It
        # exists purely so there is something in the simulated environment for
        # the Windows stack to find.
        peer = WindowsCompatController("peer", link=link, public_address=peer_address)
        print("peer controller attached to the link", flush=True)

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
        "--dual-mode",
        action="store_true",
        help="clear BR_EDR_NOT_SUPPORTED, so the controller claims BR/EDR as well as LE",
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
                args.dual_mode,
            )
        )
    except KeyboardInterrupt:
        print("stopped", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
