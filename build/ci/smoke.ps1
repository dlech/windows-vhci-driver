# Install winvhci and prove Windows binds its Bluetooth stack to it.
#
#     build\ci\smoke.ps1 -PackageDir out [-Json result.json]
#
# Run elevated. Leaves the machine as it found it.
#
# The assertion that matters is the last one: that bth.inf binds BthMini and
# BthPort to the radio PDO our driver invents. Installing successfully is not
# the same thing - com0com's root-enumerated bus installs and reports OK on a
# hosted runner while its child devices never enumerate, which is the same
# layer and the same failure shape. So this checks device state, never just
# exit codes.
#
# Note the radio PDO does not exist at driver start: user.c creates it only when
# a client writes the FF <opcode> control packet, and destroys it when that
# handle closes. So the test has to hold a client open, and the disappearance
# afterwards is itself worth asserting - handle-scoped lifetime is the whole
# design.

[CmdletBinding()]
param(
    [string]$PackageDir = 'out',
    [string]$ToolsDir,
    [string]$Json,
    [int]   $SettleSec = 30,

    # Tier 2: drive the radio with a real controller emulator instead of
    # vhcictl's hand-written answers, and assert that Windows builds its whole
    # Bluetooth stack on top and discovers an advertising peer.
    [switch]$Bumble,
    [string]$Python = 'python',

    # Tier 3: abuse the teardown path - which implementation-plan.md still lists
    # as the open risk - under what Verifier coverage a job without a reboot can
    # actually get, which is force-pending-I/O and IRP logging rather than the
    # standard rule set. See the arming block for why.
    [switch]$Verifier,
    [int]   $AbuseRounds = 3,

    [int]   $BumblePort = 6402,
    # Only a backstop. The bridge is killed explicitly when the tier finishes;
    # this has to comfortably outlast the assertions, because if it expires
    # early the handle closes, the radio vanishes, and every remaining check
    # fails for a reason that has nothing to do with the driver. A single
    # FindAllAsync scan can take 90 seconds on its own.
    [int]   $BumbleSec  = 600
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $ToolsDir) { $ToolsDir = Join-Path $repo 'tools' }

$PackageDir = (Resolve-Path $PackageDir).Path
$pkg        = Join-Path $PackageDir 'package'
$cer        = Join-Path $PackageDir 'winvhci-test.cer'
$inf        = Join-Path $pkg 'winvhci.inf'

$script:checks = [System.Collections.ArrayList]::new()
$script:failed = 0

function Check([string]$Name, [scriptblock]$Test, [string]$Detail = '') {
    $ok = $false; $err = ''
    try { $ok = [bool](& $Test) } catch { $err = $_.Exception.Message }
    [void]$script:checks.Add([ordered]@{ name = $Name; ok = $ok; detail = $Detail; error = $err })
    if ($ok) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
        if ($err)    { Write-Host "        $err"    -ForegroundColor DarkGray }
    }
    # Deliberately returns nothing. This is called as a statement, so a return
    # value would fall out into the output stream and print a bare True/False
    # under every result line.
}

# No fixed sleeps anywhere: PnP is asynchronous, and a Start-Sleep long enough
# to be reliable is also long enough to be wasteful. Every wait names the
# condition it is waiting for, so a timeout says what never became true.
function Wait-For([string]$What, [scriptblock]$Until, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Until) { return $true } } catch { }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "        timed out after ${TimeoutSec}s waiting for: $What" -ForegroundColor DarkGray
    return $false
}

# -PresentOnly matters. Without it Get-PnpDevice also lists devices that are
# merely REMEMBERED - phantom nodes left in the registry after removal, whose
# Status reads Unknown. A teardown assertion written against the unfiltered list
# can never pass, because the node keeps being reported long after it is gone.
function Get-Fdo {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'ROOT\SYSTEM\*' -and $_.FriendlyName -like '*Virtual Bluetooth*' } |
        Select-Object -First 1
}
function Get-Radio {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'WINVHCI\RADIO*' } |
        Select-Object -First 1
}
function Get-Prop($InstanceId, $Key) {
    (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction SilentlyContinue).Data
}

Write-Host "=== Prerequisites ===" -ForegroundColor Cyan

# Assert the platform is what we think it is. GitHub's runner images have had
# testsigning enabled at image build time since 2021 and it is covered by an
# image validation test - but if that ever regresses it must fail as itself,
# not as a mysterious driver load failure.
$bcd = bcdedit /enum '{current}' | Out-String
Check 'test signing is enabled' { $bcd -match 'testsigning\s+Yes' } `
      'bcdedit /set testsigning on, then reboot'

Check 'HVCI is not running' {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
            -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    -not ($dg -and $dg.SecurityServicesRunning -contains 2)
} 'a self-signed driver cannot load under memory integrity'

Check 'driver package is present' { Test-Path $inf } $inf
Check 'test certificate is present' { Test-Path $cer } $cer

if ($script:failed) { throw 'prerequisites not met' }

Write-Host ''
Write-Host '=== Trusting the test certificate ===' -ForegroundColor Cyan

# Both stores are required: Root alone is not enough, pnputil rejects the
# package as being from an untrusted publisher.
#
# TrustedPublisher must be created first. On some runner images the key does
# not exist and Import-Certificate then fails with "Access Denied" rather than
# creating it - a gotcha freedv-gui hit and documented.
$tp = 'HKLM:\Software\Microsoft\SystemCertificates\TrustedPublisher'
if (-not (Test-Path $tp)) {
    New-Item -Path $tp -ItemType RegistryKey -Force | Out-Null
    Write-Host "  created $tp"
}
foreach ($store in 'Root', 'TrustedPublisher') {
    Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    Write-Host "  added to LocalMachine\$store"
}

Write-Host ''
Write-Host '=== Installing ===' -ForegroundColor Cyan

# An untrusted or expired signer makes pnputil HANG rather than fail - msquic
# hit exactly this on a hosted runner and it cost them a support issue - so it
# gets a hard timeout rather than an unbounded wait.
$p = Start-Process pnputil.exe -ArgumentList @('/add-driver', $inf, '/install') `
        -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\pnputil.log"

# Reading .Handle here is not redundant. Start-Process -PassThru hands back a
# Process object that has not cached the native handle, and once the process
# exits there is nothing left to query - so ExitCode comes back empty no matter
# how carefully you wait for it. Touching .Handle while the process is still
# alive caches it, and the exit code survives.
$null = $p.Handle

if (-not $p.WaitForExit(120000)) {
    $p.Kill()
    throw 'pnputil /add-driver hung for 120s - almost certainly a certificate trust problem'
}
$rc = $p.ExitCode
Get-Content "$env:TEMP\pnputil.log" | ForEach-Object { Write-Host "  $_" }

# 259 = ERROR_NO_MORE_ITEMS, which is what /install returns when no matching
# device exists yet. That is precisely our case: the node is created below.
# 3010 = ERROR_SUCCESS_REBOOT_REQUIRED, which must not be swallowed.
Check "pnputil exit code $rc is success" { $rc -in @(0, 259) } `
      '0 = installed, 259 = added but no matching device yet, 3010 = reboot required'

& (Join-Path $PSScriptRoot 'vhci-devnode.ps1') -Create -Inf $inf

Write-Host ''
Write-Host '=== The device node ===' -ForegroundColor Cyan

Check 'FDO appears' { Wait-For 'the winvhci FDO' { Get-Fdo } 30 }
$fdo = Get-Fdo
if ($fdo) { Write-Host "  $($fdo.InstanceId)  '$($fdo.FriendlyName)'" }

Check 'FDO reaches Status OK' {
    Wait-For 'FDO Status=OK' { (Get-Fdo) -and (Get-Fdo).Status -eq 'OK' } 30
} "status was '$(if ($fdo) { $fdo.Status })', problem '$(if ($fdo) { $fdo.Problem })'"

if ($Verifier) {
    Write-Host ''
    Write-Host '=== Arming Driver Verifier ===' -ForegroundColor Cyan

    # Not /standard, and not /volatile either.
    #
    # /standard needs a reboot, which a CI job cannot do. /volatile looks like
    # the answer and is what several projects still use, but it is deprecated
    # and accepts only three flags - low resources simulation, force pending
    # I/O, IRP logging - so asking it for the standard set is refused outright:
    # "The specified flags 0x000209bb are not supported in volatile mode."
    #
    # The mechanism that does work without rebooting is DIF, dynamic
    # instrumentation, which Windows itself points at in that error. It takes
    # rule class numbers rather than a bitmask. These ten are exactly the ones
    # `verifier /?` marks (^), meaning they can be enabled without a reboot,
    # and they are the standard set plus the additional DDI compliance class:
    #
    #   1 special pool          2 force IRQL checking   4 pool tracking
    #   5 I/O verification      6 deadlock detection    8 DMA checking
    #   9 security checks      12 miscellaneous checks 18 DDI compliance
    #  20 DDI compliance (additional)
    #
    # Low resources simulation (class 3) is deliberately absent: development.md
    # records that it does not reach this driver at all - at 100% probability it
    # failed none of 24 allocations, because both allocation sites call
    # ExAllocatePool2 while holding the FDO spinlock at DISPATCH_LEVEL.
    # WvFailAllocOneIn is what exercises those paths.
    #
    # This runs after the driver has loaded, because DIF instruments a running
    # driver rather than arranging for a future one to be verified.
    # What is actually achievable here is narrower than /standard, and it is
    # worth being precise about why, because three other forms look like they
    # should work and do not.
    #
    #   verifier /dif <classes> /now [/driver winvhci.sys]
    #       Exits 1 and prints nothing, with or without /driver, on both
    #       windows-2025 and windows-11-vs2026-arm. This is the form the help
    #       text itself recommends for enabling flags without rebooting.
    #
    #   verifier /rc <classes> /driver winvhci.sys
    #       Works - it reports "Verifier Flags: 0x001a09bb" - but exits 2,
    #       meaning the settings are persistent and need a reboot. A CI job
    #       cannot reboot, so the flags would never take effect.
    #
    #   verifier /volatile /adddriver winvhci.sys
    #       Exits 0 and makes /query list the driver, which looks like success
    #       and is not: it reports "Verifier Volatile Flags: 0x00000000". The
    #       driver is enrolled with no checks enabled at all.
    #
    # So the driver has to be enrolled AND flags set, and only three flags are
    # permitted in volatile mode. Of those, randomized low resources simulation
    # (0x4) is already known not to reach this driver - development.md records
    # it failing none of 24 allocations, because both allocation sites call
    # ExAllocatePool2 under the FDO spinlock at DISPATCH_LEVEL. That leaves:
    #
    #   0x200  force pending I/O requests
    #   0x400  IRP logging
    #
    # Force pending I/O is the valuable one for this driver. It makes IRPs that
    # would have completed synchronously complete later instead, which is
    # precisely the shape of the read path - and the teardown abuse below is
    # about what happens to pended reads when their client dies.
    #
    # This is NOT the standard rule set, and it should not be described as
    # such. Special pool, IRQL checking and DDI compliance need a reboot and so
    # remain a local step, as development.md already describes.
    $volatileFlags = '0x600'

    verifier /volatile /adddriver winvhci.sys 2>&1 | ForEach-Object { Write-Host "  $_" }
    verifier /volatile /flags $volatileFlags 2>&1 | ForEach-Object { Write-Host "  $_" }

    $query = verifier /query 2>&1 | Out-String

    # Both halves, deliberately. Enrolment alone passed the previous version of
    # this check while zero flags were set, which is the exact failure mode the
    # check exists to catch.
    Check 'Verifier has winvhci.sys enrolled' { $query -match '(?i)winvhci' } `
          'verifier /query does not list the driver'
    Check 'Verifier has non-zero volatile flags' {
        if ($query -match '(?im)^\s*Verifier Volatile Flags:\s*(0x[0-9a-f]+)') {
            [Convert]::ToInt64($Matches[1], 16) -ne 0
        } else { $false }
    } 'enrolled with no checks enabled is not verification'
}

Write-Host ''
Write-Host '=== The radio, while a client holds the handle ===' -ForegroundColor Cyan

# vhcictl answers the stack's bring-up commands with plausible constants. It is
# not a controller - it exists to prove the transport works - which is exactly
# the right scope for a load smoke test.
$ctl = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $ToolsDir 'vhcictl.ps1'),
    '-Seconds', "$SettleSec"
)
Write-Host "  started vhcictl (pid $($ctl.Id)) for ${SettleSec}s"

try {
    Check 'radio PDO appears while the client is connected' {
        Wait-For 'a WINVHCI\RADIO node' { Get-Radio } 30
    } 'the PDO is created by the FF control packet, not at driver start'

    $radio = Get-Radio
    if ($radio) { Write-Host "  $($radio.InstanceId)  status $($radio.Status)" }

    # These two properties are the machine-readable form of the setupapi.dev.log
    # lines the binding was originally verified with, and unlike log text they
    # are deterministic and locale-independent.
    $infPath = if ($radio) { Get-Prop $radio.InstanceId 'DEVPKEY_Device_DriverInfPath' }
    $matchId = if ($radio) { Get-Prop $radio.InstanceId 'DEVPKEY_Device_MatchingDeviceId' }
    $service = if ($radio) { Get-Prop $radio.InstanceId 'DEVPKEY_Device_Service' }
    Write-Host "  inf '$infPath'  matching id '$matchId'  service '$service'"

    Check 'Windows bound bth.inf to the radio PDO' { $infPath -eq 'bth.inf' } `
          "DEVPKEY_Device_DriverInfPath was '$infPath'"
    Check 'the match was on MS_BTHX_BTHMINI' { "$matchId" -ieq 'ms_bthx_bthmini' } `
          "DEVPKEY_Device_MatchingDeviceId was '$matchId'"
    Check 'BthMini is the loaded service' { "$service" -ieq 'BthMini' } `
          "DEVPKEY_Device_Service was '$service'"
} finally {
    if (-not $ctl.HasExited) { $ctl.Kill(); $ctl.WaitForExit(10000) | Out-Null }
    Write-Host '  client stopped'
}

Write-Host ''
Write-Host '=== Handle-scoped lifetime ===' -ForegroundColor Cyan
Check 'radio PDO disappears when the client closes' {
    Wait-For 'the WINVHCI\RADIO node to go away' { -not (Get-Radio) } 40
} 'tearing the node down unloads BthPort''s whole stack above it, so it is not instant'

if ($Bumble) {
    Write-Host ''
    Write-Host '=== Tier 2: a real controller, and the stack Windows builds on it ===' -ForegroundColor Cyan

    # Tier 1 proves the transport. It does not prove the stack: vhcictl answers
    # with plausible constants and Windows gets no further than a radio node.
    # Only a controller that actually implements the initialisation sequence
    # makes Windows bring up the enumerator and RFCOMM nodes, and those are what
    # signal real success - see docs/controller-requirements.md.
    #
    # Bumble runs here on the runner itself, so the bridge connects to
    # 127.0.0.1 rather than the 10.0.2.2 slirp gateway the QEMU guest uses.
    . (Join-Path $ToolsDir 'winrt-await.ps1')
    $null = [Windows.Devices.Bluetooth.BluetoothAdapter, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]

    $bumbleOut = Join-Path (Get-Location) 'bumble.out.log'
    $bumbleErr = Join-Path (Get-Location) 'bumble.err.log'

    $controller = Start-Process $Python -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $bumbleOut -RedirectStandardError $bumbleErr `
        -ArgumentList @((Join-Path $ToolsDir 'bumble-controller.py'),
                        '--peer', '--dual-mode', '--host', '127.0.0.1', '--port', "$BumblePort")
    $null = $controller.Handle
    $bridge = $null

    try {
        # Wait on the log line, not on a TCP connect. Bumble's tcp-server
        # transport serves one HCI client, so probing the port would consume the
        # connection the bridge is about to need.
        Check 'Bumble controller starts and listens' {
            Wait-For 'the controller to announce its listener' {
                (Test-Path $bumbleOut) -and
                (Select-String -Path $bumbleOut -Pattern 'listening for an HCI client' -Quiet)
            } 60
        } "see bumble.out.log / bumble.err.log"

        $bridge = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $ToolsDir 'vhcibridge.ps1'),
            '-RemoteHost', '127.0.0.1', '-Port', "$BumblePort", '-Seconds', "$BumbleSec"
        )
        $null = $bridge.Handle
        Write-Host "  bridge started (pid $($bridge.Id))"

        Check 'radio reaches Status OK with a real controller' {
            Wait-For 'the radio node to come up' { (Get-Radio) -and (Get-Radio).Status -eq 'OK' } 60
        }

        # These two are the real signal. The radio node appears as soon as the
        # transport handshake completes, but BthPort only creates the enumerator
        # and RFCOMM nodes once the controller has answered the whole
        # initialisation sequence convincingly.
        Check 'Microsoft Bluetooth Enumerator appears' {
            Wait-For 'BTH\MS_BTHBRB' {
                @(Get-PnpDevice -PresentOnly -InstanceId 'BTH\MS_BTHBRB\*' -ErrorAction SilentlyContinue).Count -gt 0
            } 90
        } 'BthPort creates this only after a convincing initialisation sequence'

        Check 'RFCOMM node appears' {
            Wait-For 'BTH\MS_RFCOMM' {
                @(Get-PnpDevice -PresentOnly -InstanceId 'BTH\MS_RFCOMM\*' -ErrorAction SilentlyContinue).Count -gt 0
            } 90
        }

        Check 'bthserv is running' {
            Wait-For 'bthserv to reach Running' {
                (Get-Service bthserv -ErrorAction SilentlyContinue).Status -eq 'Running'
            } 60
        }

        # Now ask the layer an ordinary application uses.
        $adapter = $null
        Check 'BluetoothAdapter.GetDefaultAsync returns an adapter' {
            $script:adapter = Await ([Windows.Devices.Bluetooth.BluetoothAdapter]::GetDefaultAsync()) `
                                    ([Windows.Devices.Bluetooth.BluetoothAdapter]) 30000
            $null -ne $script:adapter
        } 'WinRT sees no adapter even though PnP does'

        if ($script:adapter) {
            $addr = ('{0:X12}' -f $script:adapter.BluetoothAddress) -replace '(..)(?=.)', '$1:'
            Write-Host "  adapter $addr  LE=$($script:adapter.IsLowEnergySupported) Classic=$($script:adapter.IsClassicSupported) Central=$($script:adapter.IsCentralRoleSupported)"

            # The controller is started with the default --address, so this also
            # proves Windows read BD_ADDR from the emulator rather than
            # inventing one.
            Check 'adapter address is the controller''s BD_ADDR' { $addr -eq 'F0:F1:F2:F3:F4:F5' } `
                  "expected F0:F1:F2:F3:F4:F5, got $addr"
            Check 'adapter reports LE support'      { $script:adapter.IsLowEnergySupported }
            Check 'adapter reports Classic support' { $script:adapter.IsClassicSupported } `
                  'requires --dual-mode; BR_EDR_NOT_SUPPORTED must be cleared'
            Check 'adapter supports the central role' { $script:adapter.IsCentralRoleSupported }

            Check 'radio state is On' {
                $r = Await ($script:adapter.GetRadioAsync()) ([Windows.Devices.Radios.Radio]) 15000
                $r.State -eq 'On'
            }
        }

        # Discovery, using FindAllAsync rather than a watcher: Windows
        # PowerShell 5.1 cannot subscribe to WinRT events at all, so an
        # event-driven watcher is silent here for reasons that have nothing to
        # do with the driver. FindAllAsync performs a real scan and returns a
        # collection, so it is the check that can actually fail meaningfully.
        Check 'Windows discovers the advertising peer' {
            $sel = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($false)
            $found = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)) `
                           ([Windows.Devices.Enumeration.DeviceInformationCollection]) 90000
            foreach ($d in $found) { Write-Host "    '$($d.Name)'  $($d.Id)" }
            @($found | Where-Object { $_.Name -eq 'BumblePeer' -or $_.Id -match 'aa:bb:cc:dd:ee:ff' }).Count -gt 0
        } 'the peer advertises from a random address; --peer-address-type public stops discovery working'
    }
    finally {
        foreach ($proc in $bridge, $controller) {
            if ($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(10000) | Out-Null }
        }
        Write-Host '  bridge and controller stopped'
    }

    Check 'radio goes away when the bridge dies' {
        Wait-For 'the radio node to go away' { -not (Get-Radio) } 40
    } 'the bridge is killed outright, so this is the abrupt-client-death path'
}

if ($Verifier -and $Bumble) {
    Write-Host ''
    Write-Host '=== Tier 3: teardown abuse, with pending-I/O forced ===' -ForegroundColor Cyan

    # A client dying abruptly is the NORMAL case here, not an edge case: the
    # radio's lifetime is a file handle's lifetime. When it dies the driver has
    # to complete BTHX reads the stack has pended, purge both backlogs and tear
    # the PDO down, all while the stack may still be issuing WRITE_HCI. That is
    # the race most likely to bugcheck, and a well-behaved session never touches
    # it - which is exactly why it needs its own tier rather than trusting the
    # clean shutdown Tier 2 performs.
    $controller = Start-Process $Python -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path (Get-Location) 'bumble.abuse.log') `
        -RedirectStandardError  (Join-Path (Get-Location) 'bumble.abuse.err.log') `
        -ArgumentList @((Join-Path $ToolsDir 'bumble-controller.py'),
                        '--peer', '--dual-mode', '--host', '127.0.0.1', '--port', "$BumblePort")
    $null = $controller.Handle
    try {
        Wait-For 'the controller to listen' {
            (Test-Path 'bumble.abuse.log') -and
            (Select-String -Path 'bumble.abuse.log' -Pattern 'listening for an HCI client' -Quiet)
        } 60 | Out-Null

        & (Join-Path $ToolsDir 'abuse-teardown.ps1') `
            -Rounds $AbuseRounds `
            -Bridge (Join-Path $ToolsDir 'vhcibridge.ps1') `
            -RemoteHost '127.0.0.1' -Port $BumblePort `
            -Devnode (Join-Path $PSScriptRoot 'vhci-devnode.ps1') `
            -SettleSec 12 -TeardownSec 30
        $abuseRc = $LASTEXITCODE
        Check 'teardown abuse leaves no stale radio' { $abuseRc -eq 0 } `
              "abuse-teardown.ps1 exited $abuseRc"
    }
    finally {
        if ($controller -and -not $controller.HasExited) {
            $controller.Kill(); $controller.WaitForExit(10000) | Out-Null
        }
    }

    # Verifier reports a bugcheck by bugchecking, so surviving is most of the
    # signal - but the counters say whether it was doing anything, and a run
    # where nothing was allocated proves nothing about pool handling.
    Write-Host ''
    Write-Host '--- verifier /query ---' -ForegroundColor DarkGray
    verifier /query 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-Host '=== Bugcheck check ===' -ForegroundColor Cyan
# A bugcheck during teardown that a successful reconnect papers over is exactly
# the failure this suite exists to catch, so look even when everything passed.
Check 'no bugcheck was recorded' {
    -not (Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001 } -MaxEvents 20 -ErrorAction SilentlyContinue |
          Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' })
}

Write-Host ''
Write-Host '=== Teardown ===' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'vhci-devnode.ps1') -Remove

# pnputil identifies a package by its INF version, not its contents: re-adding
# one whose DriverVer has not changed keeps the OLD binary in the driver store.
# Purging matters less on a throwaway runner than it does locally, but the same
# script serves both. Parse as records - pnputil prints Published Name BEFORE
# Original Name, so pairing them the other way round silently matches nothing.
$published = $null
pnputil /enum-drivers | ForEach-Object {
    if ($_ -match '^\s*Published Name:\s*(oem\d+\.inf)') { $published = $Matches[1] }
    elseif ($_ -match '^\s*Original Name:\s*winvhci\.inf' -and $published) { $published; $published = $null }
} | Sort-Object -Unique | ForEach-Object {
    Write-Host "  removing driver store entry $_"
    pnputil /delete-driver $_ /uninstall /force 2>&1 | Out-Null
}

Check 'nothing winvhci remains' { -not (Get-Fdo) -and -not (Get-Radio) }

if ($Verifier) {
    # Counterparts to what was actually used: the driver was enrolled with
    # /volatile /adddriver and the flags set with /volatile /flags, so both come
    # back off the same way. (/stop is for rule classes enabled via '/dif /now',
    # which is not the mechanism that worked here.)
    #
    # Nothing here reboots, so leaving verification armed for a driver that has
    # just been uninstalled would be a trap for whatever runs next.
    verifier /volatile /flags 0x0 2>&1 | ForEach-Object { Write-Host "  $_" }
    verifier /volatile /removedriver winvhci.sys 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
$total = $script:checks.Count
$colour = if ($script:failed) { 'Red' } else { 'Green' }
Write-Host "=== $($total - $script:failed)/$total checks passed ===" -ForegroundColor $colour

if ($Json) {
    [ordered]@{
        runner  = $env:RUNNER_NAME
        image   = $env:ImageOS
        passed  = $total - $script:failed
        total   = $total
        checks  = $script:checks
    } | ConvertTo-Json -Depth 5 | Set-Content $Json -Encoding UTF8
}

exit ([int]($script:failed -gt 0))
