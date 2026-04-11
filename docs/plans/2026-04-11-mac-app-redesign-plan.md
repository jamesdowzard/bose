# Mac App Redesign — Landscape Frosted Dark Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the portrait dark-green Mac app with a 640x360 landscape frosted-dark two-panel layout.

**Architecture:** Complete rewrite of ContentView.swift (new layout, new theme, new structure). BoseApp.swift updated for window size + style. BoseManager.swift unchanged — all @Published properties stay the same. AppDelegate.swift repurposed for NSWindow configuration (vibrancy, title bar).

**Tech Stack:** SwiftUI, NSVisualEffectView (vibrancy), SF Symbols, existing BoseManager/BoseRFCOMM

---

### Task 1: Window Configuration

**Files:**
- Modify: `macos/BoseControl/BoseApp.swift`
- Modify: `macos/BoseControl/AppDelegate.swift`

**Step 1: Update BoseApp.swift window size and style**

```swift
/// BoseControl: Native macOS app for Bose QC Ultra 2

import SwiftUI

@main
struct BoseControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = BoseManager()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                .onAppear { manager.startPolling() }
        }
        .defaultSize(width: 640, height: 360)
        .windowResizability(.contentSize)
    }
}
```

**Step 2: Update AppDelegate.swift for frosted window chrome**

```swift
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure the main window for frosted dark appearance
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first else { return }
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
```

**Step 3: Build and verify window**

Run: `cd macos && ./build.sh`
Expected: compiles clean. App opens at 640x360 with transparent title bar.

**Step 4: Commit**

```bash
git add macos/BoseControl/BoseApp.swift macos/BoseControl/AppDelegate.swift
git commit -m "feat: configure 640x360 landscape window with frosted chrome"
```

---

### Task 2: Rewrite ContentView — Theme + Layout Shell

**Files:**
- Rewrite: `macos/BoseControl/ContentView.swift`

**Step 1: Replace ContentView.swift with new two-panel layout shell**

Replace the entire file. New colour constants (no green), two-panel HStack, VisualEffectBackground, placeholder content in each panel.

```swift
/// ContentView: Landscape frosted-dark two-panel layout for Bose QC Ultra 2.
/// Left panel: status sidebar (battery, ANC, volume).
/// Right panel: device grid + EQ.

import SwiftUI

// MARK: - Theme

private enum Theme {
    static let accentWhite = Color.white
    static let dimWhite = Color(white: 0.7)
    static let subtleGrey = Color(white: 0.4)
    static let panelBg = Color(white: 0.12)
    static let cardBg = Color(white: 0.16)
    static let activeBg = Color(white: 0.22)
}

// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Device Model

private struct DeviceButton: Identifiable {
    let id: String
    let label: String
    let symbol: String
}

private let deviceButtons: [DeviceButton] = [
    DeviceButton(id: "mac", label: "Mac", symbol: "laptopcomputer"),
    DeviceButton(id: "phone", label: "Phone", symbol: "iphone"),
    DeviceButton(id: "ipad", label: "iPad", symbol: "ipad"),
    DeviceButton(id: "iphone", label: "iPhone", symbol: "iphone.gen2"),
    DeviceButton(id: "quest", label: "Quest", symbol: "visionpro"),
    DeviceButton(id: "tv", label: "TV", symbol: "tv"),
]

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var manager: BoseManager

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .ignoresSafeArea()

            if manager.isConnected {
                HStack(spacing: 0) {
                    leftPanel
                        .frame(width: 220)
                    Divider()
                        .background(Theme.subtleGrey.opacity(0.3))
                    rightPanel
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 28) // clear title bar
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "headphones")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Theme.subtleGrey)
                    Text("Not Connected")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.subtleGrey)
                }
            }
        }
        .onAppear { manager.refreshState() }
    }

    // MARK: - Left Panel (placeholder — filled in Task 3)

    private var leftPanel: some View {
        VStack { Text("sidebar").foregroundColor(.white) }
    }

    // MARK: - Right Panel (placeholder — filled in Task 4)

    private var rightPanel: some View {
        VStack { Text("devices + eq").foregroundColor(.white) }
    }
}
```

**Step 2: Build and verify shell**

Run: `cd macos && ./build.sh`
Expected: compiles clean. App opens with frosted translucent background, two placeholder panels, "Not Connected" state when headphones off.

**Step 3: Commit**

```bash
git add macos/BoseControl/ContentView.swift
git commit -m "feat: two-panel frosted layout shell with new theme"
```

---

### Task 3: Left Panel — Status Sidebar

**Files:**
- Modify: `macos/BoseControl/ContentView.swift` — replace `leftPanel`

**Step 1: Implement the sidebar**

Replace the `leftPanel` computed property with the full implementation: battery (large), device name, ANC segmented control, volume slider, firmware at bottom.

Key details:
- Battery: large font (36pt), white, with charging bolt icon
- Device name: 14pt, dimWhite
- ANC: 4 buttons in a row using `Picker` with `.segmented` style, or manual buttons
- Volume: SwiftUI `Slider`, white tint
- Firmware: 10pt, subtleGrey, pinned to bottom with Spacer

Use `manager.batteryLevel`, `manager.ancMode`, `manager.volume`, `manager.volumeMax`, `manager.firmware`, `manager.deviceName` — all existing @Published properties.

ANC modes map to: 0=Quiet, 1=Aware, 2=C1, 3=C2. Set via `manager.setAncMode(Int)`.
Volume set via `manager.setVolume(Int)`.

**Step 2: Build and verify**

Run: `cd macos && ./build.sh`
Expected: left panel shows battery %, ANC buttons, volume slider. Values update from headphones.

**Step 3: Commit**

```bash
git add macos/BoseControl/ContentView.swift
git commit -m "feat: status sidebar — battery, ANC, volume"
```

---

### Task 4: Right Panel — Device Grid

**Files:**
- Modify: `macos/BoseControl/ContentView.swift` — replace `rightPanel`

**Step 1: Implement the device grid + EQ**

Replace `rightPanel` with:
- 3x2 `LazyVGrid` of device buttons using `deviceButtons` array
- Each button shows SF Symbol + label, styled by state from `manager.deviceStates[id]`:
  - `"active"` → white text, `Theme.activeBg` background, subtle white border
  - `"connected"` → `Theme.dimWhite` text, `Theme.cardBg` background
  - `"offline"` → `Theme.subtleGrey` text at 40% opacity
- Tap calls `manager.connectDevice(id)` — this uses existing BoseManager which does RFCOMM + blueutil for mac
- Mac button gets a `"Connect Mac"` subtitle or keyboard shortcut badge
- Below grid: EQ section — preset row (Flat/Bass+/Treble+/Vocal) + 3 compact sliders

Device state keys: `manager.deviceStates` is `[String: String]` with values `"active"`, `"connected"`, `"offline"`.
EQ: `manager.eq` is `(bass: Int, mid: Int, treble: Int)`. Set via `manager.setEQ(bass:mid:treble:)`.

**Step 2: Add keyboard shortcut for Connect Mac**

In ContentView body, add `.onAppear` with `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` or use SwiftUI `.keyboardShortcut` on the Mac button.

Shortcut: Cmd+M calls `manager.connectDevice("mac")`.

**Step 3: Build and verify**

Run: `cd macos && ./build.sh`
Expected: 3x2 device grid with correct state colours. Tapping a device triggers RFCOMM switch. EQ sliders work. Cmd+M connects Mac.

**Step 4: Commit**

```bash
git add macos/BoseControl/ContentView.swift
git commit -m "feat: device grid, EQ section, Cmd+M shortcut"
```

---

### Task 5: Polish + Install

**Files:**
- Modify: `macos/BoseControl/ContentView.swift` — animations, hover states
- Modify: `macos/BoseControl/Info.plist` — if window size needs updating

**Step 1: Add hover and click feedback**

- Device buttons: `.onHover` brightness bump, press animation (`.scaleEffect(0.97)`)
- ANC buttons: highlight active with white background
- Smooth transitions: `.animation(.easeInOut(duration: 0.2), value: manager.deviceStates)`

**Step 2: Build, install, verify end-to-end**

Run: `cd macos && ./build.sh --install`

Verify:
- Window is 640x360, frosted dark, translucent
- Left panel: battery, ANC, volume all update live
- Right panel: device grid shows correct states, switching works
- EQ sliders + presets work
- Cmd+M connects Mac
- Kill old process, new one launched via LaunchAgent

**Step 3: Commit**

```bash
git add macos/BoseControl/
git commit -m "feat: polish — hover states, animations, final install"
```

---

### Task 6: PR and Ship

**Step 1: Push and create PR**

```bash
gh pr create --title "feat: landscape frosted-dark Mac app redesign" \
  --body "Replaces the portrait dark-green UI with a 640x360 landscape two-panel layout. Frosted dark theme with macOS vibrancy. Device grid front and center, Cmd+M for quick Mac connect."
```

**Step 2: Merge and clean up**

```bash
gh pr merge --squash --admin
# Clean up worktree from main repo
```
