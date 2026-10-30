# Launcher

## Design

- `launcher.Launcher.init` scans `.desktop` files once, sorts names
  case-insensitively, and keeps indices in `visible` for the filtered view.
- Filtering is a case-insensitive substring scan of the application name on
  every query edit. The query is a fixed 256-byte buffer.
- The window is a fixed 640×360 base; the list scrolls, icons decode lazily per
  drawn row, and missing icons fall back to an initial.
- Launching strips `.desktop` field codes, then runs the command through
  `sh -c`. `Terminal=true` entries are wrapped in `$TERMINAL` or a built-in
  emulator list.
- There is no action grammar: `iube launch` opens the view and nothing else.

## Strengths

- No index, cache or resident process; one scan per launch.
- Filtering is allocation-free and redraws only the visible rows.
- Icons are decoded only when their row is drawn.
- Terminal detection handles the common `-e`/`--`/`start --` conventions.
- The launcher is fully isolated from panel and tool state.

## Limits

- Linear substring matching: no fuzzy matching, word boundaries, ranking or
  command-line search.
- No clipboard paste, IME, cursor movement or query history.
- Only PNG icons; SVG and icon-theme lookups are not implemented.
- `.desktop` actions, categories, `TryExec` and `OnlyShowIn` are not handled.
- Field-code stripping is a small allow-list; unknown `%` codes are kept.
- Commands run through `sh -c`, so shell syntax in `Exec=` is honoured.
- Fixed window size; very long lists scroll without a scrollbar.
- `desktop.zig` and `launcher.zig` are not imported by `src/tests.zig`, so the
  scanner, filter and spawn paths have no unit coverage.

## Code path

1. `src/main.zig::runLauncher` builds `launcher.Launcher` with `HOME`,
   `XDG_DATA_HOME`, `XDG_DATA_DIRS` and `$TERMINAL`.
2. `src/launcher.zig` owns query state, filtering, selection, scrolling,
   launching and drawing.
3. `src/desktop.zig` scans data dirs, parses entries, indexes PNG icons and
   strips hidden entries.
4. `src/session.zig` provides config, layer surface, input and frames;
   `src/spawn.zig` is not used here.

## Testability

- No launcher tests today. The pure pieces worth testing are the filter, field
  code stripping, `.desktop` parsing and terminal-prefix selection.
- The window and layer surface are exercised manually in a layer-shell
  compositor.
