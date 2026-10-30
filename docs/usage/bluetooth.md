# Bluetooth

`iube bluetooth` opens the Bluetooth controller. It shows the first BlueZ
adapter and its known devices, and controls power, discovery, pairing and
connections.

## Controls

| Input | Effect |
| --- | --- |
| `Up`, `Down` | Select a device. Clears a pending forget confirmation. |
| `Enter` | Connect or disconnect the selected device. |
| `P` | Turn the adapter on or off. |
| `D` | Start or stop discovery. Requires the adapter to be on. |
| `A` | Pair the selected device with a just-works agent. Already-paired devices are reported. |
| `Delete` twice | Forget the selected device. The second press must arrive within 3 seconds. |
| `R` | Refresh the BlueZ object tree immediately. |
| `Esc` | Close the window. |
| Pointer click on a row | Select it; it does not connect. |
| Wheel | Scroll the device list. |

The header shows the adapter name and a badge: `No adapter`, `Off`,
`Discovering` or `On`. Rows show the device name, address and `Connected`,
`Paired` or `Available`. Connected devices show battery percentage when BlueZ
reports it; other devices show signal strength mapped from RSSI (`-100` to
`-30` dBm becomes 0–100%). Missing values show `--`.

The view refreshes every 2 seconds while powered and discovering, otherwise
every 5 seconds. Device actions show `Connecting...`, `Pairing...` or
`Forgetting...` until the job finishes.

## Commands

| Command | Effect |
| --- | --- |
| `iube bluetooth power on\|off\|toggle` | Set the first adapter's power. |
| `iube bluetooth discover on\|off` | Start or stop discovery. `toggle` is rejected. |
| `iube bluetooth connect <name\|address>` | Connect a known device. |
| `iube bluetooth disconnect <name\|address>` | Disconnect a device. |
| `iube bluetooth pair <name\|address>` | Pair using a short-lived just-works agent. |
| `iube bluetooth forget <name\|address>` | Remove the device from the adapter. |
| `iube bluetooth list` | Print the adapter and known devices. |

`connect` and `disconnect` match the device name or address exactly,
case-insensitively. `pair` and `forget` resolve in this order: address, exact
path/name/label, then a unique case-insensitive substring of the label or
address. An ambiguous substring is rejected; use the address.

`pair` requires the adapter to be on and only supports just-works pairing.
Devices that require a passkey or PIN fail with
`this device requires a passkey or PIN; only just-works pairing is supported`.
`connect` does not pair a device; it must already be known to BlueZ.

Output is one line per successful action, or a compact list:

```text
Bluetooth: on
Discovery: on
Connected: WH-1000XM4
Disconnected: WH-1000XM4
Paired "WH-1000XM4" (AA:BB:CC:DD:EE:FF)
"Keyboard" (11:22:33:44:55:66) is already paired
Forgot "Keyboard" (11:22:33:44:55:66)
Adapter: hci0	00:11:22:33:44:55	on
Connected	WH-1000XM4	AA:BB:CC:DD:EE:FF
Paired	Keyboard	11:22:33:44:55:66
```

`list` prints `No Bluetooth adapter` or `No devices` when applicable. Exit
status is `0` on success, `1` for a backend or state error (no adapter, adapter
off, device not found, pairing rejected or timed out), and `2` for invalid
syntax.

## Backend

iube talks to BlueZ on the system D-Bus directly. BlueZ must be running and own
the adapter; iube does not open the HCI device or replace `bluetoothd`. Pairing
registers a short-lived just-works agent. UI refresh and actions run on a worker
thread so a slow D-Bus call does not freeze the window.

## Limits

- Only the first adapter is shown and controlled.
- Only just-works pairing. Passkey, PIN, numeric-comparison and
  display-confirmation flows are not implemented.
- Another registered agent (for example `blueman-applet`) may remain the
  default and receive pairing requests.
- No live `PropertiesChanged` subscription; the view polls and refreshes after
  actions.
- Trust, adapter aliases and discovery filters are not exposed.
- rfkill is not controlled. A blocked adapter is reported by BlueZ and actions
  fail with an error.
