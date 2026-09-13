"""Tests for the Bumble compatibility shims.

These need neither Windows nor a driver, and exist because the shims reach into
Bumble's internals: they subclass Controller, extend its supported-commands
declaration and override HCI handlers. Bumble is free to change any of that, and
when it does the failure is not subtle - importing the module raises - but it is
invisible until something tries.

That is not hypothetical. `Controller.supported_commands | {...}` worked against
the Bumble this project installs and failed with a TypeError against the 0.0.226
that Bleak pins, because the attribute changed from a bitmask to a set. It was
found by running Bleak's test suite, not by anything here, which is why these
exist now.
"""

from __future__ import annotations

import asyncio
import logging

import pytest

import bumble
from bumble import hci
from bumble.controller import Controller

from winvhci.bumble_compat import (
    DUAL_MODE_LMP_FEATURES,
    SUPERSEDED_HANDLERS,
    WindowsCompatController,
    WindowsCompatLink,
    apply_dual_mode,
)

#: Commands Bumble implements but does not advertise, plus the ones the shim
#: adds handlers for. Windows only sends a command its controller advertises, so
#: an unadvertised-but-implemented command is invisible - which is how LE host
#: support silently stayed off.
EXPECTED_EXTRA_COMMANDS = [
    hci.HCI_WRITE_LE_HOST_SUPPORT_COMMAND,
    hci.HCI_READ_LE_HOST_SUPPORT_COMMAND,
    hci.HCI_READ_LOCAL_EXTENDED_FEATURES_COMMAND,
    hci.HCI_WRITE_SCAN_ENABLE_COMMAND,
    hci.HCI_WRITE_VOICE_SETTING_COMMAND,
]


def _supported_command_mask(controller: type[Controller]) -> int:
    """The advertised commands as one integer, whichever shape Bumble uses."""
    value = controller.supported_commands
    if isinstance(value, (set, frozenset)):
        mask = 0
        for opcode in value:
            mask |= hci.HCI_SUPPORTED_COMMANDS_MASKS.get(opcode, 0)
        return mask
    return int.from_bytes(value, 'little')


def test_module_imports_against_the_installed_bumble():
    """The regression test proper: the shim's class body must execute.

    Everything else here would fail at collection time anyway, but stating it
    separately means the report names the actual problem.
    """
    assert WindowsCompatController is not None
    assert issubclass(WindowsCompatController, Controller)


def test_supported_commands_keeps_bumbles_own():
    """Extending must not drop what Bumble already advertised."""
    base = _supported_command_mask(Controller)
    extended = _supported_command_mask(WindowsCompatController)
    assert extended & base == base


@pytest.mark.parametrize('opcode', EXPECTED_EXTRA_COMMANDS)
def test_supported_commands_adds_the_missing_ones(opcode: int):
    mask = hci.HCI_SUPPORTED_COMMANDS_MASKS.get(opcode)
    assert mask, f'bumble has no mask for opcode {opcode:#06x}'
    assert _supported_command_mask(WindowsCompatController) & mask, (
        f'opcode {opcode:#06x} is not advertised, so Windows will never send it'
    )


def test_supported_commands_has_the_same_shape_as_bumbles():
    """Whatever representation Bumble uses, the override must match it.

    Returning a set where Bumble expects a bitmask would not raise here - it
    would produce a wrong Read_Local_Supported_Commands reply on the wire, which
    is a far more expensive way to find out.
    """
    assert isinstance(
        WindowsCompatController.supported_commands,
        type(Controller.supported_commands),
    )


@pytest.mark.parametrize('opcode', EXPECTED_EXTRA_COMMANDS)
@pytest.mark.asyncio
async def test_read_local_supported_commands_advertises_them(opcode: int):
    """The same wire-path check for supported_commands.

    The type assertion above would catch a shape mismatch, but only this proves
    Bumble can actually turn the value into a reply - which is the step that
    broke for lmp_features while a value-equality assertion stayed green.
    """
    controller = WindowsCompatController('test', link=WindowsCompatLink())
    reply = controller.on_hci_read_local_supported_commands_command(
        hci.HCI_Read_Local_Supported_Commands_Command()
    )
    assert reply is not None
    assert reply.status == hci.HCI_ErrorCode.SUCCESS

    advertised = int.from_bytes(reply.supported_commands, 'little')
    mask = hci.HCI_SUPPORTED_COMMANDS_MASKS[opcode]
    assert advertised & mask, (
        f'opcode {opcode:#06x} is not in the reply, so Windows will never send it'
    )


def test_le_states_is_the_value_windows_needs():
    # Bumble's own value makes Windows abandon LE bring-up; this is the
    # empirical value that gets it to a fully capable adapter.
    assert WindowsCompatController.le_states == bytes.fromhex('ffffffffffff0300')


@pytest.mark.asyncio
async def test_apply_dual_mode_answers_read_local_supported_features():
    """Ask the controller the question Windows asks, and read the reply.

    Deliberately not `assert controller.lmp_features == DUAL_MODE_LMP_FEATURES`.
    That assertion passed against every Bumble version while the feature was
    completely broken on 0.0.226, because assigning the attribute always works -
    it is Bumble's own use of it that fails. Up to 0.0.226 lmp_features IS the
    byte mask and gets sliced; an integer there raises

        TypeError: 'int' object is not subscriptable

    inside Bumble, which logs and swallows it, so the controller never answers
    and Windows waits forever. Going through the handler is what makes that
    visible here rather than in a consumer's test suite.

    async because Controller.__init__ creates a future, so it needs a running
    loop even though nothing here awaits.
    """
    controller = WindowsCompatController('test', link=WindowsCompatLink())
    apply_dual_mode(controller)

    reply = controller.on_hci_read_local_supported_features_command(
        hci.HCI_Read_Local_Supported_Features_Command()
    )
    assert reply is not None
    assert reply.status == hci.HCI_ErrorCode.SUCCESS

    features = int.from_bytes(reply.lmp_features, 'little')
    assert features == DUAL_MODE_LMP_FEATURES & ((1 << 64) - 1)

    # Octet 4 bit 5 is BR_EDR_NOT_SUPPORTED and bit 6 is LE_SUPPORTED. Windows
    # stops dead right after this command unless the controller looks dual-mode.
    octet4 = (features >> 32) & 0xFF
    assert not octet4 & (1 << 5), 'BR_EDR_NOT_SUPPORTED must be clear'
    assert octet4 & (1 << 6), 'LE_SUPPORTED must be set'


def test_the_windows_handlers_are_present():
    """Each handler corresponds to a place the Windows stack stopped.

    A single "Unknown HCI Command" reply makes BthPort restart its whole
    initialisation sequence, forever, so losing one of these to a refactor is
    expensive to diagnose from the Windows side.
    """
    for name in (
        'on_hci_write_scan_enable_command',
        'on_hci_write_local_name_command',
        'on_hci_write_voice_setting_command',
        'on_hci_read_inquiry_response_transmit_power_level_command',
    ):
        assert hasattr(WindowsCompatController, name), f'{name} is missing'


def test_no_handler_shadows_bumbles_own():
    """The shim must never stand in front of a real Bumble implementation.

    Every handler here is a stub that answers with a status and stores nothing,
    which is the correct thing to do for a command Bumble does not implement
    and the wrong thing to do for one it does. By 0.0.234 Bumble had
    implemented five of them for real, and four of those five keep state the
    stubs discarded - write_simple_pairing_mode updates lmp_features,
    write_local_name stores local_name, write_scan_enable stores
    classic_scan_enable, write_synchronous_flow_control_enable stores
    sync_flow_control. Windows sends all four during bring-up.

    The module drops such stubs at import time, so this asserts the outcome
    rather than the mechanism: whatever Bumble is installed, nothing in this
    package is hiding it.
    """
    shadowing = sorted(
        name
        for name in vars(WindowsCompatController)
        if name.startswith('on_hci_') and hasattr(Controller, name)
    )
    assert not shadowing, (
        f'these stubs shadow Bumble {bumble.__version__} implementations: '
        f'{shadowing}'
    )


def test_superseded_handlers_are_actually_bumbles():
    """Whatever was dropped must really exist on Bumble's controller.

    Guards the drop from going too far: an over-eager rule that removed a
    handler Bumble does not implement would put back the original failure -
    BthPort restarting its initialisation forever on one "Unknown HCI Command"
    - and it would only show up on Windows.
    """
    for name in SUPERSEDED_HANDLERS:
        assert hasattr(Controller, name), (
            f'{name} was dropped as superseded, but Bumble '
            f'{bumble.__version__} does not implement it'
        )


@pytest.mark.asyncio
async def test_raw_reply_handlers_answer_once_and_quietly(caplog):
    """A connection-time command gets exactly one Command Complete, and no ERROR.

    Bumble 0.0.234 models LE_Set_Data_Length as a synchronous command, so the
    handler has to return the parameters for Bumble to send. The shim used to
    send its own Command Complete and return None, which was right on the wire
    and wrong in the log: Bumble reported "Sync command handlers should return
    parameters, got None" for every one, on a command Windows issues for every
    LE connection. Whichever shape the installed Bumble has, the host must see
    one reply carrying status SUCCESS and the handle, and nothing must be
    logged at ERROR.
    """
    controller = WindowsCompatController('test', link=WindowsCompatLink())
    sent: list[bytes] = []

    class Host:
        def on_packet(self, packet: bytes) -> None:
            sent.append(bytes(packet))

    controller.host = Host()
    command = hci.HCI_LE_Set_Data_Length_Command(
        connection_handle=0x0040, tx_octets=27, tx_time=328
    )

    with caplog.at_level(logging.ERROR, logger='bumble.controller'):
        controller.on_hci_command_packet(command)
        # send_hci_packet hands the bytes to the host via call_soon.
        await asyncio.sleep(0)

    errors = [r.getMessage() for r in caplog.records if r.levelno >= logging.ERROR]
    assert not errors, f'Bumble complained: {errors}'

    assert len(sent) == 1, f'expected one reply, got {len(sent)}'
    reply = sent[0]
    # 04 (H4 event) 0E (Command Complete) <len> <num packets> <opcode lo hi>
    # <return parameters>. The parameters are status then the handle.
    assert reply[0:2] == bytes([0x04, 0x0E])
    assert int.from_bytes(reply[4:6], 'little') == command.op_code
    assert reply[6:] == bytes([hci.HCI_ErrorCode.SUCCESS]) + (0x0040).to_bytes(2, 'little')
