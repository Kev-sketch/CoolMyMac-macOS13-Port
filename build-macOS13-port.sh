#!/bin/bash
# build-macOS13-port.sh
#
# Build, bundle, and ad-hoc sign CoolMyMac (the macOS 13 port) with NO Xcode.
#
# Why this exists:
#   SwiftPM is broken on this host (`xcrun --sdk macosx --show-sdk-platform-path`
#   fails with "unable to lookup item 'PlatformPath'"), and actool (asset catalog
#   compiler) is Xcode-only. But `swiftc` (5.8.1) works, so we drive it directly.
#
# Proven environment (do not change without re-proving):
#   macOS 13.7.8, Apple swiftc 5.8.1, SDK MacOSX13.3.sdk, target x86_64-apple-macosx13.0,
#   host is a real Intel Mac (2 physical fans -> native x86_64, no Rosetta).
#
# Usage:
#   ./build-macOS13-port.sh [REPO_PATH]
#     REPO_PATH defaults to the CoolMyMac repo root below.
#   Env overrides: SDK, TARGET, OUT (bundle parent dir).
#
# Output:
#   $OUT/CoolMyMac.app   (ad-hoc signed, hand-assembled bundle)
#     Contents/MacOS/CoolMyMac                     — the menu-bar app
#     Contents/Library/LaunchDaemons/CoolMyMac-Daemon — the privileged helper
#     Contents/MacOS/coolmymac-cli                 — the CLI (Preferences → CLI symlinks to it)
#
# Build order (all from ONE run so app + daemon + CLI share ONE code identity —
# this is what the user's one-click "Install" of the daemon depends on):
#   SMCKit -> ArgumentParser (1.4.0, vendored/downloaded) -> App -> Daemon -> CLI
#   -> assemble bundle -> sign (daemon, THEN CLI, THEN app) -> verify each.
#
# KNOWN LIMITATIONS (see PORTING-macos13.md "Gotchas"):
#   * Ad-hoc signing (codesign --sign -). No Apple Developer Team ID is available.
#     On macOS 13 this STILL lets SMAppService register + launchd run the daemon as root.
#     The daemon's XPC "trusted app" tier check (isOurSignedApp, DaemonXPCServer.swift:133)
#     is compiled two ways: built WITH -D DEBUG (as this script does), the check takes the
#     bundle-id branch (identifier "com.coolmymac.app", no Team ID needed), so fan *control*
#     works under ad-hoc signing. A RELEASE build (no -D DEBUG) enforces the hardcoded
#     Team ID G24X82SAVJ at DaemonXPCServer.swift:156 and denies fan writes to ad-hoc-signed
#     apps — for a real release you must set a paid Team ID in project.yml AND replace the
#     string at DaemonXPCServer.swift:156. Sensor/fan *reads* work in both configurations.
#   * No Assets.car (actool unavailable) -> generic app icon. Cosmetic only.
#   * Hardened runtime is NOT enabled (we don't pass --options runtime). Fine for a
#     local smoke test; a release should enable it.
set -euo pipefail

REPO="${1:-/Users/kevinnguyen/WorkBuddy AI/2026-10-11-14-09-13/CoolMyMac}"
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk}"
TARGET="${TARGET:-x86_64-apple-macosx13.0}"
OUT="${OUT:-/tmp/coolmymac-macos13}"
BUILD="$OUT/build"
APP="$OUT/CoolMyMac-macOS13.app"
# swift-argument-parser 1.4.0 source release (GitHub). Cached next to this script
# so repeat builds work offline; downloaded once if missing.
AP_TARBALL="${AP_TARBALL:-$(dirname "$0")/swift-argument-parser-1.4.0.tar.gz}"
AP_URL="https://github.com/apple/swift-argument-parser/archive/refs/tags/1.4.0.tar.gz"
AP_VERSION="1.4.0"

[ -d "$REPO" ] || { echo "error: repo not found: $REPO" >&2; exit 2; }
[ -d "$SDK" ]  || { echo "error: SDK not found: $SDK"  >&2; exit 2; }

echo "repo   : $REPO"
echo "sdk    : $SDK"
echo "target : $TARGET"
echo "out    : $APP"

rm -rf "$BUILD"; mkdir -p "$BUILD/modules" "$BUILD/lib"
rm -rf "$APP"

# --- [1/6] SMCKit: static archive + .swiftmodule so the App/Daemon/CLI can link it ---
echo "== [1/6] Build SMCKit (static lib + module) =="
swiftc -parse-as-library -emit-module -emit-library -static \
  -module-name SMCKit \
  -emit-module-path "$BUILD/modules/SMCKit.swiftmodule" \
  -o "$BUILD/lib/libSMCKit.a" \
  -sdk "$SDK" -target "$TARGET" \
  "$REPO"/SMCKit/Sources/SMCKit/*.swift

# --- [2/6] swift-argument-parser $AP_VERSION: the CLI's only external dependency.
#            SwiftPM is broken here, so fetch the source release and build TWO
#            static modules the same way we build SMCKit:
#              * ArgumentParserToolInfo (needed by DumpHelpGenerator since 1.3)
#              * ArgumentParser        (built with -I pointing at ToolInfo)
#            1.4.0 compiles clean with swiftc 5.8.1 (it ships Package@swift-5.8.swift).
echo "== [2/6] Build swift-argument-parser $AP_VERSION =="
AP_SRC="$BUILD/swift-argument-parser-$AP_VERSION"
if [ ! -s "$AP_TARBALL" ]; then
  echo "-- downloading $AP_URL (cached at $AP_TARBALL) --"
  curl -sSL -o "$AP_TARBALL" "$AP_URL"
fi
rm -rf "$AP_SRC"; mkdir -p "$AP_SRC"
tar xzf "$AP_TARBALL" -C "$AP_SRC" --strip-components=1
swiftc -parse-as-library -emit-module -emit-library -static \
  -module-name ArgumentParserToolInfo \
  -emit-module-path "$BUILD/modules/ArgumentParserToolInfo.swiftmodule" \
  -o "$BUILD/lib/libArgumentParserToolInfo.a" \
  -sdk "$SDK" -target "$TARGET" \
  "$AP_SRC"/Sources/ArgumentParserToolInfo/*.swift
swiftc -parse-as-library -emit-module -emit-library -static \
  -module-name ArgumentParser \
  -emit-module-path "$BUILD/modules/ArgumentParser.swiftmodule" \
  -o "$BUILD/lib/libArgumentParser.a" \
  -I "$BUILD/modules" \
  -sdk "$SDK" -target "$TARGET" \
  "$AP_SRC"/Sources/ArgumentParser/**/*.swift

# --- [3/6] App: has @main -> -parse-as-library; imports SwiftUI/AppKit/Combine/
#            ServiceManagement (+ IOKit pulled in transitively via SMCKit) ---
echo "== [3/6] Build App executable =="
swiftc -parse-as-library \
  -module-name CoolMyMacApp \
  -I "$BUILD/modules" -L "$BUILD/lib" -lSMCKit \
  -sdk "$SDK" -target "$TARGET" \
  -framework SwiftUI -framework AppKit -framework Combine \
  -framework ServiceManagement -framework IOKit -framework Foundation \
  -o "$BUILD/CoolMyMac" \
  "$REPO"/CoolMyMac-App/App/Sources/*.swift \
  "$REPO"/CoolMyMac-App/App/Sources/Views/*.swift

# --- [4/6] Daemon: main.swift has top-level code -> NO -parse-as-library;
#            imports IOKit(+pwr_mgt) and Security.
#            -D DEBUG switches DaemonXPCServer.isOurSignedApp to the bundle-id branch
#            (no Team ID required), so fan *writes* are permitted under ad-hoc signing.
echo "== [4/6] Build Daemon executable (-D DEBUG) =="
swiftc -D DEBUG \
  -module-name CoolMyMacDaemon \
  -I "$BUILD/modules" -L "$BUILD/lib" -lSMCKit \
  -sdk "$SDK" -target "$TARGET" \
  -framework IOKit -framework Security -framework Foundation \
  -o "$BUILD/CoolMyMac-Daemon" \
  "$REPO"/CoolMyMac-App/Daemon/Sources/*.swift

# --- [5/6] CLI: CoolMyMacCLI.swift uses @main (AsyncParsableCommand) -> -parse-as-library.
#            Links SMCKit (the XPC client + protocol live in SMCKit) and the
#            ArgumentParser static libs built in [2/6]. Module name is
#            "coolmymac-cli" so the binary matches the app's expected path
#            (Preferences -> CLI symlinks /usr/local/bin/coolmymac to
#            Contents/MacOS/coolmymac-cli).
echo "== [5/6] Build CLI executable (coolmymac-cli) =="
swiftc -parse-as-library \
  -module-name coolmymac-cli \
  -I "$BUILD/modules" -L "$BUILD/lib" -lSMCKit -lArgumentParser -lArgumentParserToolInfo \
  -sdk "$SDK" -target "$TARGET" \
  -framework Foundation \
  -o "$BUILD/coolmymac-cli" \
  "$REPO"/CoolMyMac-CLI/Sources/CoolMyMacCLI/*.swift \
  "$REPO"/CoolMyMac-CLI/Sources/CoolMyMacCLI/Commands/*.swift

# --- [6/6] Assemble the .app bundle exactly as project.yml's Embed phase does ---
echo "== [6/6] Assemble bundle + ad-hoc sign =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp "$BUILD/CoolMyMac" "$APP/Contents/MacOS/CoolMyMac"
cp "$BUILD/coolmymac-cli" "$APP/Contents/MacOS/coolmymac-cli"
cp "$BUILD/CoolMyMac-Daemon" "$APP/Contents/Library/LaunchDaemons/CoolMyMac-Daemon"
cp "$REPO/CoolMyMac-App/App/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO/CoolMyMac-App/Resources/com.coolmymac.app.macos13.daemon.v2.plist" \
   "$APP/Contents/Library/LaunchDaemons/com.coolmymac.app.macos13.daemon.v2.plist"
chmod +x "$APP/Contents/MacOS/CoolMyMac" "$APP/Contents/MacOS/coolmymac-cli" \
  "$APP/Contents/Library/LaunchDaemons/CoolMyMac-Daemon"

# Sign nested code FIRST (daemon, then CLI), then the app bundle. (--deep is
# intentionally avoided.) Daemon + CLI + app all come from this one run so they
# share a single ad-hoc code identity.
codesign --force --sign - \
  --entitlements "$REPO/CoolMyMac-App/Daemon/CoolMyMacDaemon.entitlements" \
  "$APP/Contents/Library/LaunchDaemons/CoolMyMac-Daemon"
codesign --force --sign - \
  "$APP/Contents/MacOS/coolmymac-cli"
codesign --force --sign - \
  --entitlements "$REPO/CoolMyMac-App/App/CoolMyMac.entitlements" \
  "$APP"

# Verify each binary individually.
echo "-- verify signatures --"
codesign --verify --verbose=2 "$APP/Contents/Library/LaunchDaemons/CoolMyMac-Daemon"
codesign --verify --verbose=2 "$APP/Contents/MacOS/coolmymac-cli"
codesign --verify --verbose=2 "$APP"

# --- [7/7] DMG: drag-to-Applications disk image ---
echo ""
echo "== [7/7] Build DMG =="
DMG="$OUT/CoolMyMac-macOS13-Port.dmg"
STAGE="$OUT/.dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "CoolMyMac macOS 13" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1 \
  && rm -rf "$STAGE" \
  && echo "DONE: $DMG" \
  || echo "WARN: DMG step failed (the .app above is still usable)"

echo ""
echo "DONE: $APP"
echo "Launch with:  open \"$APP\""
echo "(It is an LSUIElement menu-bar app: look for its fan/thermometer + temperature status item,"
echo " top-right of the menu bar.)"
