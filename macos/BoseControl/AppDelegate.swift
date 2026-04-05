/// AppDelegate: Menu bar status item, popover, and global hotkey (Option+B)

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var manager: BoseManager!
    private var clickMonitor: Any?
    private var eventTapPort: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager = BoseManager()

        // --- Status bar item ---
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemDisplay()

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Bose menu bar")
            button.setAccessibilityRole(.button)
            button.setAccessibilityIdentifier("bose-control-status-button")
        }

        // --- Popover ---
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.behavior = .transient
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: PopoverView(manager: manager)
        )
        hostingController.view.setAccessibilityLabel("Bose popover")
        hostingController.view.setAccessibilityIdentifier("bose-control-popover-view")
        popover.contentViewController = hostingController

        // --- Global hotkey: Option+B via CGEventTap (needs Accessibility permission) ---
        installEventTap()

        // --- Close popover on outside click ---
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        // --- Observe state changes to update menu bar display ---
        manager.onStateChange = { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusItemDisplay()
            }
        }

        // Start polling
        manager.startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stopPolling()
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        removeEventTap()
    }

    // MARK: - Status Item Display

    private func updateStatusItemDisplay() {
        guard let button = statusItem.button else { return }

        let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Bose")
        image?.isTemplate = true
        button.image = image

        if manager.isConnected {
            let level = manager.batteryLevel
            let charging = manager.batteryCharging
            let suffix = charging ? "\u{26A1}" : "%"  // bolt when charging
            button.title = " \(level)\(suffix)"
            button.setAccessibilityLabel("Bose, battery \(level) percent\(charging ? " charging" : ""), \(manager.ancModeName) mode")
        } else {
            button.title = ""
            button.setAccessibilityLabel("Bose, disconnected")
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Refresh state when opening
        manager.refreshState()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bring app to front so popover can receive focus
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    // MARK: - Hotkey (CGEventTap — needs Accessibility, not Input Monitoring)

    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        // Store self as unretained pointer for the C callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

                // Re-enable tap if macOS disabled it (CPU spike, timeout, etc.)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = delegate.eventTapPort {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                // keyCode 11 = B, Option flag = 0x80000 (NSEvent.ModifierFlags.option)
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                if keyCode == 11
                    && flags.contains(.maskAlternate)
                    && !flags.contains(.maskCommand)
                    && !flags.contains(.maskControl)
                    && !flags.contains(.maskShift) {
                    DispatchQueue.main.async {
                        delegate.togglePopover()
                    }
                    return nil  // Consume event — don't type "∫"
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            NSLog("Bose: CGEventTap failed — check Accessibility permission")
            return
        }

        eventTapPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}
