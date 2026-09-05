# Create or remove the root-enumerated winvhci device node.
#
#     build\ci\vhci-devnode.ps1 -Create -Inf C:\pkg\winvhci.inf
#     build\ci\vhci-devnode.ps1 -Remove
#
# Run elevated.
#
# This replaces `devcon install winvhci.inf root\winvhci`. pnputil can add a
# driver package to the store but cannot create a root-enumerated node, and
# devcon is a WDK tool that may not be redistributed - so it cannot ship in a
# release download, and it is absent from some runner images entirely
# (windows-2025 has the WDK Visual Studio extension but no WDK content). Doing
# it directly needs about sixty lines of SetupAPI and removes both problems.
#
# Removal does not need SetupAPI: pnputil /remove-device has existed since
# Windows 10 1903 and is simpler and easier to read.

[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    [Parameter(ParameterSetName = 'Create', Mandatory)] [switch]$Create,
    [Parameter(ParameterSetName = 'Create', Mandatory)] [string]$Inf,
    [Parameter(ParameterSetName = 'Remove', Mandatory)] [switch]$Remove,
    [string]$HardwareId = 'root\winvhci'
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated.'
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class VhciDevnode
{
    const uint DICD_GENERATE_ID   = 0x00000001;
    const uint SPDRP_HARDWAREID   = 0x00000001;
    const uint DIF_REGISTERDEVICE = 0x00000019;
    const uint INSTALLFLAG_FORCE  = 0x00000001;

    // The System device setup class, matching winvhci.inx.
    static Guid ClassSystem = new Guid("4D36E97D-E325-11CE-BFC1-08002BE10318");

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA
    {
        public uint   cbSize;
        public Guid   ClassGuid;
        public uint   DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiCreateDeviceInfoW(IntPtr DeviceInfoSet, string DeviceName,
        ref Guid ClassGuid, string DeviceDescription, IntPtr hwndParent, uint CreationFlags,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData, uint Property, byte[] PropertyBuffer,
        uint PropertyBufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiCallClassInstaller(uint InstallFunction, IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwndParent, string HardwareId,
        string FullInfPath, uint InstallFlags, out bool bRebootRequired);

    // Returns true if Windows asked for a reboot. For a freshly created node it
    // never should: UpdateDriverForPlugAndPlayDevices only requests one when an
    // existing device stack fails IRP_MN_QUERY_REMOVE_DEVICE, and there is no
    // existing stack here.
    public static bool Create(string hardwareId, string infPath)
    {
        IntPtr set = SetupDiCreateDeviceInfoList(ref ClassSystem, IntPtr.Zero);
        if (set == new IntPtr(-1)) { throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList"); }
        try
        {
            SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
            d.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));

            if (!SetupDiCreateDeviceInfoW(set, "System", ref ClassSystem, null, IntPtr.Zero,
                                          DICD_GENERATE_ID, ref d))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoW");

            // SPDRP_HARDWAREID is REG_MULTI_SZ: the id, its terminator, and the
            // list terminator. Appending two nulls to the string gives exactly
            // that once encoded as UTF-16.
            byte[] buf = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryPropertyW(set, ref d, SPDRP_HARDWAREID, buf, (uint)buf.Length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiSetDeviceRegistryProperty(HARDWAREID)");

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, ref d))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCallClassInstaller(DIF_REGISTERDEVICE)");

            bool reboot;
            if (!UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareId, infPath,
                                                    INSTALLFLAG_FORCE, out reboot))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateDriverForPlugAndPlayDevices");

            return reboot;
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
    }
}
'@

if ($Create) {
    $infPath = (Resolve-Path $Inf).Path
    Write-Host "Creating device node $HardwareId from $infPath"
    $reboot = [VhciDevnode]::Create($HardwareId, $infPath)
    Write-Host "  created; reboot requested: $reboot"
    if ($reboot) { Write-Warning 'Windows asked for a reboot, which is unexpected for a fresh node.' }
}

if ($Remove) {
    # Match on the hardware ID rather than a friendly name so this keeps working
    # if the INF's device description changes.
    $devices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $ids = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' `
                    -ErrorAction SilentlyContinue).Data
        $ids -and ($ids -contains $HardwareId)
    }
    if (-not $devices) {
        Write-Host "No device with hardware ID $HardwareId is present."
    }
    foreach ($d in $devices) {
        Write-Host "Removing $($d.InstanceId)"
        pnputil /remove-device $d.InstanceId
        if ($LASTEXITCODE -ne 0) { Write-Warning "pnputil /remove-device exited $LASTEXITCODE" }
    }
}
