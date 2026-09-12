# Driver connection

Vimotion spawns its Cua driver itself as `cua-driver mcp` over stdio — there is no
separately managed server and no socket. On startup it handshakes (MCP initialize),
requires the four tools `health_report`, `list_windows`, `get_window_state`,
`click`, and validates `health_report` schema version `1`. Link state is visible
only through the menu-bar status.

## Sub-features

- `driver-lookup` finds the binary at `~/.local/bin/cua-driver` first, then scans
  `PATH` — nowhere else.
- `driver-startup` connects once at launch; failure parks the menu bar at
  `Cua Offline` with a `Reconnect to Driver` row (no retry loop).
- `driver-health` requires schema version `1` and all four tool names before the
  link counts as connected.
- `driver-reconnect` retries on demand: one reconnect plus one retry per failed
  in-session call, manual `Reconnect to Driver` from the menu.
- `driver-shutdown` stops the child driver process when Vimotion quits.

## How to get to it (user POV)

- Launch the app (startup link) — status `Ready` means connected.
- Read the menu-bar status: `Cua Offline` means disconnected.
- Choose `Reconnect to Driver` while offline.

## Driving it with verify-vimotion helpers

Preconditions:

- Our instance launched from `build/Vimotion.app` with a recorded `RUN_PID`.
- `doctor.sh` shows `DRIVER_PATH` set (its absence is an environment failure: the
  installer step in the README was never run on this host).

- **Lookup.** Confirm the binary the app would use:
  `ls -l ~/.local/bin/cua-driver || command -v cua-driver`. Record the path in the
  run notes — it must match `doctor.sh`'s `DRIVER_PATH`.
- **Startup link.** Launch per the skill. With a healthy driver and grants, the
  menu-bar status settles at `Ready`; without the driver binary or with refused
  transport, it parks at `Cua Offline` with the reconnect row present. Either
  steady state is assertable — flapping between them is the bug.
- **Child lifetime.** While running, `pgrep -f "cua-driver mcp"` shows the child;
  after Quit it is gone. Capture both outputs to `$EVIDENCE/driver-lifetime.txt`.
- **Reconnect.** With status `Cua Offline`, choose `Reconnect to Driver`: the row
  disables (`Reconnecting…`), then status resolves to `Ready` or back to
  `Cua Offline`. There is no background retry — leaving it offline for a minute
  must not self-heal, and must not spawn extra `cua-driver mcp` processes.
- **Live handshake (Xcode hosts only).** `VIMOTION_LIVE_CUA=1 just test` runs the
  real-driver handshake test (schema `1`, clean stop). On CLT-only hosts record
  `live-handshake: unavailable` — `doctor.sh`'s `XCODE=clt-only` is the standing
  proof of why.
- **Proof.** Status string observed, reconnect-row behavior, the
  before/after `pgrep` pair, and (where runnable) the live-test result. The
  driver's own CLI (`permissions status`, `--version`) proves the binary exists —
  only the menu-bar status proves Vimotion connected to it.

## Gotchas

- `cua-driver permissions status` answers for the driver's identity via a running
  daemon; from a terminal without the daemon it reports `unknown` — that is about
  the CLI's vantage point, not the app's link. Start the daemon or grant before
  treating `unknown` as signal.
- Screen Recording is optional and never requested by Vimotion; its absence never
  blocks `Ready`.
- Scope the `pgrep` pattern to `cua-driver mcp` — bare `cua-driver` matches the
  doctor's own `--version` probe and any user session.
- Killing the driver child out from under the app (to "test recovery") strands the
  transport by design; the supported recovery is the menu's Reconnect, then relaunch.
- The health response's window titles and stderr bytes are never logged — keep them
  out of evidence files and run notes.
