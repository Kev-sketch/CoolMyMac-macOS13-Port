# CoolMyMac

> ### ⚠️ This is a community **port** — the macOS 13 branch
>
> This repository is a fork of **[ecc521/CoolMyMac](https://github.com/ecc521/CoolMyMac)**, which targets **macOS 15.0+ and Swift 6**.
> This port retargets the same codebase to **macOS 13.0+** — with **Xcode 15.4** (Swift 5.10, `SWIFT_VERSION 5.0`) **or with no Xcode at all**.
>
> All credit for the application's design and implementation belongs to the upstream authors — this is a maintenance port of their work, not a separate product. Please report upstream bugs there too.
>
> **Status: builds, signs and runs on macOS 13.** Verified end-to-end on macOS 13.7.8 (Intel MacBookPro16,2): live menu-bar temperature, helper daemon registered via `SMAppService` and running as `root`, working XPC reads/writes, and the CLI. `build-macOS13-port.sh` produces a signed `.app` **and a drag-to-Applications DMG without Xcode** (swiftc 5.8.1 + `MacOSX13.3.sdk`).

![macOS 13.0+](https://img.shields.io/badge/macOS-13.0%2B-blue.svg)
![Swift 5.8](https://img.shields.io/badge/Swift-5.8-orange.svg)
![License](https://img.shields.io/badge/license-GPLv3-green.svg)
![port](https://img.shields.io/badge/fork-macOS%2013%20port-purple.svg)

A modern, lightweight (2MB) macOS fan control and thermal management utility for macOS 13.0+ with a Menu Bar interface. Supports both Intel and Apple Silicon Macs. 

<p align="center">
  <img src="assets/screenshot.png" alt="CoolMyMac Menu Bar Interface" width="400">
</p>

## Features
- **Dynamic Menu Bar Icon**: Menu bar icon automatically shifts from green to red as your CPU/GPU gets hotter.
- **Apple Silicon & Intel SMC Support**: Native, low-level IOKit sensor readings for package power, CPU/GPU temps, and clock speeds.
- **Fan Curves**:
  - `System`: Leaves Apple's default thermal management fully in control.
  - `Balanced`: Similar to Apple's defaults, but slightly more aggressive. _Allows fans to turn off_ (<40°C)
  - `Performance`: Higher minimum RPMs and an aggressive ramp-up to max speed around 85°C.
  - `Max`: Forces all fans to run at maximum speed.
  - `Custom`: Anything you want! 
- **Zero-Overhead Daemon**: Uses native `SMAppService` and XPC for secure, event-driven Inter-Process Communication. This means the background daemon uses virtually zero system resources and no CPU cycles while waiting for commands.
- **Command Line Interface (CLI)**: `coolmymac` tool for scripting profile changes (`coolmymac temps`, `coolmymac fans`, `coolmymac profile set max`).

## Installation

> **⚠️ Do not use the Homebrew tap or the upstream Releases page** — those install the upstream macOS 15.0+ build, not this port.

### Method 1: No-Xcode build (fastest — also produces a DMG)
Needs only the Command Line Tools (`xcode-select --install`), a `MacOSX13.3.sdk`, and one network fetch (swift-argument-parser):
```bash
./build-macOS13-port.sh          # -> CoolMyMac-macOS13.app + CoolMyMac-macOS13-Port.dmg (in /tmp/coolmymac-macos13)
open /tmp/coolmymac-macos13/CoolMyMac-macOS13-Port.dmg
```
Drag **CoolMyMac-macOS13** onto Applications and launch it. The helper tool registers itself on first run — no manual "Install" step, no Team ID needed (see [Helper tool](#helper-tool-daemon)).

### Method 2: Build with Xcode 15.4
See [Building this port](#building-this-port). Use this path for a Release/distribution build with a real Team ID.

### Method 3: Prefer the upstream macOS 15+ build?
If your Mac runs macOS 15 or later, the official upstream app is the better-supported option:
```bash
brew tap ecc521/coolmymac
brew install --cask coolmymac
```

## What's different from upstream

This port changes the build target and toolchain requirements only. No application features were added or removed.

| Area | Upstream | This port |
|------|----------|-----------|
| Deployment target | macOS 15.0 | **macOS 13.0** |
| Toolchain | Xcode 16 / Swift 6 | **Xcode 15.4** (Swift 5.10), `SWIFT_VERSION = 5.0` |
| Xcode project format | `objectVersion = 77` (Xcode 16) | **`objectVersion = 60`** (Xcode 15-native) |
| SwiftPM | `swift-tools-version: 6.0` | **`swift-tools-version: 5.8`**, `.macOS(.v13)` |
| `@Observable` (macOS 14+ `Observation` framework) | Used throughout `AppState` | **Replaced with `ObservableObject` + `@Published` + Combine**, which is where the macOS 13 incompatibility really was |
| Swift 6-only syntax | `nonisolated(unsafe)`, `@retroactive` | Removed / replaced |
| `project.yml` (XcodeGen) | macOS 15.0 / Swift 6.0 / Xcode 16 | **macOS 13.0 / Swift 5.0 / Xcode 15.4** — keep this in sync, it regenerates the `.pbxproj` |

**A note on the two project files.** Upstream's `.gitignore` lists `*.xcodeproj` as a generated artifact (XcodeGen output from `project.yml`), but `project.pbxproj` was committed before that rule was added and is therefore still tracked — and the docs never mention XcodeGen at all. This port retargets **both** files, so either path works: opening the repo as-is gets the macOS 13 project, and running `xcodegen generate` regenerates the same thing. If you ever regenerate, do so with **Xcode 15.4's XcodeGen** — a newer XcodeGen will write Xcode 16 project keys straight back in.

**Verified how:** every target typechecks against `MacOSX13.3.sdk` at `-target x86_64-apple-macosx13.0` (`./scripts/verify-macos13.sh`) — and the port has since been **built and run for real** on macOS 13.7.8.

**Runtime-verified:** live menu-bar readout (the `ObservableObject` view-invalidation conversion works), helper daemon registered via `SMAppService` and running as `root`, XPC reads (`temps`, `fans`, `profile`), and clean daemon lifecycle. Running it surfaced a handful of real bugs that are fixed here — menu-bar icon clipping, XPC calls hanging when the helper is absent, a stale helper registration that could never reconnect, and a missing CLI binary. All are documented in [`PORTING-macos13.md`](PORTING-macos13.md) §9.

## Building this port

CoolMyMac is built entirely through Xcode. The Command Line Tool and Helper Tool are automatically compiled and embedded into the main App during the build process.

### Requirements
- **Xcode 15.4** — the newest Xcode that runs on macOS 13.7.8. Do not attempt with Xcode 16 (needs macOS 14.5+).
- A real signing Team ID. An ad-hoc (`-`) signature silently breaks daemon registration.

### 1. Configure Code Signing (Required)
macOS requires Helper Tools installed via `SMAppService` to be code-signed by the **same Team ID** as the host app. Upstream's own team ID has been stripped out of this port, so all you do is pick yours:

1. Open `CoolMyMac-App/CoolMyMac.xcodeproj` in Xcode.
2. Select the `CoolMyMac` project file in the Project Navigator.
3. Select the `CoolMyMac` target → **Signing & Capabilities**.
4. Select your Personal Team (or Apple Developer ID).
5. Repeat for the `CoolMyMac-Daemon` target — **same team**, not a different one.

**That's all you need for a local build.** In Debug the daemon's client check degrades to comparing bundle identifiers only (`DaemonXPCServer.swift`, `#if DEBUG` branch), so upstream's team ID is inert during development.

**For a Release build you have one extra edit.** `DaemonXPCServer.swift:156` contains the hardcoded XPC requirement `certificate leaf[subject.OU] = "G24X82SAVJ"`. Replace `G24X82SAVJ` with your own Team ID, or the daemon will reject the app's connection in release builds. The string is commented — search the file for `G24X82SAVJ`.

### 2. Build and Run
1. Select the `CoolMyMac` scheme in the top bar.
2. Hit **Cmd + R** (Run).
3. The app will compile (along with the embedded CLI and Daemon) and appear in your Mac's Menu Bar.
4. Click the gear icon to open Preferences, and click **Install Helper Tool** to activate fan control.

### 3. Clean installs only
Do not `cp -Rf` over an existing `/Applications/CoolMyMac.app` — stale files break the code seal and `SMAppService` will SIGKILL the daemon in a ~10s crash loop. Delete the old copy first.

### Reproducing the typecheck verification
The Xcode-independent check that this port actually compiles for macOS 13:
```bash
./scripts/verify-macos13.sh
```
The full analysis behind the port — every blocker, its exact location, and its fix — is kept in [`PORTING-macos13.md`](PORTING-macos13.md).

### Helper tool (daemon)
The privileged helper is registered through `SMAppService` and runs as `root` (it needs root to write fan speeds to the SMC). Two port-specific details:

- **Own daemon identity.** The port registers `com.coolmymac.app.macos13.daemon` (plist label, `MachServices` key, plist filename, daemon bundle id and `CoolMyMacXPCServiceName`) — deliberately *not* upstream's `com.coolmymac.app.daemon`, so the port and the upstream app never fight over one registration.
- **Self-healing registration.** macOS binds an `SMAppService` registration to the *code identity* of the app that created it and refuses to re-parent it. Since every ad-hoc rebuild yields a new identity, a registration can outlive its app and then never resolve again (`launchd`: `spawn failed`, `EX_CONFIG 78`). The app therefore re-registers the helper automatically (once per launch) whenever it stays unreachable — so a rebuild never leaves you with a dead helper.

For a **Release** build you must still set your own Team ID (see [Building this port](#building-this-port)) — the no-Xcode script signs ad-hoc and compiles the daemon with `-D DEBUG`, which uses the bundle-id trust branch instead.

## Architecture
- **App**: A SwiftUI MenuBarExtra application containing the Preferences window.
- **Daemon**: A secure `SMAppService` LaunchDaemon running as `root` (with an XPC listener) required to write speeds to the SMC.
- **CLI**: A standalone Swift package binary embedded in the App.

## Contributing
Please see [Contributing Guidelines](CONTRIBUTING.md) for more details on how to set up your environment and submit Pull Requests.

## License
This project is licensed under the [GNU General Public License v3.0](LICENSE).
