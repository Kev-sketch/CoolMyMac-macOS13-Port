// DaemonManager.swift
// Manages daemon installation and status via SMAppService.

import Foundation
import AppKit
import Combine
import ServiceManagement
import SMCKit
import os.log

private let logger = Logger(subsystem: "com.coolmymac.app", category: "DaemonManager")

@MainActor
final class DaemonManager: ObservableObject {

    static let shared = DaemonManager()

    private let service = SMAppService.daemon(plistName: "com.coolmymac.app.macos13.daemon.v2.plist")

    // MARK: - Status

    func currentStatus() -> DaemonInstallStatus {
        let s = service.status
        logger.debug("SMAppService status: \(String(describing: s))")
        switch s {
        case .enabled:               return .installed
        case .notRegistered:         return .notInstalled
        case .requiresApproval:      return .requiresApproval
        case .notFound:              return .notInstalled
        @unknown default:            return .unknown
        }
    }

    // MARK: - Install

    func installDaemon() async throws {
        do {
            try service.register()
            // SMAppService status may not update synchronously after register().
            // Poll until it settles (up to ~3 seconds) before returning.
            let finalStatus = try await waitForStatus(timeout: 3.0)
            logger.info("Daemon registered. Final status: \(String(describing: finalStatus))")
            if finalStatus == .requiresApproval {
                openSystemSettingsForApproval()
            }
        } catch {
            logger.error("Failed to register daemon: \(error.localizedDescription, privacy: .public)")
            // register() may throw on macOS 26+ when approval is required rather than
            // transitioning status to .requiresApproval. Check the post-throw status
            // and open System Settings if it's waiting for user approval.
            // macOS 26 also does not reliably deliver the BTM notification.
            if service.status == .requiresApproval {
                openSystemSettingsForApproval()
            }
            throw error
        }
    }

    // Polls service.status until it is no longer .notRegistered, or until timeout.
    private func waitForStatus(timeout: Double) async throws -> SMAppService.Status {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = service.status
            if s != .notRegistered {
                return s
            }
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        }
        return service.status
    }

    // MARK: - Uninstall

    func uninstallDaemon() async throws {
        do {
            try await service.unregister()
            logger.info("Daemon unregistered")
        } catch {
            logger.error("Failed to unregister daemon: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Open System Settings (for re-grant after denial)

    func openSystemSettingsForApproval() {
        // Opens Privacy & Security > Login Items & Extensions where the user can grant access
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Release on quit

    /// Hand the fans back to Apple when the app terminates — whatever state the helper is in.
    ///
    /// This runs on every quit, even when the helper is unreachable (unregistered, spawn-failing,
    /// or wedged). Releasing control is a plain SMC key write that works unprivileged, so the
    /// fans can never be left pinned after the user quits. The daemon releases them again on
    /// its side when the XPC connection drops; this is the deterministic backstop.
    func releaseFansOnQuit() {
        if let smc = try? SMCController() {
            do {
                try smc.resetAllFans()
                logger.info("Fans released to Apple auto on quit")
            } catch {
                logger.error("Failed to release fans on quit: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Repair

    /// Service identities earlier builds of this port registered.
    ///
    /// macOS keys a background-item registration to the code identity of the app that created it
    /// and will not re-parent it, so a leftover registration keeps spawning its own copy of the
    /// helper — which then runs a second thermal controller and fights the current one over the
    /// fans. Retiring the old identities on launch keeps exactly one helper alive.
    private static let legacyServicePlistNames = ["com.coolmymac.app.daemon.plist", "com.coolmymac.app.macos13.daemon.plist"]

    /// Best-effort removal of registrations left behind by earlier builds. Failures are expected
    /// and harmless on a machine that never ran an older build.
    func retireLegacyRegistrations() {
        for plistName in Self.legacyServicePlistNames {
            do {
                try SMAppService.daemon(plistName: plistName).unregister()
                logger.info("Retired legacy helper registration: \(plistName, privacy: .public)")
            } catch {
                logger.debug("No legacy registration to retire for \(plistName, privacy: .public)")
            }
        }
    }

    func repairDaemon() async throws {
        logger.info("Repair: unregistering daemon (current status: \(String(describing: self.service.status)))")
        try? await uninstallDaemon()
        // Give BTM time to fully clear the old registration before re-registering.
        // On dev builds without a version bump, re-registration may require user
        // re-approval in System Settings (macOS 26+ LWCR update requirement).
        try await Task.sleep(nanoseconds: 1_500_000_000)
        logger.info("Repair: re-registering daemon")
        do {
            try await installDaemon()
            logger.info("Repair: daemon re-registered successfully")
        } catch {
            logger.error("Repair: re-registration failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
