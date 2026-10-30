# The iube application launcher

This is the original iube experience, now opened with `iube launch`:

> A small application launcher for Wayland. It reads `.desktop` files, shows
> their names and PNG icons, filters as you type, and launches the selected
> command.

The launcher shares its configuration, theme, renderer, font and window
behaviour with the control panel and every planned tool. This document only
covers the launcher-specific parts.

![iube filtering the application list](screenshot.png)

## Why the launcher?

iube is built for the moment between pressing a shortcut and getting on with
your work. The launcher is one process with one job: read the `.desktop` files,
draw a list, launch the chosen command.

- **Opens in under 15 ms.** Measured from process start to the compositor
  mapping its layer surface, a ReleaseFast build has a median launch time of
  **11.2 ms** (10.5 to 12.8 ms across five runs). Filtering and selection redraws
  are sub-millisecond.
- **Under 10 MB of RAM.** **8.4 MB** resident after the window opens with 34
  desktop entries loaded. Icon decoding is lazy: only the icons for rows that
  are actually drawn are decoded.
- **Dependency-free.** `build.zig.zon` has no package dependencies. There is no
  GTK, Qt, SDL, OpenGL, FreeType/HarfBuzz, Rust/Node runtime or vendored
  dependency tree behind it: just Zig's standard library, libc, and the two
  libraries every Wayland desktop already has, `libwayland-client` and
  `libxkbcommon`.
- **Nothing left running.** Close the launcher and the process is gone. It keeps
  no index, database or search server resident between launches.

### How it compares

Measured on the same machine, same desktop, same 34 `.desktop` entries and
default configuration. Launch is the median of five runs, from process start
(or the service request) to the compositor mapping the window. Memory is
resident set size after the window has settled.

| Launcher | Launch (median) | Resident memory | How it runs |
| --- | ---: | ---: | --- |
| **iube** | **11.2 ms** | **8.4 MB** | one process per launch |
| fuzzel | 21.1 ms | 18.2 MB | one process per launch |
| rofi | 45.3 ms | 28.5 MB | one process per launch |
| wofi | 61.5 ms | 44.2 MB | one process per launch |
| Vicinae | 6.1 ms | 336.6 MB | server and helpers stay resident |
| Walker | 43.6 ms | 413.8 MB | Walker service and Elephant stay resident |

The memory column is the whole footprint needed to open the launcher: for
Walker it includes the Walker service and the Elephant data source; for Vicinae
it includes the Vicinae server and its helper processes. Their launch times are
low because those services are already running after login; starting them cold
is additional work not included here. That is the normal post-login comparison
for a daemon-backed launcher, and it is also why their resident footprint stays
in the hundreds of megabytes even when the window is closed. iube has no warm
service to pay for: every launch is a fresh process, and the process exits when
you close it.

Fuzzel is the closest single-process comparison. iube uses about half its
resident memory and avoids the pixel/font stack that fuzzel links (pixman and
fcft).

**Measurement notes.** Five runs after one warm-up, on Hyprland 0.55 with a
2560×1600 output at 1.25× scale, using the compositor's `openlayer` event and
`ps -o rss`. iube was built with `--release=fast`; the other launchers
were their Nixpkgs release builds. All used their default configuration, with
no tuning applied. RSS is summed per process, so multi-process launchers count
shared library pages once per process. Values vary with the number of installed
`.desktop` files, icons and providers.

## Launcher code path

The launcher is intentionally isolated from the control panel:

1. `src/main.zig` sees `iube launch` and calls `runLauncher`.
2. `src/launcher.zig` scans `.desktop` entries and builds the icon cache.
3. `src/session.zig` loads the shared config, creates the layer surface and
   runs the event loop.
4. `src/launcher.zig` owns search, filtering, selection, scrolling and process
   launching.

The `iube` control panel never imports or initialises launcher state. Opening
the launcher does not build the panel's tool registry or run any panel layout
code.

## Configuration

iube reads `$XDG_CONFIG_HOME/iube/config`, or `~/.config/iube/config` when
`XDG_CONFIG_HOME` is unset. The file is shared by every iube command. It is
optional and is only read once at startup. Lines are `key = value`; blank
lines, lines starting with `#` or `;`, and trailing `;` or ` #` comments are
ignored, and an optional `[colors]` section groups the colour keys. The file is
capped at 64 KiB and is not kept in memory after parsing.

```ini
# ~/.config/iube/config

# Multiplies every dimension: window, margins, icons, text and radii.
# Range 0.5 .. 4.0. Default: 1.0
scale = 1.0

# Window corner radius. Search, rows and fallback icons use half of this.
# Default: 0
corner_radius = 12

[colors]
# Rosé Pine defaults, shown here for clarity.
base = #191724
surface = #1f1d2e
accent = #9ccfd8      # foam
dark_accent = #31748f # pine
detail_1 = #ebbcba    # rose
detail_2 = #c4a7e7    # iris
warm_1 = #f6c177      # gold
warm_2 = #eb6f92      # love
text = #e0def4
muted = #6e6a86
highlight_low = #21202e
highlight_mid = #403d52
highlight_high = #524f67
```

Colours accept `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` and the same values with
a `0x` prefix. Invalid values are reported at startup and the default is kept.

The colour roles are:

| Key | Palette name | Used for |
| --- | --- | --- |
| `base` | n/a | window background |
| `surface` | n/a | search field and unselected rows |
| `accent` | foam | search-field focus ring, text cursor, icon-gradient start, volume-gradient start |
| `dark_accent` | pine | inline “Coming soon” text and placeholder badge |
| `detail_1` | rose | middle of the control-panel icon gradient |
| `detail_2` | iris | end of the icon gradient, audio secondary names, fallback initials |
| `warm_1` | gold | middle of the volume-bar gradient |
| `warm_2` | love | end of the volume-bar gradient |
| `text` | n/a | application/tool names and typed query |
| `muted` | n/a | placeholder text, "No matches", footer hints |
| `highlight_low` | n/a | hovered row, fallback icon background |
| `highlight_mid` | n/a | window border |
| `highlight_high` | n/a | selected row |

`warm_1` and `warm_2` are the grouped warm accents (gold and love). All control
panel icons share the same `accent → detail_1 → detail_2` gradient.

## Launcher controls

- Type to filter the list.
- `Up` / `Down` select an entry, `Enter` launches it.
- Click a row to launch it.
- Mouse wheel scrolls the list.
- Press `Esc` to close.

Clipboard paste and IME are not implemented.

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

The launcher creates an **overlay layer surface** sized 640×360 by default
(multiplied by the configured `scale`), centred on the focused output, with
exclusive keyboard focus. No compositor configuration is required.

The control panel asks for a different height: exactly enough to show every tool
row without scrolling. The tool placeholders use a shorter 640×240 window. All
views use the same layer-shell setup, colours and border.

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
