# Launch the Windows 11 ARM64 driver-test guest under QEMU.
#
# Replaces VirtualBox, which cannot host Windows guests on a Windows-on-ARM host
# (INTERNAL_POWER_ERROR on install/boot, unfixed across 7.2.0-7.2.6) and whose
# ARM firmware publishes no ACPI DBG2 table, making kernel debugging impossible.
#
# QEMU's 'virt' machine does emit a DBG2 entry for its PL011 UART, so the guest
# can be kernel-debugged over -serial pipe.

[CmdletBinding()]
param(
    [string]$VmDir    = 'C:\Users\extra\qemu-vms\winvhci',
    [string]$Disk     = 'win11.qcow2',
    [string]$Iso,                        # attach an install ISO
    [int]   $MemoryMB = 8192,
    [int]   $Cpus     = 4,
    [string]$KdPipe   = 'winvhci-kd',    # host side becomes \\.\pipe\winvhci-kd
    [switch]$NoKd,                       # no debug serial port - see note below
    [switch]$NoAccel,                    # force TCG (very slow; for triage only)
    [int]   $QmpPort     = 55556,
    [int]   $MonitorPort = 55555,
    [int]   $RdpPort     = 3390,    # host loopback port forwarded to guest 3389
    [int]   $SshPort     = 2222     # host loopback port forwarded to guest 22
)

$ErrorActionPreference = 'Stop'

$qemu     = 'C:\Program Files\qemu\qemu-system-aarch64.exe'
$codeFd   = 'C:\Program Files\qemu\share\edk2-aarch64-code.fd'
$varsFd   = Join-Path $VmDir 'edk2-aarch64-vars.fd'
$diskPath = Join-Path $VmDir $Disk
$shareIso = Join-Path $VmDir 'share.iso'
if (-not (Test-Path $shareIso)) { throw "Share ISO missing: $shareIso  (run build\make-share-iso.ps1)" }

foreach ($p in @($qemu, $codeFd, $diskPath)) {
    if (-not (Test-Path $p)) { throw "Missing: $p" }
}

# The UEFI variable store must be exactly the size of the code image (64 MiB).
if (-not (Test-Path $varsFd)) {
    $fs = [System.IO.File]::Create($varsFd); $fs.SetLength(64MB); $fs.Close()
}

$accel = if ($NoAccel) { 'tcg' } else { 'whpx' }

$qemuArgs = @(
    # gic-version=3 is what Windows on ARM expects; no secure world, no nesting.
    '-M', 'virt,gic-version=3'
    '-accel', $accel
    '-cpu', 'max'
    '-smp', $Cpus
    '-m',   $MemoryMB

    # Split firmware: read-only code plus a writable variable store.
    '-drive', "if=pflash,format=raw,unit=0,file=$codeFd,readonly=on"
    '-drive', "if=pflash,format=raw,unit=1,file=$varsFd"

    # NVMe, because it is the only controller both sides can see:
    #   - the ArmVirtQemu firmware (edk2-aarch64-code.fd) includes NvmExpressDxe
    #     but NO AHCI driver, so an ich9-ahci disk is invisible to it and the
    #     firmware falls through to PXE boot;
    #   - Windows has an inbox boot-start stornvme driver, whereas virtio-blk
    #     (which the firmware can also see) would need drivers the image lacks
    #     and would bugcheck INACCESSIBLE_BOOT_DEVICE.
    # bootindex=0 so the firmware always prefers the installed system disk over
    # any removable media we attach for file transfer.
    '-drive',  "file=$diskPath,if=none,id=hd0,format=qcow2"
    '-device', 'nvme,drive=hd0,serial=winvhci0,bootindex=0'

    # Display. Tried on ARM 'virt', in order of increasing desperation:
    #   ramfb          - fw_cfg framebuffer. WORKS end to end: firmware, Windows
    #                    boot graphics, AND the desktop all render.
    #   bochs-display  - a PCI display device, but ArmVirtQemu never programmed
    #                    it ("Guest has not initialized the display").
    #   virtio-gpu-pci - firmware drives it, but Windows has no inbox driver:
    #                    "Display output is not active" after handoff.
    #   VGA (std)      - accepted by the machine type, but ArmVirtQemu never
    #                    programs it either, so the firmware console is lost
    #                    too. ('-vga virtio' is rejected outright.)
    #
    # ramfb wins: it is the only one that renders at all, and it renders the
    # whole way through.
    #
    # An earlier version of this comment claimed the screen goes black once
    # Windows' display stack takes over. That was wrong - a screendump taken at
    # the desktop shows it rendering normally. The black screens that prompted
    # that claim were long specialize/OOBE/update phases, not a display handoff
    # failure. This matters: because ramfb keeps rendering, 'screendump' plus
    # 'sendkey' are a usable way to drive the guest with no agent inside it.
    '-device', 'ramfb'
    '-device', 'qemu-xhci,id=xhci'
    '-device', 'usb-kbd'
    '-device', 'usb-tablet'

    # File channel: a read-only ISO on a USB CD-ROM, built by
    # build\make-share-iso.ps1. Rebuild it and relaunch after each driver build.
    #
    # NOT vvfat: QEMU's read-write vvfat crashes the whole VM as soon as the
    # guest writes to it ("cluster 0 used more than once" / assertion failed in
    # commit_direntries), and usb-storage refuses a read-only vvfat node. An ISO
    # is read-only by construction, so the guest cannot trigger it.
    # bootindex=91 keeps the firmware away from it.
    '-drive',  "file=$shareIso,if=none,id=share0,media=cdrom,readonly=on,format=raw"
    '-device', 'usb-storage,drive=share0,bus=xhci.0,bootindex=91'

    # Networking. Windows on ARM has no inbox driver for ANY NIC QEMU offers -
    # e1000e, virtio-net and USB RNDIS all land in Device Manager as unknown
    # devices. The fix is the NetKVM driver from the virtio-win ISO, which does
    # ship an ARM64 build, so virtio-net-pci is the NIC to present: once NetKVM
    # is installed this becomes a working adapter and RDP arrives on $RdpPort.
    # Until then the guest has no network and files come over the share disc.
    # Two forwards: RDP for a human console, SSH for scripted control from the
    # host (build -> install -> observe -> revert without touching the guest).
    '-netdev', "user,id=n0,hostfwd=tcp:127.0.0.1:$RdpPort-:3389,hostfwd=tcp:127.0.0.1:$SshPort-:22"
    '-device', 'virtio-net-pci,netdev=n0'

    '-rtc', 'base=localtime'
    '-name', 'winvhci-test'

    # Control channels, so the VM can be inspected and driven from outside the
    # guest: QMP for screenshots (screendump) and state queries, HMP for ad-hoc
    # commands like sendkey. Loopback only.
    '-qmp',     "tcp:127.0.0.1:$QmpPort,server=on,wait=off"
    '-monitor', "tcp:127.0.0.1:$MonitorPort,server=on,wait=off"
)

# The kernel debugger transport. QEMU creates \\.\pipe\<KdPipe> on the host.
#
# IMPORTANT: on Windows, QEMU's pipe chardev BLOCKS the guest until a client
# connects - the VM sits at ~0% CPU and never boots. So only wire it up when we
# actually intend to attach a debugger. Use -NoKd for installs, OOBE, and any
# session where nothing will connect to the pipe.
if ($NoKd) {
    $qemuArgs += @('-serial', 'null')
} else {
    $qemuArgs += @('-serial', "pipe:$KdPipe")
}

if ($Iso) {
    if (-not (Test-Path $Iso)) { throw "ISO not found: $Iso" }
    # usb-storage, because this disc is for a RUNNING Windows to read, and
    # Windows has an inbox USB mass-storage driver but no virtio-scsi driver.
    # (For BOOTING an installer the opposite is true - the firmware needs
    # scsi-cd, since over USB it sees a HARDDRIVE and cannot find El Torito.)
    # A high bootindex keeps the firmware from trying to boot it.
    $qemuArgs += @(
        '-drive',  "file=$Iso,if=none,id=cd0,media=cdrom,readonly=on,format=raw"
        '-device', 'usb-storage,drive=cd0,bus=xhci.0,bootindex=90'
    )
}

Write-Host "Starting QEMU ($accel acceleration)..." -ForegroundColor Green
Write-Host "  disk    : $diskPath"
if ($NoKd) {
    Write-Host '  KD      : disabled (-NoKd)'
} else {
    Write-Host "  KD pipe : \\.\pipe\$KdPipe"
    Write-Host "  attach  : kd -k com:pipe,port=\\.\pipe\$KdPipe,resets=0,reconnect   (run ELEVATED)"
    Write-Host '  NOTE    : the guest will not boot until a client connects to that pipe.' -ForegroundColor Yellow
}
Write-Host ''

& $qemu @qemuArgs
