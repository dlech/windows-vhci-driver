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

from bumble import core, hci
from bumble.controller import Controller
from bumble.device import Device
from bumble.gatt import Characteristic, Service
from bumble.host import Host
from bumble.link import LocalLink

from bumble.transport import open_transport


# Company identifier reported for the remote end of a connection. 0xFFFF is the
# "no specific company" value from the Bluetooth assigned numbers, which is the
# honest answer for a simulated peer.
REMOTE_COMPANY_ID = 0xFFFF


class WindowsCompatLink(LocalLink):
    """LocalLink that routes LE ACL data by the address the connection uses.

    Bumble's LocalLink.send_acl_data hard-codes, for LE, that the source of a
    packet is the sending controller's RANDOM address:

        source_address = sender_controller.random_address

    That holds for two Bumble Devices talking to each other, because a Bumble
    Device sets a random address when it powers on. It does not hold for
    Windows. Windows connects as central using its PUBLIC identity address -
    the ConnectInd carries initiator_address=F0:F1:F2:F3:F4:F5/PUBLIC_DEVICE -
    and never issues LE_Set_Random_Address for the central role, so
    random_address stays at its default 00:00:00:00:00:00.

    The result is completely silent. The link is established, both hosts see
    HCI_LE_Connection_Complete, and then the peer receives every ATT packet
    stamped with a source address it has no connection for:

        WARNING bumble.controller: !!! no connection for 00:00:00:00:00:00

    so it drops them and answers nothing. Windows waits out its GATT timeout and
    surfaces GattCommunicationStatus.Unreachable, which points at the radio
    rather than at address bookkeeping in the simulated link.

    The controller already records the right answer. Each Connection carries a
    `self_address` - the address that connection was actually established with -
    so use it, and fall back to Bumble's behaviour when there is no matching
    connection.
    """

    def send_acl_data(self, sender_controller, destination_address, transport, data):
        if transport == core.PhysicalTransport.LE:
            for connection in sender_controller.le_connections.values():
                if connection.peer_address == destination_address:
                    destination_controller = self.find_le_controller(destination_address)
                    if destination_controller is not None:
                        source_address = connection.self_address
                        asyncio.get_running_loop().call_soon(
                            lambda: destination_controller.on_link_acl_data(
                                source_address, transport, data
                            )
                        )
                    return

        super().send_acl_data(sender_controller, destination_address, transport, data)


class RawReturnParameters(bytes):
    """Command Complete return parameters for a command bumble.hci cannot model.

    Serialises as the bytes it is. The only reason it is not a plain `bytes` is
    that Bumble formats every outgoing packet into a debug string as it sends
    it - unconditionally, in an f-string, whatever the log level - and that
    formatting calls `to_string()` on the return parameters. Plain bytes have no
    such method, so sending one raises inside the transport rather than
    anywhere near the handler that produced it.
    """

    def to_string(self, *_args, **_kwargs) -> str:
        return self.hex()

    def __str__(self) -> str:
        return self.hex()


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

    It also FIXES THE SUPPORTED-COMMANDS BITMASK, which turned out to matter
    more than the handlers. Bumble implements write_le_host_support,
    read_le_host_support and read_local_extended_features but does not list them
    in supported_commands. Windows only sends a command its controller
    advertises, so it never sent Write_LE_Host_Support, LE host support was
    never enabled, and BluetoothAdapter.IsLowEnergySupported stayed False even
    though the controller reported LE_SUPPORTED_CONTROLLER and Windows happily
    issued other LE commands. An unadvertised-but-implemented command is
    invisible.
    """

    # LE Supported States (Core spec 7.8.27).
    #
    # Bumble reports ffff3fffff030000. Windows queries this and then abandons
    # the LE bring-up: it never sends LE_Read_Buffer_Size,
    # LE_Read_White_List_Size, Write_LE_Host_Support or
    # LE_Read_Advertising_Channel_Tx_Power, and BluetoothAdapter reports
    # IsLowEnergySupported = False. A controller reporting the value below
    # instead makes Windows continue and end up with a fully capable adapter
    # (IsLowEnergySupported, IsCentralRoleSupported and
    # IsPeripheralRoleSupported all True), so this is where the two diverge.
    #
    # Which specific state bits Windows insists on has not been narrowed down;
    # this is the empirical value that works, not a claim about the minimum.
    le_states = bytes.fromhex('ffffffffffff0300')

    supported_commands = Controller.supported_commands | {
        # Implemented by Bumble, but missing from its bitmask.
        hci.HCI_WRITE_LE_HOST_SUPPORT_COMMAND,
        hci.HCI_READ_LE_HOST_SUPPORT_COMMAND,
        hci.HCI_READ_LOCAL_EXTENDED_FEATURES_COMMAND,
        hci.HCI_WRITE_CLASS_OF_DEVICE_COMMAND,
        hci.HCI_WRITE_EXTENDED_INQUIRY_RESPONSE_COMMAND,
        # Implemented by the handlers below.
        hci.HCI_WRITE_AUTHENTICATION_ENABLE_COMMAND,
        hci.HCI_WRITE_PAGE_TIMEOUT_COMMAND,
        hci.HCI_WRITE_PAGE_SCAN_ACTIVITY_COMMAND,
        hci.HCI_WRITE_INQUIRY_SCAN_ACTIVITY_COMMAND,
        hci.HCI_WRITE_INQUIRY_MODE_COMMAND,
        hci.HCI_WRITE_SCAN_ENABLE_COMMAND,
        hci.HCI_WRITE_LOCAL_NAME_COMMAND,
        hci.HCI_WRITE_SIMPLE_PAIRING_MODE_COMMAND,
        hci.HCI_WRITE_SECURE_CONNECTIONS_HOST_SUPPORT_COMMAND,
        hci.HCI_WRITE_CONNECTION_ACCEPT_TIMEOUT_COMMAND,
        hci.HCI_WRITE_PAGE_SCAN_TYPE_COMMAND,
        hci.HCI_WRITE_VOICE_SETTING_COMMAND,
        hci.HCI_WRITE_SYNCHRONOUS_FLOW_CONTROL_ENABLE_COMMAND,
        hci.HCI_READ_INQUIRY_RESPONSE_TRANSMIT_POWER_LEVEL_COMMAND,
    }

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

    # ---- connection-time commands ------------------------------------------
    #
    # Everything above is initialisation. The handlers below are what Windows
    # sends once an LE connection exists, and they were all missing for the same
    # structural reason: Bumble advertises 70 commands in `supported_commands`
    # and implements handlers for only 44 of them. The other 26 are advertised,
    # so a host sends them, and then fall through to a path that answers
    # nothing.
    #
    # Several of these have no return-parameter class in bumble.hci at all,
    # which makes Bumble treat them as asynchronous commands and discard the
    # unknown-command status its own fallback produced. Hence the raw helper
    # below rather than a returned object.

    @staticmethod
    def _connection_handle(command) -> int:
        """The connection handle a command refers to.

        Some of these commands bumble.hci models with named fields and some it
        does not model at all - an unmodelled one arrives as a plain HCI_Command
        whose `parameters` are the raw bytes. Every command here begins with a
        2-octet little-endian connection handle either way.
        """
        handle = getattr(command, "connection_handle", None)
        if handle is not None:
            return handle
        return int.from_bytes(command.parameters[:2], "little")

    def _command_complete(self, command, payload: bytes) -> None:
        """Send a Command Complete carrying raw return parameters.

        For commands bumble.hci has no ReturnParameters class for. The bytes are
        the return parameters exactly as the Core specification lays them out,
        starting with the status octet.
        """
        self.send_hci_packet(
            hci.HCI_Command_Complete_Event(
                num_hci_command_packets=1,
                command_opcode=command.op_code,
                return_parameters=RawReturnParameters(payload),
            )
        )

    def on_hci_le_read_channel_map_command(self, command):
        """Status, handle, and a 5-octet channel map.

        All 37 data channels in use: 0x1FFFFFFFFF, little-endian. A simulated
        link has no adaptive frequency hopping to report, so the honest answer
        is the full map.
        """
        self._command_complete(
            command,
            bytes([hci.HCI_ErrorCode.SUCCESS])
            + self._connection_handle(command).to_bytes(2, "little")
            + bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x1F]),
        )
        return None

    def on_hci_le_set_data_length_command(self, command):
        """Accept the requested PDU length; reply is status and handle."""
        self._command_complete(
            command,
            bytes([hci.HCI_ErrorCode.SUCCESS])
            + self._connection_handle(command).to_bytes(2, "little"),
        )
        return None

    def on_hci_read_authenticated_payload_timeout_command(self, command):
        """Status, handle, timeout in units of 10 ms. 0x0BB8 is the 30 s default."""
        self._command_complete(
            command,
            bytes([hci.HCI_ErrorCode.SUCCESS])
            + self._connection_handle(command).to_bytes(2, "little")
            + (0x0BB8).to_bytes(2, "little"),
        )
        return None

    def on_hci_write_authenticated_payload_timeout_command(self, command):
        self._command_complete(
            command,
            bytes([hci.HCI_ErrorCode.SUCCESS])
            + self._connection_handle(command).to_bytes(2, "little"),
        )
        return None

    def on_hci_le_connection_update_command(self, command):
        """Command Status now, LE Connection Update Complete after.

        The simulated link has no real timing to negotiate, so accept the
        central's maximum interval and report it as the one in force.
        """
        self._send_hci_command_status(hci.HCI_COMMAND_STATUS_PENDING, command.op_code)
        self.send_hci_packet(
            hci.HCI_LE_Connection_Update_Complete_Event(
                status=hci.HCI_ErrorCode.SUCCESS,
                connection_handle=self._connection_handle(command),
                connection_interval=command.connection_interval_max,
                peripheral_latency=command.max_latency,
                supervision_timeout=command.supervision_timeout,
            )
        )
        return None

    def on_hci_le_set_phy_command(self, command):
        """Command Status now, LE PHY Update Complete after.

        Always LE 1M in both directions (PHY value 1): there is no radio here,
        so there is nothing for 2M or Coded to mean.
        """
        self._send_hci_command_status(hci.HCI_COMMAND_STATUS_PENDING, command.op_code)
        self.send_hci_packet(
            hci.HCI_LE_PHY_Update_Complete_Event(
                status=hci.HCI_ErrorCode.SUCCESS,
                connection_handle=self._connection_handle(command),
                tx_phy=1,
                rx_phy=1,
            )
        )
        return None

    def on_hci_read_rssi_command(self, command):
        """A plausible fixed RSSI. This one does have a ReturnParameters class."""
        return hci.HCI_Read_RSSI_ReturnParameters(
            status=hci.HCI_ErrorCode.SUCCESS,
            handle=command.handle,
            rssi=-50,
        )

    def on_hci_read_remote_version_information_command(self, command):
        """Answer the first command Windows sends on a new LE connection.

        This one is different from the configuration setters above, in two ways.

        It is a command that completes with an EVENT rather than a Command
        Complete: the reply is a Command Status saying "pending", and the actual
        answer arrives later as HCI_Read_Remote_Version_Information_Complete.
        Bumble's convention for that shape is to return None and send both
        packets by hand.

        And it is not missing from `supported_commands` - it is already there.
        Bumble advertises the command and then has no handler for it, which is
        the exact inverse of the missing-bitmask-entry problem, and worse: the
        unsupported-command path returns a status object from what the caller
        treats as an async handler, so Bumble logs

            ERROR: Async command handlers should return None, got
            status: UNKNOWN_HCI_COMMAND_ERROR

        and sends NOTHING back. Windows waits, times out, drops the link, and
        the whole thing surfaces as GattCommunicationStatus.Unreachable from a
        service discovery - with no hint that a single unanswered HCI command
        is the cause.
        """
        self._send_hci_command_status(hci.HCI_COMMAND_STATUS_PENDING, command.op_code)
        self.send_hci_packet(
            hci.HCI_Read_Remote_Version_Information_Complete_Event(
                status=hci.HCI_ErrorCode.SUCCESS,
                connection_handle=self._connection_handle(command),
                version=hci.HCI_VERSION_BLUETOOTH_CORE_5_0,
                manufacturer_name=REMOTE_COMPANY_ID,
                subversion=0,
            )
        )
        return None

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
