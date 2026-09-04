# Third-party tools

These are **not committed** (see `.gitignore`). They are fetched onto the host
and staged onto the guest's share disc by `build\make-share-iso.ps1`, which
expects them at the paths below. Fetch them once per development machine.

| Path | What | Where it comes from |
| --- | --- | --- |
| `devcon.exe` | Creates the root-enumerated device node (`devcon install winvhci.inf root\winvhci`) | Ships with the WDK: `C:\Program Files (x86)\Windows Kits\10\Tools\<version>\<arch>\devcon.exe` |
| `DebugView\Dbgview64a.exe` | Shows the driver's `KdPrint` output live in the guest (ARM64 build) | Sysinternals DebugView: <https://learn.microsoft.com/sysinternals/downloads/debugview> |

## Fetching

`devcon.exe` — copy the one matching the guest architecture (ARM64):

```powershell
$wdk = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Tools' -Directory |
       Sort-Object Name | Select-Object -Last 1
Copy-Item "$($wdk.FullName)\arm64\devcon.exe" build\tools\devcon.exe
```

DebugView — download and extract the zip into `build\tools\DebugView\`. Only
`Dbgview64a.exe` (the ARM64 build) is used in the guest; the other binaries in
the archive are for other architectures and can be left or deleted.

## Why these are not vendored

They are redistributable but large, opaque, and versioned independently of this
project. Committing them would put several megabytes of unreviewable binaries
into every clone, and a stale copy is worse than a missing one because it fails
in confusing ways rather than obviously. `make-share-iso.ps1` treats DebugView
as optional and simply omits it if absent; `devcon.exe` is required and the
script fails loudly without it.
