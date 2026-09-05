# Print the winvhci device as JSON, or nothing if it is not present.
#
# A separate file rather than an inline -Command string because it must run
# under Windows PowerShell 5.1: Get-PnpDevice comes from the PnpDevice module,
# which is not present in PowerShell 7 on every runner image. Asking pwsh for it
# would fail as a missing cmdlet long after the install had actually succeeded.
#
# Matching on the hardware ID rather than a friendly name keeps this working if
# the INF's device description changes.

[CmdletBinding()]
param(
    [string]$HardwareId = 'root\winvhci'
)

# Filter on Service first, which Get-PnpDevice already returns. Looking up
# DEVPKEY_Device_HardwareIds for every device on the machine is a separate call
# each time and takes over a minute on a runner; the hardware ID is confirmed
# below on the single candidate, so nothing is given up.
$device = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.Service -eq 'winvhci' } | Select-Object -First 1

if ($device) {
    $ids = (Get-PnpDeviceProperty -InstanceId $device.InstanceId `
                -KeyName 'DEVPKEY_Device_HardwareIds' `
                -ErrorAction SilentlyContinue).Data
    if (-not ($ids -contains $HardwareId)) {
        throw "device $($device.InstanceId) uses the winvhci service but its hardware IDs are '$ids', not '$HardwareId'"
    }
}

if ($device) {
    [ordered]@{
        instanceId = $device.InstanceId
        status     = "$($device.Status)"
        problem    = "$($device.Problem)"
    } | ConvertTo-Json -Compress
}
