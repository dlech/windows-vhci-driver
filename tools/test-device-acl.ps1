# Check that \\.\WinVhci is only openable by an administrator.
#
# The INF narrows the device's DACL to SYSTEM and Administrators, because
# whoever holds this handle can inject arbitrary HCI into the local Bluetooth
# stack and see everything the stack sends. This script proves the restriction
# is real rather than merely declared: it opens the device twice, once with the
# caller's own (elevated) token and once with a basic-user token, and expects
# success then ERROR_ACCESS_DENIED.
#
# Run elevated, with NO client holding the device - an exclusive-open collision
# reports a sharing violation, not access denied, which would prove nothing.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$probe = @'
using System;
using System.Runtime.InteropServices;

public static class DevProbe
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string path, uint access, uint share,
        IntPtr sec, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    // Returns 0 on success, else the Win32 error code.
    public static int Try(string path)
    {
        IntPtr h = CreateFileW(path, 0xC0000000u, 0u, IntPtr.Zero, 3u, 0x40000000u, IntPtr.Zero);
        if (h == new IntPtr(-1)) { return Marshal.GetLastWin32Error(); }
        CloseHandle(h);
        return 0;
    }
}
'@

if (-not ('DevProbe' -as [type])) { Add-Type -TypeDefinition $probe }

function Describe($code) {
    switch ($code) {
        0     { 'opened' }
        2     { 'ERROR_FILE_NOT_FOUND (driver not installed?)' }
        5     { 'ERROR_ACCESS_DENIED' }
        32    { 'ERROR_SHARING_VIOLATION (something already holds it)' }
        default { "error $code" }
    }
}

Write-Host '=== as the current (elevated) token ===' -ForegroundColor Cyan
$asAdmin = [DevProbe]::Try('\\.\WinVhci')
Write-Host "  $(Describe $asAdmin)"

Write-Host ''
Write-Host '=== as a basic-user token ===' -ForegroundColor Cyan
# runas /trustlevel:0x20000 runs the command with a restricted "basic user"
# token: same account, but the Administrators SID is no longer granted. No
# password prompt is involved.
$out  = Join-Path $env:TEMP 'acl-probe.txt'
Remove-Item $out -Force -ErrorAction SilentlyContinue
$inner = "Add-Type -TypeDefinition @'`n$probe`n'@; [DevProbe]::Try('\\.\WinVhci') | Set-Content '$out'"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
& runas /trustlevel:0x20000 "powershell -NoProfile -EncodedCommand $encoded" | Out-Null

$deadline = (Get-Date).AddSeconds(25)
while (-not (Test-Path $out) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }

if (-not (Test-Path $out)) {
    Write-Host '  could not run the restricted probe' -ForegroundColor Yellow
    exit 2
}
$asUser = [int](Get-Content $out -Raw).Trim()
Write-Host "  $(Describe $asUser)"

Write-Host ''
if ($asAdmin -eq 0 -and $asUser -eq 5) {
    Write-Host 'RESULT: administrators can open it, ordinary users cannot' -ForegroundColor Green
    exit 0
}
if ($asAdmin -ne 0) {
    Write-Host "RESULT: FAILED - an administrator could not open it ($(Describe $asAdmin))" -ForegroundColor Red
} else {
    Write-Host "RESULT: FAILED - a basic user got '$(Describe $asUser)', expected ERROR_ACCESS_DENIED" -ForegroundColor Red
}
exit 1
