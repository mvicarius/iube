# iube

## What is iube?

iube is a small, dependency-light control panel for the Linux desktop. It opens
fast, draws its own UI, and keeps nothing running in the background.

The development philosophy is to stay extremely fast and lightweight: no
application toolkit, no resident daemon, and no tool-specific client libraries.
The tools talk to the kernel and system services directly. See
[Design goals and philosophy](#design-goals-and-philosophy).

## The name

**iube** comes from Latin *iubeō, iubēre* ("to order, command"). It is the
second-person singular present active imperative, meaning **"command!"** or
**"order!"**.

Classical Latin: **[ˈjʊ.beː]**, roughly **YOO-beh**.

## Features

Each command builds only the view it needs. The control panel does not scan
`.desktop` files, the launcher does not build the panel, and every tool is
separate from the others. All commands share the same config at
`~/.config/iube/config`, the same theme, scaling, font, renderer and layer-shell
window setup.

| Tool | Command | Preview | Open | Peak RSS |
| --- | --- | --- | ---: | ---: |
| Control panel | `iube` | <img src="docs/screenshot-panel.png" width="280" alt="Control panel"> | 5.5 ms | 14.4 MB |
| Application launcher | `iube launch` | <img src="docs/screenshot.png" width="280" alt="Application launcher"> | 7.8 ms | 14.4 MB |
| Audio | `iube audio` | <img src="docs/screenshot-audio.png" width="280" alt="Audio controller"> | 9.6 ms | 14.4 MB |
| Bluetooth | `iube bluetooth` | <img src="docs/screenshot-bluetooth.png" width="280" alt="Bluetooth controller"> | 7.7 ms | 14.4 MB |
| Wi-Fi | `iube wifi` | <img src="docs/screenshot-wifi.png" width="280" alt="Wi-Fi controller"> | 11.9 ms | 14.4 MB |
| Power | `iube power` | <img src="docs/screenshot-power.png" width="280" alt="Power controller"> | 16.5 ms | 14.4 MB |
| Brightness | `iube brightness` | <img src="docs/screenshot-brightness.png" width="280" alt="Brightness controller"> | 7.5 ms | 14.4 MB |

Measurements are produced by [docs/measure.py](docs/measure.py). The script runs
five measurements after one warm-up. Open time is measured from process start to
the compositor mapping the iube layer surface through Hyprland's IPC socket.
Peak RSS is the maximum resident set reported by `wait4`. The numbers above come
from a `--release=fast` build with Zig 0.17.0 on NixOS 26.05, AMD Ryzen 7 5800H,
Hyprland, on a 1920×1080 output at 1× scale.

More information about each feature lives in the [docs](docs) folder:
[launcher](docs/launcher.md), [audio](docs/audio.md),
[Bluetooth](docs/bluetooth.md), [Wi-Fi](docs/wifi.md),
[Power](docs/power.md), [Brightness](docs/brightness.md),
[CLI actions](docs/cli.md), [architecture](docs/architecture.md), and
[planned backends](docs/tools.md).

## Design goals and philosophy

- **One binary, one process per invocation.** No resident daemon, no index, no
  database, no search server. Close the window and the process is gone.
- **No application toolkit.** The UI is written directly against Wayland and
  composited by hand into `wl_shm` memory. The only linked libraries are libc,
  `libwayland-client` and `libxkbcommon`.
- **No tool-specific client libraries.** The managers speak the underlying
  protocols directly: the PulseAudio socket, BlueZ and NetworkManager over
  D-Bus, sysfs, and logind's D-Bus interface. System services such as PipeWire,
  BlueZ, NetworkManager, wpa_supplicant and logind are still expected to be
  running. iube does not replace them.
- **Shared visual language.** Theme, config, scaling, fonts, icons and window
  chrome are shared by every command.

## Requirements

iube requires a Wayland compositor that advertises `zwlr_layer_shell_v1`. That
is what gives every iube tool the same native, centred overlay window with
exclusive keyboard focus, without compositor-specific rules. Layer-shell is
supported by Hyprland, Sway and other wlroots compositors, KDE Plasma/KWin,
Wayfire, labwc, River, niri and many Mir-based compositors. It is not supported
by GNOME/Mutter, Weston or X11 sessions.

See [docs/launcher.md](docs/launcher.md#layer-shell-is-required) for the full
explanation.

The Wi-Fi controller additionally requires NetworkManager to be running and to
manage the wireless interface. NetworkManager owns the supplicant and saved
profiles; iube only reads their state over D-Bus.

## Installation

### From source

Building iube requires Zig 0.17.0, the Wayland development headers and the
libxkbcommon development headers. The generated Wayland protocol bindings for
`wlr-layer-shell` and `cursor-shape` are checked into `src/protocol`, so
`wayland-scanner` and `wayland-protocols` are not build dependencies.

```sh
zig build --release=fast
./zig-out/bin/iube
```

With no arguments the built binary opens the control panel. Use
`./zig-out/bin/iube launch` for the application launcher. Every tool also has
non-UI actions for keybinds and status bars; see [docs/cli.md](docs/cli.md).

### With Nix

If Nix is installed, the flake provides the package directly:

```sh
nix build .#iube
./result/bin/iube
```

### NixOS

Add iube as a flake input:

```nix
{
  inputs.iube.url = "github:mvicarius/iube";
}
```

Pass the package set to your configuration through `specialArgs`:

```nix
specialArgs = {
  iube = iube.packages.x86_64-linux;
};
```

Then install the package in `configuration.nix`:

```nix
environment.systemPackages = with pkgs; [
  iube.iube
];
```

Apply the configuration with your normal rebuild command, for example:

```sh
sudo nixos-rebuild switch --flake .#nixos
```

Replace `x86_64-linux` with your system if needed.

## Credits

The control-panel icons come from **Font Awesome Free 6.7.2** by Fonticons,
Inc. They are embedded in the binary as 128×128 PNGs and tinted with the active
theme. The icons are licensed under CC BY 4.0; see
[`src/icons/LICENSE-font-awesome.txt`](src/icons/LICENSE-font-awesome.txt) for
source paths and attribution.
