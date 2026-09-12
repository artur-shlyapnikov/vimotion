#!/bin/bash
# doctor.sh — read-only "is this instance worth driving?" check for Vimotion.
# No side effects: never launches, kills, or writes. Exit 0 when the bundle is
# drivable, 2 when it is not. Usage:
#   RUN_PID=<pid> helpers/doctor.sh [--app build/Vimotion.app]
set -u

APP="build/Vimotion.app"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:?--app needs a path}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

fail=0
emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf 'note: %s\n' "$1"; }

# --- bundle executable ---
if [ -x "$APP/Contents/MacOS/Vimotion" ]; then
  emit BUNDLE_OK yes
else
  emit BUNDLE_OK no; fail=1; note "missing executable: $APP/Contents/MacOS/Vimotion (run: just app)"
fi

# --- Info.plist identity ---
PLIST="$APP/Contents/Info.plist"
if [ -f "$PLIST" ]; then
  BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST" 2>/dev/null || echo "?")
  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo "?")
  LSE=$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$PLIST" 2>/dev/null || echo "?")
  emit BUNDLE_ID "$BID"; emit BUNDLE_VERSION "$VER"; emit LSUIELEMENT "$LSE"
  [ "$BID" = "local.vimotion.Vimotion" ] || { fail=1; note "unexpected bundle id: $BID"; }
  [ "$LSE" = "true" ] || { fail=1; note "LSUIElement should be true for a menu-bar accessory"; }
else
  emit BUNDLE_ID missing; fail=1; note "missing Info.plist at $PLIST"
fi

# --- code signature (ad-hoc '-' expected; re-sign churn re-prompts TCC) ---
if codesign -v "$APP" 2>/tmp/vimotion-doctor-codesign.err; then
  emit CODESIGN_OK yes
  SIG=$(codesign -dv "$APP" 2>&1 | grep -E "Authority|Identifier" | tr '\n' ';')
  emit CODESIGN_DETAIL "$SIG"
else
  emit CODESIGN_OK no; fail=1
  note "codesign failed: $(cat /tmp/vimotion-doctor-codesign.err)"
fi
rm -f /tmp/vimotion-doctor-codesign.err

# --- driver binary, in the app's own lookup order: ~/.local/bin, then PATH ---
DRIVER=""
if [ -x "$HOME/.local/bin/cua-driver" ]; then
  DRIVER="$HOME/.local/bin/cua-driver"
else
  DRIVER=$(command -v cua-driver 2>/dev/null || true)
fi
if [ -n "$DRIVER" ]; then
  emit DRIVER_PATH "$DRIVER"
  emit DRIVER_VERSION "$("$DRIVER" --version 2>/dev/null | head -1 || echo unknown)"
else
  emit DRIVER_PATH missing; fail=1
  note "no executable cua-driver in ~/.local/bin or PATH (see README install step)"
fi

# --- process state (no ports: driver link is MCP over stdio, not a socket) ---
emit TRANSPORT_MODEL "mcp-stdio (no ports)"
PIDS=$(pgrep -x Vimotion 2>/dev/null | tr '\n' ',' | sed 's/,$//')
if [ -z "$PIDS" ]; then
  emit PROCESS_RUNNING no
else
  emit PROCESS_RUNNING yes; emit PROCESS_PIDS "$PIDS"
fi
if [ -n "${RUN_PID:-}" ]; then
  case ",$PIDS," in
    *,"$RUN_PID",*) emit PID_OWNERSHIP ours ;;
    *) emit PID_OWNERSHIP foreign-or-gone; note "RUN_PID=$RUN_PID not among [$PIDS]; do not drive" ;;
  esac
fi

# --- test toolchain availability (Tier 0 scope) ---
if xcodebuild -version >/dev/null 2>&1; then
  emit XCODE full
else
  emit XCODE clt-only; note "just test/coverage need full Xcode; Tier 0 is build-only here"
fi

if [ "$fail" -eq 0 ]; then emit DOCTOR pass; else emit DOCTOR fail; fi
exit "$fail"
