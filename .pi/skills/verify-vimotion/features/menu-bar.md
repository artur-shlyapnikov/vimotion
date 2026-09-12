# Menu bar

The menu-bar item is Vimotion's only always-visible surface: an icon-only label
(color + symbol, no text — the full status lives inside the menu) plus a menu with
status, actions, and lifecycle rows. Its status is always one of `Ready`,
`Permission Required`, or `Cua Offline`.

## Sub-features

- `menu-status` shows the current status text with its color in the open menu.
- `menu-enable` offers `Enable Hints` with the current chord as a shortcut hint,
  disabled unless status is `Ready`.
- `menu-reconnect` offers `Reconnect to Driver` (or `Reconnecting…` while disabled)
  only while status is `Cua Offline`.
- `menu-settings` offers `Settings…` opening the Settings window.
- `menu-quit` offers `Quit` terminating the app and its driver child.

## How to get to it (user POV)

- Click (or keyboard-open) the Vimotion icon in the macOS menu bar.
- `Enable Hints` is also reachable via the activation chord shown beside it.

## Driving it with verify-vimotion helpers

Preconditions:

- Our instance runs from `build/Vimotion.app`, `RUN_PID` matches,
  `doctor.sh` reports `DOCTOR=pass`.

- **Icon present.** The Vimotion status icon is visible in the menu bar. Capture
  `screencapture -m "$EVIDENCE/menubar.png"` with the icon region identifiable.
- **Open menu.** Open the menu. The first section reads the current status
  (`Ready`, `Permission Required`, or `Cua Offline`); on a grant-less sandbox host
  expect `Permission Required` or `Cua Offline` — either is correct degraded
  behavior, not a failure.
- **Enable gating.** When status is not `Ready`, `Enable Hints` is disabled; when
  `Ready`, it is enabled and carries the configured chord as its shortcut hint.
- **Reconnect row.** Present and enabled only while `Cua Offline`; choosing it flips
  the row to disabled `Reconnecting…` during the attempt. Absent in every other
  status.
- **Settings….** Choose `Settings…`. The `Vimotion Settings` window opens (see
  `settings.md` for its proof).
- **Quit.** Choose `Quit` (or `kill "$RUN_PID"` where menu driving is unavailable).
  The process exits, `pgrep -x Vimotion` is empty, and
  `pgrep -f "cua-driver mcp"` shows the driver child reaped. Relaunch afterwards
  only through the skill's **Launch** section with a new `RUN_ID`.
- **Proof.** `$EVIDENCE/menubar.png`, the observed status string, which rows were
  enabled, and the before/after `pgrep` pair for Quit. A running process plus a
  doctor pass is the minimum Tier 1 proof.

## Gotchas

- The tray icon can be pushed off-screen by a full menu bar — `⌥⌘V` still opens
  Settings and `pgrep` still proves the process.
- The icon is symbol-only by design (notch clipping); asserting menu-bar *text*
  fails on every build.
- `just app` re-signs ad-hoc on every rebuild, changing the cdhash — macOS may
  re-prompt the Vimotion Accessibility grant. A status flip to
  `Permission Required` right after a rebuild is platform behavior, not a regression.
- Never `pkill -x Vimotion` for Quit proof: it would also kill a user's own
  instance. Quit via the menu, or `kill` the captured `RUN_PID`.
