"""A Bumble transport for ``\\\\.\\WinVhci``.

This is deliberately a near-copy of Bumble's own ``bumble/transport/vhci.py``,
because the driver's control protocol was modelled on Linux's ``/dev/vhci`` and
is compatible with it. Bumble's version writes ``FF 00`` to ask the kernel for a
controller and swallows any packet whose first byte is ``0xFF``; this driver
answers that same request with ``FF FF <opcode> <id_lo> <id_hi>``
(``winvhci/user.c``), which that filter already tolerates.

What does *not* carry over is the layer underneath. Bumble opens ``/dev/vhci``
with ``open_file_transport``, which relies on asyncio's Unix file-descriptor
readers; a Windows device handle is neither a socket nor a pipe, so the source
and sink here pump :mod:`winvhci.device` on threads instead.

Usage from a test fixture::

    from winvhci.transport import open_winvhci_transport

    async with await open_winvhci_transport() as transport:
        controller = Controller(
            'winvhci', host_source=transport.source, host_sink=transport.sink)
        ...

The radio exists for exactly as long as that block, because its lifetime is the
device handle's lifetime.
"""

from __future__ import annotations

import asyncio
import logging

from bumble.transport.common import (
    PumpedPacketSink,
    PumpedPacketSource,
    PumpedTransport,
    Transport,
)

from winvhci.device import DEFAULT_DEVICE_PATH, VhciDevice

__all__ = ['open_winvhci_transport', 'install_transport_scheme']

logger = logging.getLogger(__name__)

#: H4 packet type for a vendor packet, and the controller type asked for. The
#: same two bytes Bumble writes to /dev/vhci.
HCI_VENDOR_PKT = 0xFF
HCI_BREDR = 0x00


class _WinVhciTransport(PumpedTransport):
    """A :class:`PumpedTransport` that also owns the device handle.

    ``radio_id`` is the id the driver reported when it created the radio. It is
    only useful for diagnostics - correlating a log here with the
    ``WINVHCI\\RADIO\\...`` instance PnP reports - but that correlation is
    exactly what is wanted when a test fails.
    """

    def __init__(
        self,
        source: PumpedPacketSource,
        sink: PumpedPacketSink,
        device: VhciDevice,
    ) -> None:
        super().__init__(source, sink)
        self.device = device
        self.radio_id: int | None = None

    async def close(self) -> None:
        await super().close()
        # Closing the handle is what destroys the radio PDO, so it happens last
        # and unconditionally.
        await asyncio.to_thread(self.device.close)


async def open_winvhci_transport(spec: str | None = None) -> Transport:
    """Open the virtual controller device and ask it for a radio.

    ``spec`` is an optional device path, defaulting to ``\\\\.\\WinVhci``. It
    exists so a caller can point at a differently named device rather than
    because one is expected.
    """
    device = VhciDevice(spec or DEFAULT_DEVICE_PATH)
    await asyncio.to_thread(device.open)

    transport: _WinVhciTransport

    async def receive() -> bytes:
        while True:
            packet = await device.read_async()
            if not packet:
                # The device was closed. Raising CancelledError is not a hack
                # here: PumpedPacketSource treats it as the ordinary end of the
                # pump and completes `terminated` with a result rather than an
                # exception, which is what a deliberate close should look like.
                raise asyncio.CancelledError()

            if packet[0] == HCI_VENDOR_PKT:
                # Our own control channel, meaningless to the controller, so it
                # must never reach the parser. FF FF <opcode> <id_lo> <id_hi>.
                if len(packet) == 5:
                    transport.radio_id = packet[3] | (packet[4] << 8)
                    logger.info('radio %d created', transport.radio_id)
                continue

            return packet

    async def send(packet: bytes) -> None:
        await device.write_async(packet)

    source = PumpedPacketSource(receive)
    sink = PumpedPacketSink(send)
    transport = _WinVhciTransport(source, sink, device)

    # Start the pumps before asking for the radio: the sink queues packets and
    # only its pump drains them, so a request written first would sit in the
    # queue until something else happened to be sent.
    transport.start()
    sink.on_packet(bytes([HCI_VENDOR_PKT, HCI_BREDR]))

    return transport


def install_transport_scheme() -> None:
    """Teach ``bumble.transport.open_transport`` about ``winvhci:``.

    Optional, and it reaches into a private function: Bumble dispatches transport
    specs through a hardcoded if/elif chain with no registry, so there is no
    supported hook. Prefer calling :func:`open_winvhci_transport` directly; this
    exists only for callers that must express the transport as a config string.
    """
    import bumble.transport as bumble_transport

    original = bumble_transport._open_transport  # type: ignore[attr-defined]

    async def _open_transport(name: str) -> Transport:
        scheme, _, spec = name.partition(':')
        if scheme == 'winvhci':
            return await open_winvhci_transport(spec or None)
        return await original(name)

    bumble_transport._open_transport = _open_transport  # type: ignore[attr-defined]
