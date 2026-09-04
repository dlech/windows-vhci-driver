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
#
# The host default is QEMU's slirp gateway, so an emulator running on the VM
# host is reachable from inside the guest without any extra networking.
[CmdletBinding()]
param(
    [string] $RemoteHost = '10.0.2.2',
    [int]    $Port       = 6402,
    [int]    $Seconds    = 0,            # 0 = until Ctrl+C
    [string] $Device     = '\\.\WinVhci',
    [switch] $Trace
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

    $deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [DateTime]::MaxValue }

    while ((Get-Date) -lt $deadline -and $tcp.Connected) {

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
            }
        }

        # --- controller -> Windows stack ---------------------------------
        # TCP is a stream: accumulate, then hand the driver whole packets, one
        # WriteFile per packet.
        while ($stream.DataAvailable) {
            $got = $stream.Read($netBuf, 0, $netBuf.Length)
            if ($got -le 0) { break }
            if ($accLen + $got -gt $acc.Length) {
                throw 'reassembly buffer overflow - controller sent a malformed stream'
            }
            [Array]::Copy($netBuf, 0, $acc, $accLen, $got)
            $accLen += $got
        }

        while ($accLen -gt 0) {
            $frameLen = Get-H4FrameLength $acc $accLen
            if ($frameLen -eq 0) { break }        # need more bytes

            $frame = New-Object byte[] $frameLen
            [Array]::Copy($acc, 0, $frame, 0, $frameLen)
            Write-Frame '<-' $frame $frameLen
            [VhciIo]::Write($frame, $frameLen)

            $accLen -= $frameLen
            if ($accLen -gt 0) { [Array]::Copy($acc, $frameLen, $acc, 0, $accLen) }
        }
    }
} finally {
    Write-Host 'closing (this removes the radio)' -ForegroundColor Cyan
    [VhciIo]::Close()
    $tcp.Close()
}
