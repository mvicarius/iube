# The iube brightness controller

`iube brightness` reads the backlight devices exposed by the kernel and changes
their level through logind. It does not use `brightnessctl`, udev rules, a
setuid helper or root. The only inputs are `/sys/class/backlight` and the
system D-Bus connection that iube already uses for BlueZ, NetworkManager and
power actions.

## How it works

Backlight state comes from `/sys/class/backlight`:

- `max_brightness` is the device's raw range. A device without a readable,
  non-zero maximum is not usable.
- `brightness` is the current raw level.
- `type` is shown in the UI as `raw`, `platform`, `firmware` or whatever the
  driver reports.

Devices are sorted by name and the first usable one is selected by default.
On the reference laptop this is `amdgpu_bl2`, but the view lists every device
and `Up`/`Down` switches the selected one. The percentage is rounded to the
nearest whole percent and clamped to 100.

Changes are not written to sysfs. iube first resolves the current logind
session:

1. `org.freedesktop.login1.Manager.GetSessionByPID` with the current PID.
2. If that fails, `/proc/self/sessionid` is read and passed to
   `org.freedesktop.login1.Manager.GetSession`.

The returned session object path is then used for
`org.freedesktop.login1.Session.SetBrightness` with signature `ssu`:

```text
SetBrightness("backlight", "<device name>", <raw value>)
```

For example, 43% on a device with `max_brightness=65535` becomes
`28180`. logind applies the local polkit/session policy and writes the value
through the kernel. iube remains an ordinary user process.

The session lookup is deliberately tolerant: a process started from a desktop
session normally resolves through `GetSessionByPID`, while a process whose
parent is outside logind can still use the fallback. If neither path works,
the view stays read-only and explains why instead of failing silently.

## Controls

- `Left` / `Right` lowers or raises the selected device by 5%.
- `Up` / `Down` selects another backlight device when more than one exists.
- `R` re-reads sysfs and reconnects to logind.
- `Esc` closes the window.
- Clicking a row selects it. The scroll wheel adjusts the selected device.

The header badge shows `logind` when changes are available, `read-only` when
sysfs could be read but no logind session was found, and `Unavailable` when
there is no backlight at all. A failed change is shown in the footer for five
seconds; the next successful change clears it.

The window grows with the device list up to four visible rows. With the usual
single backlight it is about 640×210 at scale 1.

## CLI actions

The same backend is available without Wayland. These commands read state,
perform the action and exit:

```sh
iube brightness get
iube brightness list
iube brightness set 40
iube brightness up
iube brightness up 10
iube brightness down
iube brightness down 2
```

- `get` prints the selected device and its current percentage, for example
  `amdgpu_bl2: 43%`.
- `list` prints every device, percentage, type and raw range, for example
  `amdgpu_bl2  43%  raw  28180/65535`.
- `set <percent>` accepts 0–100.
- `up [percent]` and `down [percent]` default to 5 and clamp at 0 and 100.
- Invalid percentages, a missing backlight, a refused logind request or an
  unsupported session print one error line and exit non-zero.

`iube brightness` with no action opens the view. The CLI code lives in
`src/brightness_cli.zig` and only depends on the backend, so it can be moved to
a shared dispatcher later without changing the sysfs or D-Bus code.

## Error states

- **No backlight:** `/sys/class/backlight` is missing or contains no device with
  a non-zero maximum. The view says so and offers `R` to retry.
- **Permission denied:** sysfs could not be read, or logind returned an
  access/permission error. The view does not attempt a privileged fallback.
- **Unsupported session:** neither `GetSessionByPID` nor the
  `/proc/self/sessionid` path produced a session. Brightness is shown
  read-only; `R` retries after the process is started from a session.
- **Device disappeared:** the selected sysfs entry vanished between reads.
  `R` re-enumerates the class directory.

## Current limitations

- Only the `backlight` class is supported. Keyboard backlights
  (`/sys/class/leds`) and external DDC/CI monitors are out of scope.
- Writing sysfs directly is not a fallback. Systems without logind, or
  containers where the process has no logind session, cannot change brightness
  with iube.
- The view does not subscribe to `PropertiesChanged` or poll. Use `R` after an
  external change; changes made in iube update the local value immediately.
- The raw value is rounded from whole percentages, so the exact sysfs number
  may differ by one step from the value shown before the change.
- A device with a non-zero maximum but a broken `brightness` file is skipped
  during enumeration rather than displayed as an error row.

## Code path

1. `src/main.zig` sees `iube brightness` (UI) or delegates to
   `src/brightness_cli.zig` (one-shot actions).
2. `src/brightness_view.zig` builds the view and handles keys, pointer input
   and drawing.
3. `src/brightness.zig` enumerates sysfs, resolves the logind session and calls
   `SetBrightness`.
4. `src/dbus.zig` handles the system-bus connection, method calls, replies and
   error names.
5. `src/session.zig` provides the shared Wayland loop, config and renderer.

## Tests

`zig build test` covers the pure helpers: percentage rounding and clamping,
raw-value conversion, CLI percentage parsing, device selection and formatting,
`/proc/self/sessionid` parsing, and logind error classification. The Wayland
view itself is exercised by running `iube brightness` in a layer-shell
compositor.
