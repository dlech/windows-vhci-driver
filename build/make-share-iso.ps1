# Build the guest file-channel as a real ISO image.
#
# Replaces the vvfat approach, which crashed QEMU outright the moment Windows
# wrote to it:
#     cluster 0 used more than once
#     ERROR: block/vvfat.c:2429:commit_direntries: assertion failed: (mapping)
# vvfat's read-write path is unreliable, and read-only vvfat is refused by
# usb-storage ("Block node is read-only"). An ISO is inherently read-only, so
# the guest cannot write to it and the bug cannot trigger.
#
# Uses the in-box IMAPI2 COM API - no admin rights and no external tools.
# Re-run after every driver rebuild, then relaunch the VM.

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$ShareDir = 'C:\Users\extra\qemu-vms\winvhci\share',
    [string]$IsoPath  = 'C:\Users\extra\qemu-vms\winvhci\share.iso',
    [string]$Platform = 'ARM64',
    [string]$Config   = 'Debug'
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = Split-Path -Parent $here
}

# ---- stage the payload -------------------------------------------------------
$outDir = Join-Path $RepoRoot "winvhci\$Platform\$Config"
$pkg    = Join-Path $outDir 'winvhci'
if (-not (Test-Path $pkg)) { throw "Driver package not found: $pkg  (build it first)" }

Remove-Item $ShareDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ShareDir 'tools') -Force | Out-Null

Copy-Item $pkg (Join-Path $ShareDir 'winvhci') -Recurse -Force
$cer = Join-Path $outDir 'winvhci.cer'
if (Test-Path $cer) { Copy-Item $cer $ShareDir -Force }
foreach ($s in 'guest-setup.ps1','guest-install-driver.ps1','guest-dbg2.ps1') {
    Copy-Item (Join-Path $RepoRoot "build\$s") $ShareDir -Force
}
Copy-Item (Join-Path $RepoRoot 'build\tools\devcon.exe') (Join-Path $ShareDir 'tools') -Force

# DebugView, ARM64 builds. Both matter:
#   Dbgview64a.exe    - the GUI, for watching live at the guest console.
#   dbgviewcli64a.exe - the console version, which is the one that works over
#                       SSH: it captures kernel DbgPrint output to a file with
#                       no interactive session, so driver logs can be collected
#                       and read back from the host.
foreach ($t in 'Dbgview64a.exe', 'dbgviewcli64a.exe') {
    $p = Join-Path $RepoRoot "build\tools\DebugView\$t"
    if (Test-Path $p) { Copy-Item $p (Join-Path $ShareDir 'tools') -Force }
    else { Write-Warning "missing $t - see build\tools\README.md" }
}

# ---- author the ISO ----------------------------------------------------------
# IMAPI2 hands back an IStream; this tiny helper pumps it to disk.
if (-not ('VhciIso' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class VhciIso {
    public static void Save(string path, object stream, int blockSize, int totalBlocks) {
        IStream s = (IStream)stream;
        using (FileStream fs = File.Create(path)) {
            byte[] buf = new byte[blockSize];
            IntPtr read = Marshal.AllocHGlobal(8);
            try {
                for (int i = 0; i < totalBlocks; i++) {
                    s.Read(buf, blockSize, read);
                    fs.Write(buf, 0, Marshal.ReadInt32(read));
                }
                fs.Flush();
            } finally { Marshal.FreeHGlobal(read); }
        }
    }
}
'@
}

$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3          # ISO9660 + Joliet (long file names)
$fsi.VolumeName = 'VHCISHARE'
$fsi.Root.AddTree($ShareDir, $false)  # $false = do not include the root folder itself
$img = $fsi.CreateResultImage()

Remove-Item $IsoPath -Force -ErrorAction SilentlyContinue
[VhciIso]::Save($IsoPath, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)

Write-Host "Built $IsoPath" -ForegroundColor Green
Get-Item $IsoPath | Select-Object FullName, @{n='MB';e={[math]::Round($_.Length/1MB,2)}}
