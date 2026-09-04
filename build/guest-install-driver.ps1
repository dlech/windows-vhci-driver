# Install (or reinstall) winvhci in the guest. Run ELEVATED, INSIDE the VM.
#
# Assumes build\guest-setup.ps1 has already run AND the guest has rebooted, so
# testsigning is active and HVCI is off.

[CmdletBinding()]
param(
    # Defaults to wherever this script is running from - i.e. the QEMU VVFAT
    # drive the host stages with build\stage-share.ps1.
    [string]$Share,
    [string]$Staging = 'C:\winvhci'
)

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated.'
}

# Locate the staged files relative to this script, so the drive letter QEMU
# happens to assign to the VVFAT disk does not matter.
if (-not $Share) {
    $Share = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
}
$pkgSrc = Join-Path $Share 'winvhci'
$cer    = Join-Path $Share 'winvhci.cer'
$devcon = Join-Path $Share 'tools\devcon.exe'

Write-Host "Using staged files from: $Share" -ForegroundColor Cyan
foreach ($p in @($pkgSrc, $cer, $devcon)) {
    if (-not (Test-Path $p)) { throw "Missing: $p  (run build\stage-share.ps1 on the host and relaunch the VM)" }
}

Write-Host '== Checking test signing state ==' -ForegroundColor Cyan
$bcd = bcdedit /enum '{current}' | Out-String
if ($bcd -notmatch 'testsigning\s+Yes') {
    Write-Warning 'testsigning is not On. Run guest-setup.ps1 and reboot, or the driver will not load.'
}

Write-Host '== Trusting the WDK test certificate ==' -ForegroundColor Cyan
# A test-signed driver still needs its signing cert trusted as both a root and a
# publisher, otherwise pnputil rejects the package.
foreach ($store in 'Root', 'TrustedPublisher') {
    certutil -f -addstore $store $cer | Out-Null
    Write-Host "  added to LocalMachine\$store"
}

Write-Host '== Staging package locally ==' -ForegroundColor Cyan
# Installing straight off a UNC path is unreliable; copy it in first.
Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Staging -Force | Out-Null
Copy-Item "$pkgSrc\*" $Staging -Force
Copy-Item $devcon    $Staging -Force
$inf = Join-Path $Staging 'winvhci.inf'

Write-Host '== Removing any previous instance ==' -ForegroundColor Cyan
& "$Staging\devcon.exe" remove "root\winvhci" 2>&1 | Out-Null

# Purge every existing winvhci package from the driver store.
#
# This is NOT just tidiness. pnputil identifies a package by its INF version,
# not its contents: re-adding a package whose DriverVer has not changed prints
# "Driver package already imported" and KEEPS THE OLD BINARY, so the machine
# keeps running the previous build while you read the new source. That cost
# several confusing debugging cycles, with breadcrumbs that could not possibly
# appear because the code writing them was never installed.
#
# The earlier version of this loop parsed `pnputil /enum-drivers` with
# -Context 0,6, looking for "Published Name" AFTER "Original Name". pnputil
# prints Published Name FIRST, so the match never fired and nothing was ever
# deleted. Parse it as records instead.
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

Write-Host '== Installing driver package ==' -ForegroundColor Cyan
pnputil /add-driver $inf /install

Write-Host '== Creating the root-enumerated device node ==' -ForegroundColor Cyan
& "$Staging\devcon.exe" install $inf "root\winvhci"

Write-Host ''
Write-Host '== Result ==' -ForegroundColor Cyan
Get-PnpDevice -InstanceId 'ROOT\SYSTEM\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'Virtual Bluetooth' } |
    Format-List FriendlyName, Status, InstanceId, Problem, ProblemDescription

Write-Host 'If Status is OK, the driver loaded.'
Write-Host 'To see its KdPrint output, run DebugView elevated BEFORE installing:' -ForegroundColor Green
Write-Host "  $Share\tools\Dbgview64a.exe   (ARM64 build)"
Write-Host '  then Capture > Capture Kernel, and re-run this script.'
