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
- `org.bluez.Device1.Pair` pairs a device.
- `org.bluez.Adapter1.RemoveDevice` forgets a device.
- `org.bluez.AgentManager1` registers a short-lived `org.bluez.Agent1`
  object at `/org/iube/bluez/Agent` for just-works pairing.

BlueZ owns the controller. iube does not open the HCI device directly, and it
does not replace `bluetoothd`.

## Command line

The UI is still `iube bluetooth`. Pairing and forgetting are also available
without opening a window:

```sh
iube bluetooth pair "WH-1000XM4"
iube bluetooth pair 00:11:22:33:44:55
iube bluetooth forget "WH-1000XM4"
iube bluetooth forget 00:11:22:33:44:55
```

`pair` and `forget` resolve the device from the current BlueZ object tree.
Addresses match first (case-insensitively), then exact names and paths, then a
unique case-insensitive part of the name. An ambiguous name is rejected; use
the address instead. `pair` registers the agent, calls `Device1.Pair`, and
unregisters the agent when the call finishes. The command exits with status 1
on failure and prints the reason.

The agent uses the `NoInputNoOutput` capability. It auto-accepts just-works
`RequestConfirmation`, `RequestAuthorization` and `AuthorizeService` calls.
Devices that require a passkey or PIN are rejected with a clear error; iube
does not display or accept a code yet.

## Controls

- `Up` / `Down` selects a device.
- `Enter` connects or disconnects the selected device.
- `P` turns the adapter on or off.
- `D` starts or stops discovery.
- `A` pairs the selected device.
- `Delete` forgets the selected device.
- `R` refreshes the object tree.
- `Esc` closes.

While discovery is active, iube refreshes the device tree automatically every
two seconds. Otherwise it refreshes every five seconds so external connection
changes are picked up without pressing `R`. Devices are ordered with connected
devices first, paired devices second, and new/unpaired devices last.

Refresh, power, discovery, connect and forget jobs run on a long-lived worker
D-Bus connection; pairing uses a separate short-lived connection for its agent.
The window stays responsive either way. The selected device shows
`Connecting...`, `Pairing...` or `Forgetting...` until the action finishes, then
the device tree refreshes automatically. The worker reconnects after a D-Bus
timeout instead of leaving the connection in a partial-message state. Initial
startup and an explicit reconnect perform one synchronous load before the window
is shown.

The header shows the adapter name and its current state: `On`, `Off`, or
`Discovering`. Device rows show the name, address and connection state. Connected
devices show a battery icon, bar and fixed-width percentage; non-connected
devices show a signal icon, bar and fixed-width percentage. Signal percentages
map RSSI values from `-100` to `-30` dBm onto `0` to `100%`. Missing values use
`--` with an empty bar. The window uses the same 640×360 default size as the
launcher and scrolls when the device list grows.

## Current limitations

- The pairing agent only handles just-works pairing. Devices that require a
  passkey, PIN, or a confirmation code typed on both sides are rejected with
  `org.bluez.Error.NotSupported`. A full `RequestConfirmation` prompt would
  need a small interactive window or a terminal prompt.
- Requesting the default agent can fail when another agent (for example
  `blueman-applet`) is already registered. iube still registers its own agent,
  but BlueZ may route pairing requests to the existing default agent.
- There is no live `PropertiesChanged` subscription. The view polls every few
  seconds and refreshes after actions; press `R` for an immediate refresh.
- Trust, adapter aliases and discovery filters are not exposed.
- rfkill is not controlled directly; if the adapter is hard or soft blocked,
  BlueZ reports the resulting state and iube shows an error for failed actions.
- Only the first adapter is displayed.

## Planned work

- **Interactive confirmation.** Show the six-digit code and let the user accept
  or reject it, then support passkey entry.
- **Live updates.** Subscribe to `PropertiesChanged` and device events instead
  of refreshing manually.
- **Trust.** Add `Trusted` changes.
- **Adapter selection.** Show and select between multiple adapters.
- **rfkill state.** Read `/sys/class/rfkill` so a blocked radio is explained
  clearly before a BlueZ call fails.

## Code path

1. `src/main.zig` sees `iube bluetooth` and calls `runBluetooth`; `iube
   bluetooth pair|forget` calls the CLI handlers.
2. `src/bluetooth_view.zig` builds the view and handles keys, pointer input and
   drawing.
3. `src/bluetooth.zig` maps BlueZ objects, resolves device arguments and calls
   adapter/device methods.
4. `src/bluetooth_agent.zig` exports the short-lived `Agent1` object and answers
   pairing callbacks.
5. `src/dbus.zig` handles the system-bus connection, method calls, replies,
   incoming messages and marshalling.
6. `src/session.zig` provides the shared Wayland loop, config and renderer.
