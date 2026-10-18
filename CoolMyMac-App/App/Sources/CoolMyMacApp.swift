// CoolMyMacApp.swift
// @main entry point. Creates the MenuBarExtra and manages the preferences window.

import SwiftUI
import SMCKit
import ServiceManagement

/// Guarantees the fans are handed back to Apple on quit, whatever state the helper is in.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DaemonManager.shared.releaseFansOnQuit()
    }
}

@main
struct CoolMyMacApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        // Enforce single instance: prevent duplicate menu bar icons.
        // By terminating the OLD instances, clicking "Run" in Xcode seamlessly replaces the running app.
        if let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            for app in apps where app.processIdentifier != currentPID {
                app.terminate()
            }
        }
        
        // Defaults: Open at login on first launch
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            UserDefaults.standard.set(true, forKey: "openAtLogin")
            try? ServiceManagement.SMAppService.mainApp.register()
        }

        // Drop helper registrations from older service identities. A leftover registration keeps
        // spawning its own helper, and two helpers fight over the fans.
        DaemonManager.shared.retireLegacyRegistrations()

        // Register the helper automatically when it is missing, so fan control works out of
        // the box (and survives identity migrations without a trip through Preferences).
        Task { @MainActor in
            if DaemonManager.shared.currentStatus() == .notInstalled {
                try? await DaemonManager.shared.installDaemon()
            }
        }
    }

    var body: some Scene {

        // MARK: - Menu Bar Extra
        MenuBarExtra {
            PopoverView(state: state)
                .frame(width: 320)
                .onAppear { state.beginViewingAllSensors("popover") }
                .onDisappear { state.endViewingAllSensors("popover") }
        } label: {
            MenuBarIconView(state: state)
        }
        .menuBarExtraStyle(.window)   // Renders the content as a floating panel

        // MARK: - Preferences Window
        Window("CoolMyMac Preferences", id: "preferences") {
            PreferencesView(state: state)
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentMinSize)
    }
}
