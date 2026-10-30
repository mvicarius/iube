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
- `org.freedesktop.NetworkManager.AddAndActivateConnection` creates and
  activates a new profile for a visible access point.
- `org.freedesktop.NetworkManager.Device.Disconnect` disconnects the device.
- `org.freedesktop.DBus.Properties.Set` changes `WirelessEnabled`.

NetworkManager owns the interface, supplicant and saved secrets. iube does not
read existing passphrases, write NetworkManager connection files directly, or
replace `wpa_supplicant`. A password typed into the new-network prompt is sent
once in the D-Bus request and then discarded; it is not logged, written to the
iube config, or kept in the view.

## Controls

- `Up` / `Down` selects a network.
- `Enter` connects the selected network. A saved profile is activated directly.
  A new open network is connected with an empty password. A new secured network
  opens the password prompt.
- In the password prompt, printable characters are appended, `Backspace`
  deletes the last character, `Enter` connects, and `N` or `Esc` cancels.
  Characters are shown as `*` and the password is wiped after the attempt.
  Uppercase `N` is reserved for cancel while the prompt is open.
- `X` disconnects the current network.
- `S` requests a scan.
- `P` turns Wi-Fi on or off.
- `R` refreshes the network and saved-profile lists.
- `Esc` closes the window, or cancels the password prompt when it is open.

## Command line

```sh
iube wifi connect <ssid>
iube wifi connect <ssid> --password-stdin
```

`iube wifi connect` connects to a visible network without opening the window.
If the network already has a saved profile it is activated directly. Otherwise
iube asks for the password on stdin; when stdin is a terminal, echo is disabled
while the line is read. `--password-stdin` is an explicit synonym for the same
behaviour. Passwords are never accepted as a command-line argument, so they do
not appear in `ps` output or shell history. The command waits up to ten seconds
for NetworkManager to report the device as activated and exits non-zero on
failure.

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

- New profiles are created for WPA-PSK (`key-mgmt=wpa-psk`) only. Enterprise
  802.1X, WPA3-SAE-only, and captive-portal flows are not exposed.
- A newly created profile is saved by NetworkManager, but iube does not offer
  editing it yet.
- Saved networks that are not in range are not listed; only access points
  reported by NetworkManager appear.
- There is no live `PropertiesChanged` subscription. The view polls every few
  seconds and refreshes after actions; press `R` for an immediate refresh.
- Forget, hidden-network and enterprise flows are not exposed.
- Only the first wireless device is displayed.
- The password prompt reserves `n` and `N` for cancel, so a password containing
  those letters cannot be entered from the UI. Use `iube wifi connect <ssid>`
  for such a password.
- NetworkManager must be running and must manage the interface. The direct
  nl80211 and wpa_supplicant path described in [tools.md](tools.md) is not
  implemented.

## Planned work

- **Password editing.** Allow changing a saved profile's passphrase and add
  enterprise/WPA3-SAE support.
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

1. `src/main.zig` sees `iube wifi` and calls `runWifi`, or sees
   `iube wifi connect` and calls `runWifiConnect`.
2. `src/wifi_view.zig` builds the view and handles keys, the password modal,
   pointer input and drawing.
3. `src/wifi_worker.zig` runs scan, power, connect, new-profile connect,
   disconnect and refresh jobs on a long-lived worker connection.
4. `src/wifi.zig` maps NetworkManager devices, access points and saved profiles,
   builds the new-profile settings dictionary, and calls the NetworkManager
   methods.
5. `src/dbus.zig` handles the system-bus connection, method calls, replies and
   marshalling.
6. `src/session.zig` provides the shared Wayland loop, config and renderer.
