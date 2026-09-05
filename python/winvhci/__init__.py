"""Userspace client for the winvhci virtual Bluetooth HCI controller.

:mod:`winvhci.device` is the device itself and depends on nothing but ctypes.
:mod:`winvhci.transport` adapts it to Bumble and is imported separately, so that
a caller who only wants to drive the device does not need Bumble installed.
"""

from winvhci.device import (
    DEFAULT_DEVICE_PATH,
    MAX_H4_PACKET,
    VhciDevice,
    VhciError,
    VhciStats,
)

__all__ = [
    'DEFAULT_DEVICE_PATH',
    'MAX_H4_PACKET',
    'VhciDevice',
    'VhciError',
    'VhciStats',
    '__version__',
]

__version__ = '1.1.0'
