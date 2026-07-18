/// ContentView: Warm-paper three-panel layout for Bose headphone control.
/// Left = status sidebar (260px), middle = device sidebar (a draggable vertical list —
/// drag to rank priority, index 0 = primary; tap to connect), right = EQ.
/// Light theme — burnt-orange accent on warm paper (drawn from the Midterm "paper-hc"
/// terminal theme), matching the Android app.

import SwiftUI

// MARK: - Theme Colors

/// Midterm "paper-hc" inspired: warm paper, burnt-orange accent, earthy neutrals.
private let inkColor = Color(red: 0x21 / 255, green: 0x20 / 255, blue: 0x1C / 255)        // primary text
private let boseAccent = Color(red: 0xAF / 255, green: 0x3A / 255, blue: 0x03 / 255)     // burnt orange — accent
private let connectedColor = Color(red: 0x1B / 255, green: 0x4A / 255, blue: 0x82 / 255)  // calm blue — connected
private let secondaryColor = Color(red: 0x6E / 255, green: 0x6A / 255, blue: 0x5E / 255)  // secondary text
private let offlineColor = Color(red: 0xA8 / 255, green: 0xA1 / 255, blue: 0x8E / 255)    // tertiary / offline
private let warnColor = Color(red: 0xA8 / 255, green: 0x2E / 255, blue: 0x2E / 255)       // warm red
private let paperColor = Color(red: 0xF4 / 255, green: 0xEE / 255, blue: 0xDE / 255)      // window background
private let cardColor = Color(red: 0xFC / 255, green: 0xFA / 255, blue: 0xF4 / 255)       // card / control fill
private let activeBg = Color(red: 0xF6 / 255, green: 0xEA / 255, blue: 0xDC / 255)        // active device tint
private let hairColor = Color(red: 0xE6 / 255, green: 0xDC / 255, blue: 0xC6 / 255)       // hairline border / divider
private let dividerColor = hairColor

// MARK: - Device Button Model

private struct DeviceButton: Identifiable {
    let id: String  // name key
    let label: String
    let symbol: String
}

private let deviceButtons: [DeviceButton] = [
    DeviceButton(id: "mac", label: "Mac", symbol: "laptopcomputer"),
    DeviceButton(id: "phone", label: "Phone", symbol: "iphone"),
    DeviceButton(id: "ipad", label: "iPad", symbol: "ipad"),
    DeviceButton(id: "iphone", label: "iPhone", symbol: "iphone"),
    DeviceButton(id: "tv", label: "TV", symbol: "tv"),
    DeviceButton(id: "appletv", label: "Katrina's Apple TV", symbol: "appletv"),
    DeviceButton(id: "quest", label: "Quest", symbol: "visionpro"),
    DeviceButton(id: "audikast", label: "Avantree Audikast", symbol: "antenna.radiowaves.left.and.right"),
]

/// Live grid reorder: as a dragged tile passes over another, move it there; on drop,
/// commit (persist the order + connect the pair if the top-2 changed).
private struct DeviceDropDelegate: DropDelegate {
    let targetId: String
    @Binding var draggingId: String?
    @Binding var order: [String]
    let onCommit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingId, dragging != targetId,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: targetId) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        onCommit()
        return true
    }
}

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var manager: BoseManager

    @State private var volumeSlider: Double = 0
    @State private var noiseSlider: Double = 0
    @State private var eqBass: Double = 0
    @State private var eqMid: Double = 0
    @State private var eqTreble: Double = 0

    // C1/C2 rename (custom ANC slots 4/5) — driven from a right-click "Rename…" on the button.
    @State private var renameSlot: Int = 4
    @State private var renameText: String = ""
    @State private var showRename: Bool = false

    // Multipoint pair picker: device order (index 0 = primary/active, 1 = secondary/held,
    // rest = eviction order). Seeded from the tile default, overridden by the saved
    // `bose priority` order on appear. `draggingId` tracks the in-flight drag.
    @State private var deviceOrder: [String] = deviceButtons.map { $0.id }
    @State private var draggingId: String? = nil

    var body: some View {
        Group {
            if manager.isConnected {
                connectedLayout
            } else {
                disconnectedView
            }
        }
        // Flexible frame (min/ideal/max) so the window is resizable by dragging — a fixed
        // width/height + .windowResizability(.contentSize) pinned it to one exact size. The
        // ideal is the bigger default; maxWidth/Height .infinity let the panels fill when
        // dragged larger; the min keeps the two-column layout + hints from clipping.
        .frame(minWidth: 800, idealWidth: 860, maxWidth: .infinity,
               minHeight: 480, idealHeight: 560, maxHeight: .infinity)
        .background(paperColor)
        .preferredColorScheme(.light)
        .onAppear {
            manager.refreshState()
            manager.loadProfiles()
            syncSliders()
            installShortcuts()
            // Load the saved multipoint priority order; append any devices missing from it
            // (e.g. a newly-added device) so the list always shows every device.
            manager.loadPriorityOrder { saved in
                guard !saved.isEmpty else { return }
                let all = deviceButtons.map { $0.id }
                deviceOrder = saved.filter { all.contains($0) } + all.filter { !saved.contains($0) }
            }
        }
        .onReceive(manager.objectWillChange) { _ in
            DispatchQueue.main.async { syncSliders() }
        }
        // Rename a custom slot (C1/C2). The text field seeds with the current name; Save
        // writes via `mode-name --slot` (custom slots only; the active mode is untouched).
        .alert("Rename \(renameSlot == 4 ? "C1" : "C2")", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { manager.renameCustomMode(slot: renameSlot, name: renameText) }
        } message: {
            Text("Up to 30 characters. Names the custom mode on-device.")
        }
    }

    /// Open the rename alert for a custom slot (4 = C1, 5 = C2), seeding the field with its
    /// current name so an edit (rather than a blank retype) is the default.
    private func beginRename(slot: Int) {
        renameSlot = slot
        renameText = slot == 4 ? manager.custom1Name : manager.custom2Name
        showRename = true
    }

    private func syncSliders() {
        volumeSlider = Double(manager.volume)
        noiseSlider = Double(manager.noiseLevel)
        eqBass = Double(manager.eq.bass)
        eqMid = Double(manager.eq.mid)
        eqTreble = Double(manager.eq.treble)
    }

    /// In-window keyboard shortcuts (only while the app is focused — global hotkeys
    /// stay in Hammerspoon). ⌘1-6 ANC modes (slots 0-5), ⌘↑/⌘↓ volume. (⌘R/⌘M were
    /// removed 2026-07-18 — unused; the live-read affordance is the staleness
    /// banner's "Read live" button, and connecting the Mac is its device row.)
    private func installShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case "1": manager.setAncMode(0); return nil
            case "2": manager.setAncMode(1); return nil
            case "3": manager.setAncMode(2); return nil
            case "4": manager.setAncMode(3); return nil
            case "5": manager.setAncMode(4); return nil
            case "6": manager.setAncMode(5); return nil
            default: break
            }
            switch event.keyCode {
            case 126: manager.setVolume(manager.volume + 1); return nil  // ↑
            case 125: manager.setVolume(manager.volume - 1); return nil  // ↓
            default: return event
            }
        }
    }

    // MARK: - Connected Layout

    private var connectedLayout: some View {
        VStack(spacing: 0) {
            // Staleness banner — painting the cached snapshot because this Mac has no
            // link to the headphones (the CLI's cached-first read, #148). Honest about
            // age; its Read-live button deliberately pages for a live read (may blip audio).
            if !manager.reachable {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10, weight: .medium))
                    Text("Not connected to this Mac — last known state\(staleAgeText)\(presenceText)")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    // The deliberate live read (pages the headphones — may blip audio
                    // on the active sink). Replaced ⌘R, removed 2026-07-18.
                    Button(action: { manager.refreshState(forcePage: true) }) {
                        Text(manager.isRefreshing ? "Reading…" : "Read live")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(boseAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isRefreshing)
                }
                .foregroundColor(secondaryColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(offlineColor.opacity(0.18))
                .overlay(Rectangle().fill(dividerColor).frame(height: 1), alignment: .bottom)
            }
            connectedPanels
        }
    }

    /// " · headphones on & nearby" / " · not seen nearby" — from the passive-BLE
    /// presence check (receive-only). Empty while unknown/pending.
    private var presenceText: String {
        switch manager.nearbyPresence {
        case .some(true): return " · headphones on & nearby"
        case .some(false): return " · headphones not seen nearby"
        case .none: return ""
        }
    }

    /// " (14m ago)" — the painted snapshot's age, humanised. Empty when unknown.
    private var staleAgeText: String {
        guard let s = manager.stateAgeSeconds else { return "" }
        let text: String
        switch s {
        case ..<60: text = "just now"
        case ..<3600: text = "\(s / 60)m ago"
        default: text = "\(s / 3600)h \((s % 3600) / 60)m ago"
        }
        return " (\(text))"
    }

    private var connectedPanels: some View {
        HStack(spacing: 0) {
            // Left panel — status sidebar
            leftPanel
                .frame(width: 260)  // wide enough for the fixed-mode hints to wrap cleanly

            Rectangle().fill(dividerColor).frame(width: 1)

            // Middle panel — device sidebar (draggable priority list)
            deviceSidebar
                .frame(width: 220)

            Rectangle().fill(dividerColor).frame(width: 1)

            // Right panel — EQ
            eqPanel
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 28)  // clear transparent title bar
    }

    // MARK: - Left Panel (Status Sidebar)

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Device name + battery
            VStack(alignment: .leading, spacing: 4) {
                Text(manager.deviceName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(inkColor)

                HStack(spacing: 6) {
                    Image(systemName: batteryIcon)
                        .font(.system(size: 11))
                        .foregroundColor(batteryColor)
                    Text("\(manager.batteryLevel)%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(batteryColor)
                    if manager.batteryCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundColor(boseAccent)
                    }
                }
            }

            // Profiles — one-tap presets (`bose profile <name>`). A profile may carry a
            // multipoint pair (tv = audikast+phone) and/or settings. Chip list loads from
            // `bose profile --json` (a pure file read — no radio) on window open.
            if !manager.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROFILES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(secondaryColor)
                        .tracking(1)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 4)],
                              alignment: .leading, spacing: 4) {
                        ForEach(manager.profiles, id: \.self) { name in
                            profileChip(name)
                        }
                    }
                }
            }

            // ANC mode
            VStack(alignment: .leading, spacing: 6) {
                Text("NOISE CONTROL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .tracking(1)
                // Hardware slots 0-5: Quiet/Aware/Immersion/Cinema are fixed-level;
                // C1/C2 (slots 4/5) are the adjustable custom modes the Level slider drives.
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ancButton("Quiet", 0)
                        ancButton("Aware", 1)
                        ancButton("Immersion", 2)
                    }
                    HStack(spacing: 4) {
                        ancButton("Cinema", 3)
                        // Custom slots show their stored on-device name (set via `mode-name`),
                        // falling back to C1/C2 when unnamed. Right-click → Rename… (slots 4/5
                        // only; the preset buttons are firmware-locked, so they carry no menu).
                        ancButton(manager.custom1Name.isEmpty ? "C1" : manager.custom1Name, 4)
                            .contextMenu { Button("Rename…") { beginRename(slot: 4) } }
                        ancButton(manager.custom2Name.isEmpty ? "C2" : manager.custom2Name, 5)
                            .contextMenu { Button("Rename…") { beginRename(slot: 5) } }
                    }
                }
                // Noise level (1F,06): 0 = max cancellation … 10 = transparency.
                // Adjustable ONLY on custom modes (firmware cncMutable bit) — disabled
                // on Quiet/Aware/spatial modes. The CLI `anc-level` refuses on fixed
                // modes, so dragging this can never disable ANC (#83).
                HStack(spacing: 8) {
                    Text("Level")
                        .font(.system(size: 10))
                        .foregroundColor(manager.noiseAdjustable ? secondaryColor : offlineColor)
                        .frame(width: 38, alignment: .leading)
                    Slider(
                        value: $noiseSlider,
                        in: 0...10,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing { manager.setNoiseLevel(Int(noiseSlider)) }
                        }
                    )
                    .tint(boseAccent)
                    .disabled(!manager.noiseAdjustable)
                    Text(manager.noiseAdjustable ? "\(Int(noiseSlider))" : "—")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(manager.noiseAdjustable ? secondaryColor : offlineColor)
                        .frame(width: 22, alignment: .trailing)
                }
                .opacity(manager.noiseAdjustable ? 1.0 : 0.5)
                if !manager.noiseAdjustable {
                    Text("\(manager.modeName.isEmpty ? "This mode" : manager.modeName)'s level is fixed — pick a custom mode")
                        .font(.system(size: 9))
                        .foregroundColor(offlineColor)
                }
            }

            // Immersive Audio (1F,06 spatial byte): Off / Still / Motion. Settable only on
            // the custom modes (firmware spatialMutable bit) — the named modes carry it
            // fixed (Immersion = Motion, Cinema = Still), so this greys out on them just
            // like the Level slider. The global 05,0F function is FuncNotSupp on this fw.
            VStack(alignment: .leading, spacing: 6) {
                Text("IMMERSIVE AUDIO")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .tracking(1)
                HStack(spacing: 4) {
                    spatialButton("Off", "off")
                    spatialButton("Still", "still")
                    spatialButton("Motion", "motion")
                }
                .opacity(manager.spatialAdjustable ? 1.0 : 0.5)
                if !manager.spatialAdjustable {
                    Text("\(manager.modeName.isEmpty ? "This mode" : manager.modeName)'s spatial mode is fixed — pick a custom mode")
                        .font(.system(size: 9))
                        .foregroundColor(offlineColor)
                }
            }

            // Volume
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("VOLUME")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(secondaryColor)
                        .tracking(1)
                    Spacer()
                    Text("\(Int(volumeSlider))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(secondaryColor)
                }
                Slider(
                    value: $volumeSlider,
                    in: 0...Double(manager.volumeMax),
                    onEditingChanged: { editing in
                        if !editing {
                            manager.setVolume(Int(volumeSlider))
                        }
                    }
                )
                .tint(boseAccent)
            }

            // Multipoint
            Toggle(isOn: Binding(
                get: { manager.multipointEnabled },
                set: { manager.setMultipoint($0) }
            )) {
                Text("MULTIPOINT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .tracking(1)
            }
            .toggleStyle(.switch)
            .tint(boseAccent)

            // Auto-pause (01,18) — pause when the headphones are removed
            Toggle(isOn: Binding(
                get: { manager.autoPlayPause },
                set: { manager.setAutoPlayPause($0) }
            )) {
                Text("AUTO-PAUSE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .tracking(1)
            }
            .toggleStyle(.switch)
            .tint(boseAccent)

            // Auto-answer (01,1B) — answer a call when the headphones are donned
            Toggle(isOn: Binding(
                get: { manager.autoAnswer },
                set: { manager.setAutoAnswer($0) }
            )) {
                Text("AUTO-ANSWER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .tracking(1)
            }
            .toggleStyle(.switch)
            .tint(boseAccent)

            // Favourites (1F,08) — display-only: which mode slots are marked favourite
            if !manager.favorites.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FAVOURITES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(secondaryColor)
                        .tracking(1)
                    Text(manager.favorites.map(favoriteModeName).joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundColor(inkColor)
                }
            }

            Spacer()
        }
        .padding(16)
    }

    /// A one-tap profile chip. Applying shows a spinner on the tapped chip and blocks
    /// re-entry until it settles (a pair profile pages devices — seconds, not ms).
    private func profileChip(_ name: String) -> some View {
        Button(action: { manager.applyProfile(name) }) {
            HStack(spacing: 4) {
                if manager.applyingProfile == name {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Text(name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(cardColor)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(hairColor, lineWidth: 1))
            .cornerRadius(6)
            .foregroundColor(inkColor)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(manager.applyingProfile != nil)
    }

    /// Friendly name for a favourited AudioModes slot index (display-only).
    private func favoriteModeName(_ idx: Int) -> String {
        switch idx {
        case 0: return "Quiet"
        case 1: return "Aware"
        case 2: return "Immersion"
        case 3: return "Cinema"
        case 4: return "Custom 1"
        case 5: return "Custom 2"
        default: return "Slot \(idx)"
        }
    }

    // MARK: - Middle Panel (Device Sidebar — draggable priority list)

    private var deviceSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEVICES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(secondaryColor)
                .tracking(1)

            deviceList

            Text("Drag to rank · tap to connect")
                .font(.system(size: 9))
                .foregroundColor(offlineColor)

            Spacer(minLength: 0)

            // State legend
            HStack(spacing: 12) {
                legendDot(boseAccent, "active")
                legendDot(connectedColor, "held")
                legendDot(offlineColor.opacity(0.5), "offline")
            }
            .font(.system(size: 9))
            .foregroundColor(secondaryColor)
        }
        .padding(16)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    // MARK: - Right Panel (EQ)

    private var eqPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EQUALIZER")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(secondaryColor)
                .tracking(1)

            eqPresets
            eqSliders
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// Rows in the user's priority order (index 0 = primary, 1 = secondary, rest = eviction).
    private var orderedButtons: [DeviceButton] {
        deviceOrder.compactMap { id in deviceButtons.first { $0.id == id } }
    }

    private var deviceList: some View {
        VStack(spacing: 6) {
            ForEach(Array(orderedButtons.enumerated()), id: \.element.id) { idx, button in
                deviceRow(button, index: idx)
                    .onDrag {
                        draggingId = button.id
                        return NSItemProvider(object: button.id as NSString)
                    }
                    .onDrop(of: [.text], delegate: DeviceDropDelegate(
                        targetId: button.id,
                        draggingId: $draggingId,
                        order: $deviceOrder,
                        onCommit: applyOrder))
            }
        }
    }

    /// Persist the new priority order (index 0 = primary). Dragging ONLY ranks — it does
    /// not touch the radio. Connecting is an explicit tap on a row (see deviceRow's action).
    private func applyOrder() {
        manager.setPriority(deviceOrder)
    }

    /// One device row: [rank badge] [icon] label … [state dot]. Tap connects it; drag ranks.
    private func deviceRow(_ button: DeviceButton, index: Int) -> some View {
        let state = manager.deviceStates[button.id] ?? "offline"
        let isConnecting = manager.connectingDevice == button.id
        let isActive = state == "active"
        let isConnected = state == "connected"
        // Another row is mid-connect — dim this one and ignore taps until it settles.
        let isBlocked = manager.connectingDevice != nil && !isConnecting

        let dotColor: Color = isActive ? boseAccent
            : (isConnected ? connectedColor : offlineColor.opacity(0.5))
        let textColor: Color = (isActive || isConnecting) ? boseAccent
            : (isConnected ? inkColor : secondaryColor)
        let bg: Color = (isActive || isConnecting) ? activeBg : cardColor
        let borderColor: Color = (isActive || isConnecting) ? boseAccent.opacity(0.7) : hairColor

        return Button(action: { manager.connectDevice(button.id) }) {
            HStack(spacing: 9) {
                // Rank badge — 1/2 filled for the multipoint pair, faint number below.
                ZStack {
                    if index <= 1 {
                        Circle().fill(index == 0 ? boseAccent : connectedColor)
                            .frame(width: 16, height: 16)
                        Text(index == 0 ? "1" : "2")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(paperColor)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(offlineColor)
                    }
                }
                .frame(width: 16)

                Image(systemName: button.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(textColor)
                    .frame(width: 20)

                Text(button.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 4)

                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: 9).stroke(borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))  // whole row is the hit area
        }
        .buttonStyle(.plain)
        .disabled(isBlocked)
        .opacity(isBlocked ? 0.4 : (state == "offline" && !isConnecting ? 0.7 : 1.0))
        .help(index == 0 ? "Primary — drag to rank, tap to connect"
            : index == 1 ? "Secondary — drag to rank, tap to connect"
            : "Drag up to rank · tap to connect")
        .contextMenu {
            Button("Disconnect") { manager.disconnectDevice(button.id) }
        }
    }

    private struct EqPreset {
        let name: String
        let bass: Int
        let mid: Int
        let treble: Int
    }

    private let eqPresetList: [EqPreset] = [
        EqPreset(name: "Flat", bass: 0, mid: 0, treble: 0),
        EqPreset(name: "Bass+", bass: 6, mid: 0, treble: -2),
        EqPreset(name: "Treble+", bass: -2, mid: 0, treble: 6),
        EqPreset(name: "Vocal", bass: -2, mid: 4, treble: 2),
    ]

    private var eqPresets: some View {
        HStack(spacing: 6) {
            ForEach(eqPresetList, id: \.name) { preset in
                let selected = manager.eq.bass == preset.bass &&
                    manager.eq.mid == preset.mid &&
                    manager.eq.treble == preset.treble
                Button(action: {
                    eqBass = Double(preset.bass)
                    eqMid = Double(preset.mid)
                    eqTreble = Double(preset.treble)
                    manager.setEQ(bass: preset.bass, mid: preset.mid, treble: preset.treble)
                }) {
                    Text(preset.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(selected ? .white : secondaryColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selected ? boseAccent : cardColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected ? boseAccent : hairColor, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var eqSliders: some View {
        VStack(spacing: 4) {
            eqBandSlider("Bass", value: $eqBass) {
                manager.setEQ(bass: Int(eqBass), mid: Int(eqMid), treble: Int(eqTreble))
            }
            eqBandSlider("Mid", value: $eqMid) {
                manager.setEQ(bass: Int(eqBass), mid: Int(eqMid), treble: Int(eqTreble))
            }
            eqBandSlider("Treble", value: $eqTreble) {
                manager.setEQ(bass: Int(eqBass), mid: Int(eqMid), treble: Int(eqTreble))
            }
        }
    }

    private func eqBandSlider(_ label: String, value: Binding<Double>, onCommit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(secondaryColor)
                .frame(width: 38, alignment: .leading)
            Slider(
                value: value,
                in: -10...10,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
            .tint(boseAccent)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(secondaryColor)
                .frame(width: 22, alignment: .trailing)
        }
    }

    private func ancButton(_ label: String, _ mode: Int) -> some View {
        let isActive = manager.ancMode == mode
        let isPending = manager.pendingAncMode == mode  // optimistic + awaiting confirm
        return Button(action: { manager.setAncMode(mode) }) {
            ZStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundColor(isActive ? .white : secondaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 2)
                if isPending {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                        .tint(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 3)
                }
            }
            .background(isActive ? boseAccent : cardColor)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? boseAccent : hairColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// One Immersive Audio segment (Off/Still/Motion). Highlights the active spatial mode;
    /// disabled when the active mode's spatial is fixed (only custom modes are settable).
    private func spatialButton(_ label: String, _ value: String) -> some View {
        let isActive = manager.spatial == value
        return Button(action: { manager.setSpatial(value) }) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(isActive ? .white : secondaryColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .padding(.horizontal, 2)
                .background(isActive ? boseAccent : cardColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isActive ? boseAccent : hairColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!manager.spatialAdjustable)
    }

    // MARK: - Disconnected View

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "headphones")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(offlineColor)

            Text("Not Connected")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(secondaryColor)

            Button(action: {
                manager.connectDevice("mac")
            }) {
                Text("Connect")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(boseAccent)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 28)
    }

    // MARK: - Helpers

    private var batteryIcon: String {
        switch manager.batteryLevel {
        case 0..<10: return "battery.0"
        case 10..<35: return "battery.25"
        case 35..<65: return "battery.50"
        case 65..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    private var batteryColor: Color {
        if manager.batteryLevel < 15 { return warnColor }
        return boseAccent
    }
}
