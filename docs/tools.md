# Tool backends

This document describes how the iube management tools are meant to work, and
how the implemented ones choose their backend. Audio, Bluetooth, Wi-Fi, Power
and Brightness are implemented; the remaining entries are plans.

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

Two small pieces of infrastructure are shared by several tools:

- A minimal D-Bus client over the system/user bus socket, with `EXTERNAL`
  authentication, `Hello`, match rules, method calls and variant parsing. It
  lives in `src/dbus.zig` and serves BlueZ, NetworkManager and, eventually,
  logind and power-profiles-daemon.
- Thin helpers around netlink messages and sysfs reads/writes. sysfs reads are
  ordinary file I/O today; netlink helpers are still planned.

Both are ordinary Zig code over `std.posix` sockets and file I/O. They do not
require `libdbus`, `libsystemd` or `libnm`.

## Audio (`iube audio`)

**Status:** initial implementation. The dedicated documentation, including the
protocol details, controls, limitations and planned work, lives in
[audio.md](audio.md).

## Bluetooth (`iube bluetooth`)

**Status:** initial implementation. The dedicated documentation, including the
BlueZ integration, controls, limitations and planned work, lives in
[bluetooth.md](bluetooth.md).

## Wi-Fi (`iube wifi`)

**Status:** initial implementation. The dedicated documentation, including the
NetworkManager integration, controls, limitations and planned work, lives in
[wifi.md](wifi.md).

The first backend is NetworkManager over the system D-Bus. NetworkManager
already owns the wireless interface, supplicant and saved profiles on most
desktops, so using it avoids two processes fighting over the radio. The Wi-Fi
view can scan, list access points, connect to saved profiles, disconnect and
toggle wireless.

### Future direct backend

If NetworkManager is not present, the long-term plan is to read the interface
and scan results directly and use the existing supplicant for association:

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

### Constraints

- nl80211 operations need `CAP_NET_ADMIN` or an appropriate group membership.
  iube must not run as root; a future helper or polkit-mediated service may be
  required for a completely unprivileged install.
- WPA3, EAP and hidden-network edge cases are substantial. The first version
  should support open and WPA2-PSK networks, then expand.
- Scanning while connected is rate-limited by the kernel; the UI must tolerate
  delayed scan results.

## Power (`iube power`)

**Status:** initial implementation. The dedicated documentation, including the
sysfs fields, logind actions, controls, limitations and planned work, lives in
[power.md](power.md).

The power view reads the battery and AC state from `/sys/class/power_supply`,
uses the ACPI platform profile through sysfs or power-profiles-daemon, and
performs suspend, hibernate, restart, shutdown and lock requests through logind.
It does not link UPower, libsystemd or libnm, and it does not keep a resident
daemon.

## Brightness (`iube brightness`)

**Status:** initial implementation. The dedicated documentation, including the
sysfs fields, logind session lookup, controls, CLI syntax, limitations and
planned work, lives in [brightness.md](brightness.md).

The brightness controller enumerates `/sys/class/backlight`, reads
`brightness`/`max_brightness` and changes the level with logind's
`Session.SetBrightness` method. It does not use `brightnessctl`, write sysfs
directly, need root or install udev rules. The `up`, `down`, `set`, `get` and
`list` actions bypass Wayland and exit after one operation.

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
