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
    0x0C13 = 'Write_Local_Name'
    0x0C18 = 'Write_Page_Timeout'
    0x0C1A = 'Write_Scan_Enable'
    0x0C1C = 'Write_Page_Scan_Activity'
    0x0C1E = 'Write_Inquiry_Scan_Activity'
    0x0C20 = 'Write_Authentication_Enable'
    0x0C23 = 'Read_Class_of_Device'
    0x0C24 = 'Write_Class_of_Device'
    0x0C25 = 'Read_Voice_Setting'
    0x0C33 = 'Host_Buffer_Size'
    0x0C45 = 'Write_Inquiry_Mode'
    0x0C52 = 'Write_Extended_Inquiry_Response'
    0x0C58 = 'Read_Inquiry_Response_Transmit_Power_Level'
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
    0x2005 = 'LE_Set_Random_Address'
    0x2006 = 'LE_Set_Advertising_Parameters'
    0x2007 = 'LE_Read_Advertising_Channel_Tx_Power'
    0x2008 = 'LE_Set_Advertising_Data'
    0x2009 = 'LE_Set_Scan_Response_Data'
    0x200A = 'LE_Set_Advertise_Enable'
    0x201C = 'LE_Read_Supported_States'
    0x2023 = 'LE_Read_Maximum_Data_Length'
}

function Get-OpcodeName([int]$opcode) {
    if ($OpcodeNames.ContainsKey($opcode)) { return $OpcodeNames[$opcode] }
    return '?'
}

# Commands whose Command Complete carries a status byte and nothing else. Nearly
# every Write_*/Set_* configuration command is in this class, so listing them is
# cheaper than a round trip through the stack for each one.
$StatusOnlyOpcodes = [System.Collections.Generic.HashSet[int]]@(
    0x0C01,  # Set_Event_Mask
    0x0C05,  # Set_Event_Filter
    0x0C13,  # Write_Local_Name
    0x0C16,  # Write_Connection_Accept_Timeout
    0x0C18,  # Write_Page_Timeout
    0x0C1A,  # Write_Scan_Enable
    0x0C1C,  # Write_Page_Scan_Activity
    0x0C1E,  # Write_Inquiry_Scan_Activity
    0x0C20,  # Write_Authentication_Enable
    0x0C24,  # Write_Class_of_Device
    0x0C26,  # Write_Voice_Setting
    0x0C2D,  # Write_Automatic_Flush_Timeout
    0x0C31,  # Set_Controller_To_Host_Flow_Control
    0x0C33,  # Host_Buffer_Size
    0x0C3A,  # Write_Current_IAC_LAP
    0x0C45,  # Write_Inquiry_Mode
    0x0C47,  # Write_Page_Scan_Type
    0x0C52,  # Write_Extended_Inquiry_Response
    0x0C56,  # Write_Simple_Pairing_Mode
    0x0C63,  # Set_Event_Mask_Page_2
    0x0C6D,  # Write_LE_Host_Support
    0x0C7C,  # Write_Secure_Connections_Host_Support
    0x2001,  # LE_Set_Event_Mask
    0x2005,  # LE_Set_Random_Address
    0x2006,  # LE_Set_Advertising_Parameters
    0x2008,  # LE_Set_Advertising_Data
    0x2009,  # LE_Set_Scan_Response_Data
    0x200A,  # LE_Set_Advertise_Enable
    0x200B,  # LE_Set_Scan_Parameters
    0x200C,  # LE_Set_Scan_Enable
    0x2010,  # LE_Clear_White_List
    0x2011,  # LE_Add_Device_To_White_List
    0x2012,  # LE_Remove_Device_From_White_List
    0x2024,  # LE_Write_Suggested_Default_Data_Length
    0x2031   # LE_Set_Default_PHY
)

function New-CommandComplete([int]$opcode, [byte[]]$returnParams) {
    # Command Complete (Core spec 7.7.14): event code 0x0E, parameter length,
    # Num_HCI_Command_Packets, the opcode being completed, then the command's
    # own return parameters, which begin with a status byte.
    $params = @([byte]1, [byte]($opcode -band 0xFF), [byte](($opcode -shr 8) -band 0xFF)) + $returnParams
    return @([byte]0x0E, [byte]$params.Length) + $params
}

# Opcodes with a real, parameter-carrying answer below. Kept beside
# $StatusOnlyOpcodes so the transcript can say plainly which commands were
# actually answered and which were refused - "no name for it" and "no answer for
# it" are different problems and were previously indistinguishable in the output.
$HandledOpcodes = [System.Collections.Generic.HashSet[int]]@(
    0x0C03, 0x0C23, 0x0C25, 0x0C58,
    0x1001, 0x1002, 0x1003, 0x1005, 0x1009,
    0x2002, 0x2003, 0x2007, 0x200F, 0x201C, 0x2023
)

function Get-Answer([int]$opcode) {
    switch ($opcode) {
        0x0C03 { return New-CommandComplete $opcode @([byte]0x00) }   # Reset: status only

        0x1009 {
            # Read_BD_ADDR returns status plus the address, little endian.
            $bytes = @(($BdAddr -split '[:-]') | ForEach-Object { [Convert]::ToByte($_, 16) })
            [array]::Reverse($bytes)
            return New-CommandComplete $opcode (@([byte]0x00) + $bytes)
        }

        0x1002 {
            # Read_Local_Supported_Commands: status plus a 64-octet bitmask, one
            # bit per HCI command. Advertise only what this controller actually
            # answers - claiming a command the simulator does not implement just
            # invites the stack to use it.
            #
            #   octet 5  bit 6  Set_Event_Mask
            #   octet 5  bit 7  Reset
            #   octet 14 bit 3  Read_Local_Version_Information
            #   octet 14 bit 4  Read_Local_Supported_Commands
            #   octet 14 bit 5  Read_Local_Supported_Features
            #   octet 14 bit 7  Read_Buffer_Size
            #   octet 15 bit 1  Read_BD_ADDR
            #
            $mask = New-Object byte[] 64
            $mask[5]  = 0xC0
            $mask[14] = 0xB8
            $mask[15] = 0x02
            return New-CommandComplete $opcode (@([byte]0x00) + $mask)
        }

        0x1005 {
            # Read_Buffer_Size: status, ACL packet length (2), synchronous
            # packet length (1), then the number of each the controller can
            # buffer (2 + 2).
            #
            # The ACL length matches MaxAclTransferInSize reported to BthPort in
            # QUERY_CAPABILITIES - the two must agree or the stack will size
            # packets the transport cannot carry. Synchronous is zero because
            # there is no SCO path (we claim ScoSupportHCIBypass only because the
            # DDI insists on it, and never deliver sideband audio).
            $aclLen   = 1021
            $aclCount = 8
            return New-CommandComplete $opcode @(
                [byte]0x00,
                [byte]($aclLen -band 0xFF), [byte](($aclLen -shr 8) -band 0xFF),
                [byte]0x00,
                [byte]($aclCount -band 0xFF), [byte](($aclCount -shr 8) -band 0xFF),
                [byte]0x00, [byte]0x00
            )
        }

        0x1001 {
            # Read_Local_Version_Information: status, HCI version, HCI revision
            # (2), LMP version, manufacturer (2), LMP subversion (2).
            # 0x0C is Bluetooth 5.3; 0x05F1 is the Linux Foundation's assigned
            # company identifier, which is what other virtual controllers report.
            return New-CommandComplete $opcode @(
                [byte]0x00,
                [byte]0x0C,
                [byte]0x00, [byte]0x00,
                [byte]0x0C,
                [byte]0xF1, [byte]0x05,
                [byte]0x00, [byte]0x00
            )
        }

        0x1003 {
            # Read_Local_Supported_Features: status plus the 8-octet LMP feature
            # mask. This is a realistic BR/EDR + LE value rather than a
            # hand-rolled minimal one, because a controller that claims almost
            # nothing tends to be abandoned by the stack rather than driven.
            # Anything claimed here that the simulator cannot do will show up as
            # a command in this transcript, which is exactly how we find out.
            return New-CommandComplete $opcode (@([byte]0x00) + [byte[]]@(
                0xbf, 0xfe, 0xcf, 0xfe, 0xdb, 0xff, 0x7b, 0x87))
        }

        0x0C58 {
            # Read_Inquiry_Response_Transmit_Power_Level: status plus a signed
            # dBm value.
            return New-CommandComplete $opcode @([byte]0x00, [byte]0x00)
        }

        0x0C23 {
            # Read_Class_of_Device: status plus a 3-octet class.
            return New-CommandComplete $opcode @([byte]0x00, [byte]0x00, [byte]0x00, [byte]0x00)
        }

        0x0C25 {
            # Read_Voice_Setting: status plus a 2-octet setting.
            return New-CommandComplete $opcode @([byte]0x00, [byte]0x60, [byte]0x00)
        }

        0x2003 {
            # LE_Read_Local_Supported_Features: status plus an 8-octet LE
            # feature mask. Bit 0 is LE Encryption.
            return New-CommandComplete $opcode (@([byte]0x00) + [byte[]]@(
                0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
        }

        0x2002 {
            # LE_Read_Buffer_Size: status, LE ACL packet length (2), and how
            # many the controller can buffer (1).
            return New-CommandComplete $opcode @([byte]0x00, [byte]0xFB, [byte]0x00, [byte]0x08)
        }

        0x2007 {
            # LE_Read_Advertising_Physical_Channel_Tx_Power: status plus a
            # signed dBm level.
            return New-CommandComplete $opcode @([byte]0x00, [byte]0x00)
        }

        0x201C {
            # LE_Read_Supported_States: status plus an 8-octet bitmask of the
            # state combinations the controller can be in simultaneously.
            return New-CommandComplete $opcode (@([byte]0x00) + [byte[]]@(
                0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x00))
        }

        0x200F {
            # LE_Read_White_List_Size: status plus the entry count.
            return New-CommandComplete $opcode @([byte]0x00, [byte]0x08)
        }

        0x2023 {
            # LE_Read_Maximum_Data_Length: status plus max TX octets/time and
            # max RX octets/time, two octets each.
            return New-CommandComplete $opcode @(
                [byte]0x00,
                [byte]0xFB, [byte]0x00, [byte]0x48, [byte]0x08,
                [byte]0xFB, [byte]0x00, [byte]0x48, [byte]0x08)
        }

        default {
            # Most configuration commands - the Write_* and Set_* family - return
            # nothing but a status byte, so they are handled by shape rather than
            # one at a time. Only commands that return real parameters need their
            # own case above.
            if ($StatusOnlyOpcodes.Contains($opcode)) {
                return New-CommandComplete $opcode @([byte]0x00)
            }
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
                $evt     = Get-Answer $opcode
                $handled = $HandledOpcodes.Contains($opcode) -or $StatusOnlyOpcodes.Contains($opcode)
                [VhciIo]::Write(([byte[]](@([byte]$H4_EVENT) + $evt)), $evt.Length + 1)
                if ($handled) {
                    Write-Host ("            -> Command Complete ({0} bytes)" -f $evt.Length) `
                        -ForegroundColor DarkGreen
                } else {
                    Write-Host '            -> UNANSWERED (Unknown HCI Command)' -ForegroundColor Red
                }
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
