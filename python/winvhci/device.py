"""Overlapped I/O over ``\\\\.\\WinVhci``.

The driver's user-facing device carries H4 frames: one complete packet per
``ReadFile``, one per ``WriteFile``. There is no framing to reassemble, which is
the whole reason the transport layer above this is small.

Two constraints shape this module, and both were learned the hard way in
``tools/vhci-io.ps1``:

* **I/O must be overlapped.** A synchronous ``ReadFile`` blocks forever once the
  Bluetooth stack goes quiet, so a bounded test could never terminate and
  killing the process lost whatever it had buffered. Reads here wait on an event
  with a timeout, which also gives :meth:`VhciDevice.close` a way to stop the
  reader promptly.

* **The handle needs Administrator rights by default.** ``winvhci.inx`` sets the
  device DACL to ``D:P(A;;GA;;;SY)(A;;GA;;;BA)`` because whoever holds this
  handle is the whole radio. ``install-winvhci.ps1 -AllowInteractiveUsers``
  relaxes that for a development machine; without it, open from an elevated
  process. Note UAC means an *unelevated* shell of an administrator account is
  not enough - the Administrators SID is deny-only in that token.
"""

from __future__ import annotations

import asyncio
import ctypes
import functools
import threading
from ctypes import wintypes

__all__ = ['VhciDevice', 'VhciError', 'DEFAULT_DEVICE_PATH', 'MAX_H4_PACKET']

#: Matches ``WINVHCI_MAX_H4_PACKET`` in ``winvhci/winvhci.h``: one type byte,
#: a four byte ACL header, and ``WINVHCI_MAX_ACL_TRANSFER_IN`` of payload. A
#: short read buffer would truncate a packet rather than fail, so it is not a
#: number to guess at.
MAX_H4_PACKET = 1026

DEFAULT_DEVICE_PATH = r'\\.\WinVhci'

_GENERIC_READ = 0x80000000
_GENERIC_WRITE = 0x40000000
_OPEN_EXISTING = 3
_FILE_FLAG_OVERLAPPED = 0x40000000
_INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

_ERROR_FILE_NOT_FOUND = 2
_ERROR_ACCESS_DENIED = 5
_ERROR_OPERATION_ABORTED = 995
_ERROR_IO_PENDING = 997

# A wait that returns anything other than WAIT_OBJECT_0 timed out; WAIT_FAILED
# is turned into an exception by the errcheck handler, so the callers below only
# need to distinguish "signalled" from "not yet".
_WAIT_OBJECT_0 = 0
_WAIT_FAILED = 0xFFFFFFFF

#: How long a blocking read waits before looking at the closing flag again.
#: ``CancelIoEx`` is also issued on close, so this is a backstop rather than the
#: mechanism; it only bounds how long a reader can outlive its device.
_READ_POLL_MS = 250

#: Bound on a write. The driver queues a write and completes it, so this only
#: exists so a wedged device fails rather than hanging a test forever.
_WRITE_TIMEOUT_MS = 5000


class VhciError(Exception):
    """An error from the device or from the Win32 calls behind it."""


class _OVERLAPPED(ctypes.Structure):
    _fields_ = [
        ('Internal', ctypes.c_void_p),
        ('InternalHigh', ctypes.c_void_p),
        ('Offset', wintypes.DWORD),
        ('OffsetHigh', wintypes.DWORD),
        ('hEvent', wintypes.HANDLE),
    ]


_LPOVERLAPPED = ctypes.POINTER(_OVERLAPPED)


# -- errcheck handlers ------------------------------------------------------
#
# Each is a factory taking the function's name, because a prototyped ctypes
# function object has no __name__ to read it from - so without this every error
# message would have to say "a call failed".
#
# One subtlety governs all of them, and getting it wrong is silent: whatever
# errcheck returns becomes the result of the call, EXCEPT that returning the
# argument tuple unchanged tells ctypes to carry on and build the result from
# the out parameters. So a function with an out parameter must return `args`,
# and a function without one must not.


def _raise_last_error(func_name: str) -> None:
    # WinError formats the message for the code, so the exception reads
    # "The device is not ready" rather than just 21. winerror is preserved, and
    # callers switch on it.
    error = ctypes.WinError(ctypes.get_last_error())
    error.strerror = f'{func_name}: {error.strerror}'
    raise error


def _check_bool_with_outputs(name: str):
    """For a BOOL function that has out parameters."""
    def errcheck(result, func, args):
        if not result:
            _raise_last_error(name)
        return args
    return errcheck


def _check_bool(name: str):
    """For a BOOL function with no out parameters."""
    def errcheck(result, func, args):
        if not result:
            _raise_last_error(name)
        return None
    return errcheck


def _check_handle(name: str):
    """For a function returning a handle, NULL meaning failure."""
    def errcheck(result, func, args):
        # ctypes maps a NULL HANDLE return to None rather than 0.
        if not result:
            _raise_last_error(name)
        return result
    return errcheck


def _check_file_handle(name: str):
    """For CreateFile, whose failure value is INVALID_HANDLE_VALUE, not NULL."""
    def errcheck(result, func, args):
        if result is None or result == _INVALID_HANDLE_VALUE:
            _raise_last_error(name)
        return result
    return errcheck


def _check_wait(name: str):
    """For WaitForSingleObject, whose failure value is WAIT_FAILED."""
    def errcheck(result, func, args):
        if result == _WAIT_FAILED:
            _raise_last_error(name)
        return result
    return errcheck


@functools.lru_cache(maxsize=1)
def _api() -> '_Kernel32':
    # Built lazily and once. Lazily because importing this module must work on
    # a machine without kernel32 - the transport's wiring tests run on Linux,
    # and they are what catches Bumble changing shape underneath us. Once
    # because the prototypes are immutable and there is no reason for every
    # device to rebuild them.
    return _Kernel32()


class _Kernel32:
    """The kernel32 calls this module needs, as prototyped function objects.

    Built with ``WINFUNCTYPE`` and ``paramflags`` rather than by assigning
    ``argtypes``, which buys three things worth having here:

    * **Out parameters become return values.** ``GetOverlappedResult`` hands
      back the byte count directly instead of the caller allocating a
      ``DWORD``, taking ``byref`` of it and remembering to read ``.value``.
    * **Arguments are named**, so calls read as
      ``CreateFile(lpFileName=..., dwDesiredAccess=...)`` and the optional ones
      can simply be left out rather than passed as a bare ``None`` whose
      meaning has to be looked up.
    * **The symbol is resolved when the prototype is built**, so a misspelled
      export fails immediately and by name rather than at the first call.

    Declaring the types at all is not optional: without them ctypes truncates
    handles to a C int on 64-bit, which fails in a way that looks like a bad
    handle rather than like a binding mistake.
    """

    def __init__(self) -> None:
        kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)

        self.CreateFile = ctypes.WINFUNCTYPE(
            wintypes.HANDLE,        # returns the handle
            wintypes.LPCWSTR,       # lpFileName
            wintypes.DWORD,         # dwDesiredAccess
            wintypes.DWORD,         # dwShareMode
            ctypes.c_void_p,        # lpSecurityAttributes
            wintypes.DWORD,         # dwCreationDisposition
            wintypes.DWORD,         # dwFlagsAndAttributes
            wintypes.HANDLE,        # hTemplateFile
            use_last_error=True,
        )(
            ('CreateFileW', kernel32),
            ((1, 'lpFileName'),
             (1, 'dwDesiredAccess'),
             (1, 'dwShareMode'),
             (1, 'lpSecurityAttributes', None),
             (1, 'dwCreationDisposition'),
             (1, 'dwFlagsAndAttributes'),
             (1, 'hTemplateFile', None)),
        )
        self.CreateFile.errcheck = _check_file_handle('CreateFile')

        # lpNumberOfBytesRead is an INPUT here, always NULL, rather than an out
        # parameter. For an overlapped operation Windows may write it at
        # completion time - which is after the call has returned - so a pointer
        # into ctypes' temporary storage would be a use-after-free. The count
        # comes from GetOverlappedResult instead, which is what the API
        # documentation directs for exactly this reason.
        self.ReadFile = ctypes.WINFUNCTYPE(
            wintypes.BOOL,
            wintypes.HANDLE,                    # hFile
            ctypes.c_void_p,                    # lpBuffer
            wintypes.DWORD,                     # nNumberOfBytesToRead
            ctypes.POINTER(wintypes.DWORD),     # lpNumberOfBytesRead
            _LPOVERLAPPED,                      # lpOverlapped
            use_last_error=True,
        )(
            ('ReadFile', kernel32),
            ((1, 'hFile'),
             (1, 'lpBuffer'),
             (1, 'nNumberOfBytesToRead'),
             (1, 'lpNumberOfBytesRead', None),
             (1, 'lpOverlapped', None)),
        )
        self.ReadFile.errcheck = _check_bool('ReadFile')

        self.WriteFile = ctypes.WINFUNCTYPE(
            wintypes.BOOL,
            wintypes.HANDLE,                    # hFile
            ctypes.c_void_p,                    # lpBuffer
            wintypes.DWORD,                     # nNumberOfBytesToWrite
            ctypes.POINTER(wintypes.DWORD),     # lpNumberOfBytesWritten
            _LPOVERLAPPED,                      # lpOverlapped
            use_last_error=True,
        )(
            ('WriteFile', kernel32),
            ((1, 'hFile'),
             (1, 'lpBuffer'),
             (1, 'nNumberOfBytesToWrite'),
             (1, 'lpNumberOfBytesWritten', None),
             (1, 'lpOverlapped', None)),
        )
        self.WriteFile.errcheck = _check_bool('WriteFile')

        # The one genuine out parameter: read after the operation has completed,
        # so it returns the transferred count directly.
        self.GetOverlappedResult = ctypes.WINFUNCTYPE(
            wintypes.BOOL,
            wintypes.HANDLE,                    # hFile
            _LPOVERLAPPED,                      # lpOverlapped
            ctypes.POINTER(wintypes.DWORD),     # lpNumberOfBytesTransferred
            wintypes.BOOL,                      # bWait
            use_last_error=True,
        )(
            ('GetOverlappedResult', kernel32),
            ((1, 'hFile'),
             (1, 'lpOverlapped'),
             (2, 'lpNumberOfBytesTransferred'),
             (1, 'bWait', False)),
        )
        self.GetOverlappedResult.errcheck = _check_bool_with_outputs('GetOverlappedResult')

        self.CreateEvent = ctypes.WINFUNCTYPE(
            wintypes.HANDLE,
            ctypes.c_void_p,        # lpEventAttributes
            wintypes.BOOL,          # bManualReset
            wintypes.BOOL,          # bInitialState
            wintypes.LPCWSTR,       # lpName
            use_last_error=True,
        )(
            ('CreateEventW', kernel32),
            ((1, 'lpEventAttributes', None),
             (1, 'bManualReset', True),
             (1, 'bInitialState', False),
             (1, 'lpName', None)),
        )
        self.CreateEvent.errcheck = _check_handle('CreateEvent')

        self.WaitForSingleObject = ctypes.WINFUNCTYPE(
            wintypes.DWORD,
            wintypes.HANDLE,        # hHandle
            wintypes.DWORD,         # dwMilliseconds
            use_last_error=True,
        )(
            ('WaitForSingleObject', kernel32),
            ((1, 'hHandle'),
             (1, 'dwMilliseconds')),
        )
        self.WaitForSingleObject.errcheck = _check_wait('WaitForSingleObject')

        self.ResetEvent = ctypes.WINFUNCTYPE(
            wintypes.BOOL,
            wintypes.HANDLE,        # hEvent
            use_last_error=True,
        )(
            ('ResetEvent', kernel32),
            ((1, 'hEvent'),),
        )
        self.ResetEvent.errcheck = _check_bool('ResetEvent')

        # No errcheck on either of these. Both are called during teardown where
        # failure is expected and uninteresting: CancelIoEx returns
        # ERROR_NOT_FOUND when nothing is pending, and raising out of a close
        # path would mask whatever caused the close.
        self.CancelIoEx = ctypes.WINFUNCTYPE(
            wintypes.BOOL,
            wintypes.HANDLE,        # hFile
            _LPOVERLAPPED,          # lpOverlapped
            use_last_error=True,
        )(
            ('CancelIoEx', kernel32),
            ((1, 'hFile'),
             (1, 'lpOverlapped', None)),
        )

        self.CloseHandle = ctypes.WINFUNCTYPE(
            wintypes.BOOL,
            wintypes.HANDLE,        # hObject
            use_last_error=True,
        )(
            ('CloseHandle', kernel32),
            ((1, 'hObject'),),
        )


class VhciDevice:
    """A synchronous client for ``\\\\.\\WinVhci``.

    The radio's lifetime is this handle's lifetime: the driver creates the radio
    PDO when the control packet is written and destroys it when the handle
    closes. Closing this object is therefore how a caller takes the radio away,
    and it is why owning the handle in the test process - rather than in a
    separate bridge - gives deterministic teardown.
    """

    def __init__(self, path: str = DEFAULT_DEVICE_PATH) -> None:
        self.path = path
        self._api = _api()
        self._handle: int | None = None
        self._read_event: int | None = None
        self._write_event: int | None = None
        self._read_ov = _OVERLAPPED()
        self._write_ov = _OVERLAPPED()
        self._write_lock = threading.Lock()
        self._closing = threading.Event()

    # -- lifecycle ---------------------------------------------------------

    def open(self) -> None:
        if self._handle is not None:
            raise VhciError('already open')

        try:
            # Share mode 0. The driver is exclusive anyway
            # (WdfDeviceInitSetExclusive), so asking for sharing would only make
            # the failure arrive later and less clearly.
            self._handle = self._api.CreateFile(
                lpFileName=self.path,
                dwDesiredAccess=_GENERIC_READ | _GENERIC_WRITE,
                dwShareMode=0,
                dwCreationDisposition=_OPEN_EXISTING,
                dwFlagsAndAttributes=_FILE_FLAG_OVERLAPPED,
            )
        except OSError as error:
            raise VhciError(
                _explain_open_failure(self.path, error.winerror)) from error

        try:
            # Manual reset, initially unsignalled - the same shape
            # vhci-io.ps1 uses.
            self._read_event = self._api.CreateEvent()
            self._write_event = self._api.CreateEvent()
        except OSError as error:
            self.close()
            raise VhciError(f'CreateEvent failed: {error}') from error

        self._read_ov.hEvent = self._read_event
        self._write_ov.hEvent = self._write_event

    def close(self) -> None:
        """Close the handle, which destroys the radio.

        Safe to call from a thread other than the one blocked in :meth:`read`:
        ``CancelIoEx`` completes the pending read with
        ``ERROR_OPERATION_ABORTED`` so the reader returns promptly rather than
        waiting out its poll interval.
        """
        self._closing.set()
        handle, self._handle = self._handle, None
        if handle is not None:
            self._api.CancelIoEx(hFile=handle,
                                 lpOverlapped=ctypes.byref(self._read_ov))
            self._api.CloseHandle(hObject=handle)
        for attr in ('_read_event', '_write_event'):
            event = getattr(self, attr)
            if event:
                self._api.CloseHandle(hObject=event)
                setattr(self, attr, None)

    def __enter__(self) -> 'VhciDevice':
        self.open()
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    @property
    def closed(self) -> bool:
        return self._handle is None

    # -- I/O ---------------------------------------------------------------

    def read(self) -> bytes:
        """Return the next H4 packet, or ``b''`` once the device is closed."""
        handle = self._handle
        event = self._read_event
        if handle is None or event is None:
            return b''

        buffer = (ctypes.c_ubyte * MAX_H4_PACKET)()
        self._api.ResetEvent(hEvent=event)

        try:
            self._api.ReadFile(
                hFile=handle,
                lpBuffer=buffer,
                nNumberOfBytesToRead=MAX_H4_PACKET,
                lpOverlapped=ctypes.byref(self._read_ov),
            )
        except OSError as error:
            if error.winerror == _ERROR_OPERATION_ABORTED:
                return b''
            if error.winerror != _ERROR_IO_PENDING:
                raise VhciError(f'ReadFile failed: {error}') from error

            # Pending, which is the normal case: wait for it, in slices, so a
            # close is noticed even if CancelIoEx has not landed yet.
            while True:
                if self._closing.is_set():
                    self._api.CancelIoEx(
                        hFile=handle,
                        lpOverlapped=ctypes.byref(self._read_ov))
                    return b''
                if self._api.WaitForSingleObject(
                        hHandle=event,
                        dwMilliseconds=_READ_POLL_MS) == _WAIT_OBJECT_0:
                    break

        try:
            transferred = self._api.GetOverlappedResult(
                hFile=handle, lpOverlapped=ctypes.byref(self._read_ov))
        except OSError as error:
            if error.winerror == _ERROR_OPERATION_ABORTED:
                return b''
            raise VhciError(f'GetOverlappedResult failed: {error}') from error

        return bytes(buffer[:transferred])

    def write(self, data: bytes) -> None:
        """Write one H4 packet."""
        handle = self._handle
        event = self._write_event
        if handle is None or event is None:
            raise VhciError('device is closed')
        if not data:
            return

        buffer = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
        with self._write_lock:
            self._api.ResetEvent(hEvent=event)
            try:
                self._api.WriteFile(
                    hFile=handle,
                    lpBuffer=buffer,
                    nNumberOfBytesToWrite=len(data),
                    lpOverlapped=ctypes.byref(self._write_ov),
                )
            except OSError as error:
                if error.winerror != _ERROR_IO_PENDING:
                    raise VhciError(f'WriteFile failed: {error}') from error
                if self._api.WaitForSingleObject(
                        hHandle=event,
                        dwMilliseconds=_WRITE_TIMEOUT_MS) != _WAIT_OBJECT_0:
                    self._api.CancelIoEx(
                        hFile=handle,
                        lpOverlapped=ctypes.byref(self._write_ov))
                    raise VhciError(
                        f'WriteFile did not complete within '
                        f'{_WRITE_TIMEOUT_MS} ms')

            try:
                transferred = self._api.GetOverlappedResult(
                    hFile=handle, lpOverlapped=ctypes.byref(self._write_ov))
            except OSError as error:
                raise VhciError(
                    f'GetOverlappedResult failed: {error}') from error

        if transferred != len(data):
            raise VhciError(f'short write: {transferred} of {len(data)} bytes')

    # -- asyncio -----------------------------------------------------------
    #
    # asyncio cannot poll a device HANDLE: the proactor loop handles sockets and
    # pipes, not an arbitrary overlapped file. So the blocking calls above run
    # on threads. One thread each way, because a read blocked for minutes must
    # not delay a write.

    async def read_async(self) -> bytes:
        return await asyncio.to_thread(self.read)

    async def write_async(self, data: bytes) -> None:
        await asyncio.to_thread(self.write, data)


def _explain_open_failure(path: str, error: int) -> str:
    if error == _ERROR_ACCESS_DENIED:
        return (
            f'access denied opening {path}. The device DACL allows SYSTEM and '
            f'Administrators only; run elevated, or install with '
            f'-AllowInteractiveUsers. An unelevated shell of an administrator '
            f'account is not enough, because UAC leaves the Administrators SID '
            f'deny-only in that token.'
        )
    if error == _ERROR_FILE_NOT_FOUND:
        return (
            f'{path} does not exist. The winvhci driver is not installed, or '
            f'its device node was never created.'
        )
    return f'CreateFile({path}) failed ({error})'
