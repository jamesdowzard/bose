/// ContentView: Warm-paper two-panel layout for Bose headphone control.
/// Left panel = status sidebar (220px), right panel = device grid + EQ.
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
]

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var manager: BoseManager

    @State private var volumeSlider: Double = 0
    @State private var noiseSlider: Double = 0
    @State private var eqBass: Double = 0
    @State private var eqMid: Double = 0
    @State private var eqTreble: Double = 0

    var body: some View {
        Group {
            if manager.isConnected {
                connectedLayout
            } else {
                disconnectedView
            }
        }
        .frame(width: 640, height: 420)  // 420 fits a 3rd device-grid row (7 devices)
        .background(paperColor)
        .preferredColorScheme(.light)
        .onAppear {
            manager.refreshState()
            syncSliders()
            installShortcuts()
        }
        .onReceive(manager.objectWillChange) { _ in
            DispatchQueue.main.async { syncSliders() }
        }
    }

    private func syncSliders() {
        volumeSlider = Double(manager.volume)
        noiseSlider = Double(manager.noiseLevel)
        eqBass = Double(manager.eq.bass)
        eqMid = Double(manager.eq.mid)
        eqTreble = Double(manager.eq.treble)
    }

    /// In-window keyboard shortcuts (only while the app is focused — global hotkeys
    /// stay in Hammerspoon). ⌘1-6 ANC modes (slots 0-5), ⌘↑/⌘↓ volume, ⌘R refresh, ⌘M Mac.
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
            case "r": manager.refreshState(); return nil
            case "m": manager.connectDevice("mac"); return nil
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
        HStack(spacing: 0) {
            // Left panel — status sidebar
            leftPanel
                .frame(width: 220)

            // Divider
            Rectangle()
                .fill(dividerColor)
                .frame(width: 1)

            // Right panel — device grid + EQ
            rightPanel
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
                        ancButton("C1", 4)
                        ancButton("C2", 5)
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

    // MARK: - Right Panel (Device Grid + EQ)

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DEVICES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(secondaryColor)
                .tracking(1)

            deviceGrid

            Text("EQUALIZER")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(secondaryColor)
                .tracking(1)
                .padding(.top, 4)

            eqPresets
            eqSliders
        }
        .padding(16)
    }

    private var deviceGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(deviceButtons) { button in
                deviceButton(button)
            }
        }
    }

    private func deviceButton(_ button: DeviceButton) -> some View {
        let state = manager.deviceStates[button.id] ?? "offline"
        let isConnecting = manager.connectingDevice == button.id
        let isActive = state == "active"
        let isConnected = state == "connected"
        // Another tile is mid-connect — dim this one and ignore taps until it settles.
        let isBlocked = manager.connectingDevice != nil && !isConnecting

        let textColor: Color = (isActive || isConnecting) ? boseAccent
            : (isConnected ? connectedColor : offlineColor)
        let bg: Color = (isActive || isConnecting) ? activeBg : cardColor
        let borderColor: Color = (isActive || isConnecting) ? boseAccent.opacity(0.7) : hairColor

        return Button(action: { manager.connectDevice(button.id) }) {
            VStack(spacing: 3) {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(height: 18)
                } else {
                    Image(systemName: button.symbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(textColor)
                }
                Text(isConnecting ? "Connecting…" : button.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))  // whole tile is the hit area
        }
        .buttonStyle(.plain)
        .disabled(isBlocked)
        .opacity(isBlocked ? 0.4 : (state == "offline" && !isConnecting ? 0.6 : 1.0))
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
