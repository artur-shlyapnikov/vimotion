# Settings

The Settings window (`Vimotion Settings`, 560×480) edits the activation chord, the
hint alphabet, launch-at-login, and surfaces permission state. Chord and alphabet
edits are draft-until-applied; invalid drafts cannot be saved.

## Sub-features

- `settings-chord` edits modifiers (`⌘` `⇧` `⌃` `⌥`, at least one required) plus a
  base-key letter picker; `Apply` is disabled unless the draft is valid and changed.
- `settings-chord-preserve` keeps a non-letter base key (e.g. `Space`) across edits:
  the picker cannot select it and `Apply` never rewrites it.
- `settings-alphabet` toggles hint-alphabet chips; `Save` needs ≥4 distinct keys
  and shows the `(n/4 keys)` count in the `Save` button label while gated.
- `settings-login` toggles Launch at Login, reading `SMAppService.mainApp` as the
  source of truth (the toggle snaps back on failure).
- `settings-permissions` shows `Vimotion Accessibility` (`Enable…` prompts),
  `Cua Accessibility` (`Open System Settings`), and optional `Cua Screen Recording`
  rows with `✓` / `✗` / `—` marks.
- `settings-persist` keeps chord and alphabet across quit and relaunch.

## How to get to it (user POV)

- Choose `Settings…` from the Vimotion menu-bar menu.
- Press `⌥⌘V` anywhere in macOS.

## Driving it with verify-vimotion helpers

Preconditions:

- Our instance runs, `doctor.sh` reports `DOCTOR=pass`.
- Baseline `defaults read local.vimotion.Vimotion` captured to
  `$EVIDENCE/defaults-before.txt`.

- **Open.** Choose `Settings…` (or press `⌥⌘V`). The `Vimotion Settings` window
  appears with sections `Activation Shortcut`, `Hint Alphabet`, `General`,
  `Permissions`. Capture `$EVIDENCE/settings.png`.
- **Chord edit.** Toggle one modifier off and back, pick base key `K`, press
  `Apply`. `Apply` was disabled before the change and enabled after; the `Current`
  line shows the new chord. Close and reopen Settings — the chord persists.
- **Chord gate.** Uncheck every modifier. `Apply` disables and
  `At least one modifier is required.` appears. Re-check one modifier to recover.
- **Alphabet edit.** Deselect chips below 4 keys: `Save (n/4 keys)` disables.
  Re-select to ≥4, press `Save`. Close and reopen — the selection persists.
- **Login toggle.** Flip `Launch at Login`, close, reopen: the toggle matches
  `SMAppService` truth, not the flipped paint. (On hosts where registration throws,
  the snap-back itself is the correct behavior.)
- **Permissions rows.** Each row shows its mark (`✓`/`✗`/`—`); `Enable…` exists on
  the Vimotion row, `Open System Settings` on the Cua row. Grants themselves are
  changed in System Settings, never asserted by clicking inside this window alone.
- **Proof.** `$EVIDENCE/settings.png` per mutation, `defaults read` before/after
  diff, and the reopened window showing each persisted value. A defaults diff
  without the reopened-window screenshot is setup, not proof.

## Gotchas

- `Apply` staying disabled is usually "draft equals stored chord", not a bug —
  change something first.
- The letter picker cannot represent `Space`/`Esc` base keys; the caption
  `Base key … can't be selected here; Apply keeps it.` is the preserve path working.
- Alphabet persistence order is the ergonomic default order filtered by selection,
  not click order — assert the set, not a sequence.
- Invalid stored values self-heal per-field to defaults on next launch; a run that
  hand-edits defaults into garbage verifies repair, not corruption.
- Settings writes go to domain `local.vimotion.Vimotion`; reading any other domain
  (e.g. the driver CLI's) proves nothing about this window.
