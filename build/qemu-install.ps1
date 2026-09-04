# Install Windows 11 ARM64 into a fresh virtual disk, fully unattended.
#
# No elevation needed. Creates an empty qcow2, boots the ISO, and lets Setup run
# itself from autounattend.xml. Nothing needs to be seen or clicked, which is the
# point: no QEMU display device renders once Windows takes over on this platform.
#
# When it finishes the guest reboots to a desktop with a local admin 'vhcidev'
# and RDP enabled; connect to 127.0.0.1:<RdpPort>.

[CmdletBinding()]
param(
    [string]$Iso      = 'C:\Users\extra\Downloads\Win11_25H2_English_Arm64_v2.iso',
    [string]$VmDir    = 'C:\Users\extra\qemu-vms\winvhci',
    [string]$Disk     = 'win11.qcow2',
    [string]$DiskSize = '64G',
    [string]$CredFile = 'C:\Users\extra\AppData\Local\Temp\claude\c--Users-extra-work-windows-vhci-driver\3d2bbd61-05fd-474a-90ab-4ce686d3af08\scratchpad\guest-cred.txt',
    [int]   $MemoryMB = 8192,
    [int]   $Cpus     = 4,
    [int]   $RdpPort  = 3390,
    [int]   $QmpPort  = 55556,
    [int]   $MonitorPort = 55555,
    [switch]$KeepDisk                    # resume an interrupted install
)

$ErrorActionPreference = 'Stop'

$qemu   = 'C:\Program Files\qemu\qemu-system-aarch64.exe'
$qemuImg= 'C:\Program Files\qemu\qemu-img.exe'
$codeFd = 'C:\Program Files\qemu\share\edk2-aarch64-code.fd'
$varsFd = Join-Path $VmDir 'edk2-aarch64-vars.fd'
$disk   = Join-Path $VmDir $Disk
$answer = Join-Path $VmDir 'answer'

foreach ($p in @($qemu, $qemuImg, $codeFd, $Iso, $CredFile)) {
    if (-not (Test-Path $p)) { throw "Missing: $p" }
}
New-Item -ItemType Directory -Path $VmDir -Force | Out-Null

# The answer directory is exposed to the guest as a FAT disk, so build a copy
# with the real password substituted rather than keeping it in the repo.
Write-Host '== Staging answer file ==' -ForegroundColor Cyan
Remove-Item $answer -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $answer -Force | Out-Null
$password = (Get-Content $CredFile -Raw).Trim()
# $PSScriptRoot can be empty under Windows PowerShell 5.1 in some invocations.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$xml = (Get-Content (Join-Path $scriptDir 'answer\autounattend.xml') -Raw).Replace('__PASSWORD__', $password)
# Setup expects the file at the root of the media, encoded UTF-8.
Set-Content -Path (Join-Path $answer 'autounattend.xml') -Value $xml -Encoding UTF8
Write-Host "  $answer\autounattend.xml"

if (-not $KeepDisk) {
    Write-Host "== Creating empty $DiskSize disk ==" -ForegroundColor Cyan
    Remove-Item $disk -Force -ErrorAction SilentlyContinue
    & $qemuImg create -f qcow2 $disk $DiskSize | Out-Null
}
# Fresh UEFI variables, else the firmware may keep stale boot entries.
Remove-Item $varsFd -Force -ErrorAction SilentlyContinue
$fs = [System.IO.File]::Create($varsFd); $fs.SetLength(64MB); $fs.Close()

$qemuArgs = @(
    '-M', 'virt,gic-version=3'
    '-accel', 'whpx'
    '-cpu', 'max'
    '-smp', $Cpus
    '-m',   $MemoryMB

    '-drive', "if=pflash,format=raw,unit=0,file=$codeFd,readonly=on"
    '-drive', "if=pflash,format=raw,unit=1,file=$varsFd"

    # Target disk on NVMe: the firmware can see it (NvmExpressDxe) and WinPE has
    # an inbox stornvme driver. AHCI would be invisible to this firmware.
    '-drive',  "file=$disk,if=none,id=hd0,format=qcow2"
    '-device', 'nvme,drive=hd0,serial=winvhci0'

    # The USB controller must be declared before anything that attaches to it,
    # otherwise QEMU fails with "No 'usb-bus' bus found for device".
    '-device', 'qemu-xhci,id=xhci'
    '-device', 'usb-kbd,bus=xhci.0'
    '-device', 'usb-tablet,bus=xhci.0'

    # Install media as a real SCSI CD-ROM. Attaching the ISO via usb-storage
    # makes the firmware see a removable USB HARDDRIVE rather than a CD: it then
    # looks for \EFI\BOOT\BOOTAA64.EFI on a FAT volume, finds an ISO9660
    # filesystem instead, and hangs at "starting Boot0001 ... USB HARDDRIVE".
    # ArmVirtQemu includes VirtioScsiDxe and can read El Torito from scsi-cd.
    '-device', 'virtio-scsi-pci,id=scsi0'
    '-drive',  "file=$Iso,if=none,id=cd0,media=cdrom,readonly=on,format=raw"
    '-device', 'scsi-cd,drive=cd0,bus=scsi0.0,bootindex=0'
    # vvfat must be rw: usb-storage refuses a read-only block node
    # ("Block node is read-only"). Writes go to a throwaway overlay, not the
    # host directory. The explicit high bootindex is the important part -
    # without it the firmware picks this FAT volume over the ISO, finds no
    # bootloader, and hangs at "starting Boot0001 ... USB HARDDRIVE".
    '-drive',  "file=fat:rw:$answer,if=none,id=ans0"
    '-device', 'usb-storage,drive=ans0,bus=xhci.0,bootindex=99'

    '-device', 'virtio-gpu-pci'

    '-netdev', "user,id=n0,hostfwd=tcp:127.0.0.1:$RdpPort-:3389"
    '-device', 'virtio-net-pci,netdev=n0'

    '-serial', 'null'
    '-rtc', 'base=localtime'
    '-name', 'winvhci-install'
    '-qmp',     "tcp:127.0.0.1:$QmpPort,server=on,wait=off"
    '-monitor', "tcp:127.0.0.1:$MonitorPort,server=on,wait=off"
)

Write-Host '== Starting unattended install ==' -ForegroundColor Green
Write-Host "  iso     : $Iso"
Write-Host "  disk    : $disk ($DiskSize)"
Write-Host "  RDP     : 127.0.0.1:$RdpPort  as vhcidev"
Write-Host '  Expect 20-60 minutes with several automatic reboots.'
Write-Host '  Progress is visible via build\qemu-screenshot.ps1 (Setup renders'
Write-Host '  under WinPE, even though the desktop later will not).'
Write-Host ''

& $qemu @qemuArgs
