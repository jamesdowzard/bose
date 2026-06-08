/// AppDelegate: Window chrome configuration for frosted-dark redesign.

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindow()
    }

    private func configureWindow() {
        guard let window = NSApplication.shared.windows.first else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
    }
}
