# M0 guest-side setup. Run ELEVATED, INSIDE the ARM64 Windows 11 guest.
#
# Puts the guest into a state where an unsigned/test-signed kernel driver will
# load and a kernel debugger can attach. Requires a reboot afterwards.
#
# Prerequisite: Secure Boot off. Under QEMU this is automatic - we boot the
# plain edk2-aarch64-code.fd firmware, which has no Secure Boot support at all.
#
# Run it from the host without touching the guest:
#   ssh -p 2222 vhcidev@127.0.0.1 'powershell -ExecutionPolicy Bypass -File D:\guest-setup.ps1'
# Windows OpenSSH gives an administrator a full (unfiltered) token, so an SSH
# session is already elevated and no UAC interaction is involved.

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated.'
}

Write-Host '== Secure Boot state ==' -ForegroundColor Cyan
try {
    if (Confirm-SecureBootUEFI) { Write-Warning 'Secure Boot is still ON - test-signed drivers will not load.' }
    else { Write-Host 'Secure Boot: off' }
} catch { Write-Host 'Secure Boot: not enabled/unsupported (fine)' }

Write-Host '== Boot configuration ==' -ForegroundColor Cyan
# Load test-signed kernel drivers.
bcdedit /set testsigning on
# Leave live kernel debugging off for now.
#
# The original reason was VirtualBox-specific: its ARM64 firmware publishes no
# ACPI DBG2 table, and Windows on ARM locates its debug UART exclusively through
# DBG2, so the PL011 was undiscoverable as a debug port. That reason does NOT
# apply to QEMU, whose 'virt' machine does emit a DBG2 entry - so a live
# debugger should be possible here and is worth revisiting (run
# build\guest-dbg2.ps1 in the guest to confirm, and launch without -NoKd).
#
# It stays off by default because QEMU's pipe chardev blocks the guest until a
# debugger client connects, which would stall every unattended boot. Routine
# diagnosis comes from crash dumps plus DebugView.
bcdedit /debug off

Write-Host '== Disabling HVCI / memory integrity ==' -ForegroundColor Cyan
# With HVCI on, an unsigned binary will not load at all. Turning the scenario off
# in the registry is the supported switch; it takes effect on reboot.
$hvci = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
New-Item -Path $hvci -Force | Out-Null
Set-ItemProperty -Path $hvci -Name 'Enabled' -Type DWord -Value 0

Write-Host '== Enabling DbgPrint output ==' -ForegroundColor Cyan
# Without this, Windows discards DbgPrint/KdPrint output from drivers unless a
# kernel debugger is attached, and DebugView's "Capture Kernel" shows nothing.
# 0xFFFFFFFF enables every severity of every component; IHVDRIVER is where our
# KdPrint lands, but DEFAULT covers anything we forget to categorise.
$dpf = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Debug Print Filter'
New-Item -Path $dpf -Force | Out-Null
Set-ItemProperty -Path $dpf -Name 'DEFAULT'   -Type DWord -Value 0xFFFFFFFF
Set-ItemProperty -Path $dpf -Name 'IHVDRIVER' -Type DWord -Value 0xFFFFFFFF

Write-Host '== Crash dumps ==' -ForegroundColor Cyan
# 2 = KERNEL memory dump. Do NOT use 1 (complete dump) here: a complete dump must
# reserve space for all of RAM, which on this 16 GB VM means a 16 GB+ pagefile the
# disk cannot supply, and Windows then bugchecks INTERNAL_POWER_ERROR (0xA0) on
# boot. A kernel dump contains everything needed to debug a driver bugcheck.
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty -Path $cc -Name 'CrashDumpEnabled' -Type DWord -Value 2
# Do not silently reboot on bugcheck - we want to read the stop code.
Set-ItemProperty -Path $cc -Name 'AutoReboot'       -Type DWord -Value 0

Write-Host ''
Write-Host 'Done. Reboot the guest for testsigning and HVCI changes to take effect.' -ForegroundColor Green
Write-Host ''
Write-Host 'Diagnosis on this VM (no live kernel debugger available):' -ForegroundColor Green
Write-Host '  - DebugView (Sysinternals), run elevated with Capture > Capture Kernel,'
Write-Host '    shows driver KdPrint output live.'
Write-Host '  - Bugchecks write a complete dump to C:\Windows\MEMORY.DMP and do not'
Write-Host '    auto-reboot, so the stop code stays on screen.'
Write-Host ''
Write-Host 'After rebooting, take the baseline snapshot from the host:' -ForegroundColor Green
Write-Host '  build\qemu-snapshot.ps1 -Take testsigning'
