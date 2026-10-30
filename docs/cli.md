# CLI actions

`iube <tool>` opens the normal layer-shell view. Adding an action runs the
operation in the same process, prints a short result and exits without
connecting to Wayland, loading the theme or creating a surface. This makes iube
usable from Hyprland keybinds, Waybar `on-click` commands, shell scripts and
systemd user units.

```sh
iube audio volume-up 5       # no window, no daemon
iube bluetooth power toggle
iube wifi list
iube power battery
```

The commands talk to the same backend clients as the UI: the PulseAudio socket,
BlueZ over the system D-Bus, NetworkManager over the system D-Bus, sysfs and
logind. They never invoke `wpctl`, `nmcli` or `bluetoothctl`.

## Command reference

### Audio

| Command | Effect |
| --- | --- |
| `iube audio volume-up [percent]` | Raise the default output by `percent` (default 5). |
| `iube audio volume-down [percent]` | Lower the default output by `percent` (default 5). |
| `iube audio mute` | Toggle mute on the default output. |
| `iube audio mic-mute` | Toggle mute on the default input. |
| `iube audio default <name>` | Make a sink or source the default. |

Volume is clamped to 0-100%. A step from a value above 100% first brings the
current value into range, so `volume-down` still lowers the volume.

`default <name>` compares the query case-insensitively against the device's
PulseAudio name and its human-readable description, for example:

```sh
iube audio default "Built-in Audio Analog Stereo"
iube audio default alsa_output.pci-0000_00_1f.3.analog-stereo
```

The name is passed as one shell argument; quote descriptions containing spaces.

### Bluetooth

| Command | Effect |
| --- | --- |
| `iube bluetooth power on\|off\|toggle` | Power the first adapter. |
| `iube bluetooth discover on\|off` | Start or stop discovery on the first adapter. |
| `iube bluetooth connect <name\|address>` | Connect a known device. |
| `iube bluetooth disconnect <name\|address>` | Disconnect a device. |
| `iube bluetooth list` | Print the adapter and known devices. |

Device names and addresses are matched case-insensitively. `connect` does not
pair: the device must already be known to BlueZ. Use `iube bluetooth` or another
BlueZ client to pair a new device.

`list` prints one device per line as state, name and address:

```text
Adapter: hci0	00:11:22:33:44:55	on
Connected	Headphones	AA:BB:CC:DD:EE:FF
Paired	Keyboard	11:22:33:44:55:66
```

### Wi-Fi

| Command | Effect |
| --- | --- |
| `iube wifi on\|off\|toggle` | Toggle NetworkManager wireless. |
| `iube wifi scan` | Request a scan, wait briefly, refresh and print networks. |
| `iube wifi list` | Print the current wireless state and networks. |
| `iube wifi connect <ssid>` | Connect to an existing saved profile. |
| `iube wifi disconnect` | Disconnect the wireless device. |

`connect` never prompts for a password and never creates a profile. The SSID
must already be saved in NetworkManager; otherwise the command exits nonzero.
If the access point is not in the current scan results, NetworkManager is asked
to choose one for the saved profile. Run `iube wifi scan` first when the network
has not been seen recently.

`scan` waits 1.5 seconds for NetworkManager to collect results before printing
them. The scan itself is rate-limited by the kernel and by NetworkManager.

`list` and `scan` print one network per line as SSID, status, strength and band:

```text
Wi-Fi: on
Home	connected	78%	5 GHz
Cafe	saved	42%	2.4 GHz
Neighbour	secured	30%	5 GHz
```

### Power

| Command | Effect |
| --- | --- |
| `iube power suspend` | Suspend through logind. |
| `iube power hibernate` | Hibernate through logind. |
| `iube power reboot` | Restart through logind. |
| `iube power poweroff` | Shut down through logind. |
| `iube power lock` | Lock the current session. |
| `iube power profile next` | Cycle the platform power profile. |
| `iube power profile set <low-power\|balanced\|performance>` | Select a profile. |
| `iube power battery` | Print battery percentage, status and AC state. |

`profile set` accepts only a profile that the current backend advertises. ACPI
platform profiles commonly use `low-power balanced performance`, while
power-profiles-daemon may advertise `power-saver balanced performance`; the
command reports the requested profile as unavailable rather than silently
mapping it.

`battery` reads sysfs directly and does not require D-Bus. It prints one line:

```text
87%	Discharging	AC: off
```

## Exit codes and errors

- `0`: the action completed.
- `1`: a backend or state error, such as no default sink, no saved Wi-Fi
  profile, no adapter, permission denied or a rejected logind request.
- `2`: invalid command-line syntax, unknown action or bad argument.

Expected failures print a single concise line to standard error, for example:

```text
iube: no saved Wi-Fi profile for that network
```

They do not print a Zig stack trace. Successful actions print a short line to
standard output; scripts should rely on the exit code.

## Hyprland example

```ini
bind = SUPER, F1, exec, iube audio mute
bind = SUPER, F2, exec, iube audio volume-down 5
bind = SUPER, F3, exec, iube audio volume-up 5
bind = SUPER, F4, exec, iube bluetooth power toggle
bind = SUPER, F5, exec, iube wifi toggle
bind = SUPER, F6, exec, iube power profile next
```

## Waybar example

```jsonc
"custom/audio": {
  "exec": "iube audio mute",
  "on-click": "iube audio mute",
  "on-scroll-up": "iube audio volume-up 2",
  "on-scroll-down": "iube audio volume-down 2"
}
```

Waybar's `exec` runs periodically; actions that change state belong in event
handlers such as `on-click`, not in a polling command.

## Limitations

- Audio actions use the default sink or source. They do not select a device
  first unless `iube audio default` is used.
- Audio volume is limited to 0-100% even though PulseAudio allows up to 150%.
- Bluetooth actions use the first adapter only. Pairing, discovery filters and
  device removal are not part of this command grammar.
- Wi-Fi actions require NetworkManager. Connecting to a network without a saved
  profile, entering passphrases, and creating a profile are not supported.
- Power profiles are limited to the three names in the grammar and must exist
  in the active backend.
- `power battery` reports the first system battery, matching the power view.
- Output is plain text for humans and simple scripts. There is no JSON or
  Waybar-specific formatting mode yet.
