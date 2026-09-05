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

_ERROR_IO_PENDING = 997
_ERROR_OPERATION_ABORTED = 995
_ERROR_ACCESS_DENIED = 5
_ERROR_FILE_NOT_FOUND = 2

_WAIT_OBJECT_0 = 0
_WAIT_TIMEOUT = 258

#: How long a blocking read waits before looking at the closing flag again.
#: ``CancelIoEx`` is also issued on close, so this is a backstop rather than the
#: mechanism; it only bounds how long a reader can outlive its device.
_READ_POLL_MS = 250


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


def _kernel32():
    # WinDLL, not CDLL: these are stdcall on x86. Declaring argtypes and
    # restypes is not optional either - without them ctypes truncates HANDLEs
    # to a C int on 64-bit, which fails in a way that looks like a bad handle.
    lib = ctypes.WinDLL('kernel32', use_last_error=True)

    lib.CreateFileW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
        wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    lib.CreateFileW.restype = wintypes.HANDLE

    lib.ReadFile.argtypes = [
        wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(_OVERLAPPED),
    ]
    lib.ReadFile.restype = wintypes.BOOL

    lib.WriteFile.argtypes = [
        wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(_OVERLAPPED),
    ]
    lib.WriteFile.restype = wintypes.BOOL

    lib.GetOverlappedResult.argtypes = [
        wintypes.HANDLE, ctypes.POINTER(_OVERLAPPED),
        ctypes.POINTER(wintypes.DWORD), wintypes.BOOL,
    ]
    lib.GetOverlappedResult.restype = wintypes.BOOL

    lib.CreateEventW.argtypes = [
        ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR,
    ]
    lib.CreateEventW.restype = wintypes.HANDLE

    lib.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    lib.WaitForSingleObject.restype = wintypes.DWORD

    lib.ResetEvent.argtypes = [wintypes.HANDLE]
    lib.ResetEvent.restype = wintypes.BOOL

    lib.CancelIoEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(_OVERLAPPED)]
    lib.CancelIoEx.restype = wintypes.BOOL

    lib.CloseHandle.argtypes = [wintypes.HANDLE]
    lib.CloseHandle.restype = wintypes.BOOL

    return lib


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
        self._lib = _kernel32()
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

        # Share mode 0. The driver is exclusive anyway
        # (WdfDeviceInitSetExclusive), so asking for sharing would only make the
        # failure arrive later and less clearly.
        handle = self._lib.CreateFileW(
            self.path,
            _GENERIC_READ | _GENERIC_WRITE,
            0,
            None,
            _OPEN_EXISTING,
            _FILE_FLAG_OVERLAPPED,
            None,
        )
        if handle == _INVALID_HANDLE_VALUE or handle is None:
            error = ctypes.get_last_error()
            raise VhciError(_explain_open_failure(self.path, error))

        self._handle = handle
        try:
            self._read_event = self._create_event()
            self._write_event = self._create_event()
        except Exception:
            self.close()
            raise

        self._read_ov.hEvent = self._read_event
        self._write_ov.hEvent = self._write_event

    def _create_event(self) -> int:
        # Manual reset, initially unsignalled - the same shape vhci-io.ps1 uses.
        event = self._lib.CreateEventW(None, True, False, None)
        if not event:
            raise VhciError(
                f'CreateEvent failed ({ctypes.get_last_error()})')
        return event

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
            self._lib.CancelIoEx(handle, ctypes.byref(self._read_ov))
            self._lib.CloseHandle(handle)
        for attr in ('_read_event', '_write_event'):
            event = getattr(self, attr)
            if event:
                self._lib.CloseHandle(event)
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
        self._lib.ResetEvent(event)

        ok = self._lib.ReadFile(
            handle, buffer, MAX_H4_PACKET, None, ctypes.byref(self._read_ov))
        if not ok:
            error = ctypes.get_last_error()
            if error == _ERROR_OPERATION_ABORTED:
                return b''
            if error != _ERROR_IO_PENDING:
                raise VhciError(f'ReadFile failed ({error})')

            while True:
                if self._closing.is_set():
                    self._lib.CancelIoEx(handle, ctypes.byref(self._read_ov))
                    return b''
                wait = self._lib.WaitForSingleObject(event, _READ_POLL_MS)
                if wait == _WAIT_OBJECT_0:
                    break
                if wait != _WAIT_TIMEOUT:
                    raise VhciError(
                        f'WaitForSingleObject failed ({ctypes.get_last_error()})')

        transferred = wintypes.DWORD(0)
        if not self._lib.GetOverlappedResult(
                handle, ctypes.byref(self._read_ov),
                ctypes.byref(transferred), False):
            error = ctypes.get_last_error()
            if error == _ERROR_OPERATION_ABORTED:
                return b''
            raise VhciError(f'GetOverlappedResult(read) failed ({error})')

        return bytes(buffer[:transferred.value])

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
            self._lib.ResetEvent(event)
            ok = self._lib.WriteFile(
                handle, buffer, len(data), None, ctypes.byref(self._write_ov))
            if not ok:
                error = ctypes.get_last_error()
                if error != _ERROR_IO_PENDING:
                    raise VhciError(f'WriteFile failed ({error})')
                wait = self._lib.WaitForSingleObject(event, 5000)
                if wait != _WAIT_OBJECT_0:
                    self._lib.CancelIoEx(
                        handle, ctypes.byref(self._write_ov))
                    raise VhciError('WriteFile did not complete within 5s')

            transferred = wintypes.DWORD(0)
            if not self._lib.GetOverlappedResult(
                    handle, ctypes.byref(self._write_ov),
                    ctypes.byref(transferred), False):
                raise VhciError(
                    f'GetOverlappedResult(write) failed '
                    f'({ctypes.get_last_error()})')

        if transferred.value != len(data):
            raise VhciError(
                f'short write: {transferred.value} of {len(data)} bytes')

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
