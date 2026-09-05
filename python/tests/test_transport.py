"""End-to-end test of the Python client against the installed driver.

This is the counterpart to build/ci/smoke.ps1's Tier 2, taken through the path a
consumer actually uses: the Python transport rather than the PowerShell bridge.
It is what keeps actions/install honest - an action nobody runs is an action
that has stopped working.

Requires the driver installed and an elevated session. Skips rather than fails
when either is missing, so `pytest` on a developer machine without the driver
does not report a false problem.

    python -m pytest python/tests -v
"""

from __future__ import annotations

import asyncio
import json
import subprocess
import sys

import pytest

pytestmark = [
    pytest.mark.skipif(sys.platform != 'win32', reason='Windows only'),
    pytest.mark.asyncio,
]

HARDWARE_ID = 'root\\winvhci'
PEER_ADDRESS = 'AA:BB:CC:DD:EE:FF'
CONTROLLER_ADDRESS = 'F0:F1:F2:F3:F4:F5'


def _powershell(script: str) -> str:
    # Windows PowerShell, not pwsh: Get-PnpDevice comes from the PnpDevice
    # module, which is not present in PowerShell 7 on every image.
    result = subprocess.run(
        ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
         '-Command', script],
        capture_output=True, text=True, timeout=120,
    )
    return result.stdout.strip()


def _radio() -> dict | None:
    """The radio PDO as PnP sees it, or None.

    -PresentOnly matters: without it Get-PnpDevice also reports devices that are
    merely REMEMBERED, so an assertion about the radio going away could never
    pass.
    """
    out = _powershell(r'''
        $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -like 'WINVHCI\RADIO*' } |
             Select-Object -First 1
        if (-not $d) { '' ; exit }
        $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId `
                  -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
        $svc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId `
                  -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
        @{ instanceId = $d.InstanceId; status = "$($d.Status)";
           inf = "$inf"; service = "$svc" } | ConvertTo-Json -Compress
    ''')
    return json.loads(out) if out else None


def _driver_installed() -> bool:
    # Filter on Service, which Get-PnpDevice already returns, rather than
    # looking up DEVPKEY_Device_HardwareIds per device: the property lookup is a
    # separate call for every device on the machine and turned this check into a
    # 90 second one. The hardware ID is then confirmed on the single match.
    return bool(_powershell(rf'''
        $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
             Where-Object {{ $_.Service -eq 'winvhci' }} | Select-Object -First 1
        if (-not $d) {{ exit }}
        $ids = (Get-PnpDeviceProperty -InstanceId $d.InstanceId `
                  -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data
        if ($ids -contains '{HARDWARE_ID}') {{ 'yes' }}
    '''))


@pytest.fixture(scope='session', autouse=True)
def require_driver():
    if not _driver_installed():
        pytest.skip('the winvhci driver is not installed on this machine')


async def _wait_for(predicate, what: str, timeout: float = 45.0):
    """Poll until predicate returns something truthy, then return it.

    No fixed sleeps: PnP is asynchronous, and a sleep long enough to be reliable
    is also long enough to be wasteful. Naming the condition means a timeout
    says what never became true.
    """
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        value = await asyncio.to_thread(predicate)
        if value:
            return value
        await asyncio.sleep(0.5)
    pytest.fail(f'timed out after {timeout}s waiting for: {what}')


async def test_radio_appears_and_windows_binds_its_stack():
    """The assertion that matters: Windows binds bth.inf to our radio.

    Installing successfully is not the same thing. com0com's root-enumerated bus
    installs and reports OK on a hosted runner while its child devices never
    enumerate - the same layer and the same failure shape - so this checks device
    state, never just that the open succeeded.
    """
    from winvhci.bumble_compat import (
        WindowsCompatController,
        WindowsCompatLink,
        apply_dual_mode,
    )
    from winvhci.transport import open_winvhci_transport

    assert _radio() is None, 'a radio is already present; is another client running?'

    transport = await open_winvhci_transport()
    try:
        # A vanilla Bumble Controller does not get Windows through bring-up -
        # see winvhci.bumble_compat for the three reasons. Using it here would
        # leave the radio stuck in CM_PROB_FAILED_POST_START and the failure
        # would look like a driver bug.
        link = WindowsCompatLink()
        controller = WindowsCompatController(
            'winvhci',
            host_source=transport.source,
            host_sink=transport.sink,
            link=link,
            public_address=CONTROLLER_ADDRESS,
        )
        apply_dual_mode(controller)

        radio = await _wait_for(
            lambda: (lambda r: r if r and r['status'] == 'OK' else None)(_radio()),
            'the radio PDO to reach Status OK',
        )

        assert radio['inf'].lower() == 'bth.inf', (
            f"expected bth.inf to bind, got {radio['inf']!r}")
        assert radio['service'].lower() == 'bthmini', (
            f"expected BthMini to be the loaded service, got {radio['service']!r}")
    finally:
        await transport.close()

    # Handle-scoped lifetime is the whole design, so its other half is worth
    # asserting too. Tearing the node down unloads BthPort's stack above it, so
    # this is not instant.
    await _wait_for(lambda: _radio() is None,
                    'the radio PDO to disappear once the client closes')


async def test_radio_id_is_reported():
    """The driver's control reply carries the radio id; keep it wired up.

    It is only used for diagnostics, but correlating a Python log with the
    WINVHCI\\RADIO instance PnP reports is exactly what is wanted when a test
    fails, so a silent regression here would be felt later.
    """
    from winvhci.transport import open_winvhci_transport

    transport = await open_winvhci_transport()
    try:
        await _wait_for(lambda: transport.radio_id is not None,
                        'the driver to report a radio id', timeout=15.0)
        assert transport.radio_id >= 1
    finally:
        await transport.close()
