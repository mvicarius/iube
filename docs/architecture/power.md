# Power

## Design

- `power.read` enumerates `/sys/class/power_supply`, ignores `scope=Device`
  batteries, picks the first system battery and derives percentage from
  `capacity`, `energy_*` or `charge_*`.
- Profiles come from power-profiles-daemon (`net.hadess.PowerProfiles`) when it
  answers, otherwise from `/sys/firmware/acpi/platform_profile` and
  `platform_profile_choices`. The profile row is hidden when neither exists.
- Session actions go through logind's `Manager` interface. `CanSuspend` and
  `CanHibernate` decide availability; lock, restart and shutdown are always
  offered.
- The view confirms only destructive actions (Restart, Shut down). `N` cancels;
  other keys are ignored until confirmation ends.
- The view polls every 5 seconds and pauses polling while confirming.

## Strengths

- Battery and AC display works without D-Bus; actions fall back to a read-only
  state with an error instead of crashing.
- No UPower, libsystemd or libdbus dependency.
- The profile row adapts to the backend and both ACPI/PPD names are accepted by
  the CLI.
- Dynamic height keeps the five actions visible without scrolling.
- Availability is shown in place instead of hiding actions.

## Limits

- Only the first system battery; multiple packs are not aggregated.
- No UPower health, cycle count, charge thresholds, lid switch or
  critical-battery state.
- The sysfs `platform_profile` path often requires root; without PPD, profile
  changes can fail with a permission error.
- Polling only; no logind or power-supply event subscription.
- `CanSuspend`/`CanHibernate` can return `challenge`; iube treats it as
  available even when no polkit agent is running.
- The CLI runs reboot/poweroff without the UI confirmation.
- If D-Bus fails, the view can still read sysfs but all five actions report
  unavailable.

## Code path

1. `src/main.zig::runPower` constructs `power_view.Power`; `cli.zig` handles
   `iube power <action>`.
2. `src/power_view.zig` owns selection, confirmation, profile cycling, polling
   and drawing.
3. `src/power.zig` reads sysfs, parses profiles/availability and calls logind or
   power-profiles-daemon.
4. `src/dbus.zig` provides transport; `src/session.zig` the loop.

## Testability

- Pure tests cover battery estimates/summaries, action availability and PPD
  array alignment.
- sysfs reads use absolute paths with no injection point, so fixture testing
  would require a path parameter.
- logind and PPD calls need a live system bus; there is no mock.
