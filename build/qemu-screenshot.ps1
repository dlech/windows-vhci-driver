# Capture the guest's screen via QEMU's QMP socket.
#
# Lets the VM's display be inspected from outside the guest - useful when the
# guest is at firmware, a boot menu, OOBE, or a bugcheck, i.e. exactly when
# nothing inside it can be queried.

[CmdletBinding()]
param(
    [int]   $QmpPort = 55556,
    [string]$OutFile = (Join-Path $env:TEMP 'qemu-screen.png')
)

$ErrorActionPreference = 'Stop'

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect('127.0.0.1', $QmpPort)
$stream = $client.GetStream()
$reader = New-Object System.IO.StreamReader($stream)
$writer = New-Object System.IO.StreamWriter($stream)
$writer.AutoFlush = $true

function Send-Qmp([string]$json) {
    $writer.WriteLine($json)
    # Skip asynchronous events; return the first line carrying a return/error.
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { throw 'QMP connection closed' }
        if ($line -match '"(return|error)"') { return $line }
    }
}

# Greeting first, then negotiate out of capabilities mode.
$null = $reader.ReadLine()
$null = Send-Qmp '{"execute":"qmp_capabilities"}'

# QEMU writes the file itself, so the path is from QEMU's point of view.
# Forward slashes avoid escaping trouble inside the JSON string.
$qemuPath = $OutFile -replace '\\', '/'
$resp = Send-Qmp ("{{`"execute`":`"screendump`",`"arguments`":{{`"filename`":`"{0}`",`"format`":`"png`"}}}}" -f $qemuPath)

$client.Close()

if ($resp -match '"error"') { throw "screendump failed: $resp" }
if (-not (Test-Path $OutFile)) { throw "screendump reported success but $OutFile does not exist" }

Get-Item $OutFile | Select-Object FullName, Length, LastWriteTime
