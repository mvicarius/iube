# The iube audio controller

`iube audio` is the first implemented management view. It lists output and input
devices and changes their volume, mute and default state without linking
`libpulse`, `libpipewire` or `libasound`.

## How it works

iube speaks the **PulseAudio native protocol, version 12**, directly over
`$XDG_RUNTIME_DIR/pulse/native`. It authenticates with the user's PulseAudio
cookie and exchanges length-prefixed tagstruct packets over the Unix socket.
Both PulseAudio and `pipewire-pulse` expose this socket, so the same client
covers the two common desktop audio stacks.

Device discovery uses:

- `GET_SERVER_INFO`
- `GET_SINK_INFO_LIST`
- `GET_SOURCE_INFO_LIST`

Monitor sources are filtered out of the input list.

Changes use:

- `SET_SINK_VOLUME`
- `SET_SOURCE_VOLUME`
- `SET_SINK_MUTE`
- `SET_SOURCE_MUTE`
- `SET_DEFAULT_SINK`
- `SET_DEFAULT_SOURCE`

There is no resident daemon. The connection is opened for the window and closed
when it exits.

## Controls

- `Tab` switches between outputs and inputs.
- `Up` / `Down` selects a device.
- `Left` / `Right` changes volume in 5% steps. Holding the key repeats.
- `M` toggles mute.
- `Enter` makes the selected device the default.
- `R` refreshes the device list.
- `Esc` closes.

Volume percentages use a fixed width so the bar does not move between values
such as `0%`, `40%` and `100%`. Volume bars use the shared `accent`, `warm_1`
and `warm_2` gradient.

## Why ALSA and PipeWire both appear

They are different layers, not two alternatives that iube needs at once.

- **ALSA** is the kernel and driver interface that every Linux sound device goes
  through. iube does not open `/dev/snd/*` or link `libasound`.
- **PipeWire** is a userspace sound server. Its `pipewire-pulse` component
  exposes the PulseAudio-compatible socket that iube uses now.
- **PulseAudio** exposes the same socket on systems that still use it.
- **PipeWire's native protocol** is a possible future path for deeper graph and
  per-application routing. It is not required for normal device control.

An optional ALSA fallback for systems without a sound server is planned, but
ALSA is already underneath PipeWire and PulseAudio; the fallback would not add a
required dependency.

## Current limitations

- No per-application playback stream control.
- No live subscription updates; press `R` or reopen the window.
- No input level meters.
- No ALSA-only fallback yet.
- No PipeWire native protocol support.

## Planned work

- **ALSA fallback.** Read and write mixer controls through `/dev/snd/controlC*`
  using kernel control ioctls when no PulseAudio-compatible socket exists.
- **Per-application streams.** Add `GET_SINK_INPUT_INFO_LIST` and support
  volume, mute and move-to-device.
- **Live updates.** Subscribe to `PA_COMMAND_SUBSCRIBE` events instead of
  refreshing only on open or `R`.
- **Output and input meters.** Read stream peaks without keeping an audio stream
  open in iube.
- **PipeWire native protocol.** Deeper graph routing could skip the PulseAudio
  compatibility layer, but it is more complex and less of a stable public client
  ABI, so it remains a later target.

## Open questions

- Whether the ALSA fallback should control hardware mixers directly or defer to
  `alsactl` state. Some laptops route volume through a DSP, so control names
  vary.
- Whether subscription events are worth the extra socket and event loop work, or
  whether refresh-on-open is enough.

## Code path

1. `src/main.zig` sees `iube audio` and calls `runAudio`.
2. `src/audio_view.zig` builds the audio view and handles keys, pointer input and
   drawing.
3. `src/audio.zig` speaks the PulseAudio native protocol over the user socket.
4. `src/session.zig` provides the shared Wayland loop, config and renderer.
