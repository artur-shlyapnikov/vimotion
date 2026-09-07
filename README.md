# Vimotion

Keyboard hints for every macOS app. Vimotion is a small menu-bar utility (it does not add a Dock icon): press the activation shortcut, type the label shown over an actionable control, and activate it without reaching for the mouse.

Vimotion is a client for the external [`cua-driver`](https://cua.ai/docs/how-to-guides/driver/install) service. The driver exposes the macOS accessibility tree over MCP; Vimotion turns that tree into a fast, keyboard-first overlay.

## How it works

The global event tap catches the activation shortcut. `HintModeController` asks the Cua driver for the frontmost window and its accessibility elements (`health_report`, `list_windows`, `get_window_state`), then renders stable hint codes in a transparent overlay. Typing a code issues a `click` for the matching element token. If the driver, target window, or accessibility permission is unavailable, the overlay is dismissed and the menu-bar status explains what needs attention.

## Requirements

- macOS 14+, Swift 6.1 (`swift --version`)
- Full Xcode for tests and lint (`swift test` and `swiftlint` need the Xcode toolchain)
- `just` (command runner)
- An executable `cua-driver` at `~/.local/bin/cua-driver` or on `PATH`
- Accessibility permission for **both** Vimotion and the Cua driver (Screen Recording is optional and never requested by Vimotion)

## Quick start

```sh
just app      # build and assemble build/Vimotion.app (ad-hoc signed)
just launch   # open the assembled app
```

Place a compatible `cua-driver` executable in `~/.local/bin/cua-driver` or on `PATH`, start Vimotion, and grant Accessibility in System Settings → Privacy & Security → Accessibility when prompted. Press `⌘⇧Space` in any app to show hints. Settings open via `⌥⌘V`, which remains useful when the menu-bar item is hidden by a crowded status bar.

Install the locally built app system-wide:

```sh
just install    # copies to /Applications/Vimotion.app and opens it
just uninstall
```

`scripts/make-app.sh` signs on every rebuild (`CODESIGN_IDENTITY=…` can select a signing identity). Ad-hoc re-signing changes the app cdhash, so macOS may require the Accessibility grant again after a rebuild.

## Commands

Build:

- `just build` — debug build (`swift build`)
- `just release` — release build (`swift build -c release`)
- `just app` — release build + `build/Vimotion.app` assembly

Dev:

- `just run -- <args>` — run from source, args passed through
- `just launch` / `just stop` / `just restart` — open / kill / rebuild+reopen `build/Vimotion.app`
- `just install` / `just uninstall` — copy to / remove from `/Applications`

Test / check:

- `just test` / `just test <Filter>` — `swift test [--filter …]` (needs full Xcode)
- `just coverage` — test with code coverage
- `just check` — fast local gate (`swift build`)
- `just ci` — `check` + release build + `swift test`
- `just lint` — `swiftlint --quiet` (needs full Xcode toolchain)
- `just format-check` / `just format` — optional SwiftFormat pass (the project does not yet commit a formatting policy)

Maint:

- `just clean` / `just distclean` — clean (+ drop `.build` checkouts)
- `just deps` / `just update` / `just doctor` — show deps / update / print toolchain versions

## Project structure

```
Package.swift                  # Swift 6.1, macOS 14; dep: modelcontextprotocol/swift-sdk 0.12.1 (MCP)
justfile                       # all commands above
scripts/make-app.sh            # assembles + re-signs build/Vimotion.app (LSUIElement, local.vimotion.Vimotion)
Sources/Vimotion/
  App/                         # VimotionApp (accessory shell), AppEnvironment (composition root), SettingsHotkey (⌥⌘V)
  Input/                       # GlobalInput, InputGate (activation chord), KeyboardEventTap, PhysicalKey
  Features/HintMode/           # HintModeController, HintSessionBackend, HintModeState, WindowTargetResolver
  Overlay/                     # OverlayCoordinator, HintOverlayView, HintLayoutEngine, HintPanel
  Domain/                      # HintTarget, HintCode, HintCodeGenerator, ElementFilter, GeometryMapper
  Infrastructure/Cua/          # CuaDriverClient, CuaMCPProcess, CuaResponseDecoder, CuaModels
  Infrastructure/Permissions/  # PermissionCoordinator (Vimotion AX + driver AX/Screen Recording)
  Settings/                    # SettingsStore (UserDefaults schema v1), SettingsView
  MenuBar/                     # MenuBarView (ready / permissionRequired / cuaOffline)
  Support/                     # AsyncGate, AppLogger, PerformanceMetrics
Tests/VimotionTests/           # XCTest: controller, gate, decoder, filter, geometry, settings, permissions
```

Key settings (persisted, schema v1, per-field load-time repair): activation chord (default `⌘⇧Space`, modifiers limited to ⌘⇧⌃⌥, never empty) and hint alphabet (≥4 distinct physical keys).

## Status

Vimotion is pre-release software (`0.1.0`, bundle `local.vimotion.Vimotion`). The menu bar reports `ready`, `permissionRequired`, or `cuaOffline`; the driver is checked once at startup and can be reconnected explicitly from the menu. Interfaces and behavior may change before the first stable release.

## Limitations

- Vimotion only targets the frontmost on-screen window and actionable accessibility elements exposed by the driver.
- The Cua driver is a separate process and is not bundled with this repository.
- Both Vimotion and the driver must be trusted by macOS Accessibility; Vimotion does not silently bypass TCC.
- Screen Recording is optional and is never requested by Vimotion.

## License

Vimotion is released under the MIT License. The MCP Swift SDK and its transitive dependencies retain their own notices; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
