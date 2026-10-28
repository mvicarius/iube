# iube

A small application launcher for Wayland, built with
[dvui](https://github.com/david-vanderson/dvui) and its SDL3 backend. It reads
`.desktop` files, shows their names and PNG icons, filters as you type, and
launches the selected command.

## Build

```sh
nix develop --command zig build
./zig-out/bin/iube
```

Or:

```sh
nix develop --command zig build run
```

The first build compiles dvui and SDL3 from source, so it takes a while. Later
builds are incremental.

dvui and this project require Zig **0.17.0**. The flake tracks
`nixos-unstable`, which currently ships that version.

## Controls

- Type to filter the list.
- Click a row to launch it.
- Press `Esc` to close.

## Floating window (read this)

dvui's SDL3 backend creates a **regular Wayland toplevel** (`xdg-shell`). It
does not support `zwlr_layer_shell`, so it cannot create a layer-shell overlay.

On Hyprland, iube registers a runtime window rule named `iube-runtime` with
`hyprctl eval` *before* creating its window. The rule floats, centres, pins,
and sizes the window to 640×360, so running `iube` directly gives a floating
launcher without editing any config. The rule is re-registered on every launch
and is lost when Hyprland reloads or restarts (the next iube launch adds it
again).

The rule matches `class = "^(iube)$"` — dvui/SDL3 sets the Wayland app
id/class to the binary name, `iube`. Matching the class matters: the title can
arrive too late for the initial configure, which lets Hyprland tile the first
frame.

On Hyprland, the app maps one empty transparent frame before drawing the real
UI, then waits for the rule's resize and SDL's scale change to settle. That is
what prevents the oversized first frame on a second monitor with a different
scale. On other compositors this settle is skipped and the window is a normal
tiled toplevel.

If you prefer config-managed rules, the equivalent rule is in
[`hypr/iube.lua`](hypr/iube.lua), named `iube-config` so the app's runtime rule
does not overwrite it. Add its contents to your Hyprland Lua config (for
example `windows.lua` or via `require`).

If you need true layer-shell behaviour (anchored surfaces, keyboard
interactivity modes, always above fullscreen without compositor rules), a
different window backend is required.

## Implementation notes

- **Client size.** Hyprland maps a new toplevel tiled before applying the
  float/size rule. iube commits one empty transparent frame, waits for the
  rule's resize and SDL's scale change to settle, and only then draws the UI.
  That keeps the first visible frame at 640×360, including on a second monitor
  with a different scale.
- **Icons.** Only PNG icons are used. The scanner prefers the icon closest to
  32 px and falls back to a coloured box with the app's initial.
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
  This is what makes entries such as `btop++` and `Neovim wrapper` show up.
