# The iube Wi-Fi controller

`iube wifi` lists, scans, connects and disconnects wireless networks through
NetworkManager. It talks to the system D-Bus directly, without linking
libnm, libdbus or a supplicant client library.

NetworkManager is used as the first backend because a normal desktop already
has it manage the wireless interface, saved profiles and credentials. iube
reads that state and asks NetworkManager to act; it does not open the interface
or run a second supplicant.

## How it works

iube connects to `/run/dbus/system_bus_socket`, authenticates with `EXTERNAL`,
and calls the NetworkManager objects:

- `org.freedesktop.NetworkManager.GetDevices` finds the wireless device.
- `org.freedesktop.NetworkManager.Device` supplies the interface name, device
  state and the active connection.
- `org.freedesktop.NetworkManager.Device.Wireless.GetAllAccessPoints` supplies
  the access-point objects.
- `org.freedesktop.NetworkManager.AccessPoint` supplies SSID, strength,
  frequency and security flags.
- `org.freedesktop.NetworkManager.Settings.ListConnections` and
  `Settings.Connection.GetSettings` supply saved profiles and their SSIDs.
- `org.freedesktop.NetworkManager.Device.Wireless.RequestScan` starts a scan.
- `org.freedesktop.NetworkManager.ActivateConnection` connects a saved profile.
- `org.freedesktop.NetworkManager.Device.Disconnect` disconnects the device.
- `org.freedesktop.DBus.Properties.Set` changes `WirelessEnabled`.

NetworkManager owns the interface, supplicant and saved secrets. iube does not
read passphrases, write NetworkManager connection files, or replace `wpa_supplicant`.

## Controls

- `Up` / `Down` selects a network.
- `Enter` connects the selected network using its saved profile.
- `X` disconnects the current network.
- `S` requests a scan.
- `P` turns Wi-Fi on or off.
- `R` refreshes the network and saved-profile lists.
- `Esc` closes.

The list refreshes every five seconds so changes made by another client are
picked up without pressing `R`. Networks are ordered with the connected network
first, then by signal strength. Access points with the same SSID are collapsed
into one row, keeping the strongest one, so a mesh or multi-band network does
not appear several times.

Refresh, scan, power, connect and disconnect jobs run on a long-lived worker
D-Bus connection, so the window stays responsive. The selected row shows
`Connecting...` or `Disconnecting...` until the action finishes, and the scan
badge shows `Scanning...` while a scan is in progress. The worker reconnects
after a D-Bus timeout instead of leaving the connection in a partial-message
state. Initial startup performs one synchronous load before the window is shown.

The header shows the wireless interface and one of `On`, `Off`, `Connected` or
`Scanning...`. Rows show the SSID, security state, band and one status label:
`Connected`, `Saved`, `Secured` or `Open`. The secondary line shows the band of
the access point represented by the row (`2.4 GHz`, `5 GHz` or `6 GHz`). The
right side shows a signal icon, a gradient bar and a fixed-width percentage.
The window uses the same 640×360 default size as the launcher and scrolls when
the network list grows.

## Current limitations

- Connecting requires a profile that NetworkManager has already saved. There is
  no password prompt and no new-profile creation yet.
- Saved networks that are not in range are not listed; only access points
  reported by NetworkManager appear.
- There is no live `PropertiesChanged` subscription. The view polls every few
  seconds and refreshes after actions; press `R` for an immediate refresh.
- Forget, hidden-network, enterprise, WPA3-only and captive-portal flows are not
  exposed.
- Only the first wireless device is displayed.
- NetworkManager must be running and must manage the interface. The direct
  nl80211 and wpa_supplicant path described in [tools.md](tools.md) is not
  implemented.

## Planned work

- **Password prompt.** Create a new `802-11-wireless` connection through
  `Settings.AddConnection` and ask for the passphrase in the view.
- **Forget and edit.** Expose `Settings.Connection.Delete` and saved-profile
  editing.
- **Live updates.** Subscribe to `PropertiesChanged` on the device, access
  points and settings instead of refreshing manually.
- **Direct backend.** Read scan results through nl80211 generic netlink and
  associate through the wpa_supplicant control socket when NetworkManager is
  absent, as described in [tools.md](tools.md).
- **Link details.** Show address, frequency, channel and security details for
  the connected network.

## Code path

1. `src/main.zig` sees `iube wifi` and calls `runWifi`.
2. `src/wifi_view.zig` builds the view and handles keys, pointer input and
   drawing.
3. `src/wifi_worker.zig` runs scan, power, connect, disconnect and refresh jobs
   on a long-lived worker connection.
4. `src/wifi.zig` maps NetworkManager devices, access points and saved profiles,
   and calls the NetworkManager methods.
5. `src/dbus.zig` handles the system-bus connection, method calls, replies and
   marshalling.
6. `src/session.zig` provides the shared Wayland loop, config and renderer.
