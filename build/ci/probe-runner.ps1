# Probe a Windows machine for everything winvhci CI depends on.
#
# Written for GitHub Actions runners, but it is deliberately self-contained and
# read-only so it can also be run on a developer machine or in the QEMU guest to
# get a known-good baseline to diff against.
#
#   pwsh -File build\ci\probe-runner.ps1 -Json probe.json
#
# It answers the two questions that decide the whole CI design:
#
#   1. Is test signing already on, and is code integrity otherwise out of the
#      way?  Hosted runner images have run `bcdedit /set TESTSIGNING ON` at
#      image build time since 2021, which - if true here - removes the need for
#      a VM entirely.
#   2. Does this machine have the Bluetooth stack, and can WinRT reach it from a
#      non-interactive session?  `bth.inf` is what binds BthMini + BthPort to
#      our radio PDO, and BluetoothUserService is per-user, so a service account
#      with no interactive desktop may not be able to use the WinRT layer even
#      when the kernel side is fine.
#
# Nothing here installs, modifies or starts anything except `bthserv`, which is
# demand-start and harmless.  The script always exits 0: it is a report, not a
# test, so a missing feature must not look like infrastructure failure.

[CmdletBinding()]
param(
    [string]$Json
)

$ErrorActionPreference = 'Continue'
$script:result = [ordered]@{}

function Section([string]$Name) {
    Write-Host ''
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Note([string]$Key, $Value) {
    $script:result[$Key] = $Value
    $shown = if ($null -eq $Value) { '<null>' } else { $Value }
    Write-Host ("  {0,-34} {1}" -f $Key, $shown)
}

# Every probe runs inside this so one missing API cannot abort the report.
function Try-Note([string]$Key, [scriptblock]$Block) {
    try { Note $Key (& $Block) }
    catch { Note $Key "ERROR: $($_.Exception.Message)" }
}

Section 'Identity'
Try-Note os.caption      { (Get-CimInstance Win32_OperatingSystem).Caption }
Try-Note os.version      { (Get-CimInstance Win32_OperatingSystem).Version }
Try-Note os.build        { (Get-CimInstance Win32_OperatingSystem).BuildNumber }
# ProductType 1 = workstation (client), 2 = domain controller, 3 = server.
# This is the load-bearing one: only a client SKU is known to carry bth.inf.
Try-Note os.producttype  { (Get-CimInstance Win32_OperatingSystem).ProductType }
Try-Note os.sku          { if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) { 'client' } else { 'server' } }
Try-Note os.architecture { (Get-CimInstance Win32_OperatingSystem).OSArchitecture }
# $env:PROCESSOR_ARCHITECTURE describes the PROCESS, not the machine: an x64
# PowerShell running under emulation on Windows-on-ARM reports AMD64, which
# would make us check bth.inf for the wrong architecture section. Ask the CPU.
$archMap = @{ 0 = 'x86'; 5 = 'ARM'; 9 = 'AMD64'; 12 = 'ARM64' }
$machineArch = try {
    $a = (Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture
    if ($archMap.ContainsKey([int]$a)) { $archMap[[int]$a] } else { "unknown($a)" }
} catch { $env:PROCESSOR_ARCHITECTURE }
Note machine.arch        $machineArch
Note process.arch        $env:PROCESSOR_ARCHITECTURE
# The WinRT checks below only work under Windows PowerShell 5.1 - PowerShell 7
# dropped the WindowsRuntime type accelerator - so record which host this is.
Note host.psversion      $PSVersionTable.PSVersion.ToString()
Note host.psedition      $PSVersionTable.PSEdition
Try-Note cpu.count       { (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors }
Try-Note ram.gb          { [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) }

Section 'Session and privilege'
# BluetoothUserService_<luid> is a per-user service, so whether WinRT Bluetooth
# works at all may depend on what kind of session this is.
Try-Note session.id      { [System.Diagnostics.Process]::GetCurrentProcess().SessionId }
Try-Note session.user    { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
Try-Note session.isadmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
Try-Note session.interactive { [Environment]::UserInteractive }

Section 'Boot configuration'
# The whole "no VM needed" thesis rests on testsigning already being Yes here.
$bcd = try { (bcdedit /enum '{current}' | Out-String) } catch { '' }
Note bcd.testsigning        ($bcd -match 'testsigning\s+Yes')
Note bcd.nointegritychecks  ($bcd -match 'nointegritychecks\s+Yes')
Note bcd.debug              ($bcd -match '(?m)^debug\s+Yes')
$hvLaunch = if ($bcd -match 'hypervisorlaunchtype\s+(\w+)') { $Matches[1] } else { '<unset>' }
Note bcd.hypervisorlaunch   $hvLaunch
Try-Note secureboot {
    try { Confirm-SecureBootUEFI } catch { "unavailable ($($_.Exception.Message))" }
}

Section 'Code integrity'
# An unsigned or self-signed driver will not load under HVCI regardless of
# testsigning, so this decides whether the runner can host the driver at all.
Try-Note deviceguard.vbs {
    (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard -ErrorAction Stop).VirtualizationBasedSecurityStatus
}
Try-Note deviceguard.running {
    $v = (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
            -ClassName Win32_DeviceGuard -ErrorAction Stop).SecurityServicesRunning
    if ($v) { $v -join ',' } else { 'none' }   # 2 in this list means HVCI is on
}
Try-Note deviceguard.cipolicy {
    (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard -ErrorAction Stop).CodeIntegrityPolicyEnforcementStatus
}
Try-Note hvci.regkey {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    if (Test-Path $p) { (Get-ItemProperty $p).Enabled } else { '<absent>' }
}
Try-Note defender.realtime {
    try { (Get-MpPreference -ErrorAction Stop).DisableRealtimeMonitoring } catch { 'unavailable' }
}

Section 'Bluetooth stack: files'
$sys = Join-Path $env:windir 'System32\drivers'
foreach ($f in 'bthport.sys','bthmini.sys','bthenum.sys','rfcomm.sys','bthusb.sys','bthleenum.sys') {
    Note "file.$f" (Test-Path (Join-Path $sys $f))
}
$bthInf = Join-Path $env:windir 'INF\bth.inf'
Note 'file.bth.inf' (Test-Path $bthInf)

Section 'Bluetooth stack: bth.inf contents'
# These three are the actual binding contract this project depends on:
# bth.inf must match the compatible ID our PDO reports, and must have a section
# decorated for this architecture.
if (Test-Path $bthInf) {
    $inf = Get-Content $bthInf -Raw
    Note inf.has_ms_bthx_bthmini ($inf -match 'MS_BTHX_BTHMINI')
    Note inf.has_basicdriverok   ($inf -match 'BasicDriverOk')
    Note inf.has_ntarm64         ($inf -match '(?i)\[Microsoft\.NTarm64\]')
    Note inf.has_ntamd64         ($inf -match '(?i)\[Microsoft\.NTamd64\]')
    Note inf.bthmini_sections    (($inf | Select-String -Pattern '(?im)^\[BthMini[^\]]*\]' -AllMatches
                                    ).Matches.Value -join ' ')
} else {
    Note inf.has_ms_bthx_bthmini $false
    Write-Host '  bth.inf is absent - this machine cannot host a virtual Bluetooth radio.' -ForegroundColor Yellow
}

Section 'Bluetooth stack: services'
foreach ($svc in 'bthserv','BTAGService','BluetoothUserService','BthAvctpSvc') {
    Try-Note "svc.$svc" {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) { "$($s.Status) (StartType=$($s.StartType))" } else { '<absent>' }
    }
}
# bthserv is demand-start; starting it is the cheapest proof the user-mode side
# is functional, and it is what BthPort brings up anyway once a radio appears.
Try-Note svc.bthserv.canstart {
    $s = Get-Service -Name bthserv -ErrorAction SilentlyContinue
    if (-not $s) { return '<absent>' }
    if ($s.Status -eq 'Running') { return 'already running' }
    Start-Service bthserv -ErrorAction Stop
    (Get-Service bthserv).Status
}

Section 'Bluetooth stack: existing PnP state'
# A machine with a real radio has hundreds of BTHENUM/BTHLEDEVICE children, so
# report shapes rather than the whole list. The two that matter are the nodes
# BthPort creates once a radio comes up - they are what Tier 2 asserts on.
Try-Note pnp.bth_device_count {
    @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue).Count
}
Try-Note pnp.has_ms_bthbrb {
    @(Get-PnpDevice -InstanceId 'BTH\MS_BTHBRB\*' -ErrorAction SilentlyContinue).Count -gt 0
}
Try-Note pnp.has_ms_rfcomm {
    @(Get-PnpDevice -InstanceId 'BTH\MS_RFCOMM\*' -ErrorAction SilentlyContinue).Count -gt 0
}
# pnputil only enumerates third-party (oem*.inf) packages, never inbox ones, so
# this is NOT a check for bth.inf - it tells us the driver store is clean.
Try-Note pnp.thirdparty_packages {
    (pnputil /enum-drivers 2>&1 | Select-String -Pattern 'Published Name').Count
}

Section 'WinRT Bluetooth reachability'
# This is the part that a non-interactive service session may fail even when
# every kernel-mode check above passes. There is no radio on this machine, so
# GetDefaultAsync returning null is expected and fine - what matters is whether
# the projections load and the calls complete rather than throwing.
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host '  PowerShell 7 dropped the WindowsRuntime type accelerator; these checks' -ForegroundColor Yellow
    Write-Host '  only mean anything under Windows PowerShell 5.1 (shell: powershell).' -ForegroundColor Yellow
    Note winrt.host_supported $false
} else {
    Note winrt.host_supported $true
}
Try-Note winrt.types_load {
    $null = [Windows.Devices.Bluetooth.BluetoothAdapter, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime]
    $true
}
Try-Note winrt.device_selector {
    [Windows.Devices.Bluetooth.BluetoothAdapter]::GetDeviceSelector()
}
Try-Note winrt.radio_access {
    # Awaiting WinRT from PowerShell needs the right AsTask overload picked by
    # reflection; this mirrors tools\win-ble-test.ps1.
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    $op = [Windows.Devices.Radios.Radio]::RequestAccessAsync()
    $t  = $asTask.MakeGenericMethod([Windows.Devices.Radios.RadioAccessStatus]).Invoke($null, @($op))
    if (-not $t.Wait(15000)) { 'timed out' } else { $t.Result }
}

Section 'Driver tooling on this machine'
Try-Note kits.root {
    $p = 'C:\Program Files (x86)\Windows Kits\10'
    if (Test-Path $p) { $p } else { '<absent>' }
}
Try-Note kits.sdk_versions {
    $p = 'C:\Program Files (x86)\Windows Kits\10\Include'
    if (Test-Path $p) { (Get-ChildItem $p -Directory | Select-Object -Expand Name) -join ',' } else { '<absent>' }
}
Try-Note kits.km_headers {
    # A WDK VSIX without WDK content leaves Include\<ver>\km empty; that
    # distinction decides whether the in-image WDK is usable at all.
    $p = 'C:\Program Files (x86)\Windows Kits\10\Include'
    if (-not (Test-Path $p)) { return '<absent>' }
    (Get-ChildItem $p -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'km\ntddk.h') } |
        Select-Object -Expand Name) -join ','
}
Try-Note kits.bthxddi {
    $p = 'C:\Program Files (x86)\Windows Kits\10\Include'
    if (-not (Test-Path $p)) { return '<absent>' }
    (Get-ChildItem $p -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'km\bthxddi.h') } |
        Select-Object -Expand Name) -join ','
}
foreach ($tool in 'devgen.exe','devcon.exe','stampinf.exe','inf2cat.exe','signtool.exe') {
    Try-Note "tool.$tool" {
        $p = 'C:\Program Files (x86)\Windows Kits\10'
        if (-not (Test-Path $p)) { return '<absent>' }
        # Prefer the newest kit and this machine's architecture. Taking the
        # first match blindly finds stale 32-bit ARM copies of signtool.
        $hits = @(Get-ChildItem $p -Recurse -Filter $tool -File -ErrorAction SilentlyContinue)
        if (-not $hits) { return '<absent>' }
        $ranked = $hits | Sort-Object `
            @{ Expression = { $_.FullName -match "\\$machineArch\\" }; Descending = $true },
            @{ Expression = { $_.FullName }; Descending = $true }
        "$($ranked[0].FullName)   (of $($hits.Count) copies)"
    }
}

Section 'Verdict'
$hasStack   = $script:result['file.bth.inf'] -eq $true -and $script:result['inf.has_ms_bthx_bthmini'] -eq $true
$hasSigning = $script:result['bcd.testsigning'] -eq $true
$archKey    = if ($machineArch -eq 'ARM64') { 'inf.has_ntarm64' } else { 'inf.has_ntamd64' }
$archOk     = $script:result[$archKey]

Note verdict.testsigning_on   $hasSigning
Note verdict.bluetooth_stack  $hasStack
Note verdict.inf_arch_section $archOk
Note verdict.can_host_winvhci ($hasSigning -and $hasStack -and $archOk -eq $true)

Write-Host ''
if ($hasSigning -and $hasStack -and $archOk -eq $true) {
    Write-Host 'This machine looks able to host winvhci directly - no VM needed.' -ForegroundColor Green
} elseif ($hasSigning -and -not $hasStack) {
    Write-Host 'Test signing is available but the Bluetooth stack is not present.' -ForegroundColor Yellow
    Write-Host 'The driver would load here, but bth.inf could never bind to its radio PDO.'
} else {
    Write-Host 'This machine cannot host winvhci as configured.' -ForegroundColor Yellow
}

if ($Json) {
    $script:result | ConvertTo-Json -Depth 4 | Set-Content -Path $Json -Encoding UTF8
    Write-Host ''
    Write-Host "wrote $Json"
}

# Always succeed. This is a report; an absent feature is data, not a failure.
exit 0
