---
name: verify-vimotion
description: Drive the Vimotion macOS menu-bar app the way a user does — build, launch, menu bar, hint mode, Settings, driver link — and capture proof. Use when verifying Vimotion behavior changes, before shipping, or when tests pass but the real app is unproven.
---

# Verify Vimotion

Vimotion is a background-only macOS menu-bar accessory (`LSUIElement`, bundle id
`local.vimotion.Vimotion`, no Dock icon). There is no CLI, no web UI, no HTTP
surface, and no test-only backdoor. Verification drives the real bundle on a
live macOS GUI session, in tiers: cheap headless checks always, a launched
instance when a display exists, live hint-mode driving only with full grants.

## Tiers (run the deepest tier the host allows, never fake a deeper one)

- **Tier 0 — headless gate.** `just check` (`swift build`). Always runs, including
  CI and SSH sessions. `just test` / `just coverage` need the **full Xcode
  toolchain** and fail on CLT-only hosts (`xcodebuild` errors out); on such hosts
  record `tests: unavailable (CLT-only)` instead of claiming a pass. The opt-in
  live driver test needs both Xcode and the driver:
  `VIMOTION_LIVE_CUA=1 just test` (without the env var it self-skips).
- **Tier 1 — launched instance.** Build the bundle, open it, doctor it, observe the
  menu-bar process, capture a screenshot, quit what you started. Needs a live
  macOS GUI session (WindowServer up) on the machine running the app. Works
  without Accessibility grants — the app degrades to `Permission Required`.
- **Tier 2 — live hint-mode E2E.** Press the activation chord over a real frontmost
  window, type a hint code, watch the control activate. Needs **all** of: Tier 1
  green, Vimotion Accessibility granted, Cua driver Accessibility granted, driver
  connected (`Ready`), a scriptable target window in front. If any precondition is
  missing, report `tier-2 blocked: <concrete prerequisite>` — never simulate the
  overlay or click with stubs and call it verified.

## Launch

Single-instance app: a global event tap, global hotkeys, one `UserDefaults` suite,
one driver child process. Two copies fight over all four. Before launching, refuse
if `pgrep -x Vimotion` finds anything: tell the user to quit their copy (or that a
stale run left one behind) rather than driving or killing it.

```sh
RUN_ID=$(date +%s)-$$
EVIDENCE=.pi/skills/verify-vimotion/evidence/$RUN_ID
mkdir -p "$EVIDENCE"

# Back up shared settings so the run can restore them afterwards.
defaults export local.vimotion.Vimotion /tmp/vimotion-verify-$RUN_ID.plist 2>/dev/null || echo "no existing defaults"

just app                       # release build + assemble build/Vimotion.app + ad-hoc sign
open build/Vimotion.app        # LSUIElement: menu-bar icon only, no Dock icon, no window
for i in $(seq 1 20); do pgrep -x Vimotion >/dev/null && break; sleep 0.5; done
RUN_PID=$(pgrep -x Vimotion | head -1)
echo "$RUN_PID" > /tmp/vimotion-verify-$RUN_ID.pid
echo "RUN_ID=$RUN_ID RUN_PID=$RUN_PID EVIDENCE=$EVIDENCE"
```

Ready means: the PID exists **and** `helpers/doctor.sh` (below) reports the bundle
valid. The app shows no window on launch — absence of a window is normal, absence
of the process is failure. First launch on a fresh checkout drops the default
chord `⌘⇧Space` and the 30-key default alphabet into `UserDefaults`; that is the
baseline state every recipe starts from.

Teardown is in **Cleanup** below. Never proceed to Drive while a foreign instance
owns the menu-bar slot.

## Doctor

One read-only check answering "is this instance worth driving?" Run it before the
first drive, and again after anything surprising (failed drive, relaunch, grant
change). It touches nothing: no launches, no kills, no defaults writes.

```sh
RUN_PID=$(cat /tmp/vimotion-verify-$RUN_ID.pid) \
  .pi/skills/verify-vimotion/helpers/doctor.sh --app build/Vimotion.app | tee "$EVIDENCE/doctor.txt"
```

`doctor.sh` prints `KEY=VALUE` lines and exits non-zero when the bundle is not
drivable. It checks: bundle executable present; `Info.plist` identity
(`local.vimotion.Vimotion`), version, `LSUIElement=true`; `codesign` validity
(ad-hoc `-` is expected; a changed cdhash after `just app` re-sign explains a
re-prompt for the Vimotion Accessibility grant — that is platform behavior, not a
regression); driver binary resolvable by the app's own lookup order
(`~/.local/bin/cua-driver`, then `PATH` scan) with its version; whether a
`Vimotion` process runs and whether it is our `$RUN_PID`. There are no ports to
check — the driver link is MCP over stdio, not a socket; the skill states this so
no one goes hunting for a listener.

A doctor failure caused by skill drift (new bundle id, renamed binary, moved
plist key) is drift: fix this skill, re-run doctor once, restart only what the fix
invalidated. A doctor failure in the app (bundle won't assemble, signature
invalid, driver missing) stops the run — report it, don't route around it.

## Drive

Conventions for every recipe in `features/`:

- Start from the baseline state (fresh defaults unless the recipe says otherwise).
- Prefer stable handles: menu titles (`Enable Hints`, `Settings…`, `Quit`),
  Settings section names (`Activation Shortcut`, `Hint Alphabet`, `General`,
  `Permissions`), button labels (`Apply`, `Save`, `Enable…`, `Reconnect to Driver`),
  status strings (`Ready`, `Permission Required`, `Cua Offline`), the `⌥⌘V`
  Settings hotkey. Never coordinates, never tab order.
- GUI observation runs through `screencapture` (see Evidence) and, where the
  driving terminal holds its own Accessibility grant, `osascript` against
  System Events. If `tell application "System Events"` times out, the **driver
  terminal** lacks its grant — that blocks Tier 2, it never counts as an app
  failure. Record the block and stop.
- `defaults read local.vimotion.Vimotion` is setup confirmation and second-view
  proof only. Writing defaults and reading them back proves nothing about the UI;
  every mutation recipe must also show the change through the app (reopened
  Settings, menu-bar state, overlay behavior).
- The `cua-driver` CLI (`permissions status`, `--version`) may confirm the
  driver's presence, never the app's connection state. Only the menu-bar status
  and the live handshake prove the link.

Tier 2 recipe pattern (full steps live in `features/hint-mode.md`): focus a
known target window, press `⌘⇧Space` (or the configured chord), confirm hint
labels appear over actionable controls in a screenshot, type one complete code,
confirm the control activated **and** the overlay dismissed. Cancels are
first-class drives too: `Esc`, re-pressing the chord, Backspace, app switch,
10-second idle timeout (HUD reads `Idle timeout`).

## Evidence

Proof artifacts survive teardown in the location this skill names:

```sh
screencapture -m "$EVIDENCE/menubar.png" || echo "screencapture unavailable: $(uname -a)" > "$EVIDENCE/menubar-unavailable.txt"
defaults read local.vimotion.Vimotion > "$EVIDENCE/defaults-after.txt"
cp /tmp/vimotion-verify-$RUN_ID.pid "$EVIDENCE/run.pid" 2>/dev/null || true
```

Proof standards, enforced on every run:

- Exercise the real user path, not internals: the hint overlay via the chord, the
  Settings window via the menu / `⌥⌘V`, the driver link via launch + menu-bar
  status. There are no test-only endpoints to lean on — and `XCTest` stubs prove
  units, never the app.
- Capture the action and the resulting state, not just the final screen: chord
  pressed → overlay screenshot; code typed → target app's changed state; Apply
  clicked → reopened Settings showing the persisted chord.
- Verify side effects alongside what's visible: files/settings written (`defaults`
  second view), driver child lifetime (spawned on launch, reaped on quit —
  confirm with `pgrep -f "cua-driver mcp"` before and after), menu-bar status
  transitions (`Cua Offline` → `Ready` after Reconnect).
- Mocks only where a production boundary already isolates the system: stubbed
  `CuaDriverServing` in unit tests. Live proof uses the real `cua-driver`. A
  dry-run-style claim (e.g. "would click") is not proof of a click.
- Screenshots must show app identity: the menu-bar status entry, the
  `Vimotion Settings` window, or the on-screen hint labels — a bare target-app
  screenshot proves the target, not Vimotion.
- Record the feature file, entry point used, and tier with every artifact. Report
  an unreachable path with the attempted command and the unmet precondition
  (`verified-unreachable` needs the concrete grant, window, or host missing). A
  skipped entry point is never reported as verified through a different path.

## Cleanup

Remove instances and scratch state you created. Never the evidence.

```sh
RUN_PID=$(cat /tmp/vimotion-verify-$RUN_ID.pid)
kill "$RUN_PID"                                  # our PID only — never pkill -x
for i in $(seq 1 20); do kill -0 "$RUN_PID" 2>/dev/null || break; sleep 0.5; done
# confirm the driver child went with it:
pgrep -f "cua-driver mcp" || echo "driver child reaped"
# restore the user's settings (or remove what a fresh-domain run created):
if [ -f /tmp/vimotion-verify-$RUN_ID.plist ]; then
  defaults import local.vimotion.Vimotion /tmp/vimotion-verify-$RUN_ID.plist
else
  defaults delete local.vimotion.Vimotion 2>/dev/null || true
fi
rm -f /tmp/vimotion-verify-$RUN_ID.pid /tmp/vimotion-verify-$RUN_ID.plist
ls "$EVIDENCE"   # proof still here — a cleanup that eats the proof fails the run
```

Rules: kill by captured PID after confirming `ps -o comm= -p "$RUN_PID"` reads
`Vimotion`. If the PID is unknown (lost pid file), stop and report — do not
`pkill -x Vimotion`, which would take down the user's own instance. Run cleanup
after every failed iteration too, so broken attempts don't strand processes,
hotkeys, or event taps. Evidence under `evidence/$RUN_ID/` is never deleted by
cleanup; scratch under `/tmp/vimotion-verify-*` always is.

## Helpers

- `helpers/doctor.sh` — read-only instance/bundle/doctor check. Executable.
  Invocation is shown in **Doctor** above; `--app` overrides the bundle path,
  `RUN_PID` env carries the run's PID for the ownership check.
- `evidence/.gitkeep` + `evidence/.gitignore` — proof artifacts stay local;
  everything under `evidence/` except `.gitkeep` is git-ignored.
- No other scripts. Launch, capture, and cleanup are literal commands in this
  file so the reader never reverse-engineers a wrapper. A helper added later must
  be executable and its exact invocation added here.
