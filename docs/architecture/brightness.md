# Brightness

## Design

- `brightness.read` enumerates `/sys/class/backlight`, reads `brightness`,
  `max_brightness` and `type`, sorts by name and selects the first usable
  device. A usable device has a non-zero maximum.
- Changes never write sysfs. `Client.connect` resolves the logind session via
  `GetSessionByPID`, falling back to `/proc/self/sessionid` and `GetSession`,
  then calls `Session.SetBrightness("backlight", name, raw)`.
- The view stores the client and a snapshot, updates the local raw value only
  after a successful call, and shows errors in the footer for five seconds.
- `brightness_cli.zig` is a separate one-shot dispatcher for `up`, `down`,
  `set`, `get` and `list`; it reuses only `brightness.zig`.
- The window is a summary plus up to four device rows.

## Strengths

- No root, udev rules, setuid helper, `brightnessctl`, or sysfs write.
- logind owns policy; the process remains unprivileged.
- Session lookup is tolerant: a process started outside the session can still
  resolve through `/proc/self/sessionid`.
- If sysfs works but logind does not, the view stays open read-only and explains
  why instead of failing silently.
- Percentage conversion rounds and clamps, and raw values round back.

## Limits

- Backlight class only; keyboard LEDs and DDC/CI monitors are out of scope.
- No direct sysfs fallback. Without logind or outside a session, changes are
  impossible.
- No polling; external changes need `R`.
- Whole-percentage rounding means the raw value can differ by one step from the
  previously displayed value.
- A device with a broken `brightness` file is skipped rather than shown as an
  error row.
- `main.zig` special-cases brightness: `args.len == 2` opens the UI, any extra
  argument goes to `brightness_cli`. This differs from the `cli.isTool` path.
- `src/tests.zig` imports `brightness.zig` but not `brightness_cli.zig`, so the
  CLI's argument handling has no unit coverage.

## Code path

1. `src/main.zig` calls `runBrightness` for no action, otherwise
   `brightness_cli.run`.
2. `src/brightness_view.zig` handles selection, adjustment, retry and drawing.
3. `src/brightness_cli.zig` parses `up/down/set/get/list` and prints one line.
4. `src/brightness.zig` enumerates sysfs, chooses a device, converts percentages
   and calls logind.
5. `src/dbus.zig` provides transport; `src/session.zig` the loop.

## Testability

- Tests cover rounding/clamping, raw conversion, device choice, `listLine`
  formatting, session-id parsing and logind error classification.
- Session lookup and `SetBrightness` need a live logind; sysfs paths are fixed,
  so fixture tests would need a path parameter or a mount namespace.
