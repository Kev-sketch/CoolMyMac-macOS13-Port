// main.swift
// CoolMyMac-Daemon entry point.
// Starts an NSXPCListener and runs the run loop indefinitely.

import Foundation
import SMCKit
import os.log

let logger = Logger(subsystem: "com.coolmymac.daemon", category: "main")

// Ensure we're running as root (required for SMC writes)
/*
guard getuid() == 0 else {
    logger.critical("Daemon must run as root. Exiting.")
    fputs("CoolMyMac-Daemon must run as root.\n", stderr)
    exit(1)
}
*/

func resetFansAndExit(_ sig: Int32) {
    logger.critical("Daemon received signal \(sig). Resetting fans to Apple Auto before exiting.")
    if let smc = try? SMCController() {
        try? smc.resetAllFans()
    }
    exit(sig)
}

signal(SIGINT, resetFansAndExit)
signal(SIGTERM, resetFansAndExit)
signal(SIGHUP, resetFansAndExit)
signal(SIGABRT, resetFansAndExit)

/// The service identity this app registers. Anything else that launches this binary is a
/// leftover from an older registration.
let currentServiceName = "com.coolmymac.app.macos13.daemon"

/// Identities earlier builds of this port registered. They are retired on startup.
let legacyServiceNames = ["com.coolmymac.app.daemon"]

/// Refuse to serve when launchd started us for a legacy service identity.
///
/// An older background-item registration can still resolve to this bundle — it happens when the
/// daemon's service identity changes, or after the app is rebuilt, renamed or moved. That
/// registration spawns a second copy of this same binary, and both copies then run a thermal
/// controller. Because each caches the active profile in memory, they can disagree: the stale
/// copy keeps commanding the profile it last saw, and a Max profile commands 100%, pegging the
/// fans while the current copy commands the real curve.
///
/// launchd tells every daemon which service it was started for, so the duplicate can identify
/// itself and step aside. It exits 0, which the plist's `KeepAlive` (`SuccessfulExit = false`)
/// reads as "stay down", so launchd will not respawn it.
func yieldIfLegacyInstance() {
    guard let service = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] else { return }
    guard service != currentServiceName else { return }

    logger.notice("Started by service '\(service, privacy: .public)', not '\(currentServiceName, privacy: .public)' — retiring this instance.")
    if let smc = try? SMCController() {
        try? smc.resetAllFans()
    }
    exit(0)
}

/// Ask any legacy service to reload, so a stale instance still running the previous build
/// picks up this build and retires itself via `yieldIfLegacyInstance()`.
///
/// `launchctl kickstart -k` restarts the job; the restart exits 0 and launchd leaves it down.
/// Failures are expected and ignored (a machine that never ran the old build has no such job).
func retireLegacyServices() {
    for label in legacyServiceNames {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "system/\(label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}

logger.info("CoolMyMac-Daemon starting (version \(daemonVersionString, privacy: .public))")
yieldIfLegacyInstance()
retireLegacyServices()

// Start the XPC listener
let server = DaemonXPCServer()
server.start()

// Block forever — launchd will manage the lifecycle
dispatchMain()
