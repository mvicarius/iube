# Tool backends

This document describes how the planned iube management tools are meant to
work. None of these backends are implemented yet; the commands currently open
the placeholder view from `src/placeholder.zig`.

## Dependency policy

The goal is not "statically link every protocol". The goal is to avoid shipping
an application toolkit or a desktop-environment client library stack inside a
small launcher.

Rules for every tool:

1. **No new linked libraries unless there is no credible alternative.** The
   binary currently links libc, `libwayland-client` and `libxkbcommon`.
   Management tools should speak to the kernel and system services over their
   native sockets instead of linking client libraries.
2. **Use the kernel interfaces directly where they own the device.** sysfs,
   `/dev/rfkill`, generic netlink (`nl80211`) and Unix sockets are the ground
   truth.
3. **Let the existing system service own what it already owns.** iube does not
   implement a Bluetooth stack or a WPA supplicant. It talks to BlueZ,
   wpa_supplicant, PipeWire/PulseAudio and logind through their documented
   interfaces. Those services are part of a normal Linux desktop; iube replaces
   their GUI clients, not the services.
4. **No resident iube daemon.** Every tool is a process that opens, reads
   current state, applies changes and exits.
5. **Read-only first.** Scanning, listing and state display land before
   mutating operations.
6. **Never run setuid.** Privileged operations go through the existing service
   and its polkit/D-Bus policy. iube must remain a normal user process.
7. **Secrets stay out of logs and memory dumps.** Wi-Fi passphrases and
   Bluetooth pairing data are handed to the system service and never written to
   iube's config or log.

Two small pieces of infrastructure will be shared by several tools and are
worth implementing once:

- A minimal D-Bus client over the system/user bus socket, with `EXTERNAL`
  authentication, `Hello`, match rules, method calls and variant parsing. This
  serves BlueZ, logind and optionally power-profiles-daemon.
- Thin helpers around netlink messages and sysfs reads/writes.

Both are ordinary Zig code over `std.posix` sockets and file I/O. They do not
require `libdbus`, `libsystemd` or `libnm`.

## Audio (`iube audio`)

**Status:** initial implementation. The dedicated documentation, including the
protocol details, controls, limitations and planned work, lives in
[audio.md](audio.md).

## Bluetooth (`iube bluetooth`)

**Goal:** adapter state, discovery, pairing, connection and battery status
without linking BlueZ client libraries.

### Planned interfaces

- **BlueZ over the system D-Bus.** Connect to `/run/dbus/system_bus_socket`,
  authenticate with `EXTERNAL`, and use the `org.bluez` API:
  - `org.freedesktop.DBus.ObjectManager.GetManagedObjects` for adapters and
    known devices.
  - `org.bluez.Adapter1` for `StartDiscovery`, `StopDiscovery`,
    `SetDiscoveryFilter` and adapter properties.
  - `org.bluez.Device1` for `Pair`, `Connect`, `Disconnect`, `RemoveDevice`,
    `Connected`, `Paired`, `RSSI`, `Battery1`.
  - `org.bluez.Agent1` for pairing confirmation/passkey prompts. This requires
    iube to export a small D-Bus object and register an agent with BlueZ.
- **rfkill and sysfs for radio state.** Read and write
  `/sys/class/rfkill/rfkill*/{name,type,soft,hard}` and listen to `/dev/rfkill`
  for adapter power changes. This covers the "Bluetooth is blocked" case even
  when BlueZ is not running.

### UI shape

- Adapter switch (powered/off), discovery toggle.
- Discovered and known devices with signal strength, paired/connected state and
  battery percentage when BlueZ exposes it.
- Pair/connect/disconnect/forget actions.
- Pairing prompt for confirmation codes and passkeys.

### Constraints

- BlueZ owns the controller. iube must not open the HCI device directly while
  BlueZ is running.
- Pairing needs an agent object on D-Bus; that is the most involved part of the
  first implementation.
- D-Bus policy and polkit decide whether a normal user may toggle the adapter
  or pair. iube should surface a clear permission error rather than retrying as
  root.

## Wi-Fi (`iube wifi`)

**Goal:** scan, connect, disconnect and inspect wireless networks without
linking NetworkManager, iwd or wpa_supplicant client libraries.

### Planned interfaces

- **nl80211 generic netlink for scanning and link state.** Open an
  `AF_NETLINK`/`NETLINK_GENERIC` socket, resolve the `nl80211` family, and use
  commands such as `NL80211_CMD_TRIGGER_SCAN`, `NL80211_CMD_GET_SCAN`,
  `NL80211_CMD_GET_INTERFACE`, `NL80211_CMD_GET_STATION` and the multicast scan
  event. This gives the network list, signal, channel, security flags and
  current association without a helper library.
- **wpa_supplicant control socket for association and keys.** Speak the text
  protocol at `/run/wpa_supplicant/<interface>` (or the configured control
  path): `SCAN`, `SCAN_RESULTS`, `ADD_NETWORK`, `SET_NETWORK`,
  `ENABLE_NETWORK`, `SELECT_NETWORK`, `SAVE_CONFIG`, `REMOVE_NETWORK`. The
  supplicant performs WPA/WPA2/WPA3 and enterprise authentication; iube manages
  the network list and credentials.
- **Coexistence with existing managers.** If NetworkManager or iwd is managing
  the interface, iube should either use that manager's documented interface or
  open read-only. Two tools fighting over `wpa_supplicant` is worse than a
  missing feature.

### UI shape

- Enable/disable the radio via rfkill.
- Network list with SSID, signal, security, and connected marker.
- Connect dialog for passphrases; "forget" for saved networks.
- Current link details: address, signal, frequency, security.
- Keyboard-first navigation with the same `Up`/`Down`/`Enter`/`Esc` model as
  the launcher.

### Constraints

- nl80211 operations need `CAP_NET_ADMIN` or an appropriate group membership.
  iube must not run as root; a future helper or polkit-mediated service may be
  required for a completely unprivileged install.
- WPA3, EAP and hidden-network edge cases are substantial. The first version
  should support open and WPA2-PSK networks, then expand.
- Scanning while connected is rate-limited by the kernel; the UI must tolerate
  delayed scan results.

## Power (`iube power`)

**Goal:** battery state, power profile and session actions without linking
UPower, logind or power-profiles-daemon client libraries.

### Planned interfaces

- **Battery and AC state from sysfs.** Read
  `/sys/class/power_supply/*/type`, `capacity`, `status`, `energy_now`,
  `energy_full`, `power_now`, `voltage_now`, `online`. Handle both `BAT*` and
  `AC*`/`ADP*` naming. Use `energy_*`/`power_*` when present and fall back to
  `charge_*`/`current_*`.
- **Power profiles.** Read and write
  `/sys/firmware/acpi/platform_profile` with the choices from
  `/sys/firmware/acpi/platform_profile_choices`
  (`low-power`, `balanced`, `performance`). Fall back to
  `net.hadess.PowerProfiles` over D-Bus when the firmware interface is absent or
  read-only.
- **Session actions through logind.** Use
  `org.freedesktop.login1.Manager` on the system D-Bus:
  `CanSuspend`, `Suspend`, `CanHibernate`, `Hibernate`, `CanPowerOff`,
  `PowerOff`, `CanReboot`, `Reboot`, `LockSessions`. logind asks polkit for the
  privilege decision and performs the action.

### UI shape

- Battery percentage and charging/discharging state.
- Estimated time remaining when the kernel exposes enough data.
- Power profile selector.
- Suspend, hibernate, reboot, shutdown and lock actions, with confirmation for
  destructive ones.
- Optional: lid-switch and critical-battery state read-only.

### Constraints

- Battery sysfs layouts vary by driver; every read needs a fallback.
- Writing `platform_profile` may be denied to normal users; surface the exact
  error and leave the profile unchanged.
- logind may refuse or prompt through polkit. iube must not block the UI while
  waiting for a policy decision.

## Cross-tool conventions

- **One window, one job.** No tray icon, no background process, no polling when
  the window is closed.
- **Refresh on open.** Read state when the view starts and after each action.
  Live subscriptions are added only when a tool genuinely needs them.
- **Explicit errors in the UI.** "Permission denied", "BlueZ is not running",
  "wpa_supplicant is not running" and similar states are better than a control
  that silently does nothing.
- **No secret storage in iube's config.** Network credentials belong to
  wpa_supplicant/NetworkManager; pairing secrets belong to BlueZ.
- **Test the pure parts.** Parsers for sysfs files, netlink attributes and
  D-Bus messages can be unit-tested without a live desktop session.
