# Control panel

`iube` or `iube panel` opens the control panel: one row for every tool in the
binary. The window is sized to show all six rows; it has no search field and no
scrolling.

| Row | Opens |
| --- | --- |
| Application Launcher | `iube launch` |
| Audio | `iube audio` |
| Bluetooth | `iube bluetooth` |
| Wi-Fi | `iube wifi` |
| Power | `iube power` |
| Brightness | `iube brightness` |

## Controls

| Input | Effect |
| --- | --- |
| `Up` | Move selection up; stops at the first row. |
| `Down` | Move selection down; stops at the last row. |
| `Left`, `Right` | Ignored. |
| `Enter` | Start the selected `iube <tool>` process and close the panel. |
| Pointer move | Highlight the row under the pointer. |
| Pointer click | Start the clicked tool and close the panel. |
| Wheel | Ignored. |
| `Esc` | Close the panel. |

The panel is keyboard-first: the selected row is highlighted with
`highlight_high`, the hovered row with `highlight_low`.

## Commands

| Command | Effect |
| --- | --- |
| `iube` | Open the control panel. |
| `iube panel` | Open the control panel (same view). |

## Requirements and limits

- A compositor that advertises `zwlr_layer_shell_v1` is required.
- No system service is contacted. Rows come from the compiled `src/tools.zig`
  registry, so adding a tool requires a new build.
- Selecting a row spawns the running binary through `/proc/self/exe` and exits;
  the tool gets a fresh process and its own config/theme/renderer setup.
- There is no search, favourite list or scrolling. All registered tools fit in
  one fixed list.
