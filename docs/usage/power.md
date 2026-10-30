# Power

`iube power` opens the power controller. It shows battery and AC state, the
platform power profile when available, and five session actions: Lock, Suspend,
Hibernate, Restart and Shut down.

## Controls

| Input | Effect |
| --- | --- |
| `Up`, `Down` | Select an action. |
| `Enter` | Run the selected action. Restart and Shut down open a confirmation first. |
| `Enter` in confirmation | Run the confirmed Restart or Shut down. |
| `N` in confirmation | Cancel the confirmation. |
| `Tab` | Cycle to the next advertised power profile; reports when no profile is available. |
| `R` | Reload battery, profile and action availability. |
| `Esc` | Close the window. |
| Pointer click on a row | Select it; it does not run the action. Ignored during confirmation. |
| Wheel | Ignored. |

The header badge shows `Charging`, `AC - Full`, `AC`, `On battery`,
`No battery` or `Unavailable`. The summary card shows the battery percentage,
the charging/discharging estimate and AC state. The profile row shows the
active profile as `Low power`, `Power saver`, `Balanced` or `Performance`.

Unavailable actions stay in the list, are muted and report `Unavailable`.
Restart and Shut down are considered available even when logind may later ask
polkit. The view refreshes every 5 seconds unless a confirmation is open.

## Commands

| Command | Effect |
| --- | --- |
| `iube power suspend` | Suspend through logind. |
| `iube power hibernate` | Hibernate through logind. |
| `iube power reboot` | Restart through logind. |
| `iube power poweroff` | Shut down through logind. |
| `iube power lock` | Lock the current session. |
| `iube power battery` | Print battery percentage, status and AC state. |
| `iube power profile next` | Select the next advertised profile. |
| `iube power profile set <profile>` | Select an advertised profile. |

`profile set` accepts `low-power`, `power-saver`, `balanced` and
`performance`. `low-power` and `power-saver` are aliases for ACPI and
power-profiles-daemon naming; the command prints the name the backend actually
advertises. A profile the backend does not offer fails with
`that power profile is not available`.

The non-UI actions invoke logind directly and do not ask for confirmation.
Restart and Shut down in the window do ask; `power reboot` and
`power poweroff` do not.

Output is one line:

```text
Suspend
Power profile: balanced
87%	Discharging	AC: off
No battery	AC: on
```

`battery` reads sysfs and does not need D-Bus. Exit status is `0` on success,
`1` for a backend or state error (no profile service, rejected logind request,
permission denied), and `2` for invalid syntax or an unknown profile.

## Backend

Battery and AC state come from `/sys/class/power_supply`. Batteries with
`scope=Device` (for example a wireless mouse) are ignored; the first system
battery is used. Percentage falls back from `capacity` to
`energy_now`/`energy_full` or `charge_now`/`charge_full`.

Power profiles come from power-profiles-daemon when it is running, otherwise
from `/sys/firmware/acpi/platform_profile` and `platform_profile_choices`.

Session actions go through logind on the system D-Bus. logind decides whether
suspend and hibernate are available, owns the privilege check and performs the
action; iube stays an unprivileged process.

## Enabling platform profiles on Lenovo IdeaPad/Yoga

Some IdeaPad/Yoga models expose DYTC v4 but do not register `platform_profile`
unless `ideapad_laptop` is loaded with `allow_v4_dytc=Y`. On NixOS:

```nix
boot.extraModprobeConfig = "options ideapad_laptop allow_v4_dytc=Y";
services.power-profiles-daemon.enable = true;
```

After rebuilding and rebooting, `platform_profile_choices` should include
`low-power balanced performance`. Without power-profiles-daemon the row can
still appear, but the sysfs write may be denied.

## Limits

- Only the first system battery is shown; multiple packs are not aggregated.
- No UPower integration, so battery health, cycle count and history are absent.
- Writing `platform_profile` through sysfs often needs root. Without
  power-profiles-daemon, a profile change can fail with a permission error.
- The profile row is hidden when neither power-profiles-daemon nor
  `platform_profile` is available.
- Suspend, hibernate and shutdown depend on logind and the local polkit policy.
  A `challenge` result is treated as available, but a minimal session may have
  no polkit agent.
- No live updates or lid-switch handling; the view polls every 5 seconds.
- The UI confirmation cannot be cancelled with `Esc`; `Esc` closes the window,
  while `N` cancels the pending action.
