# Wi-Fi

## Design

- `wifi.zig` maps NetworkManager devices, access points and saved profiles over
  the system D-Bus. NetworkManager owns the interface, supplicant and secrets.
- Access points with the same SSID are collapsed to the strongest one. Rows are
  ordered connected first, then by signal strength.
- The view holds a snapshot, submits scan/power/connect/disconnect jobs to
  `wifi_worker.zig`, and polls results in `tick`. The worker uses a detached
  thread and reconnect-on-timeout behaviour.
- A new secured network opens an in-window password modal. The buffer is wiped
  on cancel, submission and deinit. The CLI reads a password from stdin with
  echo disabled on a TTY.
- Refresh is every 5 seconds, paused while the password modal is open.

## Strengths

- The UI stays responsive during D-Bus calls and scan waits.
- Saved profiles activate even when the access point is absent from a stale
  scan (`ap_path = "/"`).
- Passwords never enter argv, config or logs; job buffers are zeroed.
- Connection waits are bounded: 1.5 seconds after scan, 10 seconds for
  activation in the CLI.
- Missing values still produce a row: hidden SSID shows `(hidden)`, unknown band
  leaves the band column empty. Connecting to a hidden AP is refused because
  NetworkManager cannot match it to a saved profile by SSID alone.

## Limits

- New profiles are open or WPA-PSK only. WPA3-SAE, enterprise and captive
  portals are unsupported.
- No forget/edit for saved profiles and no hidden-network flow; hidden APs are
  refused instead of creating an unnamed profile.
- Only the first wireless device is displayed.
- Polling only; no `PropertiesChanged` subscription.
- Worker jobs are serialized; a scan sleeps 1.5 seconds in the worker, and a
  connect sleeps 1 second before refreshing.
- The CLI and UI have separate connect paths; the CLI's 10-second wait is not
  shared with the worker.

## Code path

1. `src/main.zig::runWifi` constructs `wifi_view.Wifi`; `cli.zig` handles
   `iube wifi <action>`.
2. `src/wifi_view.zig` owns selection, the password modal, status labels,
   pending actions and drawing.
3. `src/wifi_worker.zig` runs refresh/scan/wireless/connect/connect_new/
   disconnect jobs.
4. `src/wifi.zig` parses NetworkManager objects, builds new-profile settings and
   calls `RequestScan`, `ActivateConnection`, `AddAndActivateConnection`,
   `Disconnect` and `Properties.Set`.
5. `src/dbus.zig` provides transport; `src/session.zig` the loop.

## Testability

- `wifi.zig` tests network ordering, label and band mapping, and new-profile
  settings marshalling.
- Worker timing, activation and password prompts need a live NetworkManager;
  there is no fake D-Bus service.
