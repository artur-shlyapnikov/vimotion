set shell := ["bash", "-euo", "pipefail", "-c"]

# Vimotion (macOS menu-bar app, Swift 6.1). `just` to list, `just check` for the local gate.
package := "Vimotion"
app := "build/Vimotion.app"
dest := "/Applications/Vimotion.app"

default:
    @just --list --unsorted

# ── build ────────────────────────────────────────────────────────────────

[group('build')]
build:
    swift build

[group('build')]
release:
    swift build -c release

# Assemble build/Vimotion.app (release build + ad-hoc codesign; CODESIGN_IDENTITY=… overrides)
[group('build')]
app:
    ./scripts/make-app.sh

# ── test ─────────────────────────────────────────────────────────────────

# Optionally scoped: just test FilterSubstring. Needs full Xcode (XCTest); fails on CLT-only hosts.
[group('test')]
test filter="":
    swift test {{ if filter != "" { "--filter " + filter } else { "" } }}

# Needs full Xcode (XCTest); fails on CLT-only hosts.
[group('test')]
coverage filter="":
    swift test --enable-code-coverage {{ if filter != "" { "--filter " + filter } else { "" } }}

# ── check ────────────────────────────────────────────────────────────────

# Needs the full Xcode toolchain (sourcekitd); fails on CLT-only hosts.
[group('check')]
lint:
    swiftlint --quiet

# Advisory until a .swiftformat config is committed: default rules flag most of the tree.
[group('check')]
format-check:
    swiftformat --lint .

[confirm("No .swiftformat config committed — default rules will reformat much of the tree. Proceed?")]
[group('check')]
format:
    swiftformat .

# Fast local gate: plain build (tests need full Xcode, so they live in test/ci, not here)
[group('check')]
check:
    swift build

# Full gate: check + release build + test run
[group('check')]
ci: check
    swift build -c release
    swift test

# ── dev ──────────────────────────────────────────────────────────────────

# Run from source, passing args through: just run -- --help
[group('dev')]
run *args="":
    swift run {{ package }} {{ args }}

[group('dev')]
launch: app
    open "{{ app }}"

[group('dev')]
stop:
    pkill -x "{{ package }}" || true

[group('dev')]
restart: app
    pkill -x "{{ package }}" || true
    open "{{ app }}"

[confirm("Overwrite /Applications/Vimotion.app?")]
[group('dev')]
install: app
    rm -rf "{{ dest }}"
    cp -R "{{ app }}" "{{ dest }}"
    open "{{ dest }}"

[confirm("Remove /Applications/Vimotion.app?")]
[group('dev')]
uninstall:
    rm -rf "{{ dest }}"

# ── maint ────────────────────────────────────────────────────────────────

[group('maint')]
clean:
    swift package clean
    rm -rf build

# clean + drop .build checkouts (forces full dependency refetch)
[group('maint')]
distclean: clean
    rm -rf .build

[group('maint')]
deps:
    swift package show-dependencies

[group('maint')]
update:
    swift package update

[group('maint')]
doctor:
    @just --version
    @swift --version
    @swiftlint version
    @swiftformat --version
    @sw_vers -productVersion
