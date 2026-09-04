# windows-vhci-driver

A virtual Bluetooth HCI controller for Windows — the equivalent of Linux's
`/dev/vhci` (`drivers/bluetooth/hci_vhci.c`).

A userspace process supplies the controller behaviour; Windows sees a real local
Bluetooth radio, with the whole in-box stack above it (pairing, WinRT, RFCOMM,
`bthenum`) working normally.

Status: **design only, no code yet.**

- [docs/research.md](docs/research.md) — how the Windows Bluetooth stack is put
  together, where it can be extended, and why this is possible without emulating
  any hardware.
- [docs/implementation-plan.md](docs/implementation-plan.md) — what to build, in
  what order.

## The short version

Windows binds the in-box `BthMini.sys` + `BthPort.sys` to any device reporting the
compatible ID `MS_BTHX_BTHMINI`. So this project is a single root-enumerated KMDF
bus driver that creates such a child device and answers the five `bthxddi.h`
IOCTLs, bridging HCI packets to userspace over `\\.\WinVhci` in the same H4 framing
`/dev/vhci` uses.

No SCO and no LE Audio isochronous data: the Bluetooth extensibility transport
interface has no packet type for either.
