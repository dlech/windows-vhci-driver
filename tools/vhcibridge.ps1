# vhcibridge - connect \\.\WinVhci to an existing Bluetooth controller emulator.
#
# This is the real client. Implementing a controller is not this project's job;
# good ones already exist, and this bridge lets them drive the Windows Bluetooth
# stack through the winvhci driver:
#
#   RootCanal   https://github.com/google/rootcanal
#               listens for HCI on TCP 6402 (test channel on 6401)
#   Bumble      https://google.github.io/bumble/
#               supports TCP transports directly
#
# Both speak H4 - a type byte followed by the packet - which is exactly what
# \\.\WinVhci carries, so this is a byte pump and understands no HCI semantics
# beyond finding packet boundaries.
#
#   .\vhcibridge.ps1 -Port 6402
#   .\vhcibridge.ps1 -RemoteHost 10.0.2.2 -Port 6402 -Seconds 60
#   .\vhcibridge.ps1 -Stats 5            # ...reporting the driver's counters
#
# The host default is QEMU's slirp gateway, so an emulator running on the VM
# host is reachable from inside the guest without any extra networking.
[CmdletBinding()]
param(
    [string] $RemoteHost = '10.0.2.2',
    [int]    $Port       = 6402,
    [int]    $Seconds    = 0,            # 0 = until Ctrl+C
    [string] $Device     = '\\.\WinVhci',
    [switch] $Trace,

    # Report IOCTL_WINVHCI_GET_STATS every this many seconds, and once more at
    # exit. The bridge is the only process that can: \\.\WinVhci is exclusive,
    # so nothing else can open a handle to ask.
    [int]    $Stats      = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vhci-io.ps1')

function Write-Frame([string]$dir, [byte[]]$buf, [int]$len) {
    if (-not $Trace) { return }
    $hex = ($buf[0..([Math]::Min($len, 24) - 1)] | ForEach-Object { $_.ToString('x2') }) -join ' '
    $more = if ($len -gt 24) { " ... ($len bytes)" } else { '' }
    Write-Host ("{0} {1} {2}{3}" -f (Get-Date -Format HH:mm:ss.fff), $dir, $hex, $more) `
        -ForegroundColor DarkGray
}

Write-Host "connecting to ${RemoteHost}:${Port} ..." -ForegroundColor Cyan
$tcp = New-Object System.Net.Sockets.TcpClient
$tcp.Connect($RemoteHost, $Port)
$tcp.NoDelay = $true
$stream = $tcp.GetStream()
Write-Host 'connected to controller' -ForegroundColor Green

Write-Host "opening $Device ..." -ForegroundColor Cyan
[VhciIo]::Open($Device)
Write-Host 'opened' -ForegroundColor Green

try {
    # Ask the driver for a radio. The reply, FF FF <opcode> <id_lo> <id_hi>, is
    # ours to consume: it is winvhci's own control channel and means nothing to
    # the controller, so it must not be forwarded.
    [VhciIo]::Write([byte[]]@($script:H4_VENDOR, 0x00), 2)
    Write-Host 'requested a radio' -ForegroundColor Cyan

    $devBuf = New-Object byte[] 1026
    $netBuf = New-Object byte[] 4096
    $acc    = New-Object byte[] 8192      # reassembly for the socket direction
    $accLen = 0

    # Frame counts, so a stats line can distinguish "nothing arrived" from
    # "everything arrived and the driver absorbed it". Without them a flat
    # WritesPended is ambiguous, which cost a whole test run to work out.
    $toController = 0
    $toDriver     = 0

    $deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [DateTime]::MaxValue }
    $nextStats = if ($Stats -gt 0) { (Get-Date).AddSeconds($Stats) } else { [DateTime]::MaxValue }

    while ((Get-Date) -lt $deadline -and $tcp.Connected) {

        if ((Get-Date) -ge $nextStats) {
            Write-Host ("stats at {0}" -f (Get-Date -Format HH:mm:ss)) -ForegroundColor Cyan
            Write-Host ("   bridge       ->controller $toController   ->driver $toDriver")
            Format-VhciStats ([VhciIo]::GetStats()) | ForEach-Object { Write-Host $_ }
            $nextStats = (Get-Date).AddSeconds($Stats)
        }

        # --- has the link died under us? ---------------------------------
        #
        # $tcp.Connected only reflects the last I/O operation, and
        # $stream.DataAvailable is false for an idle socket and a dead one
        # alike, so neither notices a link that has gone away. Poll does:
        # readable with nothing available means the peer is gone.
        #
        # Exiting closes the device handle, which removes the radio: the
        # controller went away, so the adapter goes away, which is exactly what
        # closing /dev/vhci does on Linux. Verified by killing the controller -
        # the bridge exits and the radio disappears.
        #
        # KNOWN GAP: this does NOT catch the socket being severed by
        # hibernating the guest. There the connection vanishes without a FIN or
        # RST ever reaching this socket, so Poll never reports it readable, and
        # the bridge sits waiting on a link that is gone while still holding the
        # handle. On resume the radio therefore still exists, the Bluetooth
        # stack tries to initialise it, nothing answers, and it lands in
        # CM_PROB_FAILED_POST_START. Catching that needs an inactivity timeout
        # or a keepalive, which is not implemented.
        #
        if ($tcp.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and
            $tcp.Client.Available -eq 0) {
            Write-Host 'controller disconnected' -ForegroundColor Yellow
            break
        }

        # --- Windows stack -> controller ---------------------------------
        # Each read yields exactly one whole H4 frame, so it can go straight
        # out on the socket.
        $n = [VhciIo]::Read($devBuf, 50)
        if ($n -gt 0) {
            if ($devBuf[0] -eq $script:H4_VENDOR) {
                Write-Host ('control: ' + (($devBuf[0..($n-1)] | ForEach-Object { $_.ToString('x2') }) -join ' ')) `
                    -ForegroundColor Cyan
            } else {
                Write-Frame '->' $devBuf $n
                $stream.Write($devBuf, 0, $n)
                $stream.Flush()
                $toController++
            }
        }

        # --- controller -> Windows stack ---------------------------------
        # TCP is a stream, so this accumulates bytes and hands the driver whole
        # packets, one WriteFile per packet.
        #
        # Reading and draining are interleaved, and the read is capped at the
        # free space. The first version read everything available before
        # parsing any of it and treated a full accumulator as a protocol error:
        #
        #     throw 'reassembly buffer overflow - controller sent a malformed stream'
        #
        # That diagnosis was wrong, and the bug it hid was real. A burst of
        # events - a flood of advertising reports, or any busy moment - puts far
        # more than 8 KB in the socket at once, entirely well-formed. The
        # accumulator only ever needs to hold ONE partial frame; anything more
        # is buffering that TCP is already doing.
        #
        # The inner loop matters too. Going back around the outer loop for each
        # 8 KB would pay another 50 ms device-read timeout per chunk, which
        # throttles this direction to a crawl exactly when it is busiest.
        do {
            $progress = $false

            while ($stream.DataAvailable -and $accLen -lt $acc.Length) {
                $want = [Math]::Min($acc.Length - $accLen, $netBuf.Length)
                $got = $stream.Read($netBuf, 0, $want)
                if ($got -le 0) { break }
                [Array]::Copy($netBuf, 0, $acc, $accLen, $got)
                $accLen += $got
                $progress = $true
            }

            while ($accLen -gt 0) {
                $frameLen = Get-H4FrameLength $acc $accLen
                if ($frameLen -eq 0) {
                    # A frame that cannot fit is the only genuine framing error
                    # left: the longest H4 packet the driver accepts is 1026
                    # bytes, so a full accumulator with no complete frame in it
                    # means the stream is not H4.
                    if ($accLen -eq $acc.Length) {
                        throw ("no complete H4 frame in $accLen buffered bytes " +
                               '- the controller is not speaking H4')
                    }
                    break                          # need more bytes
                }

                $frame = New-Object byte[] $frameLen
                [Array]::Copy($acc, 0, $frame, 0, $frameLen)
                Write-Frame '<-' $frame $frameLen
                [VhciIo]::Write($frame, $frameLen)
                $toDriver++

                $accLen -= $frameLen
                if ($accLen -gt 0) { [Array]::Copy($acc, $frameLen, $acc, 0, $accLen) }
                $progress = $true
            }
        } while ($progress)
    }
} finally {
    # Read the counters before closing: the handle is what the IOCTL needs, and
    # closing it also resets the backlogs.
    if ($Stats -gt 0) {
        Write-Host 'final stats' -ForegroundColor Cyan
        Write-Host ("   bridge       ->controller $toController   ->driver $toDriver")
        try   { Format-VhciStats ([VhciIo]::GetStats()) | ForEach-Object { Write-Host $_ } }
        catch { Write-Host "  could not read stats: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    Write-Host 'closing (this removes the radio)' -ForegroundColor Cyan
    [VhciIo]::Close()
    $tcp.Close()
}
