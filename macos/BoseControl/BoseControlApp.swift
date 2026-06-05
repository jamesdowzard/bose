/// BoseControlApp: the menu-bar entry point (replaces v1's WindowGroup/Dock app).
///
/// `MenuBarExtra` + `LSUIElement=true` (Info.plist) => no Dock icon, no window.
/// The app is a silent resident: it does NOT poll, does NOT force-connect on launch.
/// State refreshes only when the menu opens or on a BT connect/disconnect event.
///
/// `--selftest` constructs the manager and exits 0 — an init-only smoke that proves
/// the app links + boots without touching the live BT link (no menu, no refresh).

import SwiftUI
import AppKit

@main
struct BoseControlApp: App {
    @StateObject private var manager = BoseManager()
    @State private var hotkey = HotkeyMonitor()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            // Construct the core types, prove they link, then exit cleanly.
            _ = Transport()
            _ = BoseDeviceMap.knownDevices
            FileHandle.standardOutput.write(Data("selftest: ok\n".utf8))
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra("Bose", systemImage: "headphones") {
            MenuView(manager: manager)
                .onAppear {
                    // Event-driven refresh: menu just opened.
                    Task { await manager.refresh() }
                    hotkey.start { manager.cycleNextDevice() }
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Global hotkey (⌃⌥⌘B) to cycle devices via the devices.toml cycle order.
/// A local NSEvent monitor — no SwiftPM dependency. Only fires while the app is key
/// (menu open); a global monitor would need extra entitlements, so this stays simple.
@MainActor
final class HotkeyMonitor {
    private var monitor: Any?

    func start(_ onCycle: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌃⌥⌘B
            let mods: NSEvent.ModifierFlags = [.control, .option, .command]
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == mods,
               event.charactersIgnoringModifiers?.lowercased() == "b" {
                onCycle()
                return nil
            }
            return event
        }
    }
}
