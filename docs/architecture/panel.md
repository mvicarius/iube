# Control panel

## Design

- The panel is a fixed list compiled from `tools.all`; there is no search,
  scroll or runtime discovery.
- Its window height is `metrics.listWindowSize(tools.all.len)`, so every row is
  visible without clipping.
- Activating a row calls `spawn.spawnSelf` with the tool id and sets
  `running = false`. The child is a new `iube <id>` process; the panel does not
  switch views in place.
- Icons are embedded PNGs in the registry, decoded lazily on first draw and
  tinted with the `accent -> detail_1 -> detail_2` gradient.

## Strengths

- The panel never scans `.desktop` files or builds launcher/icon state.
- The handoff keeps each tool's first process free of other tools' setup.
- No compositor-specific rules; layer-shell supplies the overlay and focus.
- Missing or corrupt icons degrade to a rounded box with the initial.

## Limits

- A separate `exec` per selection costs a process start; there is no in-place
  view switch.
- No search, favourites, categories or reordering. The list is whatever
  `tools.zig` contains at build time.
- `spawnSelf` resolves `/proc/self/exe` and falls back to `"iube"` when the
  link cannot be read, which fails if the binary is not on `PATH`.
- Every registry entry must have an explicit `main.zig` branch; unknown ids
  print usage instead of opening a generic view.

## Code path

1. `src/main.zig::runPanel` constructs `panel.Panel` and calls `session.run`.
2. `src/panel.zig` provides `windowSize`, keyboard/pointer handling and `draw`.
3. `src/tools.zig` supplies ids, names, icons and the row count.
4. `src/spawn.zig` starts `/proc/self/exe <id>`; `src/session.zig` closes the
   panel.

## Testability

- `ui.Metrics.listWindowSize` has a unit test for exact row fitting.
- `tools.zig` tests id uniqueness and lookup; the registry is compile-time data,
  so malformed entries fail the build.
- Pointer hit-testing, activation and layered drawing are manual: there is no
  headless view test.
