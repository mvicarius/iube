# Architecture overview

iube is one binary with one process per invocation. There is no daemon, index,
database or resident service.

## Dispatch

`src/main.zig` is dispatch only. It does not scan `.desktop` files or create a
window itself.

```text
iube                         -> panel.Panel
iube panel                   -> panel.Panel
iube launch                  -> launcher.Launcher
iube audio                   -> audio_view.Audio
iube bluetooth               -> bluetooth_view.Bluetooth
iube wifi                    -> wifi_view.Wifi
iube power                   -> power_view.Power
iube brightness              -> brightness_view.Brightness
iube <tool> <action> [...]   -> cli.zig (audio/bluetooth/wifi/power)
iube brightness <action>     -> brightness_cli.zig
iube help | version          -> stdout, no Wayland
```

Action paths run before config, theme or Wayland setup. They build the same
backend client as the UI, print a short result and exit. Parse errors exit `2`;
backend failures exit `1`. An unknown command prints usage and exits `2`.

## Shared modules

| File | Role |
| --- | --- |
| `main.zig` | Argument dispatch and per-view constructors. |
| `session.zig` | Wayland event loop, config load, metrics, key repeat, blink, frames. |
| `ui.zig` | Base metrics, scaling, key symbols, chrome, text wrapping. |
| `config.zig` | `key = value` parser and Rosé Pine defaults. |
| `render.zig` | Software premultiplied ARGB8888 canvas. |
| `font.zig` | Embedded bitmap font. |
| `png.zig` | PNG decoder and tinting inputs. |
| `wayland.zig` | `wl_shm`, input, cursor-shape and layer-shell setup. |
| `dbus.zig` | Minimal system D-Bus client (EXTERNAL auth, calls, variants). |
| `worker.zig` | Generic detached job queue, result polling and client reconnect. |
| `spawn.zig` | Start another `iube <tool>` process via `/proc/self/exe`. |
| `tools.zig` | Panel registry: id, name, backend note, icon. |

Per-tool modules are `panel.zig`, `launcher.zig`, `desktop.zig`,
`audio_view.zig`/`audio.zig`, `bluetooth_view.zig`/`bluetooth.zig`/
`bluetooth_worker.zig`/`bluetooth_agent.zig`, `wifi_view.zig`/`wifi.zig`/
`wifi_worker.zig`, `power_view.zig`/`power.zig`,
`brightness_view.zig`/`brightness.zig`, and `cli.zig`.

## View interface

`session.run(io, gpa, env, view)` is generic over the view type:

```zig
fn windowSize(view: *View, metrics: ui.Metrics) ui.WindowSize;
fn wantsBlink(view: *View) bool;
fn overTextField(view: *View, session: *session.Session) bool;
fn handleKey(view: *View, session: *session.Session, key: wayland.Key, is_repeat: bool) void;
fn pointerMoved(view: *View, session: *session.Session) void;
fn pointerLeft(view: *View, session: *session.Session) void;
fn pointerClick(view: *View, session: *session.Session) void;
fn pointerScroll(view: *View, session: *session.Session, delta: f32) void;
fn draw(view: *View, session: *session.Session, canvas: *render.Canvas, now_ms: i64) void;
```

Optional hooks: `tick(session)` for polling and worker results, and
`handleEscape(session) bool` to consume `Esc` (used by the Wi-Fi password
prompt). `session.zig` owns `Esc`-to-close, key repeat, blink timing, pointer
tracking, cursor shape and frame submission. A view sets `session.dirty = true`
only when something changed.

## Window sizing

All views share a 640 px base width. `scale` multiplies every layout number.

- Launcher: fixed 640×360 base; the list scrolls.
- Bluetooth and Wi-Fi: fixed 640×360 base; lists scroll.
- Audio: grows with the device list, up to eight rows.
- Power: battery summary, optional profile row and five action rows.
- Brightness: summary plus up to four device rows.
- Panel: `margin * 2 + rows * row_step - gap`; every registry row fits.

## Adding a tool

1. Add an entry to `tools.zig` with a stable `id`, name, description and backend
   note.
2. Add `src/<tool>_view.zig` implementing the view interface.
3. Add a branch and constructor in `main.zig`.
4. Add an icon.
5. Document user controls in `docs/usage/` and backend notes here.

Every registry id must have an explicit branch in `main.zig`; an unknown id
prints usage and exits `2`.

## Dependency policy

- No new linked library unless there is no credible alternative. The binary
  links libc, `libwayland-client` and `libxkbcommon`.
- Use the kernel interface where it owns the device: sysfs, generic netlink,
  Unix sockets.
- Let existing services own what they already own: PipeWire/PulseAudio, BlueZ,
  NetworkManager/wpa_supplicant, logind and power-profiles-daemon. iube replaces
  their GUI clients, not the services.
- One process per invocation; no resident iube daemon, no polling while closed.
- Read-only paths land before mutating operations.
- Never setuid or run as root. Privileged operations go through the existing
  service and polkit/D-Bus policy.
- Secrets go to the system service and are wiped from transient buffers; never
  write them to config or logs.

## Future backends and constraints

- **Audio:** optional ALSA fallback through kernel control ioctls when no
  PulseAudio-compatible socket exists; later per-application streams and
  subscriptions.
- **Wi-Fi:** a direct path could use `nl80211` generic netlink for scan/link
  state and the wpa_supplicant control socket for association. It needs
  `CAP_NET_ADMIN` or a polkit-mediated helper, must not fight NetworkManager or
  iwd for the interface, and must tolerate rate-limited scans.
- **Bluetooth:** interactive confirmation and passkey entry would need a small
  prompt or terminal flow; live `PropertiesChanged` updates replace polling.
- **Power:** multiple-battery aggregation, UPower details as an optional source,
  lid/critical-battery state.
- **Brightness:** backlight class only; keyboard LEDs and DDC/CI are separate
  problems.

## Tests

`zig build test` compiles `src/tests.zig`, which imports the pure modules:
config parsing, renderer primitives, metrics, tool registry, audio protocol
helpers, D-Bus marshalling, Bluetooth resolution, Wi-Fi parsing, power sysfs and
logind helpers, brightness conversion/session helpers, and CLI parsing. Views
and layer-shell behaviour are tested by running the binary in a capable
compositor.
