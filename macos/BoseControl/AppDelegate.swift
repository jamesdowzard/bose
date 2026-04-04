/// AppDelegate: Menu bar status item, popover, and global hotkey (Option+B)

import AppKit
import SwiftUI
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var manager: BoseManager!
    private var eventMonitor: Any?
    private var hotkeyRef: EventHotKeyRef?

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
        }

        // --- Popover ---
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(manager: manager)
        )

        // --- Global hotkey: Option+B ---
        registerHotkey()

        // --- Close popover on outside click ---
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
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
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        unregisterHotkey()
    }

    // MARK: - Status Item Display

    private func updateStatusItemDisplay() {
        guard let button = statusItem.button else { return }

        let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Bose Control")
        image?.isTemplate = true
        button.image = image

        if manager.isConnected {
            let level = manager.batteryLevel
            let charging = manager.batteryCharging
            let suffix = charging ? "\u{26A1}" : "%"  // bolt when charging
            button.title = " \(level)\(suffix)"
        } else {
            button.title = ""
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

    // MARK: - Global Hotkey (Option+B)

    private func registerHotkey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x424F5345), id: 1)  // "BOSE"
        var ref: EventHotKeyRef?

        // kVK_ANSI_B = 0x0B, optionKey = 0x0800
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotkeyRef = ref
        }

        // Install Carbon event handler for hotkey
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.togglePopover()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    private func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
        }
    }
}
