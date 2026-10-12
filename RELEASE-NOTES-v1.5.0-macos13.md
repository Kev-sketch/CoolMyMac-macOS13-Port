# CoolMyMac v1.5.0-macos13 — Release Notes

**This is a community port of [ecc521/CoolMyMac](https://github.com/ecc521/CoolMyMac), not an upstream release.**
Upstream targets macOS 15.0+ / Swift 6. This port retargets the same code to **macOS 13.0+**.

## ✅ Installable build attached — no Xcode required

**`CoolMyMac-macOS13-Port.dmg`** is attached below. It contains a signed (ad-hoc) `CoolMyMac-macOS13.app`
with the privileged helper daemon and the CLI embedded:

1. Open the DMG and drag **CoolMyMac-macOS13** onto Applications.
2. Launch it — it's a menu-bar app (fan/thermometer icon with a live temperature readout).
3. The helper registers itself on first launch; fan control, the four profiles
   (**System · Balanced · Performance · Max**) and the CLI then work.

The app is **ad-hoc signed** (no Apple Developer ID), which is fine for local use but not notarized.
It is built from this tag by `build-macOS13-port.sh` — a **no-Xcode** build (swiftc 5.8.1 +
`MacOSX13.3.sdk`) that also works on machines with only the Command Line Tools, and which produces
both the `.app` and this DMG.

## Status

- **Built, signed and run on macOS 13.7.8** (Intel MacBookPro16,2): live menu-bar readout, helper
  daemon registered via `SMAppService` and running as **root**, working XPC reads and writes, and the
  CLI (`temps`, `fans`, `profile`).
- Every target also typechecks clean against `MacOSX13.3.sdk` at `-target x86_64-apple-macosx13.0`
  (`./scripts/verify-macos13.sh`, exit 0).

## What changed from upstream

| Area | Upstream | This port |
|---|---|---|
| Deployment target | macOS 15.0 | **macOS 13.0** |
| Toolchain | Xcode 16 / Swift 6 | **Xcode 15.4** (Swift 5.10) *or* no Xcode at all |
| Xcode project format | `objectVersion 77` | **`objectVersion 60`** |
| SwiftPM | `swift-tools-version 6.0` | **`5.8`** + `.macOS(.v13)` |
| Observation framework | `@Observable` / `@Bindable` throughout | **`ObservableObject` + `@Published` + Combine** — the real macOS 13 blocker (the module is absent from the 13.3 SDK) |
| Swift 6-only syntax | `nonisolated(unsafe)`, `@retroactive` | Removed / replaced |
| Hardcoded Team ID | `G24X82SAVJ` | Removed — pick your own for Release builds |

## Fixes found by actually running it (all in this tag)

- **Menu-bar icon was clipped** — the vertical layout drew the symbol 1 pt above its 22 pt canvas.
- **XPC calls could hang forever** when the helper wasn't running, so the app never reached its
  direct-SMC fallback (and the CLI hung too). Now bounded by per-call timeouts plus a
  pending-continuation registry.
- **The refresh loop discarded its own fallback readings** (the 1 s cadence was shorter than the
  ~1.7 s unreachable path), leaving the menu bar stuck on "no reading yet".
- **The CLI was never built** — it is now compiled with swiftc and embedded in the bundle.
- **A stale helper registration could never reconnect.** macOS binds an `SMAppService` record to the
  code identity of the app that created it and refuses to re-parent it, so every rebuild could
  permanently break the helper (`launchd`: `spawn failed`, `EX_CONFIG 78`). The port now uses its own
  daemon identity (`com.coolmymac.app.macos13.daemon`, so it can coexist with the upstream app) and
  re-registers itself automatically when the helper is unreachable.

Details: [`PORTING-macos13.md`](PORTING-macos13.md) §9.

## Known limitations

- **Ad-hoc signed / not notarized.** For a Release build with a real Team ID: set it on both targets in
  `project.yml` and replace the `G24X82SAVJ` string at `DaemonXPCServer.swift:156`, then build with Xcode 15.4.
- **No app icon** in the no-Xcode build (`actool` is Xcode-only) — cosmetic; the Xcode build produces it.
- **GPU temperature** shows N/A on Intel Macs with integrated graphics only (no GPU sensors exist) — expected.
- **CLI profile writes** need `sudo` or the app's "Allow Unprivileged CLI" toggle (by design).
- Upstream deliberately targets macOS 15 + Swift 6, so this is maintained as a **fork**, not a PR.

## Credits

All application design and implementation credit belongs to the upstream authors,
[ecc521/CoolMyMac](https://github.com/ecc521/CoolMyMac), GPLv3. The port is build-configuration work
plus the runtime fixes listed above.
