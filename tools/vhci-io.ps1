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

    // How long a write may pend before it is treated as a stalled stack rather
    // than as backpressure. Generous: the driver releases a pended write as
    // soon as the stack takes one packet, so reaching this is a fault.
    const uint WRITE_TIMEOUT_MS     = 5000;

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

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr h, uint code,
        IntPtr inBuf, uint inLen, IntPtr outBuf, uint outLen,
        out uint returned, IntPtr overlapped);

    static IntPtr _handle = IntPtr.Zero;

    // Exposed so a caller can issue DeviceIoControl on the same handle -
    // IOCTL_WINVHCI_GET_STATS, in particular. Read-only: the handle's lifetime
    // stays owned by Open and Close.
    public static IntPtr Handle { get { return _handle; } }
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
                // The timeout has to be acted on. This used to ignore the
                // wait result and fall straight into GetOverlappedResult with
                // bWait = true, which waits FOREVER - so the 5 s bound was
                // decorative and a stalled write hung the caller outright.
                //
                // That was harmless only while the driver failed a write the
                // instant its backlog was full. The driver now pends the write
                // for backpressure instead, so a write legitimately blocks
                // until the Bluetooth stack drains one packet, and "the stack
                // stopped draining" has to be reported rather than waited on.
                if (WaitForSingleObject(evt, WRITE_TIMEOUT_MS) == WAIT_TIMEOUT) {
                    CancelIoEx(_handle, ov);
                    // Collect the cancelled request so the OVERLAPPED is not
                    // freed while the driver may still own it.
                    GetOverlappedResult(_handle, ov, out n, true);
                    throw new TimeoutException(
                        "write did not complete within " + WRITE_TIMEOUT_MS +
                        " ms. The driver pends a write when its backlog to the " +
                        "Bluetooth stack is full, so this means the stack " +
                        "stopped draining - check IOCTL_WINVHCI_GET_STATS.");
                }
            }
            if (!GetOverlappedResult(_handle, ov, out n, true)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "write did not complete");
            }
        } finally {
            Marshal.FreeHGlobal(ov);
            CloseHandle(evt);
        }
    }

    // --- writes that are allowed to still be in flight --------------------
    //
    // Write() above waits for completion, which cannot express the one case
    // worth testing: a write that the driver has PENDED for backpressure and
    // will complete later. Waiting for it is precisely what must not happen -
    // the caller has to be able to issue more writes, and then do the thing
    // that releases them.
    //
    // So these split the operation. BeginWrite issues it and returns a token;
    // EndWrite collects the result. The buffer is pinned for the duration,
    // because the driver may copy from it after BeginWrite has returned.

    public class PendingWrite {
        public IntPtr Event;
        public IntPtr Overlapped;
        public GCHandle Pin;
        public int Length;
        public bool Completed;
    }

    public static PendingWrite BeginWrite(byte[] buf, int len) {
        PendingWrite w = new PendingWrite();
        w.Event      = CreateEventW(IntPtr.Zero, true, false, null);
        w.Overlapped = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeOverlapped)));
        w.Pin        = GCHandle.Alloc(buf, GCHandleType.Pinned);
        w.Length     = len;

        NativeOverlapped o = new NativeOverlapped();
        o.EventHandle = w.Event;
        Marshal.StructureToPtr(o, w.Overlapped, false);

        if (!WriteFile(_handle, buf, len, IntPtr.Zero, w.Overlapped)) {
            int err = Marshal.GetLastWin32Error();
            if (err != ERROR_IO_PENDING) {
                FreeWrite(w);
                throw new Win32Exception(err, "WriteFile failed");
            }
        } else {
            w.Completed = true;
        }
        return w;
    }

    // True if the write completed within the timeout. Throws if it failed for
    // any reason other than not having finished yet.
    public static bool EndWrite(PendingWrite w, int timeoutMs) {
        try {
            if (!w.Completed) {
                if (WaitForSingleObject(w.Event, (uint)timeoutMs) != WAIT_OBJECT_0) {
                    return false;
                }
            }
            int n;
            if (!GetOverlappedResult(_handle, w.Overlapped, out n, true)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "write failed");
            }
            if (n != w.Length) {
                throw new InvalidOperationException(
                    "short write: " + n + " of " + w.Length + " bytes");
            }
            return true;
        } finally {
            FreeWrite(w);
        }
    }

    // Abandon a write that is still pending. Cancels it and reaps the result,
    // so the OVERLAPPED and the pinned buffer are not released while the
    // driver may still be using them.
    public static void CancelWrite(PendingWrite w) {
        int n;
        CancelIoEx(_handle, w.Overlapped);
        GetOverlappedResult(_handle, w.Overlapped, out n, true);
        FreeWrite(w);
    }

    static void FreeWrite(PendingWrite w) {
        if (w.Pin.IsAllocated) { w.Pin.Free(); }
        if (w.Overlapped != IntPtr.Zero) { Marshal.FreeHGlobal(w.Overlapped); w.Overlapped = IntPtr.Zero; }
        if (w.Event != IntPtr.Zero) { CloseHandle(w.Event); w.Event = IntPtr.Zero; }
    }

    // IOCTL_WINVHCI_GET_STATS, from winvhci/winvhci.h:
    //   CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_ACCESS)
    //
    // Assembled from its parts rather than written as a literal. A
    // hand-computed value here was wrong on the first attempt (0x00222004
    // instead of 0x00226000), and a wrong control code comes back as
    // "incorrect function" - which reads as the driver not implementing the
    // IOCTL rather than as the caller asking for the wrong one.
    const uint FILE_DEVICE_UNKNOWN = 0x22;
    const uint METHOD_BUFFERED     = 0;
    const uint FILE_READ_ACCESS    = 1;
    public const uint IOCTL_WINVHCI_GET_STATS =
        (FILE_DEVICE_UNKNOWN << 16) | (FILE_READ_ACCESS << 14) |
        (0x800 << 2) | METHOD_BUFFERED;

    // Mirrors WINVHCI_STATS. Size is the driver's own sizeof, so a mismatch
    // between this declaration and the driver is detectable rather than
    // silently misaligned.
    [StructLayout(LayoutKind.Sequential)]
    public struct Stats {
        public uint Size;
        public uint DropsNoClient;
        public uint DropsAllocFailed;
        public uint HostToCtrlCount;
        public uint HostToCtrlPeak;
        public uint PendingEventCount;
        public uint PendingEventPeak;
        public uint PendingDataCount;
        public uint PendingDataPeak;
        public uint WritesTotal;
        public uint QueuedToUserTotal;
        public uint WritesPended;
        public uint WritesWaiting;
    }

    public static Stats GetStats() {
        int size = Marshal.SizeOf(typeof(Stats));
        IntPtr buf = Marshal.AllocHGlobal(size);
        try {
            uint returned;
            if (!DeviceIoControl(_handle, IOCTL_WINVHCI_GET_STATS,
                                 IntPtr.Zero, 0, buf, (uint)size,
                                 out returned, IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                                         "DeviceIoControl(GET_STATS) failed");
            }
            Stats s = (Stats)Marshal.PtrToStructure(buf, typeof(Stats));
            if (s.Size != size) {
                throw new InvalidOperationException(
                    "WINVHCI_STATS size mismatch: the driver reports " +
                    s.Size + " bytes, this script expects " + size +
                    ". The driver and vhci-io.ps1 are from different builds.");
            }
            return s;
        } finally {
            Marshal.FreeHGlobal(buf);
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

function Format-VhciStats {
    <#
    .SYNOPSIS
        One-line-per-group rendering of the driver's packet counters.

    .DESCRIPTION
        Loss in this driver is otherwise invisible: a dropped advertising
        report looks exactly like a device that was never advertising. Any
        non-zero drop count is a defect or a client that vanished mid-flight.
    #>
    param([Parameter(Mandatory)] $Stats, [string]$Prefix = '  ')

    $s = $Stats
    "$Prefix totals       user->stack $($s.WritesTotal)  stack->user $($s.QueuedToUserTotal)"
    "$Prefix drops        no-client $($s.DropsNoClient)  alloc-failed $($s.DropsAllocFailed)"
    "$Prefix stack->user  depth $($s.HostToCtrlCount)  peak $($s.HostToCtrlPeak)   (unbounded by design)"
    "$Prefix user->stack  events depth $($s.PendingEventCount) peak $($s.PendingEventPeak)   acl depth $($s.PendingDataCount) peak $($s.PendingDataPeak)"
    "$Prefix writes       pended $($s.WritesPended)  waiting now $($s.WritesWaiting)"
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
