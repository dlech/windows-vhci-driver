"""Unit tests for the transport's wiring, with no driver and no elevation.

These run anywhere, including on Linux, and exist to catch the failure mode that
would otherwise only show up on a runner: Bumble changing the shape of
``PumpedPacketSource`` / ``PumpedPacketSink`` / ``PumpedTransport`` under us.
That would break ``winvhci.transport`` while every driver-level test kept
passing, because nothing else in this repository touches those classes.

test_transport.py is the end-to-end counterpart and needs a real device.
"""

from __future__ import annotations

import asyncio

import pytest

pytestmark = pytest.mark.asyncio

#: The driver's control reply: FF FF <opcode> <id_lo> <id_hi>, little-endian id.
CONTROL_REPLY = bytes([0xFF, 0xFF, 0x00, 0x05, 0x00])
CONTROL_REQUEST = bytes([0xFF, 0x00])

#: A Command Complete for HCI_Reset - any non-vendor packet will do, but a real
#: one makes a failure easier to read.
HCI_EVENT = bytes([0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00])


class FakeDevice:
    """Stands in for :class:`winvhci.device.VhciDevice`.

    Answers the control request the way the driver does, and treats an empty
    read as the close signal, which is the contract the real device follows.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.writes: list[bytes] = []
        self.queue: asyncio.Queue[bytes] = asyncio.Queue()
        self.was_closed = False

    def open(self) -> None:
        pass

    async def read_async(self) -> bytes:
        return await self.queue.get()

    async def write_async(self, data: bytes) -> None:
        self.writes.append(bytes(data))
        if bytes(data) == CONTROL_REQUEST:
            self.queue.put_nowait(CONTROL_REPLY)

    def close(self) -> None:
        self.was_closed = True
        self.queue.put_nowait(b'')


@pytest.fixture
def fake_transport_module(monkeypatch):
    import winvhci.transport as transport_module

    monkeypatch.setattr(transport_module, 'VhciDevice', FakeDevice)
    return transport_module


async def _wait_for(predicate, what: str, timeout: float = 2.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        if predicate():
            return
        await asyncio.sleep(0.01)
    pytest.fail(f'timed out waiting for: {what}')


async def test_asks_for_a_radio_on_open(fake_transport_module):
    transport = await fake_transport_module.open_winvhci_transport()
    try:
        await _wait_for(lambda: transport.device.writes,
                        'the control request to be written')
        # Bumble writes the same two bytes to /dev/vhci. If this stops being the
        # first thing sent, no radio is ever created.
        assert transport.device.writes[0] == CONTROL_REQUEST
    finally:
        await transport.close()


async def test_reports_the_radio_id_and_swallows_the_reply(fake_transport_module):
    transport = await fake_transport_module.open_winvhci_transport()
    fed: list[bytes] = []
    try:
        transport.source.parser.feed_data = lambda data: fed.append(bytes(data))
        await _wait_for(lambda: transport.radio_id is not None,
                        'the radio id to be parsed')
        assert transport.radio_id == 5
        # The reply is our own control channel and means nothing to a
        # controller, so forwarding it would corrupt the HCI stream.
        assert CONTROL_REPLY not in fed
    finally:
        await transport.close()


async def test_ordinary_packets_reach_the_parser(fake_transport_module):
    transport = await fake_transport_module.open_winvhci_transport()
    fed: list[bytes] = []
    try:
        transport.source.parser.feed_data = lambda data: fed.append(bytes(data))
        transport.device.queue.put_nowait(HCI_EVENT)
        await _wait_for(lambda: HCI_EVENT in fed, 'the event to reach the parser')
    finally:
        await transport.close()


async def test_close_closes_the_device(fake_transport_module):
    """Closing the handle is what destroys the radio, so it must be guaranteed."""
    transport = await fake_transport_module.open_winvhci_transport()
    await transport.close()
    assert transport.device.was_closed


async def test_a_closed_device_terminates_the_source_cleanly(fake_transport_module):
    """An empty read is a deliberate close, not an error.

    The source raises CancelledError so PumpedPacketSource completes its
    `terminated` future with a result rather than an exception. If that changed,
    a normal shutdown would start surfacing as a transport failure.
    """
    transport = await fake_transport_module.open_winvhci_transport()
    transport.device.queue.put_nowait(b'')
    await _wait_for(lambda: transport.source.terminated.done(),
                    'the source to terminate')
    assert transport.source.terminated.exception() is None
    await transport.close()


async def test_close_closes_the_device_even_when_the_pumps_fail(
    fake_transport_module, monkeypatch
):
    """The comment claimed "unconditionally" long before the code delivered it.

    A pump that raised on the way down skipped the device close entirely.
    Because the device is exclusive, the leaked handle then locked out every
    later open until the garbage collector happened to reclaim it, and the
    error that arrived blamed the DACL rather than naming a handle still in
    use.

    This test is the evidence for the bug. It was found while chasing an
    unrelated fault, and the access-denied errors that prompted the look had a
    different cause - a second test loop still running and holding the device -
    so nothing observed at the time demonstrated this path.
    """
    from bumble.transport.common import PumpedTransport

    transport = await fake_transport_module.open_winvhci_transport()

    async def boom(self):
        raise RuntimeError('a pump failed on the way down')

    monkeypatch.setattr(PumpedTransport, 'close', boom)

    # The error must still propagate - swallowing it would trade one silent
    # failure for another.
    with pytest.raises(RuntimeError):
        await transport.close()

    assert transport.device.was_closed


async def test_a_failed_setup_closes_the_device(fake_transport_module, monkeypatch):
    """The window between opening the handle and returning the transport.

    Everything after the open - starting the pumps, asking for the radio,
    wrapping the snooper - has to hand the handle back if it raises, or the
    caller has no reference with which to close it.
    """
    from bumble.transport.common import PumpedTransport

    created: list[FakeDevice] = []

    class RecordingDevice(FakeDevice):
        def __init__(self, path: str) -> None:
            super().__init__(path)
            created.append(self)

    monkeypatch.setattr(fake_transport_module, 'VhciDevice', RecordingDevice)

    def boom(self):
        raise RuntimeError('the pumps would not start')

    monkeypatch.setattr(PumpedTransport, 'start', boom)

    with pytest.raises(RuntimeError):
        await fake_transport_module.open_winvhci_transport()

    assert created, 'the device was never constructed'
    assert created[0].was_closed
