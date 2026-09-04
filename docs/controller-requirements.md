# What Windows demands of the controller

The driver is a pipe. Everything that decides whether Windows brings a radio up happens at the
far end of it, in the userspace controller. This document records what BthPort actually
requires — measured against the real stack, not inferred from the specification — because it is
the part that is not written down anywhere and the part that cost the most time.

The short version: **Windows is a markedly stricter host than BlueZ.** A controller that BlueZ
accepts unmodified can be rejected by Windows without a single error message — the stack simply
stops sending commands, or completes its initialisation while silently declining to use half of
what the controller offers.

---

## The initialisation sequence

In a 20-second steady-state run there are 39 commands and zero unanswered, covering 29 distinct
opcodes:

```
reset/identity   HCI_Reset, Read_BD_ADDR, Read_Local_Version_Information,
                 Read_Local_Supported_Commands, Read_Local_Supported_Features,
                 Read_Buffer_Size
BR/EDR config    Set_Event_Mask, Write_Authentication_Enable, Write_Page_Timeout,
                 Write_Page_Scan_Activity, Write_Inquiry_Scan_Activity,
                 Write_Inquiry_Mode, Write_Class_of_Device, Write_Local_Name,
                 Write_Extended_Inquiry_Response, Host_Buffer_Size,
                 Write_Scan_Enable, Read_Inquiry_Response_Transmit_Power_Level
LE config        Write_LE_Host_Support, LE_Set_Event_Mask,
                 LE_Read_Local_Supported_Features, LE_Read_Buffer_Size,
                 LE_Read_White_List_Size, LE_Read_Supported_States,
                 LE_Read_Advertising_Channel_Tx_Power
LE advertising   LE_Set_Random_Address, LE_Set_Advertising_Parameters,
                 LE_Set_Advertising_Data, LE_Set_Advertise_Enable
```

Most of these return status only and can be answered by shape from a table; only the
parameter-returning commands need individual handling.

Two values must agree with what the driver told BthPort in `QUERY_CAPABILITIES`: the ACL packet
length in `Read_Buffer_Size` (1021) and anything derived from it.

**A single refusal restarts everything.** One `Unknown HCI Command` reply makes the stack begin
its whole sequence again, indefinitely. During bring-up this looks like a hang or a lost packet;
it is neither. The loop stops as soon as every command in the sequence is answered plausibly.

---

## Windows requires a dual-mode controller

Bumble defaults to LE-only. The failure was isolated in three steps:

| Controller configuration | Result |
| --- | --- |
| Default: `BR_EDR_NOT_SUPPORTED` set, BR/EDR feature octets zero | Windows stops dead after `Read_Local_Supported_Features` — no further commands, no retry |
| `BR_EDR_NOT_SUPPORTED` cleared, feature octets still zero | Identical stop, in exactly the same place |
| Realistic dual-mode LMP features (`bf fe cf fe db ff 7b 87`) | Proceeds to BR/EDR configuration |

So the bit alone is not what matters. A controller that claims BR/EDR while supporting none of
its mandatory features is rejected just as firmly as one that admits to being LE-only.

This is the opposite of BlueZ, which accepts Bumble's LE-only controller as-is — which is why
[Bleak's VHCI integration tests](https://github.com/hbldh/bleak/blob/develop/tests/integration/README.rst)
work on Linux with stock Bumble. Same architecture, stricter host stack.

---

## Unadvertised commands are invisible

**Windows only sends a command that the controller advertises in
`Read_Local_Supported_Commands`.** A command that is implemented but missing from the bitmask
will never be exercised, and the resulting failure has no diagnostic at all — Windows just
doesn't ask.

Bumble implements `write_le_host_support`, `read_le_host_support` and
`read_local_extended_features` but omits all three from `supported_commands`. That alone keeps
LE support from coming up.

---

## LE Supported States decides whether Windows pursues LE at all

This is the subtlest of the three and the one worth remembering.

Bumble reports `le_states = ffff3fffff030000`. Windows reads it and then **abandons LE bring-up
entirely** — no `LE_Read_Buffer_Size`, no `Write_LE_Host_Support` — leaving
`IsLowEnergySupported` False even though the controller advertised `LE_SUPPORTED_CONTROLLER`
and Windows had happily issued other LE commands beforehand. There is no error and no retry.

Reporting `ffffffffffff0300` makes it continue. Which bits Windows actually insists on has not
been narrowed down; that value is empirical.

### How this was found

By diffing against `tools/vhcictl.ps1`, whose hand-written answers *did* produce
`IsLowEnergySupported: True`. That proved neither the driver nor the Windows stack was at
fault and reduced the problem to a difference between two sets of controller replies.

Keeping a dumb, fully-controlled scaffolding client around paid for itself here, and is the
general technique for this class of bug: when a real emulator fails, bisect against a client
whose every byte you chose.

---

## Connecting: a second, larger gap

Discovery only needs HCI commands, events and advertising reports. Making a **GATT connection**
work uncovered a structurally different problem, and one that is much easier to misread.

**Bumble advertises 70 commands and implements handlers for 44.** The other 26 are listed in
`supported_commands`, so a host sends them, and they then fall through to a path that answers
*nothing at all*. Several of them have no return-parameter class in `bumble.hci`, which makes
Bumble classify them as asynchronous commands and discard the unknown-command status its own
fallback produced:

```
WARNING bumble.controller: --- Unsupported command HCI_READ_REMOTE_VERSION_INFORMATION_COMMAND
ERROR   bumble.controller: Async command handlers should return None, got
                           status: UNKNOWN_HCI_COMMAND_ERROR
```

This is the inverse of the discovery-time bug. There, a command was implemented but not
advertised, so Windows never sent it. Here it is advertised but not implemented, so Windows
sends it and waits forever.

The first one Windows hits is `HCI_Read_Remote_Version_Information`, issued **immediately**
after `HCI_LE_Connection_Complete`. Then `LE_Read_Channel_Map`. Each unanswered command
surfaces identically — `GattCommunicationStatus.Unreachable` from a service discovery, roughly
30 seconds later — which points at the radio rather than at a single missing HCI reply.

## LE ACL routing assumes a random address

The last obstacle was not a command at all, and it is the most interesting finding here.

`LocalLink.send_acl_data` decides, for LE, that the source of a packet is the sending
controller's **random** address:

```python
source_address = sender_controller.random_address
```

That holds for two Bumble `Device`s talking to each other, because a Bumble Device sets a random
address when it powers on. **Windows connects as central using its public identity address** —
the `ConnectInd` carries `initiator_address=F0:F1:F2:F3:F4:F5/PUBLIC_DEVICE` — and never issues
`LE_Set_Random_Address` for the central role, so `random_address` stays at its default
`00:00:00:00:00:00`.

The failure is completely silent. The link establishes, both hosts see
`HCI_LE_Connection_Complete`, ATT packets cross the transport correctly, and then the peer
discards every one of them:

```
WARNING bumble.controller: !!! no connection for 00:00:00:00:00:00
```

The controller already records the right answer: each `Connection` carries a `self_address`,
the address that connection was actually established with. `WindowsCompatLink` in
`tools/bumble-controller.py` uses it, and everything works.

**A related trap:** advertising the peer with `own_address_type=PUBLIC` looks more correct —
`aa:bb:cc:dd:ee:ff` is not a well-formed random static address — but it stops Windows
discovering the peer at all. Bumble's simulated link wants `RANDOM`, which is its default. The
`--peer-address-type` flag exists to switch between them.

## The Bumble shim

`tools/bumble-controller.py` defines `WindowsCompatController`, which is Bumble's `Controller`
plus exactly what the above requires:

- 14 BR/EDR configuration handlers Bumble does not implement (`Write_Authentication_Enable`
  first, then page/inquiry/scan/name/voice settings). Every one of these command classes
  already exists in `bumble.hci` — only the handlers were absent — and each is a setter whose
  reply is a status byte, so the shim stores nothing and decides nothing.
- The missing `supported_commands` entries, both for the handlers above and for the three
  commands Bumble already implemented.
- `le_states = ffffffffffff0300`.
- `--dual-mode`, which clears `BR_EDR_NOT_SUPPORTED` and sets
  `lmp_features = 0x877BFFDBFECFFEBF`, a realistic mask from a commodity dual-mode adapter.
- Connection-time handlers: `Read_Remote_Version_Information`, `LE_Read_Channel_Map`,
  `LE_Set_Data_Length`, `Read`/`Write_Authenticated_Payload_Timeout`, `LE_Connection_Update`,
  `LE_Set_PHY` and `Read_RSSI`. Two shapes appear here that the configuration setters do not
  have: commands answered by a Command Status followed by a completion *event*, and commands
  with no return-parameter class in `bumble.hci` at all, whose Command Complete has to be built
  from raw specification-shaped bytes.
- `WindowsCompatLink`, the ACL routing fix above.
- `RawReturnParameters`, a `bytes` subclass with a `to_string()` method. Bumble formats every
  outgoing packet into a debug string as it sends it — unconditionally, in an f-string,
  whatever the log level — and that formatting calls `to_string()` on the return parameters, so
  sending plain bytes raises inside the transport rather than anywhere near the handler.

**This belongs upstream in Bumble.** None of it is specific to this project; it is what any
Bumble controller needs to face a Windows host.

One caveat: the dual-mode LMP mask advertises BR/EDR capabilities Bumble cannot actually
honour, so BR/EDR operations will fail if anything tries them. LE is the path that works, which
suits Bleak and every other BLE client.

---

## What a peer needs in order to be discoverable

A bare `Controller` on the simulated link is not enough — with no host attached it never
advertises, so there is nothing for Windows to find. The peer needs a `Device` driving it:

```python
peer_controller = WindowsCompatController("peer", link=link, public_address=peer_address)
peer_device = Device(
    name=peer_name,
    address=hci.Address(peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS),
    host=Host(peer_controller, peer_controller),
)
await peer_device.power_on()
await peer_device.start_advertising(auto_restart=True)
```

`auto_restart` matters because a connection stops advertising, and the peer should become
discoverable again afterwards.

Give the Windows-facing controller an explicit `public_address` too. Without one it reports
`00:00:00:00:00:00` to `Read_BD_ADDR`, and an all-zero address is not a plausible identity for
a host stack to build on.

---

## The result

```
BluetoothAdapter.GetDefaultAsync()
  adapter address           : F0:F1:F2:F3:F4:F5
  IsLowEnergySupported      : True
  IsClassicSupported        : True
  IsCentralRoleSupported    : True
  IsPeripheralRoleSupported : True
  Radio state               : On

DeviceInformation.FindAllAsync (unpaired BLE)
  'Bumble'  BluetoothLE#BluetoothLEf0:f1:f2:f3:f4:f5-aa:bb:cc:dd:ee:ff
```

and a GATT connection, which is what actually moves data:

```
GATT service discovery (uncached)   status: Success
    00001800-...  00001801-...      (GAP, GATT)
    7a9b0001-4c1d-4e2a-9f3b-1d2c3e4f5a6b
  characteristics
    7a9b0002-...  [Read]
    7a9b0003-...  [WriteWithoutResponse, Write]
    7a9b0004-...  [Read, Notify]
  read   17 bytes: 'hello from bumble'
  write  18 bytes: Success
```

with the write arriving at the Python peer:

```
peer: characteristic write from F0:F1:F2:F3:F4:F5/P: b'hello from windows'
```

Windows also builds its whole stack on top of the virtual radio, and it is the *enumerator and
RFCOMM* nodes that signal success — not the radio node alone, which appears as soon as the
transport handshake completes:

```
Bluetooth Radio                        OK   WINVHCI\RADIO\...
Microsoft Bluetooth Enumerator         OK   BTH\MS_BTHBRB\...
Bluetooth Device (RFCOMM Protocol TDI) OK   BTH\MS_RFCOMM\...
bthserv                                Running
```

Once up, Windows pushes its own hostname into the controller (`Write_Local_Name` and
`Write_Extended_Inquiry_Response` carrying `DESKTOP-...`) and enables scanning — steady-state
operation, not initialisation.
