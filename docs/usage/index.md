# Usage

`iube` is one binary. A command either opens a layer-shell window or runs a
single non-UI action and exits.

```sh
iube                 # control panel
iube launch          # application launcher
iube <tool>          # tool window
iube <tool> <action> # one-shot action, no Wayland connection
iube help            # usage
iube version         # version
```

Tools are `audio`, `bluetooth`, `wifi`, `power` and `brightness`. `panel` is an
alias for the control panel.

Window commands exit `0` when closed normally. Actions exit `0` on success, `1`
on a backend or state error, and `2` on invalid syntax. Expected failures print
one line to stderr, not a stack trace.

## Pages

| Command | Page |
| --- | --- |
| `iube`, `iube panel` | [Control panel](panel.md) |
| `iube launch` | [Application launcher](launcher.md) |
| `iube audio` | [Audio](audio.md) |
| `iube bluetooth` | [Bluetooth](bluetooth.md) |
| `iube wifi` | [Wi-Fi](wifi.md) |
| `iube power` | [Power](power.md) |
| `iube brightness` | [Brightness](brightness.md) |
| shared config | [Configuration](config.md) |

## Keybind example

```ini
# Hyprland
bind = SUPER, F1, exec, iube audio mute
bind = SUPER, F2, exec, iube audio volume-down 5
bind = SUPER, F3, exec, iube audio volume-up 5
bind = SUPER, F4, exec, iube bluetooth power toggle
bind = SUPER, F5, exec, iube wifi toggle
bind = SUPER, F6, exec, iube power profile next
```

Architecture and backend notes live in
[architecture/overview.md](../architecture/overview.md).
