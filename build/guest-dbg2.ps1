# Dump the ACPI DBG2 table from inside the guest.
#
# On ARM64 the kernel debugger's serial device is selected with
#   bcdedit /dbgsettings serial busparams:<N>
# where <N> indexes the DBG2 table's debug device array. This tells us whether
# the firmware publishes a debug UART at all, and which index to use, instead of
# guessing through reboots.
#
# Run inside the guest (elevated not strictly required).

$sig = @'
using System;
using System.Runtime.InteropServices;
public static class Fw {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint GetSystemFirmwareTable(uint provider, uint table, byte[] buffer, uint size);
}
'@
Add-Type -TypeDefinition $sig

# 'ACPI' and 'DBG2' as little-endian DWORDs.
$ACPI = [BitConverter]::ToUInt32([Text.Encoding]::ASCII.GetBytes('ACPI'), 0)
$DBG2 = [BitConverter]::ToUInt32([Text.Encoding]::ASCII.GetBytes('2GBD'), 0)   # reversed

$size = [Fw]::GetSystemFirmwareTable($ACPI, $DBG2, $null, 0)
if ($size -eq 0) {
    Write-Warning 'No DBG2 table published by this firmware.'
    Write-Warning 'Serial kernel debugging is not available on this VM; use KDNET or fall back to crash dumps + DebugView.'
    return
}

$buf = New-Object byte[] $size
[void][Fw]::GetSystemFirmwareTable($ACPI, $DBG2, $buf, $size)
Write-Host "DBG2 table present, $size bytes" -ForegroundColor Green

# DBG2 header: standard 36-byte ACPI header, then OffsetDbgDeviceInfo (4) and NumberDbgDeviceInfo (4).
$offset = [BitConverter]::ToUInt32($buf, 36)
$count  = [BitConverter]::ToUInt32($buf, 40)
Write-Host ("Debug device entries: {0} (array at offset 0x{1:X})" -f $count, $offset)

$p = $offset
for ($i = 0; $i -lt $count; $i++) {
    # Debug Device Information: Revision(1) Length(2) NumberOfGenericAddressRegisters(1)
    # NameSpaceStringLength(2) NameSpaceStringOffset(2) OemDataLength(2) OemDataOffset(2)
    # PortType(2) PortSubtype(2) Reserved(2) BaseAddressRegisterOffset(2) AddressSizeOffset(2)
    $len      = [BitConverter]::ToUInt16($buf, $p + 1)
    $portType = [BitConverter]::ToUInt16($buf, $p + 12)
    $subtype  = [BitConverter]::ToUInt16($buf, $p + 14)

    $typeName = switch ($portType) {
        0x8000  { 'Serial' }
        0x8001  { '1394' }
        0x8002  { 'USB' }
        0x8003  { 'Net' }
        default { ('0x{0:X4}' -f $portType) }
    }
    $subName = switch ($subtype) {
        0x0000  { '16550 (fully compatible)' }
        0x0001  { '16550 subset' }
        0x0003  { 'ARM PL011' }
        0x000e  { 'ARM SBSA generic UART' }
        0x000d  { 'ARM SBSA 32-bit' }
        default { ('0x{0:X4}' -f $subtype) }
    }

    # busparams is 1-based over this array.
    Write-Host ("  busparams:{0}  PortType={1}  Subtype={2}" -f ($i + 1), $typeName, $subName) -ForegroundColor Cyan
    $p += $len
}

Write-Host ''
Write-Host 'Current debugger settings:' -ForegroundColor Cyan
bcdedit /dbgsettings
