# Application launcher

`iube launch` opens a 640×360 overlay (multiplied by the configured `scale`)
with a search field and a scrollable list of installed `.desktop` applications.

## Controls

| Input | Effect |
| --- | --- |
| Printable text | Append to the query; filters application names by case-insensitive substring. |
| `Backspace` | Delete the last codepoint. |
| `Ctrl+U` | Clear the query. |
| `Up` | Select the previous row; from no selection, select the last row. |
| `Down` | Select the next row; from no selection, select the first row. |
| `Enter` | Launch the selected application and close the launcher. |
| Pointer move | Highlight the row under the pointer. |
| Pointer click | Launch the clicked row immediately. |
| Wheel | Scroll the list. |
| `Left`, `Right` | Ignored. |
| `Esc` | Close the launcher. |

Other `Ctrl`, `Alt` and `Super` combinations are ignored. The query accepts up
to 256 bytes; long queries scroll horizontally to keep the end visible. Matching
is on the application name only, not on the command line or categories.

## Launch behaviour

- `%f`, `%F`, `%u`, `%U`, `%i`, `%c`, `%k`, `%d`, `%D`, `%n`, `%N`, `%v` and
  `%m` field codes are removed; `%%` becomes `%`.
- The resulting command is run through `sh -c`.
- `Terminal=true` entries run inside `$TERMINAL` when it is set, otherwise in
  the first available of Ghostty, Kitty, Foot, Alacritty, WezTerm, XTerm,
  Konsole, GNOME Terminal or `xdg-terminal-exec`.
- If no terminal can be started, the failure is logged and the launcher stays
  open. The window also stays open when spawning the command fails.

## Backend

The launcher scans `/usr/share/applications`, `/run/current-system/sw/share/applications`,
`$XDG_DATA_HOME` (or `~/.local/share`), and each `$XDG_DATA_DIRS` entry. Entries
with `Hidden=true` or `NoDisplay=true` are skipped. Only PNG icons are used;
icons are decoded lazily per drawn row, and a missing icon falls back to a
coloured box with the application's initial.

The only non-UI command is `iube launch`; it has no action grammar.

## Layer-shell is required

`iube` creates a `zwlr_layer_shell_v1` overlay surface. This is what gives it a
centred, floating window with exclusive keyboard focus and no compositor-specific
rules.

Supported by Hyprland, Sway and other wlroots compositors, KDE Plasma/KWin,
Wayfire, labwc, River, niri and many Mir-based compositors. Not supported by
GNOME/Mutter, Weston or X11 sessions. There is no `xdg-shell` fallback: iube
exits with `LayerShellUnavailable` instead of opening a tiled window.

## Limits

- No clipboard paste, IME or cursor movement inside the query.
- No application actions, categories, favourites or recently used list.
- The list is filtered in memory after one scan; there is no index or cache.
- The window size is fixed; very long lists scroll.
