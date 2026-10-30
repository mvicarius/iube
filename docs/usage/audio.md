# Audio

`iube audio` opens the audio controller. It lists PulseAudio/PipeWire output and
input devices and changes volume, mute and the default device.

## Controls

| Input | Effect |
| --- | --- |
| `Tab` | Switch between Outputs and Inputs. Selection and scroll reset. |
| `Up`, `Down` | Select a device. |
| `Left` | Lower the selected device by 5%. |
| `Right` | Raise the selected device by 5%. |
| `M` | Toggle mute on the selected device. |
| `Enter` | Make the selected device the default output or input. |
| `R` | Reconnect and reload the device lists. |
| `Esc` | Close the window. |
| Pointer click on a tab | Switch to that tab. |
| Pointer click on a row | Select it. |
| Wheel | Scroll the list when it overflows; otherwise adjust volume by 5%. |

The view starts on Outputs. A dot marks the default device. The header shows
`Audio`; the footer shows the key hints or the last error for five seconds.
The window grows with the list, up to eight visible rows.

`Left`/`Right` and the wheel clamp at 0% and 150% in the view. The non-UI
commands clamp at 0% and 100%; see the note under [Limits](#limits).

## Commands

All percentages are integers from 0 to 100.

| Command | Effect |
| --- | --- |
| `iube audio volume-up [percent]` | Raise the default output by `percent` (default 5), clamped to 100. |
| `iube audio volume-down [percent]` | Lower the default output by `percent` (default 5), clamped to 0. |
| `iube audio mute` | Toggle mute on the default output. |
| `iube audio mic-mute` | Toggle mute on the default input. |
| `iube audio default <name>` | Make a sink or source the default device. |

`default` matches `<name>` case-insensitively against the PulseAudio device name
and its human-readable description. If the query matches both a sink and a
source, the command fails as ambiguous. Quote descriptions containing spaces:

```sh
iube audio default "Built-in Audio Analog Stereo"
iube audio default alsa_output.pci-0000_00_1f.3.analog-stereo
```

Output is one line on stdout:

```text
Volume: 45%
Output: muted
Input: unmuted
Default output: Built-in Audio Analog Stereo
```

`volume-up`/`volume-down` clamp the current value to 0–100 first, so a device
already above 100% comes back into range. Exit status is `0` on success, `1`
for backend errors (no default sink/source, no match, ambiguity), and `2` for
invalid syntax or a percentage outside 0–100.

## Backend

iube connects to the PulseAudio-compatible socket at
`$XDG_RUNTIME_DIR/pulse/native` (falling back to `/run/user/<uid>/pulse/native`)
and authenticates with the PulseAudio cookie. Both PulseAudio and
`pipewire-pulse` expose this socket. No `libpulse`, `libpipewire` or `libasound`
is linked.

If the socket is unavailable, the view shows `Audio unavailable` and the error;
press `R` to retry. Actions print `iube: no default audio output` or a similar
one-line error.

## Limits

- No per-application stream control, device profiles or port selection.
- No live subscription; use `R` or reopen the window after external changes.
- No input level meters.
- No ALSA-only fallback when no PulseAudio-compatible socket exists.
- The CLI only changes the default sink/source; select another device first with
  `iube audio default`.
- The view allows up to 150%, but the CLI and `volumeTarget` clamp to 100%.
- Monitor sources are hidden from the Inputs tab.
