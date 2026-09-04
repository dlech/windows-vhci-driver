#!/bin/sh
# Build -> guest in one step, with NO reboot and NO ISO rebuild.
#
# The share ISO is only readable at boot and QEMU holds it open while running,
# so using it for iteration costs a full shutdown/rebuild/boot cycle per build.
# Copying the package over SSH instead makes the edit-build-test loop seconds
# rather than minutes. The ISO stays useful for first-time bring-up of a fresh
# guest, when there is no SSH yet.
#
#   ./deploy-driver.sh                 build, copy, install, restart device
#   ./deploy-driver.sh --capture 20    ... and capture a kernel trace
#   ./deploy-driver.sh --no-build      deploy whatever is already built
#
# Requires: guest reachable on 127.0.0.1:2222, askpass helper for password auth.

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO/winvhci/ARM64/Debug/winvhci"
: "${GUEST_PORT:=2222}"
: "${GUEST_USER:=vhcidev}"

if [ -z "$SSH_ASKPASS" ]; then
    echo "SSH_ASKPASS must point at a helper that echoes the guest password" >&2
    exit 1
fi
export SSH_ASKPASS_REQUIRE=force
export DISPLAY=:0

SSHOPTS="-p $GUEST_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20"
SCPOPTS="-P $GUEST_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
TARGET="$GUEST_USER@127.0.0.1"

CAPTURE=0
BUILD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --capture)  CAPTURE="${2:-20}"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        *)          echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$BUILD" = 1 ]; then
    # Two things have to be true of the MSBuild we pick.
    #
    # It must be the ARM64 one: the default Bin\MSBuild.exe is x86 and the WDK
    # ships infverif.dll only for arm64 and x64, so an x86 MSBuild fails with
    # "Unable to load DLL 'x86\InfVerif.dll'".
    #
    # And its installation must carry the WDK's platform toolset. More than one
    # Visual Studio can be installed while only one has the WDK VSIX, and the
    # others fail with MSB8020 "build tools for WindowsKernelModeDriver10.0
    # cannot be found" - which reads like a missing WDK rather than the wrong
    # MSBuild. So select on the toolset directory, not on version order.
    if [ -z "$MSBUILD" ]; then
        for ts in "/c/Program Files/Microsoft Visual Studio"/*/*/MSBuild/Microsoft/VC/*/Platforms/ARM64/PlatformToolsets/WindowsKernelModeDriver10.0; do
            [ -d "$ts" ] || continue
            vs="${ts%%/MSBuild/*}"
            if [ -x "$vs/MSBuild/Current/Bin/arm64/MSBuild.exe" ]; then
                MSBUILD="$vs/MSBuild/Current/Bin/arm64/MSBuild.exe"
            fi
        done
    fi
    [ -x "$MSBUILD" ] || {
        echo "no ARM64 MSBuild with the WDK toolset found; set MSBUILD" >&2
        exit 1
    }

    echo "==> building"
    "$MSBUILD" "$(cygpath -w "$REPO/winvhci/winvhci.vcxproj")" \
        -p:Configuration=Debug -p:Platform=ARM64 -v:minimal -nologo
fi

echo "==> copying package"
ssh $SSHOPTS "$TARGET" 'New-Item -ItemType Directory C:\pkg -Force | Out-Null'
for f in winvhci.sys winvhci.inf winvhci.cat; do
    scp $SCPOPTS "$PKG/$f" "$TARGET:C:/pkg/$f" >/dev/null
done

# Purge first. pnputil identifies a package by INF version, not contents, so a
# stale entry is served in preference to what was just copied.
echo "==> purging old driver store entries"
ssh $SSHOPTS "$TARGET" '& C:\winvhci\devcon.exe remove "root\winvhci" | Out-Null; $p=$null; pnputil /enum-drivers | ForEach-Object { if ($_ -match "^\s*Published Name:\s*(oem\d+\.inf)") { $p=$Matches[1] } elseif ($_ -match "^\s*Original Name:\s*winvhci\.inf" -and $p) { $p; $p=$null } } | Sort-Object -Unique | ForEach-Object { pnputil /delete-driver $_ /uninstall /force | Out-Null }'

echo "==> installing"
ssh $SSHOPTS "$TARGET" 'pnputil /add-driver C:\pkg\winvhci.inf /install | Select-String "Published Name|Driver package"; & C:\winvhci\devcon.exe install C:\pkg\winvhci.inf "root\winvhci" | Out-Null'

echo "==> device state"
ssh $SSHOPTS "$TARGET" 'Get-PnpDevice | Where-Object { ($_.InstanceId -like "ROOT\SYSTEM\*" -and $_.FriendlyName -match "Virtual Bluetooth") -or ($_.InstanceId -like "WINVHCI\RADIO*" -and $_.Problem -ne "CM_PROB_PHANTOM") } | Format-Table FriendlyName,Status,Problem -AutoSize'

if [ "$CAPTURE" != "0" ]; then
    # Capture around a DEVICE RESTART, after the install has settled - not
    # around the install itself. pnputil/devcon can take longer than the
    # capture window, and the transcript then comes back empty. A restart
    # reproduces the whole interesting sequence (unload, DriverEntry,
    # EvtDeviceAdd, PDO creation, the BTHX handshake, HCI_Reset) in under a
    # second, which is what we actually want to read.
    #
    # --stop first: only one process may hold the kernel capture at a time, and
    # a stray CLI instance or a DebugView GUI silently starves this one into an
    # empty log rather than reporting an error.
    echo "==> capturing kernel trace around a device restart (${CAPTURE}s)"
    ssh $SSHOPTS "$TARGET" "C:\\tools\\dbgviewcli64a.exe --stop 2>\$null | Out-Null; Start-Sleep -Seconds 1; Remove-Item C:\\kd.log -Force -ErrorAction SilentlyContinue; Start-Process 'C:\\tools\\dbgviewcli64a.exe' -ArgumentList '--accepteula','--kernel','--duration','$CAPTURE','--log','C:\\kd.log' -WindowStyle Hidden; Start-Sleep -Seconds 3; & C:\\winvhci\\devcon.exe restart 'root\\winvhci' | Out-Null; Start-Sleep -Seconds $CAPTURE; Get-Content C:\\kd.log -ErrorAction SilentlyContinue | Out-String -Width 200"
fi
