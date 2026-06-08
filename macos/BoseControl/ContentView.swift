/// ContentView: Frosted-dark two-panel layout for Bose headphone control.
/// Left panel = status sidebar (220px), right panel = device grid + EQ.
/// Uses NSVisualEffectView for macOS vibrancy/translucency.

import SwiftUI

// MARK: - Theme Colors

/// No neon green. White/light grey for active, warm grey for secondary, 40% opacity grey for offline.
private let activeColor = Color.white
private let secondaryColor = Color(white: 0.55)
private let offlineColor = Color(white: 0.4)
private let cardColor = Color.white.opacity(0.06)
private let dividerColor = Color.white.opacity(0.08)

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
    DeviceButton(id: "quest", label: "Quest", symbol: "visionpro"),
]

// MARK: - Visual Effect Background

/// NSViewRepresentable wrapping NSVisualEffectView with .hudWindow material
/// for macOS dark vibrancy/translucency.
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

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var manager: BoseManager

    @State private var volumeSlider: Double = 0
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
        .frame(width: 640, height: 360)
        .background(VisualEffectBackground())
        .onAppear {
            manager.refreshState()
            syncSliders()
            installCmdMShortcut()
        }
        .onReceive(manager.objectWillChange) { _ in
            DispatchQueue.main.async { syncSliders() }
        }
    }

    private func syncSliders() {
        volumeSlider = Double(manager.volume)
        eqBass = Double(manager.eq.bass)
        eqMid = Double(manager.eq.mid)
        eqTreble = Double(manager.eq.treble)
    }

    private func installCmdMShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "m" {
                manager.connectDevice("mac")
                return nil
            }
            return event
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
                    .foregroundColor(activeColor)

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
                            .foregroundColor(.orange)
                    }
                }
            }

            // ANC mode
            VStack(alignment: .leading, spacing: 6) {
                Text("NOISE CONTROL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .tracking(1)
                HStack(spacing: 4) {
                    ancButton("Quiet", 0)
                    ancButton("Aware", 1)
                    ancButton("C1", 2)
                    ancButton("C2", 3)
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
                .tint(activeColor)
            }

            // Wear detection
            VStack(alignment: .leading, spacing: 4) {
                Text("STATUS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .tracking(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(manager.onHead ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(manager.onHead ? "On head" : "Off head")
                        .font(.system(size: 12))
                        .foregroundColor(activeColor)
                }
            }

            Spacer()
        }
        .padding(16)
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
        let isActive = state == "active"
        let isConnected = state == "connected"

        let textColor: Color = isActive ? activeColor : (isConnected ? secondaryColor : offlineColor)
        let bg: Color = isActive ? Color.white.opacity(0.14) : cardColor
        let borderColor: Color = isActive ? activeColor.opacity(0.7) : Color.white.opacity(0.04)

        return Button(action: { manager.connectDevice(button.id) }) {
            VStack(spacing: 3) {
                Image(systemName: button.symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(textColor)
                Text(button.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(textColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(state == "offline" ? 0.6 : 1.0)
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
                        .foregroundColor(selected ? .black : secondaryColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selected ? activeColor : cardColor)
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
            .tint(activeColor)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(secondaryColor)
                .frame(width: 22, alignment: .trailing)
        }
    }

    private func ancButton(_ label: String, _ mode: Int) -> some View {
        let isActive = manager.ancMode == mode
        return Button(action: { manager.setAncMode(mode) }) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? .black : secondaryColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(isActive ? activeColor : cardColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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
                    .foregroundColor(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(activeColor)
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
        if manager.batteryCharging { return .green }
        if manager.batteryLevel < 15 { return .red }
        if manager.batteryLevel < 30 { return .orange }
        return activeColor
    }
}
