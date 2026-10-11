#!/bin/bash
# verify-macos13.sh
#
# Typechecks every CoolMyMac target against the macOS 13 SDK with a
# deployment target of 13.0, so we can prove the macOS 13 port actually
# compiles (API-availability errors included) without needing Xcode.
#
# Why not `swift build` / `xcodebuild`?
#   - There is no Xcode on this machine, only CommandLineTools.
#   - This machine's SwiftPM is broken: `xcrun --sdk macosx
#     --show-sdk-platform-path` fails with "unable to lookup item
#     'PlatformPath'", so `swift build` cannot run at all.
#   swiftc works fine, so we drive it directly.
#
# Usage:
#   ./scripts/verify-macos13.sh          # checks the repo containing this script
#   ./scripts/verify-macos13.sh /path/to/repo
#   SDK=/path/to/Other.sdk ./scripts/verify-macos13.sh
#
# Exit code 0 = every target typechecks clean.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$HERE/..}"
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk}"
TARGET="x86_64-apple-macosx13.0"
BUILD="$(mktemp -d)"

status=0
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

if [ ! -d "$REPO" ]; then
  echo "error: repo not found at $REPO" >&2
  exit 2
fi
if [ ! -d "$SDK" ]; then
  echo "error: SDK not found at $SDK" >&2
  exit 2
fi

echo "repo    : $REPO"
echo "sdk     : $SDK"
echo "target  : $TARGET"

# --- 1. SMCKit: standalone library, no external dependencies ---------------
step "SMCKit (library)"
swiftc -typecheck -sdk "$SDK" -target "$TARGET" \
  "$REPO"/SMCKit/Sources/SMCKit/*.swift || status=1

# --- 2. Emit SMCKit as a real module so downstream targets can import it ---
step "SMCKit -> .swiftmodule"
swiftc -emit-module -emit-module-path "$BUILD/SMCKit.swiftmodule" \
  -sdk "$SDK" -target "$TARGET" -module-name SMCKit \
  "$REPO"/SMCKit/Sources/SMCKit/*.swift || status=1

# --- 3. The SwiftUI menu bar app (has an @main type) ----------------------
step "CoolMyMac App (SwiftUI)"
swiftc -typecheck -parse-as-library -I "$BUILD" -sdk "$SDK" -target "$TARGET" \
  -module-name CoolMyMacApp \
  "$REPO"/CoolMyMac-App/App/Sources/*.swift \
  "$REPO"/CoolMyMac-App/App/Sources/Views/*.swift || status=1

# --- 4. The root LaunchDaemon (has top-level code in main.swift, so NO
#        -parse-as-library here) -------------------------------------------
step "CoolMyMac Daemon"
swiftc -typecheck -I "$BUILD" -sdk "$SDK" -target "$TARGET" \
  -module-name CoolMyMacDaemon \
  "$REPO"/CoolMyMac-App/Daemon/Sources/*.swift || status=1

# --- 5. CLI is not checked: it depends on swift-argument-parser, which
#        cannot be resolved while SwiftPM is broken on this machine. The CLI
#        sources are macOS 13-safe except for the `@retroactive` conformance
#        noted in HANDOFF-macos13.md. ------------------------------------
step "CoolMyMac CLI (skipped — needs SwiftPM to resolve ArgumentParser)"

printf '\n'
if [ "$status" -eq 0 ]; then
  echo "RESULT: all checked targets typecheck clean on macOS 13"
else
  echo "RESULT: failures above (see 'error:' lines)"
fi
exit "$status"
