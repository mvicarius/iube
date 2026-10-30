# Brightness

`iube brightness` opens the brightness controller. It enumerates backlight
devices from sysfs and changes the selected device through logind.

## Controls

| Input | Effect |
| --- | --- |
| `Up`, `Down` | Select a backlight device when more than one exists. |
| `Left` | Lower the selected device by 5%. |
| `Right` | Raise the selected device by 5%. |
| `R` | Re-read sysfs and reconnect to logind. |
| `Esc` | Close the window. |
| Pointer click on a row | Select it. |
| Wheel | Lower or raise the selected device by 5%. |

The header badge shows `logind` when changes are available, `read-only` when
sysfs was readable but no logind session was found, and `Unavailable` when no
usable backlight exists. The summary card shows the current percentage, device
name, type and a bar. Rows show each device, its type and the raw
`brightness/max_brightness` values.

The window grows with the device list up to four visible rows. With one
backlight it is about 640×212 at scale 1. Errors appear in the footer for five
seconds; the next successful change clears them.

## Commands

| Command | Effect |
| --- | --- |
| `iube brightness up [percent]` | Raise the selected device by `percent` (0–100, default 5). |
| `iube brightness down [percent]` | Lower the selected device by `percent` (0–100, default 5). |
| `iube brightness set <percent>` | Set the selected device to 0–100%. |
| `iube brightness get` | Print the selected device and current percentage. |
| `iube brightness list` | Print every device, percentage, type and raw range. |

`up` and `down` clamp at 0% and 100%. `get` and `list` are read-only. Output is
one line per device:

```text
amdgpu_bl2: 43%
amdgpu_bl2  43%  raw  28212/65535
```

`set` and `get` act on the first usable device in name-sorted order. `list`
prints all enumerated devices, including an unusable one when another usable
device exists.

Exit status is `0` on success, `1` for a backend error (no backlight,
permission denied, no logind session, device disappeared, logind refused), and
`2` for invalid syntax or a percentage outside 0–100. Runtime errors are printed
as `iube brightness: <message>` on stderr; usage errors print the brightness
usage block and exit `2`.

`iube brightness` with no action opens the window. Any extra argument selects
the non-UI grammar; there is no `iube brightness help` success path.

## Backend

Backlight state comes from `/sys/class/backlight`: `max_brightness`,
`brightness` and `type`. A device without a readable, non-zero maximum is not
usable. Devices are sorted by name.

iube does not write sysfs directly. It resolves the current logind session,
falling back to `/proc/self/sessionid`, and asks logind to set the raw value for
the device. logind applies the local polkit/session policy and writes the value.
iube stays an unprivileged process and does not use `brightnessctl`, udev rules
or a setuid helper.

## Limits

- Only `/sys/class/backlight`; keyboard backlights (`/sys/class/leds`) and
  external DDC/CI monitors are out of scope.
- No direct sysfs write fallback. Without logind, or outside a logind session,
  the view is read-only and the CLI fails.
- No polling or `PropertiesChanged` subscription; use `R` after an external
  change. Changes made in iube update the local value immediately.
- Raw values are rounded from whole percentages, so the exact sysfs number can
  differ by one step.
- A device with a non-zero maximum but a broken `brightness` file is skipped
  during enumeration.
