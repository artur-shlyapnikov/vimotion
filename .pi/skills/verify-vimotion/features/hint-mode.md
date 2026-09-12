# Hint mode

Hint mode scans the frontmost window, draws keyboard labels over actionable
controls, and activates the matching control as soon as the typed code is complete
— no Enter. It is cancellable at any point and never leaves the overlay stranded.

## Sub-features

- `hint-activate` shows hint labels over the frontmost window's actionable controls.
- `hint-click` activates the control whose complete code was typed.
- `hint-backspace` removes the last typed key and narrows matches again.
- `hint-invalid-key` flashes the hints on a non-matching key and keeps the session.
- `hint-cancel-esc` cancels silently on `Esc`.
- `hint-cancel-toggle` cancels silently on a second press of the activation chord.
- `hint-cancel-mouse` cancels when a mouse or scroll event reaches the target app.
- `hint-cancel-modifier` cancels when a modifier shortcut or unsupported key reaches
  the target app.
- `hint-cancel-context` cancels silently on frontmost-app or screen change.
- `hint-idle-timeout` cancels after 10 seconds without an accepted hint key with an
  `Idle timeout` HUD.
- `hint-recovery` retries once on a stale element token: one recovery scan, one click
  on a single matching replacement, silent abort otherwise.

## How to get to it (user POV)

- Press the activation chord anywhere in macOS (default `⌘⇧Space`).
- Choose `Enable Hints` from the Vimotion menu-bar menu (disabled unless `Ready`).

## Driving it with verify-vimotion helpers

Preconditions:

- Tier 1 green: our instance runs, `doctor.sh` reports `DOCTOR=pass`.
- Tier 2 grants: Vimotion Accessibility granted, Cua driver Accessibility granted,
  menu-bar status `Ready`.
- A known target window is frontmost (e.g. TextEdit with a few buttons) and stays
  frontmost for the drive.
- `RUN_PID` matches the running process.

- **Activate.** Press the activation chord. Hint labels appear over actionable
  controls within ~1.5 seconds (the scan budget). Capture
  `screencapture -m "$EVIDENCE/hint-overlay.png"` showing the labels.
- **Click.** Type one complete displayed code. The target control activates (its own
  visible effect in the target app) and the overlay dismisses with no HUD. Capture
  the target app's changed state in `$EVIDENCE/hint-clicked.png`.
- **Backspace.** Activate again, type a partial code prefix, press `Backspace`. The
  prefix shortens and the match set widens; the session stays active.
- **Invalid key.** Type a hint-alphabet key matching no code. The hints flash, the
  key is dropped from the prefix, the session stays active.
- **Cancel paths.** Drive each: `Esc` (silent), chord re-press (silent), app switch
  (silent), 10-second idle (HUD reads `Idle timeout`). After every cancel the
  overlay is gone and the next activation starts a fresh session.
- **Proof.** Reopen the target window state plus both screenshots. The artifacts
  identify the chord used, the code typed, the control's effect, and the overlay
  dismissed. `defaults` writes are never proof of a click.

## Gotchas

- With a non-US input source, use the physical key position of the displayed glyph,
  not the typed character.
- Pressing the activation base letter without modifiers types into the target app
  instead of cancelling — chord re-press means the full chord.
- The scan covers at most 2,500 elements at depth 25 within 1.5 seconds; a sparse
  overlay on a huge window is a budget outcome, not necessarily a bug.
- A frontmost-app or screen change mid-drive cancels the session silently — lock the
  test setup down before pressing the chord.
- Codes are prefix-free and assigned shortest-first top-to-bottom, left-to-right;
  assert the rendered labels, not an assumed assignment.
- `Enable Hints` is disabled unless status is `Ready`; a disabled row is a precondition
  failure (grants/driver), not a hint-mode bug.
