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
    [int]   $SettleSec = 30
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
