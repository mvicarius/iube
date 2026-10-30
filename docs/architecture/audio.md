# Audio

## Design

- `audio.zig` speaks the PulseAudio native protocol (version 12) over the user
  socket, using tagstruct packets and the PulseAudio cookie. It does not link
  `libpulse`, `libpipewire` or `libasound`.
- The view owns one client and one state snapshot for the window lifetime.
  Device lists come from `GET_SERVER_INFO`, `GET_SINK_INFO_LIST` and
  `GET_SOURCE_INFO_LIST`; monitor sources are filtered out.
- Volume and mute changes mutate the local `Device` first, then send the
  matching `SET_*` command. `Enter` sends `SET_DEFAULT_SINK`/`SOURCE`.
- The window height is derived from the larger of the sink and source counts,
  clamped to eight visible rows.

## Strengths

- Works with PulseAudio and `pipewire-pulse` through the same socket.
- No client library, no daemon and no process left behind.
- Device lookup for the CLI is case-insensitive on both name and description.
- The UI shows backend errors without exiting, and `R` reconnects.
- Volume bars use fixed-width percentages so layout does not jitter.
- Volume changes scale the per-channel values instead of flattening balance.

## Limits

- All protocol calls are synchronous on the view thread; a slow server can
  stall a redraw or key action.
- No subscription events; external changes appear only after `R` or reopen.
- No per-application streams, profiles, ports, meters or PipeWire-native graph
  control.
- No ALSA-only fallback when no PulseAudio-compatible socket exists.
- The view clamps at 150%, but `cli.zig::volumeTarget` clamps at 100%: the same
  volume can behave differently from the window and from `iube audio`.
- The CLI only changes the default sink/source; it cannot select a device by
  index.
- `audio default` checks sinks and sources separately and reports ambiguity if
  both contain a match.

## Code path

1. `src/main.zig::runAudio` constructs `audio_view.Audio`.
2. `src/audio_view.zig` owns tabs, selection, volume/mute/default actions and
   drawing.
3. `src/audio.zig` connects to `$XDG_RUNTIME_DIR/pulse/native` (or
   `/run/user/<uid>/pulse/native`), authenticates with the cookie and exchanges
   native packets.
4. `src/cli.zig` reuses the same client for `iube audio <action>`; action paths
   exit before Wayland setup.
5. `src/session.zig` supplies the shared loop and renderer.

## Testability

- `audio.zig` tests the tagstruct builder/reader and device percentage/label
  formatting; `cli.zig` tests action parsing, device lookup and volume
  clamping.
- The socket protocol itself needs a live PulseAudio/PipeWire server; there is
  no fake server harness.
