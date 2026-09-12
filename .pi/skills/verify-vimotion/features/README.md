# Vimotion verification map

This directory is the maintained source for verifying the user-facing behavior of
Vimotion. Read this index before driving the app, then use the matching feature
file as the recipe.

## Baseline preconditions

- Release bundle assembled: `just app` produced `build/Vimotion.app`.
- No other `Vimotion` process runs (`pgrep -x Vimotion` empty) — never drive a
  foreign instance.
- Fresh run identity: `RUN_ID`, `EVIDENCE=.pi/skills/verify-vimotion/evidence/$RUN_ID`,
  PID file at `/tmp/vimotion-verify-$RUN_ID.pid`.
- Shared settings backed up (`defaults export local.vimotion.Vimotion ...`) and
  restored or deleted during cleanup; proof artifacts under `evidence/$RUN_ID/`
  are never removed.
- `helpers/doctor.sh` reports `DOCTOR=pass` before the first drive and after
  anything surprising.
- Tier 0 (`just check`) is the gate for every run; `just test` additionally
  requires full Xcode (CLT-only hosts record `tests: unavailable`).

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say otherwise.
- Prefer stable handles (menu titles, Settings section/button labels, status
  strings, hotkeys) over coordinates and tab order.
- Treat every command as literal. Keep quoted names and flags unchanged.
- Run read-only instance checks through `helpers/doctor.sh`.
- Observe GUI state with `screencapture -m`; drive menus/windows only where the
  driving terminal holds its own Accessibility grant, else stop at Tier 1.
- Restore seeded settings after a mutation. Do not remove proof artifacts during
  cleanup.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- Overlay proof includes the chord pressed, a screenshot showing the hint labels,
  and the target app's changed state after activation.
- Mutation proof includes a read-only second view (`defaults read` plus the
  reopened Settings window showing the persisted value).
- Driver-link proof includes the menu-bar status and the driver child's lifetime
  (`pgrep -f "cua-driver mcp"` before and after quit).
- Record the feature ID and entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the
user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with verify-vimotion helpers` starts with `Preconditions:` and uses
   labeled bullets that pair each user action with an exact command and observable
   result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles,
required state, commands, and observable proof.

## Features

- [Hint mode](./hint-mode.md) covers activation, typing a code to click, editing
  and cancel paths, timeout, and session-cancel triggers.
- [Menu bar](./menu-bar.md) covers status display, Enable Hints gating, Reconnect,
  Settings…, and Quit.
- [Settings](./settings.md) covers the activation editor, alphabet editor,
  launch-at-login toggle, permission rows, and persistence.
- [Driver connection](./driver-connection.md) covers startup health, offline and
  reconnect behavior, and driver-process lifetime.
