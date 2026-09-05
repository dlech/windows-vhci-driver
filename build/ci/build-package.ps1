# Build and test-sign a ready-to-install winvhci package.
#
#     build\ci\build-package.ps1 -Platform x64 -Configuration Debug -OutDir out
#
# Runs on a GitHub Actions runner or on a developer machine. The WDK comes from
# NuGet (see packages.config) rather than from whatever happens to be installed,
# so CI and local builds use the same toolchain - which matters for a driver
# whose correctness rests on measured buffer layouts.
#
# Signing is done here rather than by the WDK's own SignMode=TestSign, because
# that mode has no default certificate: GenerateTestCertificate,
# CertificateStoreName and SubjectName have no defaults anywhere in the WDK
# props, and the WDKTestCert name lives only in the Visual Studio "Create Test
# Certificate" dialog. On a command-line build the sign task just searches
# CurrentUser\My, and on a fresh runner that store is empty - the build then
# fails and RemoveUnsignedOutput deletes the .sys and .cat on the way out.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('x64', 'ARM64')] [string]$Platform,
    [ValidateSet('Debug', 'Release')]                   [string]$Configuration = 'Debug',
    [string]$OutDir       = 'out',
    [string]$WdkVersion   = '10.0.28000.2526',
    [string]$SdkVersion   = '10.0.28000.0',
    [string]$CertSubject  = 'CN=winvhci CI test signing'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repo
try {

function Step([string]$Text) { Write-Host ''; Write-Host "== $Text ==" -ForegroundColor Cyan }
# NOTE: the parameter must not be called $Args. That is an automatic variable
# holding a function's unbound arguments, so declaring it here shadows the
# caller's array with an empty one and the command runs with no arguments at
# all - which looks exactly like the command itself failing.
function Run([string]$Exe, [string[]]$Arguments) {
    Write-Host "  $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path -Leaf $Exe) failed with exit code $LASTEXITCODE" }
}

# ---------------------------------------------------------------------------
Step 'Locating the NuGet WDK'

$pkgArch = $Platform.ToLower()
$wdkRoot = Join-Path $repo "packages\Microsoft.Windows.WDK.$pkgArch.$WdkVersion\c"

# Every WDK import in the toolset is Exists()-guarded, so a mismatch between the
# package layout and WindowsTargetPlatformVersion produces NO error - just a
# project with no driver targets and a later failure that reads like a missing
# ntddk.h. Assert the two paths that matter, so it fails as itself.
foreach ($p in @(
    (Join-Path $wdkRoot "build\$SdkVersion\WindowsDriver.Common.targets"),
    (Join-Path $wdkRoot "Include\$SdkVersion\km\bthxddi.h")
)) {
    if (-not (Test-Path $p)) { throw "WDK NuGet layout unexpected, missing: $p" }
    Write-Host "  found $p"
}

# ---------------------------------------------------------------------------
Step 'Locating MSBuild'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere not found at $vswhere" }
$vsPath = & $vswhere -latest -products * -property installationPath
if (-not $vsPath) { throw 'No Visual Studio installation found.' }

# The host architecture matters and the default is wrong. The WDK's package
# verifier P/Invokes infverif.dll *inside the MSBuild process*, and the WDK
# ships only bin\x64 and bin\arm64 copies - so an x86 MSBuild fails with
# "Unable to load DLL 'x86\InfVerif.dll'". MSBuild\Current\Bin\MSBuild.exe is
# x86 in every VS install, including VS 2026.
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$msbuild  = Join-Path $vsPath "MSBuild\Current\Bin\$hostArch\MSBuild.exe"
if (-not (Test-Path $msbuild)) { throw "64-bit MSBuild not found at $msbuild" }
Write-Host "  $msbuild"

# ---------------------------------------------------------------------------
Step "Building $Platform $Configuration"

$logDir = Join-Path $repo 'artifacts\logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Run $msbuild @(
    "$repo\winvhci\winvhci.vcxproj"
    "-p:Configuration=$Configuration"
    "-p:Platform=$Platform"
    # Drives WDKBuildFolder; must match the NuGet package's build\<ver>\ folder.
    "-p:WindowsTargetPlatformVersion=$SdkVersion"
    # 0xA000010 = 10.0.26100 (24H2). Without this the build inherits
    # NTDDI_VERSION 0xA000012, which the WDK maps to build 28000 - newer than
    # any released Windows, so an unresolvable kernel import would look like a
    # driver bug rather than a targeting mistake.
    '-p:_NT_TARGET_VERSION=0xA000010'
    # We sign below instead; this still leaves Inf2Cat and InfVerif running
    # in-build, so the INF validation gate is kept.
    '-p:SignMode=Off'
    '-m', '-nologo', '-v:minimal'
    "-bl:$logDir\winvhci.$Platform.$Configuration.binlog"
)

# The WDK stages a ready-to-install package next to the binary. OutDir is
# deliberately left at the WDK default - redirecting it breaks this step.
$pkg = Join-Path $repo "winvhci\$Platform\$Configuration\winvhci"
if (-not (Test-Path (Join-Path $pkg 'winvhci.sys'))) { throw "No driver package at $pkg" }

# ---------------------------------------------------------------------------
Step 'Creating an ephemeral test-signing certificate'

# Test signing accepts a signature from ANY certificate - the chain need not
# reach a trusted root - so a per-job self-signed cert is sufficient and no
# secret is needed. That is what lets pull requests from forks produce a fully
# installable package.
$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $CertSubject `
    -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
    -CertStoreLocation Cert:\CurrentUser\My `
    -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddYears(5) `
    -TextExtension @(
        '2.5.29.37={text}1.3.6.1.5.5.7.3.3',   # EKU: Code Signing
        '2.5.29.19={text}'                     # Basic Constraints: end entity
    )
Write-Host "  thumbprint $($cert.Thumbprint)"

$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\$($Platform.ToLower())\\" -or $_.FullName -match '\\x64\\' } |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe not found in the installed Windows Kits.' }
Write-Host "  $($signtool.FullName)"

$inf2cat = Join-Path $wdkRoot "bin\$SdkVersion\x86\Inf2Cat.exe"   # x86-only by design
if (-not (Test-Path $inf2cat)) { throw "Inf2Cat not found at $inf2cat" }

# ---------------------------------------------------------------------------
Step 'Signing'

# Order matters: the catalog hashes the file bytes, so the .sys must be signed
# BEFORE the catalog is generated. Signing it afterwards makes pnputil reject
# the package with "hash for file is not present in the specified catalog file".
Run $signtool.FullName @('sign', '/fd', 'sha256', '/ph', '/sha1', $cert.Thumbprint, "$pkg\winvhci.sys")

# ARM64 gets the Server10_ prefix, everything else 10_<arch>; this mirrors the
# WDK's own defaults in WindowsDriver.OS.Props.
$osList = if ($Platform -eq 'ARM64') { 'Server10_arm64' } else { '10_x64' }
Run $inf2cat @("/driver:$pkg", "/os:$osList", '/verbose')

Run $signtool.FullName @('sign', '/fd', 'sha256', '/sha1', $cert.Thumbprint, "$pkg\winvhci.cat")

# ---------------------------------------------------------------------------
Step 'Verifying the signatures'

$cerPath = Join-Path $repo 'winvhci-test.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null

# Check that both files carry a signature from the certificate we just made.
#
# Deliberately NOT `signtool verify /pa`: that requires the signing certificate
# to chain to a trusted root, which for a self-signed cert means importing it
# into a root store first. Doing that on a developer machine is an actual trust
# change, and it is not even possible unattended - Import-Certificate into
# CurrentUser\Root raises a confirmation dialog and fails with "UI is not
# allowed in this operation" in a non-interactive session.
#
# What can be checked here without mutating anything is the part we control:
# that the signature exists and is ours. Whether the signature is TRUSTED is a
# property of the target machine, not of the build, and it is checked where it
# actually matters - pnputil refuses the package at install time if the
# certificate is not in Root and TrustedPublisher, which is what smoke.ps1 sets
# up and exercises for real.
foreach ($f in 'winvhci.sys', 'winvhci.cat') {
    $sig = Get-AuthenticodeSignature (Join-Path $pkg $f)
    if (-not $sig.SignerCertificate) { throw "$f is not signed" }
    if ($sig.SignerCertificate.Thumbprint -ne $cert.Thumbprint) {
        throw "$f is signed by $($sig.SignerCertificate.Thumbprint), expected $($cert.Thumbprint)"
    }
    # 'UnknownError' here is the expected status for a self-signed chain on a
    # machine that does not trust it, and says nothing about the signature.
    Write-Host "  $f signed by $($sig.SignerCertificate.Subject) [$($sig.Status)]"
}

# The private key has done its job. Leave nothing behind in the personal store.
Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue
Write-Host '  removed the ephemeral certificate from CurrentUser\My'

# ---------------------------------------------------------------------------
Step 'Staging the artifact'

# One directory, so actions/upload-artifact@v4 reproduces a known tree - it
# roots the archive at the common ancestor of whatever paths it is given.
$stage = Join-Path $repo $OutDir
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $stage 'package') -Force | Out-Null
Copy-Item "$pkg\winvhci.sys", "$pkg\winvhci.inf", "$pkg\winvhci.cat" (Join-Path $stage 'package')
Move-Item $cerPath (Join-Path $stage 'winvhci-test.cer') -Force

$inf = Get-Content (Join-Path $stage 'package\winvhci.inf') -Raw
$driverVer = if ($inf -match '(?m)^\s*DriverVer\s*=\s*(.+)$') { $Matches[1].Trim() } else { 'unknown' }

[ordered]@{
    platform        = $Platform
    configuration   = $Configuration
    commit          = (git rev-parse HEAD 2>$null)
    driverVer       = $driverVer
    wdkNuGetVersion = $WdkVersion
    sdkVersion      = $SdkVersion
    inf2catOs       = $osList
    certThumbprint  = $cert.Thumbprint
    certSubject     = $CertSubject
    hardwareId      = 'root\winvhci'
    childCompatId   = 'MS_BTHX_BTHMINI'
    sysSha256       = (Get-FileHash (Join-Path $stage 'package\winvhci.sys') -Algorithm SHA256).Hash
    catSha256       = (Get-FileHash (Join-Path $stage 'package\winvhci.cat') -Algorithm SHA256).Hash
} | ConvertTo-Json | Set-Content (Join-Path $stage 'build-info.json') -Encoding UTF8

Get-ChildItem $stage -Recurse -File | ForEach-Object {
    Write-Host ("  {0,-40} {1,8} bytes" -f $_.FullName.Substring($stage.Length + 1), $_.Length)
}

Write-Host ''
Write-Host "Package staged in $stage" -ForegroundColor Green

}
finally { Pop-Location }
