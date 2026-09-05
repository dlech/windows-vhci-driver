# One-shot installer for a winvhci driver package.
#
#     .\install-winvhci.ps1                        install from this directory
#     .\install-winvhci.ps1 -PackageDir C:\pkg     install from elsewhere
#     .\install-winvhci.ps1 -AllowInteractiveUsers let normal users open the
#                                                  device (see below)
#     .\install-winvhci.ps1 -Uninstall             remove everything it added
#
# Run elevated. This is the same script CI runs and the same script a release
# download contains, deliberately: an installer that only ever runs on a user's
# machine is an installer nobody has tested.
#
# It refuses rather than half-installing. A test-signed driver silently fails to
# load when Secure Boot is on, and a self-signed one cannot load under memory
# integrity at all, so each prerequisite is named and checked up front and an
# unmet one exits 2.
#
# Exit codes:
#   0  installed (or uninstalled) successfully
#   1  something failed unexpectedly
#   2  a prerequisite is not met - nothing was changed
#   3  the user declined at the prompt

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [string]$PackageDir = $PSScriptRoot,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch]$Uninstall,

    # Relax the device DACL so an unelevated interactive user can open
    # \\.\WinVhci.
    #
    # Understand what this grants. Whoever holds that handle IS the radio: they
    # can feed arbitrary HCI events to the local Bluetooth stack and see
    # everything the stack sends. That is why winvhci.inx restricts it to SYSTEM
    # and Administrators by default. This switch is for a development machine
    # where the tests should not need an elevated shell - not for a machine that
    # matters.
    [switch]$AllowInteractiveUsers,

    [switch]$NoPrompt,

    [string]$HardwareId = 'root\winvhci'
)

$ErrorActionPreference = 'Stop'

# The locked-down descriptor winvhci.inx installs, and the relaxed one.
#   D:P            discretionary ACL, protected: no inherited entries
#   (A;;GA;;;SY)   GENERIC_ALL to SYSTEM
#   (A;;GA;;;BA)   GENERIC_ALL to the built-in Administrators group
#   (A;;GRGW;;;IU) GENERIC_READ|GENERIC_WRITE to INTERACTIVE users
$SddlDefault = 'D:P(A;;GA;;;SY)(A;;GA;;;BA)'
$SddlRelaxed = 'D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Fail-Prerequisite([string]$What, [string]$Fix) {
    Write-Host "  BLOCKED  $What" -ForegroundColor Red
    Write-Host "           $Fix" -ForegroundColor DarkGray
    $script:blocked++
}

# The SetupAPI shim that creates the root-enumerated node. Kept as one
# implementation rather than copied in here: CI exercises it on every run, and a
# second copy would be the one that rots.
function Get-DevnodeScript {
    $candidates = @(
        (Join-Path $PSScriptRoot 'vhci-devnode.ps1'),
        (Join-Path $PSScriptRoot 'ci\vhci-devnode.ps1'),
        (Join-Path $PackageDir  'vhci-devnode.ps1')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    throw "vhci-devnode.ps1 not found. Looked in: $($candidates -join '; ')"
}

# Filter on Service, which Get-PnpDevice already returns, rather than looking up
# DEVPKEY_Device_HardwareIds for every device on the machine - that is a separate
# call per device and takes over a minute. -PresentOnly matters too: without it
# Get-PnpDevice also reports devices that are merely REMEMBERED, so an assertion
# about the device going away could never pass.
function Get-Fdo {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Service -eq 'winvhci' } | Select-Object -First 1
}

# The machine type in the PE header, so a mismatched download is named as such.
# Getting this wrong otherwise fails opaquely: the INF's [Standard.NTARM64...]
# section simply does not apply and Windows reports no matching driver.
function Get-PeMachine([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $machine  = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    switch ($machine) {
        0x8664  { 'x64' }
        0xAA64  { 'ARM64' }
        0x014C  { 'x86' }
        default { "unknown (0x{0:X4})" -f $machine }
    }
}

function Remove-VhciCertificates([string]$Cer) {
    $thumbprint = $null
    if ($Cer -and (Test-Path $Cer)) {
        $thumbprint = ([System.Security.Cryptography.X509Certificates.X509Certificate2]::
                        CreateFromCertFile((Resolve-Path $Cer).Path)).GetCertHashString()
    }
    foreach ($store in 'Root', 'TrustedPublisher') {
        Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue |
            Where-Object {
                if ($thumbprint) { $_.Thumbprint -eq $thumbprint }
                else { $_.Subject -like '*winvhci*' }
            } |
            ForEach-Object {
                Write-Host "  removing $($_.Thumbprint) from LocalMachine\$store"
                Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue
            }
    }
}

# pnputil identifies a package by its INF version, not its contents, so a stale
# driver store entry means a later install silently keeps the OLD binary.
#
# Parse as records: pnputil prints Published Name BEFORE Original Name, so
# pairing them the other way round matches nothing at all and deletes nothing.
function Remove-VhciDriverStoreEntries {
    $published = $null
    pnputil /enum-drivers | ForEach-Object {
        if ($_ -match '^\s*Published Name:\s*(oem\d+\.inf)') {
            $published = $Matches[1]
        } elseif ($_ -match '^\s*Original Name:\s*winvhci\.inf' -and $published) {
            $published
            $published = $null
        }
    } | Sort-Object -Unique | ForEach-Object {
        Write-Host "  removing driver store entry $_"
        pnputil /delete-driver $_ /uninstall /force 2>&1 | Out-Null
    }
}

function Set-DeviceSecurity([string]$InstanceId, [string]$Sddl) {
    # The PnP manager reads this value when it creates the device object, and
    # \\.\WinVhci is a symbolic link to that object - so the change takes effect
    # on the next device start, which is why the caller restarts the device.
    #
    # Administrators have KEY_ALL_ACCESS on the Enum subtree, so this does not
    # need to run as SYSTEM.
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId"
    if (-not (Test-Path $key)) {
        throw "device key not found: $key"
    }
    $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor($Sddl)
    $binary = New-Object byte[] $sd.BinaryLength
    $sd.GetBinaryForm($binary, 0)
    Set-ItemProperty -Path $key -Name 'Security' -Value $binary `
                     -Type Binary -Force
    Write-Host "  Security = $Sddl"
}

# ---------------------------------------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'BLOCKED  not running elevated' -ForegroundColor Red
    Write-Host '         Start an elevated PowerShell and run this again.' -ForegroundColor DarkGray
    exit 2
}

$devnode = Get-DevnodeScript

if ($Uninstall) {
    Write-Step 'Uninstalling'

    & $devnode -Remove
    Remove-VhciDriverStoreEntries

    $cer = Join-Path $PSScriptRoot 'winvhci-test.cer'
    if (-not (Test-Path $cer)) { $cer = $null }
    Remove-VhciCertificates $cer

    if (Get-Fdo) {
        Write-Host 'FAILED: the device is still present' -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    Write-Host 'Uninstalled.' -ForegroundColor Green
    exit 0
}

# ---- install --------------------------------------------------------------

$PackageDir = (Resolve-Path $PackageDir).Path

# Accept either the package directory itself or a release tree that contains it,
# so an unzipped download works without the caller reading the layout.
$pkg = $PackageDir
if (-not (Test-Path (Join-Path $pkg 'winvhci.inf'))) {
    $nested = Join-Path $PackageDir 'package'
    if (Test-Path (Join-Path $nested 'winvhci.inf')) { $pkg = $nested }
}
$inf = Join-Path $pkg 'winvhci.inf'
$sys = Join-Path $pkg 'winvhci.sys'

$cer = Join-Path $PackageDir 'winvhci-test.cer'
if (-not (Test-Path $cer)) {
    $alt = Join-Path $pkg 'winvhci-test.cer'
    if (Test-Path $alt) { $cer = $alt }
}

Write-Step 'Prerequisites'
$script:blocked = 0

if (-not (Test-Path $inf)) {
    Fail-Prerequisite "no driver package at $pkg" `
        'Point -PackageDir at the directory holding winvhci.inf.'
}

if (Test-Path $sys) {
    $packageArch = Get-PeMachine $sys
    $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    # OSArchitecture reports X64 / Arm64; normalise before comparing. Note the
    # PROCESSOR_ARCHITECTURE environment variable is NOT usable here - it
    # reports the architecture of the current PROCESS, so an emulated x64
    # PowerShell on an ARM64 machine reports AMD64.
    $osNormalised = switch ($osArch) {
        'X64'   { 'x64' }
        'Arm64' { 'ARM64' }
        default { $osArch }
    }
    Write-Host "  package is $packageArch, this machine is $osNormalised"
    if ($packageArch -ne $osNormalised) {
        Fail-Prerequisite "package architecture $packageArch does not match $osNormalised" `
            'Download the package built for this machine.'
    }
}

$bcd = bcdedit /enum '{current}' | Out-String
if ($bcd -match 'testsigning\s+Yes') {
    Write-Host '  test signing is enabled'
} else {
    Fail-Prerequisite 'test signing is not enabled' `
        'bcdedit /set testsigning on, then reboot. Windows will show a Test Mode watermark.'
}

# Secure Boot must be off. This is the quiet one: with Secure Boot on, Windows
# IGNORES the testsigning flag entirely, so bcdedit reports Yes and the driver
# still refuses to load.
$secureBoot = $null
try { $secureBoot = Confirm-SecureBootUEFI } catch { $secureBoot = $null }
if ($secureBoot -eq $true) {
    Fail-Prerequisite 'Secure Boot is enabled' `
        'Windows ignores testsigning while Secure Boot is on. Disable it in firmware.'
} elseif ($null -eq $secureBoot) {
    Write-Host '  Secure Boot state unknown (legacy BIOS or not queryable)'
} else {
    Write-Host '  Secure Boot is off'
}

$dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
if ($dg -and $dg.SecurityServicesRunning -contains 2) {
    Fail-Prerequisite 'memory integrity (HVCI) is running' `
        'A self-signed driver cannot load under HVCI. Turn off Core Isolation > Memory Integrity, then reboot.'
} else {
    Write-Host '  memory integrity is not running'
}

if (-not (Test-Path $cer)) {
    Fail-Prerequisite 'no certificate found next to the package' `
        'winvhci-test.cer must accompany the package so its signer can be trusted.'
}

if ($script:blocked -gt 0) {
    Write-Host ''
    Write-Host "$($script:blocked) prerequisite(s) not met. Nothing was changed." -ForegroundColor Red
    exit 2
}

$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::
            CreateFromCertFile((Resolve-Path $cer).Path)

if (-not $NoPrompt) {
    Write-Host ''
    Write-Host 'This will:' -ForegroundColor Yellow
    Write-Host "  * trust the certificate $($cert.Subject)"
    Write-Host "    thumbprint $($cert.GetCertHashString())"
    Write-Host '    by adding it to LocalMachine\Root and LocalMachine\TrustedPublisher'
    Write-Host "  * install $inf and create the device node $HardwareId"
    if ($AllowInteractiveUsers) {
        Write-Host '  * allow any interactive user to open the device, which lets them'
        Write-Host '    inject arbitrary HCI into this machine''s Bluetooth stack'
    }
    Write-Host ''
    Write-Host 'Undo all of it with:  .\install-winvhci.ps1 -Uninstall'
    Write-Host ''
    $answer = Read-Host 'Continue? [y/N]'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host 'Declined; nothing was changed.'
        exit 3
    }
}

Write-Step 'Trusting the certificate'
# Both stores are required: Root alone leaves pnputil rejecting the package as
# being from an untrusted publisher.
#
# TrustedPublisher must exist before the import. On some machines the key is
# absent and Import-Certificate then fails with "Access Denied" instead of
# creating it.
$tp = 'HKLM:\Software\Microsoft\SystemCertificates\TrustedPublisher'
if (-not (Test-Path $tp)) {
    New-Item -Path $tp -ItemType RegistryKey -Force | Out-Null
    Write-Host "  created $tp"
}
foreach ($store in 'Root', 'TrustedPublisher') {
    Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    Write-Host "  added to LocalMachine\$store"
}

Write-Step 'Installing the driver package'
# An untrusted or expired signer makes pnputil HANG rather than fail, so this
# gets a hard timeout instead of an unbounded wait.
$log = Join-Path $env:TEMP 'winvhci-pnputil.log'
$proc = Start-Process pnputil.exe -ArgumentList @('/add-driver', $inf, '/install') `
            -NoNewWindow -PassThru -RedirectStandardOutput $log

# Reading .Handle is not redundant: Start-Process -PassThru returns a Process
# that has not cached the native handle, and once it exits ExitCode reads back
# empty. Touching .Handle while it is alive caches it.
$null = $proc.Handle

if (-not $proc.WaitForExit(120000)) {
    $proc.Kill()
    Write-Host 'FAILED: pnputil hung for 120s, which is almost always a certificate trust problem' -ForegroundColor Red
    exit 1
}
$rc = $proc.ExitCode
if (Test-Path $log) {
    Get-Content $log | ForEach-Object { Write-Host "  $_" }
}

# 259 = ERROR_NO_MORE_ITEMS, what /install returns when no matching device
# exists yet - precisely this case, since the node is created next.
# 3010 = ERROR_SUCCESS_REBOOT_REQUIRED, which must not be swallowed.
if ($rc -eq 3010) {
    Write-Host 'FAILED: pnputil asked for a reboot (3010). Reboot and run this again.' -ForegroundColor Red
    exit 1
}
if ($rc -notin @(0, 259)) {
    Write-Host "FAILED: pnputil exited $rc" -ForegroundColor Red
    exit 1
}

Write-Step 'Creating the device node'
# Idempotent: a node left over from an earlier install is reused rather than
# duplicated, since a second root-enumerated node would give two radios
# competing for one exclusive device.
$fdo = Get-Fdo
if ($fdo) {
    Write-Host "  already present: $($fdo.InstanceId)"
} else {
    & $devnode -Create -Inf $inf
    $fdo = Get-Fdo
}

$deadline = (Get-Date).AddSeconds(30)
while ((-not $fdo -or $fdo.Status -ne 'OK') -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $fdo = Get-Fdo
}
if (-not $fdo) {
    Write-Host 'FAILED: no winvhci device appeared' -ForegroundColor Red
    exit 1
}
if ($fdo.Status -ne 'OK') {
    Write-Host "FAILED: device is present but not started: $($fdo.Status) / $($fdo.Problem)" -ForegroundColor Red
    exit 1
}
Write-Host "  $($fdo.InstanceId)  status $($fdo.Status)"

if ($AllowInteractiveUsers) {
    Write-Step 'Relaxing the device security descriptor'
    Set-DeviceSecurity $fdo.InstanceId $SddlRelaxed
    # The descriptor is applied when the device object is created, so the
    # running device still has the old one until it restarts.
    & $devnode -Restart | Out-Null
    Write-Host '  any interactive user can now open \\.\WinVhci'
    Write-Host "  undo with: .\install-winvhci.ps1 -Uninstall, or set Security back to $SddlDefault" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Installed.' -ForegroundColor Green
Write-Host "  device      \\.\WinVhci"
Write-Host "  instance    $($fdo.InstanceId)"
Write-Host ''
Write-Host 'The radio appears only while a client holds the device open - that is by' -ForegroundColor DarkGray
Write-Host 'design, the radio''s lifetime is the handle''s lifetime.' -ForegroundColor DarkGray
exit 0
