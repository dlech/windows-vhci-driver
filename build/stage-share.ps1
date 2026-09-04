# Stage everything the guest needs into the directory QEMU serves as a FAT disk.
#
# The guest has no working network (Windows on ARM has no inbox driver for any
# NIC QEMU offers here) and no Guest Additions equivalent, so files reach it as
# a vvfat-backed NVMe disk instead. NVMe is used because it is one of the few
# controllers this Windows image can actually drive.
#
# Run on the host after building. Re-run after every rebuild, then re-launch the
# VM (vvfat snapshots the directory listing at start-up).

[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ShareDir = 'C:\Users\extra\qemu-vms\winvhci\share',
    [string]$Platform = 'ARM64',
    [string]$Config   = 'Debug'
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }

$outDir = Join-Path $RepoRoot "winvhci\$Platform\$Config"
$pkg    = Join-Path $outDir 'winvhci'
$cer    = Join-Path $outDir 'winvhci.cer'

if (-not (Test-Path $pkg)) { throw "Driver package not found: $pkg  (build it first)" }

Remove-Item $ShareDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null

# Driver package (inf + sys + cat) and its test certificate.
Copy-Item $pkg (Join-Path $ShareDir 'winvhci') -Recurse -Force
if (Test-Path $cer) { Copy-Item $cer $ShareDir -Force }

# Guest-side scripts and tools.
New-Item -ItemType Directory -Path (Join-Path $ShareDir 'tools') -Force | Out-Null
Copy-Item (Join-Path $RepoRoot 'build\guest-setup.ps1')          $ShareDir -Force
Copy-Item (Join-Path $RepoRoot 'build\guest-install-driver.ps1') $ShareDir -Force
Copy-Item (Join-Path $RepoRoot 'build\guest-dbg2.ps1')           $ShareDir -Force
Copy-Item (Join-Path $RepoRoot 'build\tools\devcon.exe')         (Join-Path $ShareDir 'tools') -Force
$dbgv = Join-Path $RepoRoot 'build\tools\DebugView\Dbgview64a.exe'
if (Test-Path $dbgv) { Copy-Item $dbgv (Join-Path $ShareDir 'tools') -Force }

Write-Host "Staged to $ShareDir :" -ForegroundColor Green
Get-ChildItem $ShareDir -Recurse -File |
    Select-Object @{n='KB';e={[math]::Round($_.Length/1KB,1)}},
                  @{n='Path';e={$_.FullName.Substring($ShareDir.Length+1)}}
$total = (Get-ChildItem $ShareDir -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("total {0:N1} MB (vvfat default FAT16 caps around 500 MB)" -f ($total/1MB))
