# Architecture

iube is one binary with several entry points. Each entry point builds only the
view it needs, then hands it to a shared Wayland session and render loop. This
keeps the fast paths fast and prevents one tool from paying for another tool's
setup.

## Command dispatch

```text
iube                    -> panel.Panel
iube launch             -> launcher.Launcher
iube audio              -> audio_view.Audio
iube bluetooth          -> bluetooth_view.Bluetooth
iube wifi               -> wifi_view.Wifi
iube power              -> power_view.Power
iube brightness         -> brightness_view.Brightness
iube <tool> <action>    -> cli action, no Wayland connection
iube help / version     -> text output, no Wayland connection
```

`src/main.zig` is only dispatch. It does not load `.desktop` files, build tool
metadata, or create a window itself. Action paths run before the config or
Wayland session is set up.

## Module layout

```text
src/
  main.zig         command-line parsing and dispatch
  session.zig      shared Wayland session, event loop, key repeat, blinking
  ui.zig           shared metrics, scale, key symbols, window chrome, text wrap

  panel.zig        control panel: fixed list of all tools, no search/scroll
  launcher.zig     application launcher: .desktop scan, search, launch
  audio_view.zig   audio controller: outputs, inputs, volume, mute, default
  audio.zig        PulseAudio native-protocol client (no libpulse)
  bluetooth_view.zig  Bluetooth controller: adapter and device list
  bluetooth_worker.zig  long-lived Bluetooth job worker
  bluetooth.zig    BlueZ object model over D-Bus (no BlueZ client library)
  wifi_view.zig    Wi-Fi controller: network list, scan, connect, power
  wifi_worker.zig  long-lived Wi-Fi job worker
  wifi.zig         NetworkManager device, access point and profile model over D-Bus
  power_view.zig   power controller: battery, profiles and session actions
  power.zig        sysfs power supply, platform profile and logind client
  brightness_view.zig  brightness controller: sysfs devices and logind changes
  brightness.zig   sysfs backlight enumeration and logind SetBrightness client
  brightness_cli.zig   one-shot brightness commands without Wayland
  cli.zig          non-UI actions for keybinds and status bars
  dbus.zig         minimal system D-Bus client (no libdbus)

  placeholder.zig  "coming soon" view for unfinished tools
  tools.zig        tool registry (id, name, description, status, backend note)
  spawn.zig        start another `iube <tool>` process from the panel

  config.zig       shared ~/.config/iube/config parser
  render.zig       shared software renderer for premultiplied ARGB8888
  font.zig         shared embedded bitmap font
  png.zig          shared PNG decoder
  desktop.zig      .desktop discovery and icon lookup (launcher only)
  wayland.zig      shared Wayland client, wl_shm buffers, layer-shell setup
  protocol/        checked-in generated Wayland protocol bindings
```

## Shared pieces

Every command uses:

- `config.zig`: the same `~/.config/iube/config`, colours, scale and corner
  radius.
- `ui.zig`: the same scaled metrics, key constants, border/body chrome,
  text height and wrapped-text helper.
- `render.zig`, `font.zig`, `png.zig`: the same software renderer, bitmap font
  and PNG decoder.
- `wayland.zig`: the same `wl_shm` buffer management, input handling and
  `zwlr_layer_shell_v1` overlay setup.
- `session.zig`: the same event loop, key repeat, blinking and cursor-shape
  handling.

Only the view differs. `audio_view.zig` additionally uses `audio.zig`,
`bluetooth_view.zig` uses `bluetooth.zig` and `dbus.zig`, `wifi_view.zig` uses
`wifi.zig` and `dbus.zig`, and `power_view.zig` uses `power.zig` and
`dbus.zig`. `brightness_view.zig` uses `brightness.zig` and `dbus.zig`. These
are specific to their tools but still linked without any new dependency.

## View interface

`session.run(io, gpa, env, view)` is generic over the view type. A view is a
pointer to a struct with these methods:

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

`session.zig` owns:

- Wayland client creation and teardown.
- Config loading and metric calculation.
- The requested window size (from `view.windowSize`).
- `Esc` to close.
- Key-repeat timing and the repeated `handleKey` call.
- Text-cursor blinking for views that ask for it.
- Pointer position tracking and cursor shape selection.
- Frame allocation, drawing and submission.

A view only marks `session.dirty = true` when something changed.

## Why the command paths are separate

The control panel is not a launcher with extra buttons. It is a separate view
with different work:

| Path | Does | Does not do |
| --- | --- | --- |
| `iube` | read tool registry, size window to fit rows, draw panel | scan `.desktop` files, decode icons, load launcher search state |
| `iube launch` | scan `.desktop` files, load icon cache, set up search | build the tool registry, lay out the control panel |
| `iube <tool>` | build one tool view | scan applications or build other tools |

When the user selects a panel entry, `panel.zig` starts `iube <id>` and exits.
The selected command therefore starts as a clean process with only its own work
to do. `spawn.zig` resolves the running binary through `/proc/self/exe`, so this
works even when iube was started as `./zig-out/bin/iube` and is not on `PATH`.

This handoff is also why the control panel currently opens a new process rather
than switching views in place. In-place switching would require the panel
process to keep every view alive, including the launcher's `.desktop` state,
which is exactly the cost the separate `iube launch` path is designed to avoid.

## Window sizing

All views share the same 640 px base width, multiplied by `scale` from the
config. Heights differ:

- Launcher: 640×360 base; the list scrolls.
- Audio, Bluetooth, Wi-Fi, Power and Brightness: the window grows to fit the
  visible controls; Power uses a battery summary plus five action rows, and
  Brightness uses a selected-device summary plus up to four device rows.
- Control panel: height is computed from the number of tools:
  `margin * 2 + rows * row_step - gap`. Every entry is visible; the panel does
  not implement scrolling.
- Placeholder: 640×240 base, enough for the tool name, badge, description and
  planned backend.

## Adding a tool

1. Add an entry to `tools.zig` with a stable `id`, display name, description,
   status and a short backend note.
2. Create `src/<tool>.zig` with the view methods above.
3. Add a branch in `src/main.zig` that constructs that view.
4. Flip the registry entry to `Status.available`.
5. Document the backend in `docs/tools.md` and, for implemented tools, a
   dedicated page in `docs/`.

Until step 2 is done, the registry entry stays `coming_soon` and the generic
`placeholder.zig` view is used. `iube <id>` already works in that state.

## Tests

`zig build test` covers the pure modules: config parsing, rendering primitives,
metrics/window sizing, the tool registry, sysfs parsing and D-Bus marshalling.
The Wayland views are exercised by running the binary in a layer-shell-capable
compositor.
