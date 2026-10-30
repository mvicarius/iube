# Wi-Fi

`iube wifi` opens the Wi-Fi controller. It lists access points reported by
NetworkManager and can scan, connect, disconnect and toggle the radio.

## Controls

| Input | Effect |
| --- | --- |
| `Up`, `Down` | Select a network. |
| `Enter` | Connect the selected network. |
| `X` | Disconnect the active network. |
| `S` | Request a scan. The badge shows `Scanning...` until it finishes. |
| `P` | Turn Wi-Fi on or off. |
| `R` | Refresh networks and saved profiles immediately. |
| `Esc` | Close the window, or cancel the password prompt when it is open. |
| Pointer click on a row | Select it; it does not connect. Ignored while the password prompt is open. |
| Wheel | Scroll the network list. Ignored while the password prompt is open. |

`Enter` on a saved network activates the saved profile. `Enter` on a visible
secured network without a saved profile opens a password prompt. `Enter` on an
open network creates an open profile. `Enter` on the connected network reports
`Already connected`.

While the password prompt is open, printable characters are appended,
`Backspace` deletes, `Enter` connects, and `Esc` cancels. The password is
displayed as `*` and wiped after the attempt. An empty password is rejected.

The header shows the interface and `On`, `Off`, `Connected`, `Scanning...` or
`Unavailable`. Rows show SSID, security, band and one status: `Connected`,
`Saved`, `Secured` or `Open`. The list refreshes every 5 seconds unless the
password prompt is open.

## Commands

| Command | Effect |
| --- | --- |
| `iube wifi on\|off\|toggle` | Set NetworkManager's wireless state. |
| `iube wifi scan` | Request a scan, wait 1.5 seconds, then print the networks. |
| `iube wifi list` | Print the current wireless state and networks. |
| `iube wifi connect <ssid> [--password-stdin]` | Connect to a saved profile, or create one and prompt on stdin. |
| `iube wifi disconnect` | Disconnect the wireless device. |

`connect` first looks for a saved NetworkManager profile for the exact SSID. A
saved profile is activated even when the access point is not in the current scan
results. If no profile exists and the network is visible and open, iube creates
an open profile. If it is secured, iube prints `Password: ` on stderr and reads
one line from stdin, disabling terminal echo when stdin is a TTY. Passwords are
never accepted in argv. `--password-stdin` is an accepted synonym; it does not
change how the password is read.

The command waits up to 10 seconds for NetworkManager to activate the
connection, then prints `Connected` or fails with `connection timed out`.
Already-connected and already-saved cases are reported explicitly.

`list` and `scan` print one network per line:

```text
Wi-Fi: on
Home	connected	78%	5 GHz
Cafe	saved	42%	2.4 GHz
Neighbour	secured	30%	5 GHz
```

The status is `connected`, `saved`, `secured` or `open`. The last column is
`2.4 GHz`, `5 GHz`, `6 GHz` or empty when NetworkManager reports no usable
frequency. `Wi-Fi: off`, `No Wi-Fi device` and `No networks` are printed as
plain lines.

Exit status is `0` on success, `1` for a backend or state error (no device,
network not found, no saved profile, empty password, timeout), and `2` for
invalid syntax.

## Backend

NetworkManager must be running and manage the wireless interface. iube reads
the device, access points and saved profiles over the system D-Bus and asks
NetworkManager to scan, activate, add or disconnect. It does not open the radio,
run a supplicant or store credentials itself. UI jobs run on a worker thread.

## Limits

- New profiles are created for open and WPA-PSK (`wpa-psk`) networks only.
  WPA3-SAE-only, enterprise 802.1X and captive portals are not supported.
- Hidden access points are listed as `(hidden)` but cannot be connected from
  the UI or CLI. Forgetting and editing saved profiles are not exposed.
- Only access points currently reported by NetworkManager are listed; saved
  networks out of range do not appear (the CLI can still activate one by SSID).
- Only the first wireless device is used.
- No live `PropertiesChanged` subscription; the view polls every 5 seconds.
- The CLI password path also reads stdin when it is not a TTY; it does not
  accept a password as an argument.
