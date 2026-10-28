# iube

A small application launcher for Wayland. It reads `.desktop` files, shows
their names and PNG icons, filters as you type, and launches the selected
command.

The UI is written directly against Wayland and renders into `wl_shm` shared
memory. There is no SDL, no GL, no dvui and no widget toolkit: the only
libraries are `libwayland-client` and `libxkbcommon`.

## Build

```sh
nix develop --command zig build
./zig-out/bin/iube
```

Or:

```sh
nix develop --command zig build run
```

The build needs `wayland` and `libxkbcommon` development headers. The
generated protocol bindings for `wlr-layer-shell` and `cursor-shape` are
checked into `src/protocol`, so `wayland-scanner` and `wayland-protocols` are
not build dependencies.

This project requires Zig **0.17.0**. The flake tracks `nixos-unstable`, which
currently ships that version.

## Controls

- Type to filter the list.
- `Up` / `Down` select an entry, `Enter` launches it.
- Click a row to launch it.
- Mouse wheel scrolls the list.
- Press `Esc` to close.

## Layer-shell is required

**Layer-shell is needed for optimal working of the application.** iube creates
its window as a `zwlr_layer_shell_v1` overlay surface: that is what gives it a
native Wayland, centred 640×360 window with exclusive keyboard focus, without
any compositor-specific window rule.

Layer-shell is supported by:

- Hyprland, Sway and other wlroots-based compositors
- KDE Plasma / KWin
- Wayfire, labwc, River, niri
- many Mir-based compositors (some need
  `--add-wayland-extension zwlr_layer_shell_v1`)

It is **not** supported by GNOME/Mutter, Weston, or X11 sessions. On those,
iube exits with `LayerShellUnavailable` rather than opening a normal tiled
window. Core Wayland (`xdg-shell`) has no portable way to request a floating,
centred overlay, so there is no useful fallback.

## Window behaviour

iube creates an **overlay layer surface** sized 640×360, centred on the
focused output, with exclusive keyboard focus. No compositor configuration is
required.

## Implementation notes

- **Rendering.** Every frame is composited by hand into a premultiplied
  ARGB8888 `wl_shm` buffer: rounded rectangles with analytic antialiasing,
  a built-in bitmap font, and PNG icons.
- **HiDPI.** iube listens for `wl_surface.preferred_buffer_scale` and renders
  at the compositor's preferred integer scale, so text and icons stay crisp.
- **Font.** Text uses an embedded 8×16 VGA-derived bitmap font with Latin-1
  coverage. There is no FreeType/HarfBuzz dependency. Characters outside the
  font are rendered as `?`.
- **Icons.** Only PNG icons are used. The scanner prefers the icon closest to
  32 px and falls back to a coloured box with the app's initial. PNGs are
  decoded lazily with Zig's standard-library zlib decoder.
- **Desktop entries.** It scans `/usr/share`, `/run/current-system/sw/share`,
  `XDG_DATA_DIRS`, and `XDG_DATA_HOME` (falling back to
  `~/.local/share`), ignoring `Hidden=true` / `NoDisplay=true`.
- **Launching.** `%f`-style field codes are removed and the command is handed
  to `sh -c`, so shell quoting and environment assignments work as written in
  the `.desktop` file.
- **Terminal apps.** Entries with `Terminal=true` are run inside `$TERMINAL`
  when it is set (split on whitespace, with terminal-specific `-e`/`--`/`start`
  handling); otherwise iube tries Ghostty, Kitty, Foot, Alacritty, WezTerm,
  XTerm, Konsole, GNOME Terminal, and `xdg-terminal-exec`. If no terminal can
  be started, iube reports an error instead of running the TUI app invisibly.
- **Input.** Keyboard handling uses the compositor-provided xkb keymap plus
  `libxkbcommon`. Key repeat is implemented on the client, and mouse pointer
  cursor shapes come from `cursor-shape-v1`. Text is appended at the end of
  the query (backspace and `Ctrl+U` are supported); clipboard paste and IME
  are not implemented.
