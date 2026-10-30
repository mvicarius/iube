# iube

## What is iube?

iube is a small, dependency-light control panel for the Linux desktop. It opens
fast, draws its own UI, and keeps nothing running in the background.

The project started as an application launcher. It is now growing into a set of
small OS management tools that share one binary, one theme, one config file and
one renderer:

- **Application launcher**: implemented (`iube launch`).
- **Control panel**: implemented (`iube`), listing every tool iube exposes.
- **Audio manager**: initial implementation (`iube audio`) with outputs, inputs,
  volume, mute and default device.
- **Bluetooth manager**: planned; placeholder view available (`iube bluetooth`).
- **Wi-Fi manager**: planned; placeholder view available (`iube wifi`).
- **Power manager**: planned; placeholder view available (`iube power`).

The management tools talk to the kernel and system services directly instead of
pulling in GTK, Qt, NetworkManager client libraries, BlueZ client libraries,
PipeWire client libraries or D-Bus client libraries. See
[docs/tools.md](docs/tools.md) for the implemented and planned backends.

## The name

**iube** comes from Latin *iubeō, iubēre* (“to order, command”). The form
*iube* (also written *iubē*) is the second-person singular present active
imperative, so it means **“command!”** or **“order!”**.

The imperative was chosen deliberately. iube is a tool for telling your OS what
to do: launch this application, connect to that network, change this setting,
turn that off. It is not a passive settings browser. The name is the action:
you give the command, and iube carries it out.

Classical Latin: **[ˈjʊ.beː]**, roughly **YOO-beh**, with a short *u* and a long
final *e*.

## Current status

| Area | Status | Command |
| --- | --- | --- |
| Control panel | **Available** | `iube` |
| Application launcher | **Available** | `iube launch` |
| Shared config, theme and renderer | **Available** | all commands |
| Audio | **Initial implementation** | `iube audio` |
| Bluetooth | Placeholder ("coming soon") | `iube bluetooth` |
| Wi-Fi | Placeholder ("coming soon") | `iube wifi` |
| Power | Placeholder ("coming soon") | `iube power` |

"Placeholder" means the command already opens a real iube window with the
shared theme and window behaviour. It shows the tool name, a **Coming soon**
badge and the planned backend. The tool itself is not implemented yet. This
currently applies to Bluetooth, Wi-Fi and Power.

## How the commands work

```sh
iube             # control panel: every tool, all entries visible, no search
iube launch      # application launcher (the original iube experience)
iube audio       # output/input volume, mute and default device
iube bluetooth   # bluetooth tool (placeholder for now)
iube wifi        # Wi-Fi tool (placeholder for now)
iube power       # power tool (placeholder for now)
iube help        # command list
iube version     # version
```

The paths are deliberately separate:

- `iube` builds only the control panel. It does **not** scan `.desktop` files,
  load icons or initialise launcher state.
- `iube launch` builds only the launcher. It does **not** build the panel or
  inspect the tool registry beyond dispatch.
- `iube <tool>` builds only that tool's view. Audio is a real view; Bluetooth,
  Wi-Fi and Power are still placeholders.

All paths load the same `~/.config/iube/config`, compute the same scaled
metrics, use the same `wl_shm` renderer, font, colours, rounded rectangles and
layer-shell window setup. Selecting an entry in the control panel hands off to
the matching `iube <tool>` process and exits, so the selected path still starts
with only its own work.

## Audio controls

`iube audio` talks to `$XDG_RUNTIME_DIR/pulse/native` directly. That socket is
provided by PulseAudio and by `pipewire-pulse`, so no libpulse or PipeWire
client library is linked.

- `Tab` switches between outputs and inputs.
- `Up` / `Down` selects a device.
- `Left` / `Right` changes volume in 5% steps.
- `M` toggles mute.
- `Enter` makes the selected device the default.
- `R` refreshes the device list.
- `Esc` closes.

The initial implementation lists real sinks and real capture sources (monitor
sources are filtered out) and changes their volume, mute and default state
directly. Per-application streams, the ALSA fallback and live subscription
updates are still planned.

## Design goals

- **One binary, one process per invocation.** No resident daemon, no index, no
  database, no search server. Close the window and the process is gone.
- **No application toolkit.** The UI is written directly against Wayland and
  composited by hand into `wl_shm` memory. The only linked libraries are libc,
  `libwayland-client` and `libxkbcommon`.
- **No tool-specific client libraries.** The managers speak the underlying
  protocols directly: the PulseAudio socket, kernel netlink (nl80211),
  rfkill/sysfs, D-Bus over the system socket, and logind's D-Bus interface.
  System services such as PipeWire, BlueZ, wpa_supplicant and logind are still
  expected to be running; iube does not replace them.
- **Shared visual language.** Theme, config, scaling, fonts, icons and window
  chrome are shared by every command.
- **Honest placeholders.** A feature that is not implemented says so in the UI
  instead of shipping a broken control.

The application launcher still has its original performance characteristics.
The measurements, configuration reference and implementation notes now live in
[docs/launcher.md](docs/launcher.md).

## Documentation

- [docs/launcher.md](docs/launcher.md): launcher features, performance,
  configuration, controls, layer-shell requirements and implementation notes.
- [docs/architecture.md](docs/architecture.md): command dispatch, module
  layout, shared view interface and how to add a tool.
- [docs/tools.md](docs/tools.md): dependency policy and the implemented and
  planned audio, Bluetooth, Wi-Fi and power backends.

## Build

For a normal release build:

```sh
nix develop --command zig build --release=fast
./zig-out/bin/iube
```

Or, to build and run in one step:

```sh
nix develop --command zig build run --release=fast
```

With no arguments the installed binary opens the control panel. Use
`./zig-out/bin/iube launch` for the application launcher.

A plain `zig build` produces a Debug build. It is fine while developing, but
uses more memory. The launcher figures in [docs/launcher.md](docs/launcher.md)
are from a `--release=fast` build.

The build needs `wayland` and `libxkbcommon` development headers. The generated
protocol bindings for `wlr-layer-shell` and `cursor-shape` are checked into
`src/protocol`, so `wayland-scanner` and `wayland-protocols` are not build
dependencies.

This project requires Zig **0.17.0**. The flake tracks `nixos-unstable`, which
currently ships that version.

## Roadmap

The four requested tools are the current near-term scope. Several other desktop
jobs fit the same model and could follow:

- **Display and brightness**: backlight via sysfs, external monitors via DDC,
  and night light/colour temperature via `wlr-gamma-control`.
- **Session actions**: lock, logout, suspend, reboot and shutdown via logind.
- **Network overview**: wired, VPN and connection state alongside Wi-Fi.
- **Clipboard history**: `wlr-data-control` / `ext-data-control`.
- **Notifications**: the `org.freedesktop.Notifications` D-Bus service.
- **Media controls**: MPRIS players over D-Bus.
- **Storage**: mounts and removable media via udisks2.
- **Input**: keyboard layout and pointer settings.
- **Screenshots and screen capture**: `wlr-screencopy` / `ext-image-copy-capture`.

These are ideas, not commitments. The first milestone is to finish the control
panel structure and the four requested tool views. Audio is the first real
backend and is in progress; Bluetooth, Wi-Fi and power still need theirs.

## Credits

The control-panel icons come from **Font Awesome Free 6.7.2** by Fonticons,
Inc. They are embedded in the binary as 128×128 PNGs and tinted with the active
theme. The icons are licensed under CC BY 4.0; see
[`src/icons/LICENSE-font-awesome.txt`](src/icons/LICENSE-font-awesome.txt) for
source paths and attribution.

## Requirements

iube requires a Wayland compositor that advertises `zwlr_layer_shell_v1`. That
is what gives every iube tool the same native, centred overlay window with
exclusive keyboard focus, without compositor-specific rules. Layer-shell is
supported by Hyprland, Sway and other wlroots compositors, KDE Plasma/KWin,
Wayfire, labwc, River, niri and many Mir-based compositors. It is not supported
by GNOME/Mutter, Weston or X11 sessions.

See [docs/launcher.md](docs/launcher.md#layer-shell-is-required) for the full
explanation.
