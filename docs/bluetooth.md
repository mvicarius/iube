# The iube Bluetooth controller

`iube bluetooth` reads and controls the local Bluetooth adapter through BlueZ.
It talks to the system D-Bus directly, without linking libdbus or a BlueZ client
library.

## How it works

iube connects to `/run/dbus/system_bus_socket`, authenticates with `EXTERNAL`,
and calls the BlueZ object manager:

- `org.freedesktop.DBus.ObjectManager.GetManagedObjects` supplies the adapter
  and device tree.
- `org.bluez.Adapter1` supplies adapter identity, `Powered`, `Discovering`,
  `Discoverable` and `Pairable`.
- `org.bluez.Device1` supplies device names, addresses, pairing and connection
  state.
- `org.bluez.Battery1` supplies battery percentages when BlueZ exposes them.
- `org.freedesktop.DBus.Properties.Set` changes `Powered`.
- `org.bluez.Adapter1.StartDiscovery` and `StopDiscovery` control scanning.
- `org.bluez.Device1.Connect` and `Disconnect` control device connections.

BlueZ owns the controller. iube does not open the HCI device directly, and it
does not replace `bluetoothd`.

## Controls

- `Up` / `Down` selects a device.
- `Enter` connects or disconnects the selected device.
- `P` turns the adapter on or off.
- `D` starts or stops discovery.
- `R` refreshes the object tree.
- `Esc` closes.

While discovery is active, iube refreshes the device tree automatically every
two seconds. Devices are ordered with connected devices first, paired devices
second, and new/unpaired devices last.

The header shows the adapter name and its current state: `On`, `Off`, or
`Discovering`. Device rows show the name, address and connection state. Connected
devices show a battery icon, bar and fixed-width percentage; non-connected
devices show a signal icon, bar and fixed-width percentage. Signal percentages
map RSSI values from `-100` to `-30` dBm onto `0` to `100%`. Missing values use
`--` with an empty bar. The window uses the same 640×360 default size as the
launcher and scrolls when the device list grows.

## Current limitations

- There is no pairing agent yet. Connecting an unpaired device may fail or
  require a passkey that iube cannot show.
- There is no live `PropertiesChanged` subscription. Press `R` or reopen the
  window to refresh.
- Trust, removal, adapter aliases and discovery filters are not exposed.
- rfkill is not controlled directly; if the adapter is hard or soft blocked,
  BlueZ reports the resulting state and iube shows an error for failed actions.
- Only the first adapter is displayed.

## Planned work

- **Pairing agent.** Export a small `org.bluez.Agent1` object so iube can handle
  confirmation codes and passkeys.
- **Live updates.** Subscribe to `PropertiesChanged` and device events instead
  of refreshing manually.
- **Trust and remove.** Add `Trusted` changes and `Adapter1.RemoveDevice`.
- **Adapter selection.** Show and select between multiple adapters.
- **rfkill state.** Read `/sys/class/rfkill` so a blocked radio is explained
  clearly before a BlueZ call fails.

## Code path

1. `src/main.zig` sees `iube bluetooth` and calls `runBluetooth`.
2. `src/bluetooth_view.zig` builds the view and handles keys, pointer input and
   drawing.
3. `src/bluetooth.zig` maps BlueZ objects and calls adapter/device methods.
4. `src/dbus.zig` handles the system-bus connection, method calls, replies and
   marshalling.
5. `src/session.zig` provides the shared Wayland loop, config and renderer.
