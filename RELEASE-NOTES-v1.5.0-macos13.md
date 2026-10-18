# CoolMyMac v1.5.0-macos13 — Release Notes

**A community port of [ecc521/CoolMyMac](https://github.com/ecc521/CoolMyMac), not an upstream release.**
Upstream targets macOS 15.0+ and Swift 6. This port targets **macOS 13.0+**.

## Installable build attached

**`CoolMyMac-macOS13-Port.dmg`** is attached below. It holds a signed (ad-hoc) `CoolMyMac-macOS13.app`
with the privileged helper daemon and the CLI inside.

1. Open the DMG and drag **CoolMyMac-macOS13** onto Applications.
2. Launch it. It's a menu-bar app: fan/thermometer icon with a live temperature readout.
3. The helper registers itself on first launch. Fan control, the four profiles
   (**System · Balanced · Performance · Max**) and the CLI then work.

The app is ad-hoc signed, so it isn't notarized; that's fine for local use. `build-macOS13-port.sh`
builds it from this tag with no Xcode (swiftc 5.8.1 + `MacOSX13.3.sdk`) and produces both the `.app`
and this DMG.

## Status

- **Built, signed and run on macOS 13.7.8** (Intel MacBookPro16,2): live menu-bar readout, helper
  daemon registered through `SMAppService` and running as **root**, XPC reads and writes, and the CLI
  (`temps`, `fans`, `profile`).
- Every target typechecks against `MacOSX13.3.sdk` at `-target x86_64-apple-macosx13.0`
  (`./scripts/verify-macos13.sh`, exit 0).

## What changed from upstream

| Area | Upstream | This port |
|---|---|---|
| Deployment target | macOS 15.0 | **macOS 13.0** |
| Toolchain | Xcode 16 / Swift 6 | **Xcode 15.4** (Swift 5.10), or no Xcode at all |
| Xcode project format | `objectVersion 77` | **`objectVersion 60`** |
| SwiftPM | `swift-tools-version 6.0` | **`5.8`** + `.macOS(.v13)` |
| Observation framework | `@Observable` / `@Bindable` throughout | **`ObservableObject` + `@Published` + Combine**. The `Observation` module is absent from the 13.3 SDK, so this was the real blocker. |
| Swift 6-only syntax | `nonisolated(unsafe)`, `@retroactive` | Removed or replaced |
| Hardcoded Team ID | `G24X82SAVJ` | Removed. Set your own for Release builds. |

## Fixes found by running it

- **Menu-bar icon was clipped.** The vertical layout drew the symbol 1 pt above its 22 pt canvas.
- **XPC calls could hang forever** when the helper wasn't running, so the app never reached its
  direct-SMC fallback, and the CLI hung too. Per-call timeouts and a pending-continuation registry
  bound them now.
- **The refresh loop discarded its own fallback readings.** The 1 s cadence was shorter than the
  ~1.7 s unreachable path, which left the menu bar stuck on "no reading yet".
- **The CLI was never built.** It's compiled with swiftc and embedded in the bundle now.
- **A stale helper registration could never reconnect.** macOS ties an `SMAppService` record to the
  code identity of the app that made it and won't re-parent it, so a rebuild could break the helper
  for good (`launchd`: `spawn failed`, `EX_CONFIG 78`). The port uses its own daemon identity
  (`com.coolmymac.app.macos13.daemon`, so it can sit alongside the upstream app) and re-registers
  itself whenever the helper is unreachable.

Details in [`PORTING-macos13.md`](PORTING-macos13.md) §9.

## Known limitations

- **Ad-hoc signed, not notarized.** For a Release build with a real Team ID, set it on both targets in
  `project.yml`, replace the `G24X82SAVJ` string at `DaemonXPCServer.swift:156`, and build with Xcode 15.4.
- **No app icon** in the no-Xcode build (`actool` ships with Xcode). Cosmetic; the Xcode build produces it.
- **GPU temperature** reads N/A on Intel Macs with integrated graphics, which have no GPU sensors.
- **CLI profile writes** need `sudo` or the app's "Allow Unprivileged CLI" toggle.
- Upstream targets macOS 15 and Swift 6, so this stays a fork rather than a PR.

## Credits

The application's design and implementation are the upstream authors' work:
[ecc521/CoolMyMac](https://github.com/ecc521/CoolMyMac), GPLv3. The port is build configuration plus
the fixes listed above.

## Post-port fixes in this tag's app build

Found by running the port for real (all fixed in the attached DMG):

- **Fans pinned after quit.** With a non-System profile active, quitting the app left the daemon
  driving the fans near maximum — moving the app didn't release them either. The daemon's
  auto-suspend only covered the System profile, and it cached the active profile forever.
  Fan control is now **client-gated**: the daemon drives fans only while the app is connected,
  and within ~2 s of the app quitting it resets all fans to Apple auto and exits. Profile
  changes are now re-read from disk, so a stale cache can't peg the fans.
- **"20,000 RPM" fan readout.** Garbage SMC float reads on `F{i}Ac` (observed: 68,027 RPM on a
  6,336-max fan) are re-read once and treated as unknown instead of being displayed.
- **Helper identity.** The daemon registers as `com.coolmymac.app.macos13.daemon.v2` (a fresh
  identity), and the app registers the helper itself on first launch — no Install click.
- On ad-hoc builds the background-item subsystem can wedge after many re-registrations
  (spawn failures with `EX_CONFIG 78`); `scripts/reset-helper.sh` (sudo) clears the stale
  registrations, then relaunch. A Developer-ID-signed build doesn't have this problem.
