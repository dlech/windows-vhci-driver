# vhcictl - a minimal userspace client for \\.\WinVhci.
#
# Opens the control device, asks for a radio with the FF <opcode> control
# packet, then prints every host-to-controller packet the Windows Bluetooth
# stack emits. That transcript is the specification for M3.
#
# It answers just enough for the stack to keep talking: without a reply to
# HCI_Reset the stack retries the same command forever and the transcript never
# advances past it. Everything it answers is a stand-in, not a controller model.
#
#   .\vhcictl.ps1                 run until Ctrl+C
#   .\vhcictl.ps1 -Seconds 20     run for a bounded time (for scripted use)
#   .\vhcictl.ps1 -NoAnswer       print only, never reply
#
# I/O is OVERLAPPED. A synchronous ReadFile blocks forever once the stack goes
# quiet, so -Seconds could never expire and the process had to be killed - which
# also lost its output. Overlapped reads with a wait timeout make the loop
# bounded and let a client interleave reads and writes.
[CmdletBinding()]
param(
    [int]    $Seconds = 0,          # 0 = until Ctrl+C
    [switch] $NoAnswer,
    [string] $Device = '\\.\WinVhci',
    [string] $BdAddr = '00:11:22:33:44:55',
    [int]    $ReadTimeoutMs = 1000
)

$ErrorActionPreference = 'Stop'

if (-not ('VhciIo' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

// A device path cannot be opened through FileStream reliably, so go straight to
// the Win32 calls. Everything is overlapped so reads can time out.
public static class VhciIo {
    const uint GENERIC_READ         = 0x80000000;
    const uint GENERIC_WRITE        = 0x40000000;
    const uint OPEN_EXISTING        = 3;
    const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    const int  ERROR_IO_PENDING     = 997;
    const uint WAIT_OBJECT_0        = 0;
    const uint WAIT_TIMEOUT         = 258;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string path, uint access, uint share,
        IntPtr sec, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, int toRead, IntPtr read, IntPtr ov);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr h, byte[] buf, int toWrite, IntPtr written, IntPtr ov);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetOverlappedResult(IntPtr h, IntPtr ov, out int transferred, bool wait);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CancelIoEx(IntPtr h, IntPtr ov);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateEventW(IntPtr attrs, bool manualReset, bool initial, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ResetEvent(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    static IntPtr _handle = IntPtr.Zero;
    static IntPtr _event  = IntPtr.Zero;
    static IntPtr _ov     = IntPtr.Zero;

    public static void Open(string path) {
        // Share mode 0: the driver is exclusive anyway, and asking for sharing
        // would only hide a second client behind a confusing error later.
        _handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0,
                              IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        if (_handle == (IntPtr)(-1)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "opening " + path + " failed");
        }
        _event = CreateEventW(IntPtr.Zero, true, false, null);
        _ov    = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeOverlapped)));
    }

    static void PrepareOverlapped() {
        NativeOverlapped ov = new NativeOverlapped();
        ResetEvent(_event);
        ov.EventHandle = _event;
        Marshal.StructureToPtr(ov, _ov, false);
    }

    // Returns the number of bytes read, or 0 if the wait timed out.
    public static int Read(byte[] buf, int timeoutMs) {
        PrepareOverlapped();

        int n;
        if (ReadFile(_handle, buf, buf.Length, IntPtr.Zero, _ov)) {
            GetOverlappedResult(_handle, _ov, out n, false);
            return n;
        }

        int err = Marshal.GetLastWin32Error();
        if (err != ERROR_IO_PENDING) {
            throw new Win32Exception(err, "ReadFile failed");
        }

        uint wait = WaitForSingleObject(_event, (uint)timeoutMs);
        if (wait == WAIT_TIMEOUT) {
            // Cancel and reap, so the next read starts from a clean state.
            CancelIoEx(_handle, _ov);
            GetOverlappedResult(_handle, _ov, out n, true);
            return 0;
        }
        if (wait != WAIT_OBJECT_0) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "wait failed");
        }

        if (!GetOverlappedResult(_handle, _ov, out n, false)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetOverlappedResult failed");
        }
        return n;
    }

    public static void Write(byte[] buf, int len) {
        // Writes complete promptly; a separate OVERLAPPED keeps them from
        // colliding with an outstanding read on the shared one.
        IntPtr evt = CreateEventW(IntPtr.Zero, true, false, null);
        IntPtr ov  = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeOverlapped)));
        try {
            NativeOverlapped o = new NativeOverlapped();
            o.EventHandle = evt;
            Marshal.StructureToPtr(o, ov, false);

            int n;
            if (!WriteFile(_handle, buf, len, IntPtr.Zero, ov)) {
                int err = Marshal.GetLastWin32Error();
                if (err != ERROR_IO_PENDING) {
                    throw new Win32Exception(err, "WriteFile failed");
                }
                WaitForSingleObject(evt, 5000);
            }
            if (!GetOverlappedResult(_handle, ov, out n, true)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "write did not complete");
            }
        } finally {
            Marshal.FreeHGlobal(ov);
            CloseHandle(evt);
        }
    }

    public static void Close() {
        if (_handle != IntPtr.Zero && _handle != (IntPtr)(-1)) { CloseHandle(_handle); }
        if (_event  != IntPtr.Zero) { CloseHandle(_event); }
        if (_ov     != IntPtr.Zero) { Marshal.FreeHGlobal(_ov); }
        _handle = IntPtr.Zero;
    }
}
'@
}

# ---- HCI vocabulary ---------------------------------------------------------

$H4_COMMAND = 0x01
$H4_ACL     = 0x02
$H4_EVENT   = 0x04
$H4_VENDOR  = 0xFF

# Opcodes the stack is expected to use during bring-up. OGF is the top 6 bits,
# OCF the low 10.
$OpcodeNames = @{
    0x0C03 = 'HCI_Reset'
    0x0C01 = 'Set_Event_Mask'
    0x0C63 = 'Set_Event_Mask_Page_2'
    0x0C6C = 'Read_LE_Host_Support'
    0x0C6D = 'Write_LE_Host_Support'
    0x1001 = 'Read_Local_Version_Information'
    0x1002 = 'Read_Local_Supported_Commands'
    0x1003 = 'Read_Local_Supported_Features'
    0x1005 = 'Read_Buffer_Size'
    0x1009 = 'Read_BD_ADDR'
    0x2001 = 'LE_Set_Event_Mask'
    0x2002 = 'LE_Read_Buffer_Size'
    0x2003 = 'LE_Read_Local_Supported_Features'
    0x200F = 'LE_Read_White_List_Size'
}

function Get-OpcodeName([int]$opcode) {
    if ($OpcodeNames.ContainsKey($opcode)) { return $OpcodeNames[$opcode] }
    return '?'
}

function New-CommandComplete([int]$opcode, [byte[]]$returnParams) {
    # Command Complete (Core spec 7.7.14): event code 0x0E, parameter length,
    # Num_HCI_Command_Packets, the opcode being completed, then the command's
    # own return parameters, which begin with a status byte.
    $params = @([byte]1, [byte]($opcode -band 0xFF), [byte](($opcode -shr 8) -band 0xFF)) + $returnParams
    return @([byte]0x0E, [byte]$params.Length) + $params
}

function Get-Answer([int]$opcode) {
    switch ($opcode) {
        0x0C03 { return New-CommandComplete $opcode @([byte]0x00) }   # Reset: status only

        0x1009 {
            # Read_BD_ADDR returns status plus the address, little endian.
            $bytes = @(($BdAddr -split '[:-]') | ForEach-Object { [Convert]::ToByte($_, 16) })
            [array]::Reverse($bytes)
            return New-CommandComplete $opcode (@([byte]0x00) + $bytes)
        }

        default {
            # 0x01 = Unknown HCI Command. Answering honestly beats claiming
            # success with no return parameters, which would leave the stack
            # parsing whatever happened to follow.
            return New-CommandComplete $opcode @([byte]0x01)
        }
    }
}

# ---- main -------------------------------------------------------------------

Write-Host "opening $Device ..." -ForegroundColor Cyan
[VhciIo]::Open($Device)
Write-Host 'opened' -ForegroundColor Green

try {
    # FF <opcode> asks for a radio; the driver replies FF FF <opcode> <id_lo> <id_hi>.
    Write-Host 'requesting a radio (FF 00) ...' -ForegroundColor Cyan
    [VhciIo]::Write([byte[]]@($H4_VENDOR, 0x00), 2)

    $buf = New-Object byte[] 1026
    $deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [DateTime]::MaxValue }

    while ((Get-Date) -lt $deadline) {
        $n = [VhciIo]::Read($buf, $ReadTimeoutMs)
        if ($n -le 0) { continue }        # timed out; check the deadline again

        $type = $buf[0]
        $body = if ($n -gt 1) { $buf[1..($n - 1)] } else { @() }
        $hex  = ($body | ForEach-Object { $_.ToString('x2') }) -join ' '
        $ts   = (Get-Date).ToString('HH:mm:ss.fff')

        if ($type -eq $H4_COMMAND -and $body.Length -ge 3) {
            #
            # Cast to [int] BEFORE shifting. PowerShell's -shl performs the
            # shift in the left operand's type, so [byte]0x0c -shl 8 is 0, not
            # 0x0c00 - which silently decoded HCI_Reset (0x0c03) as 0x0003 and
            # made us answer a Command Complete for an opcode the stack had
            # never sent.
            #
            $opcode = [int]$body[0] -bor ([int]$body[1] -shl 8)
            $ogf    = $opcode -shr 10
            $ocf    = $opcode -band 0x3FF
            Write-Host ("{0}  CMD  0x{1:x4}  OGF 0x{2:x2} OCF 0x{3:x3}  plen {4}  {5}" -f `
                $ts, $opcode, $ogf, $ocf, $body[2], (Get-OpcodeName $opcode)) -ForegroundColor Yellow
            Write-Host "            $hex" -ForegroundColor DarkGray

            if (-not $NoAnswer) {
                $evt = Get-Answer $opcode
                [VhciIo]::Write(([byte[]](@([byte]$H4_EVENT) + $evt)), $evt.Length + 1)
                Write-Host ("            -> Command Complete ({0} bytes)" -f $evt.Length) `
                    -ForegroundColor DarkGreen
            }
        }
        elseif ($type -eq $H4_ACL)    { Write-Host "$ts  ACL  $hex" -ForegroundColor Magenta }
        elseif ($type -eq $H4_VENDOR) { Write-Host "$ts  CTRL $hex" -ForegroundColor Cyan }
        else                          { Write-Host ("{0}  0x{1:x2} {2}" -f $ts, $type, $hex) }
    }
} finally {
    Write-Host 'closing (this removes the radio)' -ForegroundColor Cyan
    [VhciIo]::Close()
}
