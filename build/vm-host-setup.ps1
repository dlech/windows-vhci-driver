# M0 host-side VM setup. Run on the HOST, with the VM POWERED OFF.
#
# Configures the ARM64 Windows 11 guest for kernel-mode driver development:
# a serial port for WinDbg, Secure Boot off (required to boot with testsigning),
# and the Guest Additions ISO attached so the guest can be driven from the host.

$ErrorActionPreference = 'Stop'

$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$VM         = 'Windows 11'
$KdPipe     = '\\.\pipe\winvhci-kd'

function Invoke-VBox { & $VBoxManage @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage failed: $args" } }

# Refuse to run against a live VM - modifyvm requires it powered off.
$state = (& $VBoxManage showvminfo $VM --machinereadable | Select-String '^VMState=').ToString().Split('=')[1].Trim('"')
if ($state -ne 'poweroff') { throw "VM is '$state'. Power it off first (VBoxManage controlvm '$VM' acpipowerbutton)." }

# 1. COM1 as a named-pipe server on the host. WinDbg attaches to the pipe;
#    the guest sees a plain 16550A at the legacy base. This is the transport
#    that works under VirtualBox - KDNET needs a NIC from its supported list,
#    and this VM's virtio-net is not on it.
Invoke-VBox modifyvm $VM --uart1 0x3F8 4 --uart-type1 16550A --uart-mode1 server $KdPipe

# 2. Secure Boot off. Test-signed kernel drivers will not load with it on.
Invoke-VBox modifynvram $VM secureboot --disable

# 3. Guest Additions ISO, so the guest can install them. Additions give us shared
#    folders and `VBoxManage guestcontrol`, which turns the build/install/test
#    loop into something scriptable from the host.
$info = & $VBoxManage showvminfo $VM --machinereadable
if ($info | Select-String -SimpleMatch 'VBoxGuestAdditions.iso') {
    Write-Host 'Guest Additions ISO already attached.'
} else {
    # SATA-0-0 holds the system disk; port 1 is the free slot on this VM.
    Invoke-VBox storageattach $VM --storagectl SATA --port 1 --device 0 `
        --type dvddrive --medium additions
}

# 4. Share the repo into the guest, so built drivers and scripts are reachable
#    at \\VBOXSVR\vhci without copying. Needs Guest Additions in the guest.
if (-not ($info | Select-String -SimpleMatch 'SharedFolderNameMachineMapping1="vhci"')) {
    Invoke-VBox sharedfolder add $VM --name vhci `
        --hostpath (Split-Path $PSScriptRoot -Parent) --automount
}

Write-Host "Host-side setup done." -ForegroundColor Green
Write-Host "  KD pipe : $KdPipe"
Write-Host "  Attach  : windbg -k com:pipe,port=$KdPipe,resets=0,reconnect"
Write-Host ""
Write-Host "Next: boot the VM, install Guest Additions from the mounted ISO,"
Write-Host "      then run build\guest-setup.ps1 elevated inside the guest."
