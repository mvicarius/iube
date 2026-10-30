# Configuration

Every iube command reads the same optional config file once at startup.

## Location

1. `$XDG_CONFIG_HOME/iube/config` when `XDG_CONFIG_HOME` is set to a non-empty
   absolute path.
2. Otherwise `~/.config/iube/config`.
3. Otherwise the built-in defaults are used.

Trailing slashes are trimmed. A relative `XDG_CONFIG_HOME` is ignored. The file
is capped at 64 KiB and is not kept in memory after parsing. Missing files are
not an error.

## Format

```ini
# comment
; another comment

scale = 1.0
corner_radius = 12

[colors]
accent = #9ccfd8
```

- Lines are `key = value`. A `:` is accepted instead of `=`.
- Blank lines, lines starting with `#` or `;`, and any line starting with `[`
  are ignored. The `[colors]` section is cosmetic; colours work outside it too.
- Keys are case-insensitive. `-` and `_` are equivalent, so `corner-radius`
  and `Corner_Radius` work.
- A value may be quoted with matching single or double quotes.
- Inline comments: `;` starts one anywhere; ` #` or a tab followed by `#`
  starts one.
- Unknown keys are ignored silently. An invalid value logs a warning and keeps
  the previous value (usually the default). Empty values are ignored.
- If a key is repeated, the last valid assignment wins.

## Keys

| Key | Type | Default | Range / notes |
| --- | --- | --- | --- |
| `scale` | float | `1.0` | `0.5`–`4.0`. Multiplies window, margins, icons, text, gaps and radii. |
| `corner_radius` | number | `0` | `0`–`256`. Rounded to an integer; larger values clamp to 256. Search fields, rows and fallback icons use half. |

`scale` also multiplies the font; body text uses an internal 1.125 factor on top
of it. Invalid, non-finite or out-of-range scale values are ignored.
Negative corner radii are invalid; values above 256 are clamped, not rejected.

## Colours

All colour keys accept:

| Form | Example |
| --- | --- |
| `#rgb` | `#acd` |
| `#rgba` | `#acdf` |
| `#rrggbb` | `#9ccfd8` |
| `#rrggbbaa` | `#9ccfd8ff` |
| `0x...` | `0x9ccfd8`, `0x9ccfd8ff` |

`0X` is also accepted. A bare hex value without `#` or `0x` is invalid. Short
forms expand each nibble (`#abc` → `#aabbcc`). Missing alpha is opaque.

| Key | Default | Main use |
| --- | --- | --- |
| `base` | `#191724` | Window background and dimmed confirmation overlay. |
| `surface` | `#1f1d2e` | Unselected rows, cards and the search field body. |
| `accent` | `#9ccfd8` | Focus ring, cursor, active tab text, connected state, gradient start. |
| `dark_accent` | `#31748f` | Reserved dark accent for palette compatibility. |
| `detail_1` | `#ebbcba` | Middle of the panel icon gradient; saved/paired states. |
| `detail_2` | `#c4a7e7` | Secondary text, fallback initials, icon gradient end. |
| `warm_1` | `#f6c177` | Pending actions, discharging state, gradient middle. |
| `warm_2` | `#eb6f92` | Errors, destructive actions, gradient end. |
| `text` | `#e0def4` | Primary names, values and typed text. |
| `muted` | `#6e6a86` | Hints, placeholders, disabled and unavailable text. |
| `highlight_low` | `#21202e` | Hovered row, fallback icon background, badge background. |
| `highlight_mid` | `#403d52` | Window border and password modal border. |
| `highlight_high` | `#524f67` | Selected row. |

## Example

```ini
# ~/.config/iube/config
scale = 1.25
corner-radius = 12

[colors]
base = #191724
surface = #1f1d2e
accent = #9ccfd8        # foam
dark_accent = #31748f   # pine
detail_1 = #ebbcba      # rose
detail_2 = #c4a7e7      # iris
warm_1 = #f6c177        # gold
warm_2 = #eb6f92        # love
text = #e0def4
muted = #6e6a86
highlight_low = #21202e
highlight_mid = #403d52
highlight_high = #524f67
```
