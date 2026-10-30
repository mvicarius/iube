# Bluetooth

## Design

- `bluetooth.zig` reads BlueZ through `ObjectManager.GetManagedObjects` and
  maps `org.bluez.Adapter1`, `Device1` and `Battery1` into one arena-owned
  snapshot.
- The view keeps the latest snapshot, submits jobs to `bluetooth_worker.zig`,
  and polls results in `tick`. The worker owns a long-lived D-Bus connection on
  a detached thread.
- Pairing uses `bluetooth_agent.zig`: a short-lived `org.bluez.Agent1` with
  `NoInputNoOutput`, registered for the call and removed afterwards.
- Refresh cadence is 2 seconds while powered and discovering, otherwise 5
  seconds. Actions trigger a refresh after completing.
- Device order is connected first, then paired, then available.

## Strengths

- D-Bus calls cannot freeze the UI; the worker reconnects after timeout,
  closed connection or protocol errors.
- Optional fields (`battery`, `rssi`) degrade to `--` and an empty bar.
- Pending actions are labelled on the selected row.
- Forget requires a second `Delete` within 3 seconds.
- No libdbus or BlueZ client library.

## Limits

- Only the first adapter is exposed.
- Polling, not `PropertiesChanged`; external changes can lag by the interval.
- Pairing is just-works only. Passkey, PIN, numeric comparison and
  display-confirmation flows return `PasskeyRequired`.
- Another registered agent can remain BlueZ's default and receive requests.
- Trust, aliases, discovery filters and rfkill are not exposed.
- The worker uses the process-wide `c_allocator` and is detached; shutdown does
  not join a blocked D-Bus call. The process exit reclaims it.
- Worker actions are serialized; a long connect blocks later jobs.

## Code path

1. `src/main.zig::runBluetooth` constructs `bluetooth_view.Bluetooth`; the CLI
   uses `cli.zig` for `pair`, `forget` and the other actions.
2. `src/bluetooth_view.zig` handles selection, power, discovery, pairing,
   forgetting and drawing.
3. `src/bluetooth_worker.zig` runs refresh/power/discovery/connect/pair/forget
   jobs on its thread.
4. `src/bluetooth.zig` parses the BlueZ tree, resolves names, and calls adapter
   and device methods.
5. `src/bluetooth_agent.zig` answers just-works agent callbacks;
   `src/dbus.zig` does the transport.

## Testability

- Pure tests cover managed-object parsing, device ordering, `resolveDevice`
  precedence/ambiguity and agent reply data.
- Worker scheduling, D-Bus timeouts and agent registration require a live
  `bluetoothd`; there is no mock bus.
