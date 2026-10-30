# The iube power controller

`iube power` shows the laptop battery, changes the platform power profile and
requests session actions through logind. It talks to sysfs and the system D-Bus
directly, without linking UPower, libsystemd, libnm or a power-profiles client
library.

## How it works

Battery and AC state come from `/sys/class/power_supply`:

- `type` identifies `Battery`, `Mains` and other supplies. Batteries with
  `scope=Device`, such as a wireless mouse, are ignored so the laptop battery
  is used.
- `capacity` supplies the percentage; when it is missing iube derives it from
  `energy_now`/`energy_full`, or from `charge_now`/`charge_full`.
- `status` distinguishes charging, discharging, full and not charging.
- `energy_now`, `energy_full` and `power_now` supply the time estimate. If the
  driver exposes `charge_*` and `current_now` instead, those are used as the
  fallback.
- `online` on a `Mains` supply distinguishes AC from battery operation.

Power profiles use `/sys/firmware/acpi/platform_profile` and
`platform_profile_choices` when the firmware exposes them. When
`net.hadess.PowerProfiles` is running, its `ActiveProfile` and `Profiles`
properties are used instead, so the profile change goes through the same
service as the rest of the desktop.

Session actions use `org.freedesktop.login1.Manager`:

- `CanSuspend` and `CanHibernate` decide whether those rows are available.
- `Suspend`, `Hibernate`, `Reboot` and `PowerOff` perform the action with the
  interactive flag set, so logind may ask polkit for confirmation. Restart and
  shutdown are always offered; if logind refuses them, iube shows the error.
- `LockSessions` locks the current session.

logind owns the privilege decision and performs the action. iube does not run as
root and does not replace logind.

## Controls

- `Up` / `Down` selects an action.
- `Enter` runs the selected action.
- `Tab` cycles the power profile when the platform exposes one.
- `R` refreshes the battery, profile and availability state.
- `N` cancels a restart or shutdown confirmation.
- `Esc` closes.

The view refreshes every five seconds so plugging in the charger or a battery
level change is picked up without pressing `R`. Restart and shutdown ask for a
second confirmation; suspend, hibernate and lock run immediately. Unavailable
actions stay visible and report that they cannot be used instead of disappearing
silently.

## Enabling the profile on Lenovo IdeaPad/Yoga

Some Lenovo IdeaPad and Yoga models expose the DYTC v4 interface, but the kernel
does not register `platform_profile` unless the `ideapad_laptop` module is loaded
with `allow_v4_dytc=Y`. The kernel log states this explicitly:

```text
ideapad_acpi VPC2004:00: DYTC_VERSION 4 support may not work.
Pass ideapad_laptop.allow_v4_dytc=Y on the kernel commandline to enable
```

On NixOS, add both settings:

```nix
boot.extraModprobeConfig = "options ideapad_laptop allow_v4_dytc=Y";
services.power-profiles-daemon.enable = true;
```

Rebuild and reboot, then verify:

```sh
cat /sys/firmware/acpi/platform_profile
cat /sys/firmware/acpi/platform_profile_choices
```

The choices should include `low-power balanced performance`. Without
power-profiles-daemon the profile row can still appear, but writes to
`platform_profile` usually require root; iube reports the permission error
instead of silently ignoring it. With power-profiles-daemon running, iube changes
the profile through `net.hadess.PowerProfiles`.

## Current limitations

- Only the first system battery is displayed. Multiple battery packs are not
  aggregated yet.
- There is no UPower integration, so battery health, cycle count and detailed
  history are not shown.
- The ACPI platform profile is often writable only by root. If the write is
  denied, iube shows the error and leaves the current profile unchanged.
- Power-profiles-daemon is optional. When it is not running, the sysfs profile
  is used directly; when neither is present, the profile row is hidden.
- Hibernate, suspend and the other actions depend on logind and the local polkit
  policy. A `challenge` result is treated as available, but there may be no
  polkit agent in a minimal session.
- There is no live `PropertiesChanged` subscription or lid-switch handling. The
  view polls and refreshes after actions.

## Planned work

- **Multiple batteries.** Aggregate capacity, energy and time remaining across
  `BAT*` supplies.
- **UPower details.** Add health, cycle count and charge thresholds when UPower
  is available, without making it a hard dependency.
- **Polkit helper.** Provide a small agent or documented policy for suspend,
  hibernate and shutdown on minimal sessions.
- **Lid and critical battery.** Read the lid switch and expose a read-only
  critical-battery state.
- **Live updates.** Subscribe to logind and power-supply changes instead of
  polling.

## Code path

1. `src/main.zig` sees `iube power` and calls `runPower`.
2. `src/power_view.zig` builds the view and handles keys, pointer input and
   drawing.
3. `src/power.zig` reads sysfs, parses the platform profile and calls logind or
   power-profiles-daemon.
4. `src/dbus.zig` handles the system-bus connection, method calls, replies and
   marshalling.
5. `src/session.zig` provides the shared Wayland loop, config and renderer.
