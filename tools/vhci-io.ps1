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
    const int  ERROR_OPERATION_ABORTED   = 995;
    const int  ERROR_INSUFFICIENT_BUFFER = 122;
    const uint WAIT_OBJECT_0        = 0;
    const uint WAIT_TIMEOUT         = 258;

    // Bound on a write. The driver never pends a write - its backlogs are
    // unbounded and every path either completes or fails - so reaching this is
    // always a fault rather than congestion.
    const uint WRITE_TIMEOUT_MS     = 5000;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string path, uint access, uint share,
        IntPtr sec, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, IntPtr buf, int toRead, IntPtr read, IntPtr ov);

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
        // This type is static and outlives any one script, so an Open without
        // a Close in between would leak the previous event and OVERLAPPED.
        // Release whatever is there first; Close is safe when nothing is.
        Close();

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

        // The buffer stays PINNED until the request has been collected, on
        // every path out of here. A byte[] handed straight to a P/Invoke is
        // pinned only for the duration of that call - and ReadFile returns
        // with the request still pending. The device uses buffered I/O, so
        // the kernel copies the packet to the buffer's address when the
        // request completes, later; if the garbage collector has compacted
        // the heap in between, the array has moved and the packet lands on
        // whatever object lives at the old address now. The bridge issues one
        // of these every 50 ms for hours, so that is not a hypothetical.
        GCHandle pin = GCHandle.Alloc(buf, GCHandleType.Pinned);
        try {
            int n;
            if (ReadFile(_handle, pin.AddrOfPinnedObject(), buf.Length, IntPtr.Zero, _ov)) {
                GetOverlappedResult(_handle, _ov, out n, false);
                return n;
            }

            int err = Marshal.GetLastWin32Error();
            if (err != ERROR_IO_PENDING) {
                throw new Win32Exception(err, "ReadFile failed");
            }

            uint wait = WaitForSingleObject(_event, (uint)timeoutMs);
            if (wait == WAIT_OBJECT_0) {
                if (!GetOverlappedResult(_handle, _ov, out n, false)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetOverlappedResult failed");
                }
                return n;
            }

            // Timed out, or the wait itself failed. Either way cancel and
            // collect the request, so the next read starts from a clean state
            // and the buffer is not unpinned with a request still targeting it.
            //
            // The request can complete WITH DATA between the wait expiring
            // and the cancel landing: the driver dequeues a read under its lock
            // and completes it outside, and a cancel is a no-op on a request
            // that has already completed. That packet is real and is returned.
            // This used to return 0 regardless, and the packet - an HCI
            // command from the stack, typically - vanished, which from the
            // outside looked like a controller that had not answered.
            CancelIoEx(_handle, _ov);
            bool completed = GetOverlappedResult(_handle, _ov, out n, true);
            if (wait != WAIT_TIMEOUT) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "wait failed");
            }
            if (completed) {
                return n;
            }
            int reap = Marshal.GetLastWin32Error();
            if (reap == ERROR_OPERATION_ABORTED) {
                return 0;
            }
            throw new Win32Exception(reap, "collecting the cancelled read failed");
        } finally {
            pin.Free();
        }
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
                // decorative and a wedged device hung the caller outright with
                // no way to tell it from a slow one.
                uint wait = WaitForSingleObject(evt, WRITE_TIMEOUT_MS);
                if (wait != WAIT_OBJECT_0) {
                    CancelIoEx(_handle, ov);
                    // Collect the cancelled request so the OVERLAPPED is not
                    // freed while the driver may still own it. If it completed
                    // in the gap between the wait expiring and the cancel, the
                    // write SUCCEEDED and is reported as such rather than as a
                    // timeout that never happened.
                    bool completed = GetOverlappedResult(_handle, ov, out n, true);
                    if (wait != WAIT_TIMEOUT) {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "wait failed");
                    }
                    if (completed) {
                        return;
                    }
                    int reap = Marshal.GetLastWin32Error();
                    if (reap != ERROR_OPERATION_ABORTED) {
                        throw new Win32Exception(reap, "write did not complete");
                    }
                    throw new TimeoutException(
                        "write did not complete within " + WRITE_TIMEOUT_MS +
                        " ms. The driver completes or fails every write, so " +
                        "this means the device is wedged - check " +
                        "IOCTL_WINVHCI_GET_STATS.");
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

    // Mirrors WINVHCI_STATS, field for field and in order - the layout is
    // sequential, so a field added to winvhci.h and not to this declaration
    // does not merely mis-name a counter, it makes the buffer too short and
    // the driver refuses the whole request with STATUS_BUFFER_TOO_SMALL. The
    // Size check below then never runs, because there is nothing to check.
    // That is how v1.2.0 broke this script: RadiosAlive was added to the
    // driver and to the Python client, and not here.
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
        public uint WritesNoRadio;
        public uint RadiosAlive;
    }

    public static Stats GetStats() {
        int size = Marshal.SizeOf(typeof(Stats));
        IntPtr buf = Marshal.AllocHGlobal(size);
        try {
            uint returned;
            if (!DeviceIoControl(_handle, IOCTL_WINVHCI_GET_STATS,
                                 IntPtr.Zero, 0, buf, (uint)size,
                                 out returned, IntPtr.Zero)) {
                int err = Marshal.GetLastWin32Error();
                // ERROR_INSUFFICIENT_BUFFER means this declaration is shorter
                // than the driver's struct: the driver refuses the whole
                // request with STATUS_BUFFER_TOO_SMALL rather than fill what
                // fits. It also records the size it needs in the request's
                // Information field, but that never reaches a Win32 caller -
                // for an error status DeviceIoControl reports zero bytes
                // returned - so the error code is the only signal there is.
                // This branch used to require returned > size as well, which
                // made it unreachable, and the very mismatch it describes
                // (v1.2.0 adding RadiosAlive) surfaced as a bare "failed" that
                // sent the reader looking at the IOCTL definition.
                if (err == ERROR_INSUFFICIENT_BUFFER) {
                    throw new InvalidOperationException(
                        "WINVHCI_STATS size mismatch: the driver refused a " +
                        size + "-byte buffer as too small, so its struct has " +
                        "grown. vhci-io.ps1 is older than the installed driver.");
                }
                throw new Win32Exception(err, "DeviceIoControl(GET_STATS) failed");
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

    // Issues IOCTL_WINVHCI_GET_STATS with an output buffer of exactly
    // outLen bytes and returns the Win32 error, 0 on success, with the byte
    // count DeviceIoControl reported. For tests of the size-mismatch contract
    // above: a buffer shorter than the driver's struct must come back as
    // ERROR_INSUFFICIENT_BUFFER with nothing returned.
    public static int ProbeStatsSize(int outLen, out uint returned) {
        IntPtr buf = Marshal.AllocHGlobal(Math.Max(outLen, 1));
        try {
            if (DeviceIoControl(_handle, IOCTL_WINVHCI_GET_STATS,
                                IntPtr.Zero, 0, buf, (uint)outLen,
                                out returned, IntPtr.Zero)) {
                return 0;
            }
            return Marshal.GetLastWin32Error();
        } finally {
            Marshal.FreeHGlobal(buf);
        }
    }

    public static void Close() {
        if (_handle != IntPtr.Zero && _handle != (IntPtr)(-1)) { CloseHandle(_handle); }
        if (_event  != IntPtr.Zero) { CloseHandle(_event); }
        if (_ov     != IntPtr.Zero) { Marshal.FreeHGlobal(_ov); }
        // All three, not just the handle: a second Close used to free _ov
        // again, and Open used to allocate over whatever was still here.
        _handle = IntPtr.Zero;
        _event  = IntPtr.Zero;
        _ov     = IntPtr.Zero;
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
    "$Prefix refused      no-radio $($s.WritesNoRadio)"
    "$Prefix radios       alive $($s.RadiosAlive)   (non-zero until PnP finishes removing one)"
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
