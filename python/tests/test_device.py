"""Unit tests for :class:`winvhci.device.VhciDevice` against a fake kernel32.

The real device needs Windows, the driver and elevation; these need none of
that. The fake reproduces exactly the Win32 shapes the class depends on - a
read that pends, an event that is or is not signalled, a handle that has been
closed - so the two lifecycle bugs found by review can be shown and kept fixed
anywhere the test suite runs:

* a device closed and opened again had every read return b'' immediately,
  because close() set the closing flag and nothing cleared it;
* close() from another thread closed the handles while the reader was between
  its wait and GetOverlappedResult, so the reader raised VhciError instead of
  returning b'' as the docstring promised.
"""

from __future__ import annotations

import ctypes

import pytest

import winvhci.device as device_module
from winvhci.device import VhciDevice, VhciError

ERROR_INVALID_HANDLE = 6
ERROR_IO_PENDING = 997
WAIT_OBJECT_0 = 0
WAIT_TIMEOUT = 258

PACKET = bytes([0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00])


class FakeWinError(OSError):
    """An OSError carrying ``winerror``, as ctypes.WinError produces on Windows.

    Built by hand so the tests also run where ctypes has no WinError.
    """

    def __init__(self, code: int) -> None:
        super().__init__(code, f'fake win32 error {code}')
        self.winerror = code


class FakeKernel32:
    """Just enough of kernel32 for open, read and close.

    Handles are small integers handed out in sequence; a closed handle goes
    into ``closed`` and any call using it fails with ERROR_INVALID_HANDLE, which
    is what the real thing does. ``data`` is what the next read completes with;
    ``on_wait`` is a hook the tests use to act "from another thread" while the
    reader is inside WaitForSingleObject.
    """

    def __init__(self) -> None:
        self.next_handle = 0x100
        self.closed: set[int] = set()
        self.data = b''
        self.buffer = None
        self.on_wait = None
        self.cancelled = 0

    def _check(self, handle: int) -> None:
        if handle in self.closed:
            raise FakeWinError(ERROR_INVALID_HANDLE)

    def _new_handle(self) -> int:
        self.next_handle += 1
        return self.next_handle

    def CreateFile(self, **_kwargs) -> int:
        return self._new_handle()

    def CreateEvent(self, **_kwargs) -> int:
        return self._new_handle()

    def ResetEvent(self, hEvent: int) -> None:
        self._check(hEvent)

    def ReadFile(self, hFile: int, lpBuffer, nNumberOfBytesToRead: int, lpOverlapped) -> None:
        self._check(hFile)
        self.buffer = lpBuffer
        raise FakeWinError(ERROR_IO_PENDING)

    def WaitForSingleObject(self, hHandle: int, dwMilliseconds: int) -> int:
        if self.on_wait is not None:
            hook, self.on_wait = self.on_wait, None
            result = hook()
            if result is not None:
                return result
        self._check(hHandle)
        return WAIT_OBJECT_0 if self.data else WAIT_TIMEOUT

    def GetOverlappedResult(self, hFile: int, lpOverlapped) -> int:
        self._check(hFile)
        ctypes.memmove(self.buffer, self.data, len(self.data))
        return len(self.data)

    def CancelIoEx(self, hFile: int, lpOverlapped=None) -> bool:
        self.cancelled += 1
        return True

    def CloseHandle(self, hObject: int) -> bool:
        self.closed.add(hObject)
        return True


@pytest.fixture
def fake(monkeypatch) -> FakeKernel32:
    api = FakeKernel32()
    monkeypatch.setattr(device_module, '_api', lambda: api)
    return api


def test_a_reopened_device_still_reads(fake: FakeKernel32):
    device = VhciDevice()
    device.open()
    device.close()

    device.open()
    fake.data = PACKET
    try:
        # Before the fix this returned b'' at once: the closing flag from the
        # first close() was still set, so the pending read cancelled itself.
        assert device.read() == PACKET
    finally:
        device.close()


def test_close_from_another_thread_ends_a_read_quietly(fake: FakeKernel32):
    device = VhciDevice()
    device.open()

    def close_while_waiting():
        # Simulates close() landing on another thread while the reader is in
        # WaitForSingleObject. Its CancelIoEx completes the read, so the wait
        # then returns signalled - and the handles are already closed by the
        # time the reader reaches GetOverlappedResult.
        device.close()
        return WAIT_OBJECT_0

    fake.on_wait = close_while_waiting

    # Before the fix: VhciError('GetOverlappedResult failed: ... 6').
    assert device.read() == b''
    assert device.closed


def test_a_closing_read_reaps_its_request(fake: FakeKernel32):
    """After CancelIoEx the reader collects the request before returning.

    The read buffer is a local, and with buffered I/O the kernel writes into
    it when the request completes, which is after CancelIoEx returns. So the
    reader must wait for and collect the cancelled request rather than drop
    the buffer on the floor.
    """
    device = VhciDevice()
    device.open()
    reaped = []

    original = fake.GetOverlappedResult

    def recording(hFile, lpOverlapped):
        reaped.append(hFile)
        return original(hFile, lpOverlapped)

    fake.GetOverlappedResult = recording

    def mark_closing():
        device._closing.set()
        return WAIT_TIMEOUT

    fake.on_wait = mark_closing

    assert device.read() == b''
    assert fake.cancelled == 1
    assert reaped, 'the cancelled read was never collected'
    device.close()


def test_read_error_without_a_close_is_still_an_error(fake: FakeKernel32):
    """Tolerating failures after close() must not swallow real ones."""
    device = VhciDevice()
    device.open()

    def break_the_wait():
        raise FakeWinError(ERROR_INVALID_HANDLE)

    fake.on_wait = break_the_wait
    with pytest.raises(VhciError):
        device.read()
    device.close()
