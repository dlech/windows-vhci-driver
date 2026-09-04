# Shared overlapped I/O helper for \\.\WinVhci.
#
# Dot-source this from a client script:
#     . "$PSScriptRoot\vhci-io.ps1"
#
# A device path cannot be opened through FileStream reliably, so this goes
# straight to the Win32 calls. I/O is OVERLAPPED because a synchronous ReadFile
# blocks forever once the Bluetooth stack goes quiet - a bounded run could never
# terminate, and killing the process also lost its buffered output.

if (-not ('VhciIo' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

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
        // A separate OVERLAPPED per write keeps it from colliding with an
        // outstanding read on the shared one.
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

# H4 packet type bytes.
$script:H4_COMMAND = 0x01
$script:H4_ACL     = 0x02
$script:H4_SCO     = 0x03
$script:H4_EVENT   = 0x04
$script:H4_ISO     = 0x05
$script:H4_VENDOR  = 0xFF

function Get-H4FrameLength {
    <#
    .SYNOPSIS
        Length of the complete H4 frame at the start of $Buffer, or 0 if more
        bytes are needed.

    .DESCRIPTION
        \\.\WinVhci delivers exactly one packet per ReadFile, but TCP is a byte
        stream, so anything bridged from a socket has to be reassembled into
        whole packets before being written to the device. Each H4 type carries
        its length differently.
    #>
    param([byte[]]$Buffer, [int]$Count)

    if ($Count -lt 1) { return 0 }

    switch ($Buffer[0]) {
        0x01 {   # Command: opcode (2) + parameter length (1)
            if ($Count -lt 4) { return 0 }
            $need = 4 + $Buffer[3]
        }
        0x02 {   # ACL: handle (2) + data length (2)
            if ($Count -lt 5) { return 0 }
            $need = 5 + ([int]$Buffer[3] -bor ([int]$Buffer[4] -shl 8))
        }
        0x03 {   # SCO: handle (2) + data length (1)
            if ($Count -lt 4) { return 0 }
            $need = 4 + $Buffer[3]
        }
        0x04 {   # Event: event code (1) + parameter length (1)
            if ($Count -lt 3) { return 0 }
            $need = 3 + $Buffer[2]
        }
        0x05 {   # ISO: handle (2) + 14-bit data length
            if ($Count -lt 5) { return 0 }
            $need = 5 + (([int]$Buffer[3] -bor ([int]$Buffer[4] -shl 8)) -band 0x3FFF)
        }
        default {
            throw ("unknown H4 packet type 0x{0:x2} in stream" -f $Buffer[0])
        }
    }

    if ($Count -lt $need) { return 0 }
    return $need
}
