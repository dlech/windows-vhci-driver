# Prepare the QEMU guest disk offline, then convert it to qcow2.
#
# Run ELEVATED on the HOST. Mount-DiskImage needs administrator rights.
#
# Why this exists: no QEMU display device renders once this Windows-on-ARM image
# hands off to its own display stack, so OOBE cannot be completed interactively.
# Injecting an unattend file skips OOBE and enables RDP, which then serves as
# the guest's console.

[CmdletBinding()]
param(
    [string]$SourceVhdx = 'C:\Users\extra\Downloads\Windows11_InsiderPreview_Client_ARM64_en-us_26200.VHDX',
    [string]$VmDir      = 'C:\Users\extra\qemu-vms\winvhci',
    # A file holding the guest account password on its first line. Deliberately
    # outside the repository: the answer file here carries a __PASSWORD__
    # placeholder and the real value is substituted at run time, so no password
    # is ever committed.
    [string]$CredFile   = (Join-Path $env:LOCALAPPDATA 'winvhci\guest-cred.txt'),
    [string]$Unattend
)

# $PSScriptRoot is not populated while param() defaults are evaluated under
# Windows PowerShell 5.1, so resolve the script directory here instead.
if (-not $Unattend) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Unattend = Join-Path $scriptDir 'unattend.xml'
}

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated - Mount-DiskImage requires it.'
}

foreach ($p in @($SourceVhdx, $CredFile, $Unattend)) {
    if (-not (Test-Path $p)) { throw "Missing: $p" }
}

$work = Join-Path $VmDir 'work.vhdx'
$qcow = Join-Path $VmDir 'win11.qcow2'

# Work on a copy so the downloaded image stays pristine.
Write-Host '== Copying VHDX (13 GB, takes a minute) ==' -ForegroundColor Cyan
Copy-Item $SourceVhdx $work -Force

Write-Host '== Mounting ==' -ForegroundColor Cyan
$img = Mount-DiskImage -ImagePath $work -PassThru -NoDriveLetter:$false
try {
    $disk = $img | Get-DiskImage | Get-Disk
    # The Windows volume is the large NTFS one; the ESP and recovery partitions
    # are small and must not be picked.
    $vol = Get-Partition -DiskNumber $disk.Number |
           Get-Volume |
           Where-Object { $_.DriveLetter -and $_.FileSystemType -eq 'NTFS' } |
           Sort-Object Size -Descending | Select-Object -First 1
    if (-not $vol) { throw 'Could not find the Windows NTFS volume in the mounted image.' }
    $root = "$($vol.DriveLetter):"
    Write-Host "  Windows volume: $root ($([math]::Round($vol.Size/1GB,1)) GB)"
    if (-not (Test-Path "$root\Windows\System32")) { throw "$root does not look like a Windows volume." }

    Write-Host '== Injecting unattend.xml ==' -ForegroundColor Cyan
    $password = (Get-Content $CredFile -Raw).Trim()
    $xml = (Get-Content $Unattend -Raw).Replace('__PASSWORD__', $password)
    $panther = "$root\Windows\Panther"
    New-Item -ItemType Directory -Path $panther -Force | Out-Null
    Set-Content -Path (Join-Path $panther 'unattend.xml') -Value $xml -Encoding UTF8
    Write-Host "  wrote $panther\unattend.xml"
}
finally {
    Write-Host '== Dismounting ==' -ForegroundColor Cyan
    Dismount-DiskImage -ImagePath $work | Out-Null
}

Write-Host '== Converting to qcow2 ==' -ForegroundColor Cyan
Remove-Item $qcow -Force -ErrorAction SilentlyContinue
& 'C:\Program Files\qemu\qemu-img.exe' convert -p -f vhdx -O qcow2 $work $qcow
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert failed ($LASTEXITCODE)" }

Remove-Item $work -Force -ErrorAction SilentlyContinue
# Fresh UEFI variables so the new disk is enumerated from scratch.
Remove-Item (Join-Path $VmDir 'edk2-aarch64-vars.fd') -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Get-ChildItem $VmDir | Select-Object Name, @{n='GB';e={[math]::Round($_.Length/1GB,2)}}
Write-Host ''
Write-Host 'Next: build\qemu-run.ps1 -NoKd   then RDP to 127.0.0.1:3389 as vhcidev'
