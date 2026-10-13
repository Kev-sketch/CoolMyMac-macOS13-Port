# Handoff — Porting CoolMyMac to macOS 13

> **Porting working record.** This is the analysis plan that drove the macOS 13 port, kept
> for provenance. Every item below has since been **applied and verified** — see the git
> history and the "What's different from upstream" table in [`README.md`](README.md).
> Where it says "pending", read it as "done".
>
> Re-run the verification at any time with `./scripts/verify-macos13.sh`.

**Status:** Analysis complete, harness built and validated. **All source edits now applied and typecheck-verified.**
**Repo:** this repository (forked from `ecc521/CoolMyMac` v1.5.0, upstream HEAD `0667927`)
**Harness:** `scripts/verify-macos13.sh`
**Goal:** make `https://github.com/ecc521/CoolMyMac` build and run on macOS 13 (host is 13.7.8).

---

## 1. Environment findings (read this first — it changes the approach)

| Fact | Consequence |
|---|---|
| Host is **macOS 13.7.8** (22H730) | Deployment target must be 13.0 |
| **No Xcode installed.** `xcode-select -p` → `/Library/Developer/CommandLineTools` | Cannot run `xcodebuild`. Cannot produce a `.app`. |
| `swiftc` **5.8.1**, default target `x86_64-apple-macosx13.0` | Compiler is older than the project requires (needs Swift 6) |
| **SwiftPM is broken**: `xcrun --sdk macosx --show-sdk-platform-path` → *"unable to lookup item 'PlatformPath'"* | `swift build` / `swift test` **cannot run at all**. Not fixable from the workspace. |
| SDKs present: `MacOSX12.1`, `12.3`, `13.1`, `13.3` (`MacOSX.sdk` → 13.3) | Use `MacOSX13.3.sdk` for verification |
| Newest Xcode that runs on macOS 13.7.8 = **Xcode 15.4** (Swift 5.10, macOS 14.5 SDK). Xcode 16 needs macOS 14.5+. | Project format + language level must target **Xcode 15.4**, not 16 |

**Therefore:** verification is done by typechecking against the macOS 13.3 SDK at `-target x86_64-apple-macosx13.0`. This genuinely catches every API-availability problem (that is exactly how the Observation blocker was confirmed). It does **not** validate runtime behaviour, and no installable app can be produced in this environment.

---

## 2. Verified baseline (harness output)

```
== SMCKit (library)          -> PASS (clean)
== SMCKit -> .swiftmodule    -> PASS
== CoolMyMac App (SwiftUI)   -> FAIL: AppState.swift:8 error: no such module 'Observation'
== CoolMyMac Daemon          -> FAIL: DaemonXPCServer.swift:81 `nonisolated(unsafe)` rejected
```

Note `Observation` is not merely version-gated — the module does not exist in the 13.3 SDK, so it must be removed outright.

---

## 3. Blocker inventory (exact locations)

### A. Deployment target & metadata
| # | File:line | Change |
|---|---|---|
| 1 | `project.pbxproj:343, 368, 424, 452, 515, 544` | `MACOSX_DEPLOYMENT_TARGET = 15.0` → `13.0` |
| 2 | `project.pbxproj:347, 371, 456, 547` | `SWIFT_VERSION = 6.0` → `5.0` (project level is already `5.0`) |
| 3 | `SMCKit/Package.swift` | `swift-tools-version: 6.0` → `5.8`; `.macOS(.v15)` → `.macOS(.v13)` |
| 4 | `CoolMyMac-CLI/Package.swift` | same two edits |
| 5 | `CoolMyMac-App/App/Info.plist` | `LSMinimumSystemVersion` `15.0` → `13.0` |
| 6 | `CoolMyMac-App/Daemon/Info.plist` | `LSMinimumSystemVersion` `15.0` → `13.0` |

### B. macOS 14+ API — the Observation framework (the real work)
| # | File:line | Change |
|---|---|---|
| 7 | `AppState.swift:8, 14, 52, 55, 496` | `import Observation` + `@Observable` + `@ObservationIgnored` → `import Combine`, `ObservableObject`, `@Published`; drop `@ObservationIgnored` (non-published properties need no attribute) |
| 8 | `PreferencesView.swift:976` | `@Bindable var state: AppState` → `@ObservedObject` |
| 9 | `CoolMyMacApp.swift:11` | `@State private var state = AppState()` → `@StateObject` |
| 10 | **all** `var state: AppState` in views | → `@ObservedObject var state: AppState`. **Sites:** `MenuBarIconView.swift:38`; `PopoverView.swift:10, 179, 253`; `PreferencesView.swift:11, 73, 297, 474, 491, 570, 812, 1014`. (`PreferencesView.swift:590` is an init *parameter* — leave it.) |
| 11 | `AppState.swift` init | **Do not miss this:** `UpdateChecker` becomes a nested `ObservableObject`. Nested changes do not propagate automatically. Add `updateChecker.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }` stored in a `Set<AnyCancellable>`, or the "update available" banner in `GeneralPrefsView` stops refreshing. |

> **#10 is the highest-risk item.** With the Observation macro, a plain `var state: AppState` still triggered re-renders. With `ObservableObject` it does **not** — the code still compiles, but views silently freeze. Every site listed above must be converted; missing one produces a subtle "UI stopped updating" bug rather than a build error.

### C. Swift 6-only toolchain syntax (breaks Xcode 15.4)
| # | File:line | Change |
|---|---|---|
| 12 | `DaemonXPCServer.swift:81` | `nonisolated(unsafe) static var activeConnectionCount = 0` → drop `nonisolated(unsafe)` (needs Swift 5.10+; already guarded by `connectionLock`) |
| 13 | `CLIContext.swift:151` | `extension SMCError: @retroactive Equatable` → `extension SMCError: Equatable` (`@retroactive` needs Swift 6.0) |
| 14 | `DaemonManager.swift:13` | declares `: ObservableObject` with no `import Combine` — add the import (currently relies on an accidental re-export) |

### D. Xcode project format (Xcode 15 cannot open `objectVersion = 77`)
| # | File:line | Change |
|---|---|---|
| 15 | `project.pbxproj:6` | `objectVersion = 77` → `60` |
| 16 | `project.pbxproj:227` | remove `preferredProjectObjectVersion = 77` (Xcode 16-only key) |
| 17 | `project.pbxproj:223` | remove `minimizedProjectReferenceProxies = 1` (Xcode 16-only key) |
| 18 | `project.pbxproj:203` | `LastUpgradeCheck = 2650` → `1540` (cosmetic) |

Keep `XCLocalSwiftPackageReference` — it is native to Xcode 15, the newest Xcode available on macOS 13. *(If Xcode 14.3 support is ever wanted, drop to `objectVersion = 56` and convert the local package to the pre-Xcode-15 folder-`PBXFileReference` style. Not recommended; adds risk.)*

### E. Docs / user-facing strings
| # | File | Change |
|---|---|---|
| 19 | `README.md` | "for macOS 15.0+" → 13.0+; update the requirements blurb |
| 20 | `AGENTS.md` (rule 5) | "This project targets macOS 15.0+" → 13.0 |
| 21 | `PreferencesView.swift` (About tab) | any "macOS 15+" copy |

---

## 4. Verified safe — do NOT waste time on these

All of the following are macOS 13.0 or older, confirmed against the 13.3 SDK:

- `MenuBarExtra`, `.menuBarExtraStyle(.window)`, `Window(_:id:)`, `.defaultSize`, `.windowResizability`, `@Environment(\.openWindow)`
- `NavigationSplitView`, `.navigationSplitViewColumnWidth`, `Grid`/`GridRow`, `.scrollContentBackground`, `.listStyle(.sidebar)`
- `SMAppService` in full (`daemon(plistName:)`, `.mainApp`, `.status`, `register()`, `unregister()`, `.requiresApproval`) and `SMAppService.openSystemSettingsLoginItems()` — all 13.0
- SMC backends: `IOServiceGetMatchingService`, `IOServiceOpen`, `IOConnectCallStructMethod`, `kIOMainPortDefault` (12.0+), `IORegisterForSystemPower`, `IOAllowPowerChange`
- `ProcessInfo.beginActivity`, `ProcessInfo.thermalState`, `DispatchSourceTimer`, `NSXPCListener`, `Security` `SecCode*` APIs, `NSRecursiveLock`, `Logger`
- SwiftUI 12.0+ APIs used: `NSImage.SymbolConfiguration(paletteColors:)`, `.background(_:in:)`, `AnyShapeStyle`, `.foregroundStyle`, `TimelineView`, `.alert(_:isPresented:presenting:actions:message:)`, `.tint`
- **`SMCKit` already typechecks clean at target 13.0** — zero changes needed there

---

## 5. How to verify (validated, works today)

```bash
./scripts/verify-macos13.sh
```

It typechecks SMCKit, then emits SMCKit as a real `.swiftmodule`, then typechecks the App (`-parse-as-library`, it has `@main`) and the Daemon (**no** `-parse-as-library`, `main.swift` has top-level code) against `MacOSX13.3.sdk` at `x86_64-apple-macosx13.0`. Target is 0 errors.

Raw equivalent:
```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk
swiftc -typecheck -sdk "$SDK" -target x86_64-apple-macosx13.0 SMCKit/Sources/SMCKit/*.swift
```

**CLI is not covered** — `CoolMyMac-CLI` depends on `swift-argument-parser 1.5.0` and SwiftPM is broken here, so it can't be resolved. Its sources are macOS 13-safe apart from item #13. Also note: if SwiftPM is ever repaired on this machine, `swift-argument-parser 1.5.0` may declare a tools-version newer than 5.8, which would fail against the 5.8.1 toolchain — pin it lower if that happens.

---

## 6. Gotchas the next person must know

1. **Code signing will block the daemon.** `SMAppService` requires the app **and** the embedded daemon to be signed with the *same* Team ID. The repo hardcodes upstream's team ID in two places: `DevelopmentTeam = G24X82SAVJ` (pbxproj, both targets) and the requirement string in `DaemonXPCServer.swift:156` (`certificate leaf[subject.OU] = "G24X82SAVJ"`). These must be replaced with the user's own team ID, or the daemon is refused/killed with a code-signing failure. **This is likely to be the next blocker after compilation.** *(Update: the `DEVELOPMENT_TEAM` build-setting occurrences in both `project.pbxproj` and `project.yml` have since been removed from this port, so only the `DaemonXPCServer.swift:156` requirement string needs touching — and only for release builds; the Debug path degrades to a bundle-ID check.)*
2. **Never build with `CODE_SIGN_IDENTITY="-"`** (ad-hoc) — it silently breaks daemon registration. Documented in `AGENTS.md`.
3. **Reinstall cleanly.** Do not `cp -Rf` over an existing `/Applications/CoolMyMac.app`; it leaves stale files that break the code seal and make `SMAppService` SIGKILL the daemon in a ~10s crash loop. `rm -rf` first.
4. `nonisolated(unsafe)` and `@retroactive` are *compiler* features (Swift 5.10 / 6.0), not language-mode features — setting `SWIFT_VERSION = 5.0` alone does **not** make them compile.
5. The `Embed Daemon` script phase looks for `$SRCROOT/App/Resources/...` first and falls back to `$SRCROOT/Resources/...`. Only the fallback exists — that's fine, but don't "fix" it without checking.
6. `CoolMyMac-App/DaemonTests/ThermalControllerTests.swift` is **stale and not in any target** — it references `SensorReading(id:...celsius:)`, which doesn't exist in `Models.swift`. Ignore it.
7. `AppIcon.appiconset` contains only a single `512x512@2x` (1024px) image. Xcode may warn about missing sizes; it should still build.
8. The `homebrew-coolmymac` submodule is not initialized (irrelevant to the port). `scripts/release.sh` and `ExportOptions.plist` are for upstream's notarized DMG flow — not needed to get a local build.

---

## 7. Remaining task list

| # | Task | Status |
|---|---|---|
| 1 | Set up macOS 13.3 SDK typecheck harness | **done** (`verify-macos13.sh`) |
| 2 | Lower deployment targets to macOS 13 (items 1–6) | pending |
| 3 | Replace Observation with ObservableObject (items 7–11) | pending |
| 4 | Remove Swift 6-only toolchain requirements (items 12–18) | pending |
| 5 | Verify all targets typecheck on macOS 13 | pending |
| 6 | Update docs and report results (items 19–21) | pending |

**Suggested order:** 4 → 2 → 3 → 5 → 6. Do the toolchain/project-format edits first so the harness gives clean signal, then the Observation conversion (the risky part), then re-verify.

---

## 8. Risks

- **Typecheck ≠ working app.** The Observation→`ObservableObject` conversion changes *when* views invalidate. `@StateObject` lifecycle and the Combine forwarding (#11) are reasoned but unexecuted. Budget for a manual smoke test on a real Mac.
- **No installable artifact can be produced here.** The end user still needs Xcode 15.4 to actually build. If they cannot install Xcode 15.4, this port cannot be completed on this machine at all — worth confirming before investing in the full edit pass.
- **Alternative path worth considering:** if the user only wants the app for themselves, a fork with items 1–21 applied plus their own Team ID is the practical deliverable. Upstream will likely not accept `swift-tools-version: 5.8` (it deliberately targets macOS 15 + Swift 6 concurrency), so keep this as a maintained fork rather than a PR.

---

## 9. Post-port fixes (macOS 13 port, after first real run)

Found by running the no-Xcode bundle (`CoolMyMac-macOS13.app`) on this host (macOS 13.7.8). Each entry
says whether it's specific to macOS 13 or an upstream bug the port fixes.

### Menu-bar icon clipped at the top edge (vertical layout)
- **File:** `CoolMyMac-App/App/Sources/Views/MenuBarIconView.swift`, `drawMenuBarIcon()`
- **Symptom:** with the default vertical layout (SF Symbol on top, temperature below), the wind
  symbol was clipped by 1pt at the top of the 22pt menu-bar canvas.
- **Root cause:** the vertical branch computed `symY = totalHeight - symbol.size.height + 1.0`.
  On macOS 13 the `wind` symbol at pointSize 11 / weight medium measures **14.0 × 12.0 pt**
  (measured with a standalone probe against MacOSX13.3.sdk), so `symY = 22 - 12 + 1 = 11`
  and the symbol's drawing rect spans y=11..23 — one point above the 22pt canvas.
- **Fix:** bounds-clamp the symbol into the canvas, preserving aspect:
  `symH = min(symbol.size.height, totalHeight)`,
  `symW = symbol.size.width * (symH / symbol.size.height)`,
  `symX = (totalWidth - symW) / 2`, `symY = totalHeight - symH`. Applied the same clamp guard
  to the horizontal branch (its old `(totalHeight - symbol.size.height) / 2` could go negative
  for a taller symbol). Text drawing unchanged.
- **Note:** upstream has the same `+ 1.0`. It's harmless on macOS 15 because the symbol measures
  differently there. Don't send upstream.

### Helper tool could never connect after the app was rebuilt, renamed or moved
- **Files:** `CoolMyMac-App/Resources/com.coolmymac.app.macos13.daemon.plist` (renamed from
  `…app.daemon.plist`), `SMCKit/Sources/SMCKit/CoolMyMacXPCProtocol.swift`,
  `CoolMyMac-App/App/Sources/DaemonManager.swift`, `CoolMyMac-App/App/Sources/AppState.swift`,
  `CoolMyMac-App/Daemon/Sources/DaemonXPCServer.swift`, `CoolMyMac-App/project.yml`
- **Symptom:** the popover showed "Helper Tool disconnected." forever; `launchctl print
  system/com.coolmymac.app.daemon` reported `job state = spawn failed`, `last exit code = 78:
  EX_CONFIG`; `sfltool dumpbtm` showed the background-item record's parent was the cdhash of a
  **deleted** bundle copy (`file:///private/tmp/…`), not the installed app.
- **Root cause:** macOS keys an SMAppService/BTM registration to the registering app's code
  identity, and will not re-parent a registered service to a different identity. Every ad-hoc
  rebuild produces a new cdhash, so after a rebuild, rename or move the record can no longer
  resolve its daemon, and re-registering from the new app doesn't help.
- **Fix:** (1) the port uses its **own daemon identity**: plist `Label`, `MachServices` key,
  plist filename, daemon bundle id and `CoolMyMacXPCServiceName` are all
  `com.coolmymac.app.macos13.daemon`, so it registers a fresh service instead of colliding with
  the stale one. This also lets the port coexist with the upstream app, which keeps
  `com.coolmymac.app.daemon`. (2) `AppState.refresh()` **self-heals**: if the helper is not
  reachable for 3 consecutive refreshes it re-registers it once per launch, so the next launch
  recovers on its own.
- **Verified:** daemon runs as root (`launchctl` state=running, root-owned
  `/var/log/com.coolmymac.macos13.daemon*.log`), XPC reads work (`coolmymac-cli temps/fans`
  return live data with no fallback warning), and CLI profile writes are refused without sudo or
  `Allow Unprivileged CLI`.
- **Note:** a stale upstream-identity record may linger in System Settings → Login Items. It's
  inert (its parent app is gone) and can be removed there.

### A leftover helper instance fought the current one and pegged the fans
- **Files:** `CoolMyMac-App/Daemon/Sources/main.swift`, `CoolMyMac-App/App/Sources/DaemonManager.swift`,
  `CoolMyMac-App/App/Sources/CoolMyMacApp.swift`, `scripts/reset-helper.sh`
- **Symptom:** with the Balanced profile selected and the CPU around 65 °C, both fans ran at ~100%
  (6,200–6,700 RPM). The raw SMC target (`F0Tg`) read 6,336 — the fan's maximum — while the curve at
  that temperature asks for ~2,500. `F0Md` was 1 (manual mode), `F0Mn` still held the hardware
  minimum, so the *floor* writes never landed and the *target* was pinned at max.
- **Root cause:** two daemons were running — the current service
  (`com.coolmymac.app.macos13.daemon`) and a leftover instance from the pre-rename identity
  (`com.coolmymac.app.daemon`). Each runs its own thermal controller and caches the active profile
  in memory, so they disagreed: the leftover had cached **Max** and rewrote the target to 100% every
  second while the current one wrote the real curve. They overwrote each other and the fans followed
  the higher value. The leftover also held the XPC mach service, so profile changes from the app never
  reached the instance doing the damage — which is why switching profiles in the UI changed nothing.
- **Fix:** (1) the daemon refuses to serve when launchd started it for a service identity other than
  the current one — it resets the fans and exits 0, which the plist's `KeepAlive`
  (`SuccessfulExit = false`) reads as "stay down" instead of respawning; (2) on startup it kickstarts
  legacy service labels so an older instance still running the previous build reloads this build and
  retires itself; (3) the app unregisters legacy service identities at launch; (4) `scripts/reset-helper.sh`
  clears both registrations (needs sudo) when a registration is already stale.
- **Caveat for ad-hoc builds:** macOS keys a registration to the code identity that created it and will
  not re-parent it, so **rebuilding an ad-hoc-signed app invalidates its helper registration**, and the
  app cannot repair that by itself. Clear the registrations once (System Settings → Login Items &
  Extensions, or `scripts/reset-helper.sh`) and launch the app to register fresh. A signed build with a
  stable Developer ID does not have this problem.

### CLI binary missing from the hand-built bundle
- **Symptom:** Preferences → CLI "Install Command" symlinked `/usr/local/bin/coolmymac` to
  `Contents/MacOS/coolmymac-cli`, but that binary was never produced (SwiftPM is broken here).
- **Fix:** `build-macOS13-port.sh` builds the CLI directly with swiftc (`-parse-as-library`,
  linking the already-built SMCKit static lib and a vendored swift-argument-parser 1.4.0 source
  drop), copies it into `Contents/MacOS/`, and ad-hoc signs it (sign order: daemon, CLI, app) so
  all three share one code identity from a single build+sign run.

### XPC client hangs forever when the helper tool is not running (pre-install)
- **Files:** `SMCKit/Sources/SMCKit/CoolMyMacClient.swift`, `CoolMyMac-App/App/Sources/AppState.swift`
- **Symptom:** with the daemon not installed, `AppState.refresh()` could hang forever at
  `await client.isDaemonReachable()` and never reach its direct-SMC fallback — the menu bar
  randomly stayed on the neutral "no reading yet" icon; `coolmymac-cli temps/fans` hung
  indefinitely (no output, no crash).
- **Root cause 1 (upstream):** `NSXPCConnection` does not invoke the error handler passed to
  `remoteObjectProxyWithErrorHandler` when the connection invalidates, so every awaited
  continuation (routed through `xpcCall` / `daemonVersion()` / …) was stranded. A mach service
  with a stale BTM reservation but no live helper makes it worse: the connection stays open, so
  it never replies and never invalidates.
- **Root cause 2 (upstream):** `AppState.refresh()` bailed at `if Task.isCancelled { return }`
  after its fallback read. The refresh cadence (default 1s) is shorter than the
  unreachable-daemon path (~0.7s reachability timeout + ~1s direct SMC read), so once the
  timeouts existed, each cycle's data was discarded by the next cycle's cancellation.
- **Fix:** (1) pending-continuation registry in `CoolMyMacClient`, resumed with a descriptive
  error on interruption/invalidation, plus per-call timeouts (reachability 0.7s, read 1.0s,
  request 5.0s) as a backstop for open-but-silent connections, an idempotent resume-once
  wrapper, error-resume on the nil-proxy path, and dead-connection discard on invalidation;
  (2) `refresh()` now publishes fetched/fallback readings even when a newer refresh tick
  cancelled the task. Verified: 3/3 launches show a live readout within ~2s with no daemon
  installed (previously a coin flip), and CLI `temps`/`fans` return in 1–2s with direct-SMC data.
