/// AppDelegate: Window chrome configuration for the warm-paper light redesign.

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    // Warm paper (0xF4EEDE) — matches ContentView's window background so no white shows.
    private let paper = NSColor(red: 0xF4 / 255.0, green: 0xEE / 255.0, blue: 0xDE / 255.0, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The WindowGroup window isn't attached yet at this point — defer a tick so
        // configureWindow() doesn't silently no-op on a nil window (the old bug: the
        // chrome config never applied, leaving the default white title bar).
        DispatchQueue.main.async { [weak self] in self?.configureWindow() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-assert in case SwiftUI re-creates the window and resets the chrome.
        configureWindow()
    }

    private func configureWindow() {
        for window in NSApplication.shared.windows {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true   // drag anywhere on the paper
            window.backgroundColor = paper
            window.appearance = NSAppearance(named: .aqua)
            // Chromeless: hide the traffic lights. Close/hide via ⌘W, ⌘Q, or Opt+B.
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
