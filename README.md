# iube

iube is a small, dependency-light control panel for the Linux desktop. It opens
fast, draws its own UI, and keeps nothing running in the background.

The project started as an application launcher. It is now growing into a set of
small OS management tools that share one binary, one theme, one config file and
one renderer:

- **Application launcher** — implemented (`iube launch`).
- **Control panel** — implemented (`iube`), listing every tool iube exposes.
- **Audio manager** — planned; placeholder view available (`iube audio`).
- **Bluetooth manager** — planned; placeholder view available (`iube bluetooth`).
- **Wi-Fi manager** — planned; placeholder view available (`iube wifi`).
- **Power manager** — planned; placeholder view available (`iube power`).

The management tools will talk to the kernel and system services directly
instead of pulling in GTK, Qt, NetworkManager client libraries, BlueZ client
libraries, PipeWire client libraries or D-Bus client libraries. See
[docs/tools.md](docs/tools.md) for the planned backends.

## Current status

| Area | Status | Command |
| --- | --- | --- |
| Control panel | **Available** | `iube` |
| Application launcher | **Available** | `iube launch` |
| Shared config, theme and renderer | **Available** | all commands |
| Audio | Placeholder ("coming soon") | `iube audio` |
| Bluetooth | Placeholder ("coming soon") | `iube bluetooth` |
| Wi-Fi | Placeholder ("coming soon") | `iube wifi` |
| Power | Placeholder ("coming soon") | `iube power` |

"Placeholder" means the command already opens a real iube window with the
shared theme and window behaviour. It shows the tool name, a **Coming soon**
badge and the planned backend. The tool itself is not implemented yet.

## How the commands work

```sh
iube             # control panel: every tool, all entries visible, no search
iube launch      # application launcher (the original iube experience)
iube audio       # audio tool (placeholder for now)
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
- `iube <tool>` builds only that tool's view. For now that is a placeholder.

All paths load the same `~/.config/iube/config`, compute the same scaled
metrics, use the same `wl_shm` renderer, font, colours, rounded rectangles and
layer-shell window setup. Selecting an entry in the control panel hands off to
the matching `iube <tool>` process and exits, so the selected path still starts
with only its own work.

## Design goals

- **One binary, one process per invocation.** No resident daemon, no index, no
  database, no search server. Close the window and the process is gone.
- **No application toolkit.** The UI is written directly against Wayland and
  composited by hand into `wl_shm` memory. The only linked libraries are libc,
  `libwayland-client` and `libxkbcommon`.
- **No tool-specific client libraries.** The planned managers will speak the
  underlying protocols directly: kernel netlink (nl80211), rfkill/sysfs, D-Bus
  over the system socket, the PulseAudio/PipeWire socket, and logind's D-Bus
  interface. System services such as BlueZ, wpa_supplicant, PipeWire and logind
  are still expected to be running; iube does not replace them.
- **Shared visual language.** Theme, config, scaling, fonts, icons and window
  chrome are shared by every command.
- **Honest placeholders.** A feature that is not implemented says so in the UI
  instead of shipping a broken control.

The application launcher still has its original performance characteristics.
The measurements, configuration reference and implementation notes now live in
[docs/launcher.md](docs/launcher.md).

## Documentation

- [docs/launcher.md](docs/launcher.md) — launcher features, performance,
  configuration, controls, layer-shell requirements and implementation notes.
- [docs/architecture.md](docs/architecture.md) — command dispatch, module
  layout, shared view interface and how to add a tool.
- [docs/tools.md](docs/tools.md) — dependency policy and the planned audio,
  Bluetooth, Wi-Fi and power backends.

## Build

For a normal release build:

```sh
nix develop --command zig build -Doptimize=ReleaseFast
./zig-out/bin/iube
```

Or, to build and run in one step:

```sh
nix develop --command zig build run -Doptimize=ReleaseFast
```

With no arguments the installed binary opens the control panel. Use
`./zig-out/bin/iube launch` for the application launcher.

A plain `zig build` produces a Debug build. It is fine while developing, but
uses more memory. The launcher figures in [docs/launcher.md](docs/launcher.md)
are from a ReleaseFast build.

The build needs `wayland` and `libxkbcommon` development headers. The generated
protocol bindings for `wlr-layer-shell` and `cursor-shape` are checked into
`src/protocol`, so `wayland-scanner` and `wayland-protocols` are not build
dependencies.

This project requires Zig **0.17.0**. The flake tracks `nixos-unstable`, which
currently ships that version.

## Roadmap

The four requested tools are the current near-term scope. Several other desktop
jobs fit the same model and could follow:

- **Display and brightness** — backlight via sysfs, external monitors via DDC,
  and night light/colour temperature via `wlr-gamma-control`.
- **Session actions** — lock, logout, suspend, reboot and shutdown via logind.
- **Network overview** — wired, VPN and connection state alongside Wi-Fi.
- **Clipboard history** — `wlr-data-control` / `ext-data-control`.
- **Notifications** — the `org.freedesktop.Notifications` D-Bus service.
- **Media controls** — MPRIS players over D-Bus.
- **Storage** — mounts and removable media via udisks2.
- **Input** — keyboard layout and pointer settings.
- **Screenshots and screen capture** — `wlr-screencopy` / `ext-image-copy-capture`.

These are ideas, not commitments. The first milestone is to finish the control
panel structure and the four requested tool views, then replace their
placeholders with real backends.

## Requirements

iube requires a Wayland compositor that advertises `zwlr_layer_shell_v1`. That
is what gives every iube tool the same native, centred overlay window with
exclusive keyboard focus, without compositor-specific rules. Layer-shell is
supported by Hyprland, Sway and other wlroots compositors, KDE Plasma/KWin,
Wayfire, labwc, River, niri and many Mir-based compositors. It is not supported
by GNOME/Mutter, Weston or X11 sessions.

See [docs/launcher.md](docs/launcher.md#layer-shell-is-required) for the full
explanation.
