# Vimotion

Vimotion is an experimental macOS menu-bar utility that puts keyboard labels
over actionable controls in the frontmost window. Press the activation
shortcut and type a label. Vimotion activates the matching control without
a mouse click.

Vimotion uses an external Cua driver to read the macOS accessibility tree and
activate controls. It connects to that driver through MCP over stdio. The
driver is not included in this repository.

## Requirements

- macOS 14 or later.
- Swift 6.1 or later. The package declares Swift tools version 6.1.
- `just` for the documented commands.
- The package depends on `modelcontextprotocol/swift-sdk` 0.12.1.
- You need an executable `cua-driver` that accepts the `mcp` subcommand.
  It exposes `health_report`, `list_windows`, `get_window_state`, and
  `click`.
- You need Accessibility permission for both Vimotion and the Cua driver.
- `just test` and `just lint` need the full Xcode toolchain. Install SwiftLint
  for `just lint` and SwiftFormat for `just format-check` or `just format`.

### Install the Cua driver

Follow the [Cua driver installation guide](https://cua.ai/docs/how-to-guides/driver/install).
The upstream installer currently uses this command on macOS:

```sh
/bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"
```

The installer creates `~/.local/bin/cua-driver`. Vimotion checks that path
first, then scans the entries in `PATH`. It does not search other directories.
Vimotion starts the driver itself as `cua-driver mcp` and uses stdio rather
than a separately started socket server.

## Build and launch

Run these commands from the repository root.

```sh
just launch
```

`just launch` builds a release binary, assembles
`build/Vimotion.app`, signs it with an ad-hoc identity, and opens the app.
Vimotion runs as a menu-bar accessory and does not add a Dock icon.

To build without opening the app:

```sh
just app
```

To install the assembled app in `/Applications`:

```sh
just install
```

To remove that installed copy:

```sh
just uninstall
```

Both installation commands ask for confirmation. The app bundle is local to
this repository until you run `just install`.

### Grant permissions

Vimotion needs its own Accessibility permission to install the global keyboard
event tap. The Cua driver needs a separate Accessibility permission to inspect
other applications.

1. Open Vimotion's Settings from the menu-bar item, or press `⌥⌘V`.
2. In the Permissions section, use `Enable...` for Vimotion Accessibility.
3. Open System Settings, then Privacy & Security and Accessibility.
4. Enable both Vimotion and Cua Driver.

Screen Recording is optional for this build. Vimotion never requests it and
disables screenshots in its window-state requests.

`just app` re-signs the bundle on every rebuild. With the default ad-hoc
identity, the app's code signature hash changes, so macOS may ask for the
Vimotion Accessibility grant again. Set `CODESIGN_IDENTITY` to a stable
signing identity when you have one.

## Keyboard hints

The default activation shortcut is `⌘⇧Space`.

1. Focus the app and window you want to control.
2. Press `⌘⇧Space` to scan the frontmost window and show the hints.
3. Type the code displayed over the target control.
4. Vimotion activates the control as soon as the complete code matches. You do
   not need to press Enter.

The default hint alphabet is:

```text
A S D F G H J K L Q W E R T Y U I O P Z X C V B N M
```

Vimotion matches ANSI physical letter keycodes and draws Latin uppercase
glyphs. With a non-US input source, use the physical key position represented
by the displayed glyph. Codes are prefix-free, so a complete code identifies
one target. Vimotion assigns shorter codes first in top-to-bottom, then
left-to-right order. It uses multiple-key codes when the number of targets
exceeds the alphabet size.

While hints are visible:

- `Backspace` removes the last typed key.
- `Esc` cancels hint mode.
- Pressing the activation shortcut again cancels hint mode.
- A mouse or scroll event cancels hint mode and reaches the target app.
- A modifier shortcut or an unsupported ordinary key cancels hint mode and
  reaches the target app. The activation shortcut is the exception because
  Vimotion consumes it to cancel the session.
- Hint mode cancels after 10 seconds without an accepted hint key.

The hint overlay does not take mouse events or activate Vimotion. When a
configured hint key does not match any code, Vimotion flashes the hints,
removes that key from the prefix, and keeps the session active.

The menu-bar item also contains Enable Hints, Settings, and Quit. Its status is
one of `Ready`, `Permission Required`, or `Cua Offline`. Enable Hints is
disabled until Vimotion Accessibility is granted, the driver is connected,
and the driver's Cua Accessibility check is granted.

## Settings

The Settings window is available from the menu-bar item and through the global
`⌥⌘V` shortcut. It provides these controls:

- Activation modifiers and a letter base key. At least one of `⌘`, `⇧`, `⌃`,
  and `⌥` is required.
- The hint alphabet. It must contain at least four distinct physical letter
  keys.
- Launch at Login through macOS `SMAppService`.
- Vimotion Accessibility, Cua Accessibility, and the optional Cua Screen
  Recording status.

Vimotion stores the activation chord and alphabet in `UserDefaults` and
applies them to the global input gate. The base key may remain `Space`
when the activation editor has no selected letter.

## MCP driver integration

Vimotion starts the driver as a child process and performs the MCP
initialization handshake over the driver's standard input and output. It then
checks the advertised tools and requires all four names listed below. The
health response must use schema version `1`.

| Phase | MCP tool | Request details |
| --- | --- | --- |
| Startup and reconnect | `health_report` | Requests the driver version, platform, session, bundle, Accessibility, and AX capability checks. |
| Window selection | `list_windows` | Uses `on_screen_only: true`, excludes Vimotion, and selects an on-screen window on the current Space. |
| Hint scan | `get_window_state` | Sends `pid`, `window_id`, `include_screenshot: false`, `max_depth: 25`, `max_elements: 2500`, and a per-launch session label. |
| Activation | `click` | Sends `pid`, `element_token`, `delivery_mode: "background"`, and the same session label. |

Vimotion chooses the frontmost candidate by the driver's `zIndex`. If all
candidates lack that value, it uses the macOS window list as a stacking-order
fallback. It filters out invalid, off-screen, off-Space, and Vimotion-owned
windows before choosing a target.

The app makes one driver health attempt at startup. If the connection fails,
the menu-bar item shows Cua Offline and offers Reconnect to Driver. A failed
in-session transport call gets one reconnect and one retry. There is no
continuous driver retry loop. Vimotion stops the child driver process when it
quits.

## Commands

Build and run:

- `just build` runs `swift build`.
- `just release` runs `swift build -c release`.
- `just app` creates the release app bundle in `build/Vimotion.app`.
- `just run` runs the executable from SwiftPM. Extra arguments are forwarded
  to the executable.
- `just launch`, `just stop`, and `just restart` open, stop, or rebuild and
  reopen the app bundle.
- `just install` and `just uninstall` copy to or remove from
  `/Applications/Vimotion.app`.

Check and test:

- `just check` runs the fast local build gate, `swift build`.
- `just test` runs `swift test`.
- `just test FilterSubstring` runs a filtered test set.
- `just coverage` runs tests with code coverage enabled.
- `just ci` runs the build gate, release build, and test suite.
- `just lint` runs SwiftLint.
- `just format-check` checks SwiftFormat. `just format` applies it after a
  confirmation prompt. No `.swiftformat` configuration is committed.

The live driver test is skipped unless `VIMOTION_LIVE_CUA=1` is set:

```sh
VIMOTION_LIVE_CUA=1 just test
```

That test launches the real `cua-driver` found by Vimotion's lookup rules.
The remaining tests use stubs or injected dependencies where possible.

Maintenance commands include `just clean`, `just distclean`, `just deps`,
`just update`, and `just doctor`. `just doctor` expects the SwiftLint and
SwiftFormat commands to be installed.

## Project structure

```text
Package.swift                  SwiftPM manifest and MCP Swift SDK dependency
justfile                       build, run, test, and maintenance commands
scripts/make-app.sh            app bundle assembly and code signing
Sources/Vimotion/App/          menu-bar app shell and composition root
Sources/Vimotion/Input/        global event tap and keyboard decision gate
Sources/Vimotion/Features/     hint-mode workflow and window selection
Sources/Vimotion/Overlay/      multi-screen hint panels and error HUD
Sources/Vimotion/Domain/       target filtering, geometry, and code generation
Sources/Vimotion/Infrastructure/Cua/
                               MCP process, client, models, and response decoding
Sources/Vimotion/Settings/     persisted settings and Settings window
Tests/VimotionTests/           unit tests and opt-in live handshake test
```

## Limitations and status

Vimotion is pre-release software. The current app bundle version is `0.1.0`
with bundle identifier `local.vimotion.Vimotion`. Interfaces and behavior may
change before a stable release.

- The driver is a separate executable. This repository does not bundle or
  install it.
- Vimotion targets only the frontmost on-screen window on the current Space and
  only the actionable elements the driver exposes through Accessibility.
- Each scan is limited to 2,500 elements and depth 25. A snapshot has a hard
  1.5-second budget.
- A frontmost-app or screen change cancels the active hint session. If a
  clicked element token becomes stale, Vimotion makes one recovery scan and
  clicks only when it finds one matching replacement. An ambiguous or missing
  replacement aborts without a second click.
- Both Vimotion and the driver must be trusted by macOS Accessibility. Vimotion
  does not bypass TCC permissions.
- Screen Recording is optional and is never requested by Vimotion.

## License

Vimotion is released under the MIT License. The MCP Swift SDK and its
transitive dependencies retain their own notices. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
