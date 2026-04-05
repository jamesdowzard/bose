/// PopoverView: Main SwiftUI interface shown from menu bar click or Option+B.
/// Dark theme, ~320px wide, sections: header, devices, ANC, volume, settings, info.

import SwiftUI
import Combine

// MARK: - Color Constants

private let bgColor = Color(red: 0.1, green: 0.1, blue: 0.1)          // #1A1A1A
private let cardColor = Color(red: 0.15, green: 0.15, blue: 0.15)     // #262626
private let accentGreen = Color(red: 0, green: 1.0, blue: 0.533)      // #00FF88
private let textPrimary = Color.white
private let textSecondary = Color(white: 0.6)

// MARK: - Device Button Model

private struct DeviceButton: Identifiable {
    let id: String  // name key
    let label: String
    let symbol: String
}

private let deviceButtons: [DeviceButton] = [
    DeviceButton(id: "phone", label: "Phone", symbol: "iphone"),
    DeviceButton(id: "mac", label: "Mac", symbol: "laptopcomputer"),
    DeviceButton(id: "ipad", label: "iPad", symbol: "ipad"),
    DeviceButton(id: "iphone", label: "iPhone", symbol: "iphone"),
    DeviceButton(id: "tv", label: "TV", symbol: "tv"),
]

// MARK: - Main View

struct PopoverView: View {
    @ObservedObject var manager: BoseManager
    @State private var showSettings = false
    @State private var showInfo = false
    @State private var editingName = false
    @State private var nameField: String = ""
    @State private var volumeSliderValue: Double = 0
    @State private var eqBass: Double = 0
    @State private var eqMid: Double = 0
    @State private var eqTreble: Double = 0
    @State private var cncSliderValue: Double = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                headerSection
                if manager.isConnected {
                    devicesSection
                    ancSection
                    volumeSection
                    eqSection
                    settingsSection
                    infoSection
                } else {
                    disconnectedView
                }
            }
            .padding(16)
        }
        .frame(width: 320)
        .background(bgColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bose")
        .accessibilityIdentifier("bose-control-popover")
        .onAppear { syncSliders() }
        .onReceive(manager.objectWillChange) { _ in
            DispatchQueue.main.async { syncSliders() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.deviceName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textPrimary)
                    .accessibilityLabel("Device name: \(manager.deviceName)")

                if manager.isConnected {
                    HStack(spacing: 6) {
                        batteryView
                        if manager.isRefreshing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                                .accessibilityLabel("Refreshing state")
                        }
                    }
                } else {
                    Text("Disconnected")
                        .font(.system(size: 12))
                        .foregroundColor(textSecondary)
                        .accessibilityLabel("Connection status: Disconnected")
                }
            }

            Spacer()

            if manager.isConnected {
                ancPill
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Header")
    }

    private var batteryView: some View {
        HStack(spacing: 3) {
            Image(systemName: manager.batteryCharging ? "bolt.fill" : batteryIcon)
                .font(.system(size: 11))
                .foregroundColor(batteryColor)
            Text("\(manager.batteryLevel)%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(batteryColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery level: \(manager.batteryLevel) percent\(manager.batteryCharging ? ", charging" : "")")
    }

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
        if manager.batteryCharging { return accentGreen }
        if manager.batteryLevel < 15 { return .red }
        if manager.batteryLevel < 30 { return .orange }
        return textPrimary
    }

    private var ancPill: some View {
        Text(manager.ancModeName)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(bgColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(accentGreen)
            .cornerRadius(12)
            .accessibilityLabel("Current noise control mode: \(manager.ancModeName)")
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 40))
                .foregroundColor(textSecondary)
                .accessibilityLabel("Headphones icon")
            Text("Headphones not connected")
                .font(.system(size: 13))
                .foregroundColor(textSecondary)
                .accessibilityLabel("Headphones not connected")
            Button(action: {
                manager.connectDevice("mac")
            }) {
                Text("Connect")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(bgColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(accentGreen)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connect headphones to Mac")
            .accessibilityIdentifier("connect-button")
        }
        .padding(.vertical, 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disconnected view")
    }

    // MARK: - Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("DEVICES")

            HStack(spacing: 8) {
                ForEach(deviceButtons) { device in
                    deviceButton(device)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Devices section")
    }

    private func deviceButton(_ device: DeviceButton) -> some View {
        let state = manager.deviceStates[device.id] ?? "offline"
        let actionVerb = (state == "active" || state == "connected") ? "Disconnect" : "Connect"

        return Button(action: {
            if state == "active" || state == "connected" {
                manager.disconnectDevice(device.id)
            } else {
                manager.connectDevice(device.id)
            }
        }) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(state == "active" ? accentGreen.opacity(0.15) : cardColor)
                        .frame(width: 50, height: 44)

                    Image(systemName: device.symbol)
                        .font(.system(size: 18))
                        .foregroundColor(
                            state == "active" ? accentGreen :
                            state == "connected" ? .orange :
                            textSecondary
                        )
                }

                HStack(spacing: 2) {
                    Circle()
                        .fill(
                            state == "active" ? accentGreen :
                            state == "connected" ? .orange :
                            Color(white: 0.3)
                        )
                        .frame(width: 6, height: 6)
                    Text(device.label)
                        .font(.system(size: 9))
                        .foregroundColor(textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(actionVerb) \(device.label), status: \(state)")
        .accessibilityIdentifier("device-\(device.id)")
    }

    // MARK: - ANC

    private var ancSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("NOISE CONTROL")

            HStack(spacing: 0) {
                ancButton("Quiet", mode: 0)
                ancButton("Aware", mode: 1)
                ancButton("C1", mode: 2)
                ancButton("C2", mode: 3)
            }
            .background(cardColor)
            .cornerRadius(8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Noise control section")
    }

    private func ancButton(_ label: String, mode: Int) -> some View {
        let isSelected = manager.ancMode == mode
        let fullModeNames = ["Quiet", "Aware", "Custom 1", "Custom 2"]
        let modeName = mode < fullModeNames.count ? fullModeNames[mode] : label

        return Button(action: {
            manager.setAncMode(mode)
        }) {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? bgColor : textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? accentGreen : Color.clear)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Noise control: \(modeName)\(isSelected ? " (selected)" : "")")
        .accessibilityIdentifier("anc-\(label.lowercased())")
    }

    // MARK: - Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("VOLUME")
                Spacer()
                Text("\(Int(volumeSliderValue))/\(manager.volumeMax)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textSecondary)
                    .accessibilityLabel("Volume: \(Int(volumeSliderValue)) of \(manager.volumeMax)")
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 11))
                    .foregroundColor(textSecondary)
                    .accessibilityLabel("Volume minimum")

                Slider(value: $volumeSliderValue, in: 0...Double(manager.volumeMax), step: 1) { editing in
                    if !editing {
                        manager.setVolume(Int(volumeSliderValue))
                    }
                }
                .accentColor(accentGreen)
                .accessibilityLabel("Volume slider")
                .accessibilityValue("\(Int(volumeSliderValue)) of \(manager.volumeMax)")
                .accessibilityIdentifier("volume-slider")

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 11))
                    .foregroundColor(textSecondary)
                    .accessibilityLabel("Volume maximum")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Volume section")
    }

    // MARK: - EQ

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("EQUALIZER")

            // Presets
            HStack(spacing: 6) {
                eqPresetButton("Flat", bass: 0, mid: 0, treble: 0)
                eqPresetButton("Bass+", bass: 6, mid: 0, treble: -2)
                eqPresetButton("Treble+", bass: -2, mid: 0, treble: 6)
                eqPresetButton("Vocal", bass: -2, mid: 4, treble: 2)
            }

            // Sliders
            eqSlider("Bass", value: $eqBass, band: 0)
            eqSlider("Mid", value: $eqMid, band: 1)
            eqSlider("Treble", value: $eqTreble, band: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Equalizer section")
    }

    private func eqPresetButton(_ label: String, bass: Int, mid: Int, treble: Int) -> some View {
        let isSelected = manager.eq.bass == bass && manager.eq.mid == mid && manager.eq.treble == treble
        return Button(action: {
            eqBass = Double(bass)
            eqMid = Double(mid)
            eqTreble = Double(treble)
            manager.setEQ(bass: bass, mid: mid, treble: treble)
        }) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? bgColor : textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(isSelected ? accentGreen : cardColor)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("EQ preset: \(label)\(isSelected ? " (selected)" : "")")
    }

    private func eqSlider(_ label: String, value: Binding<Double>, band: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(textSecondary)
                .frame(width: 42, alignment: .leading)

            Slider(value: value, in: -10...10, step: 1) { editing in
                if !editing {
                    manager.setEQ(
                        bass: Int(eqBass),
                        mid: Int(eqMid),
                        treble: Int(eqTreble)
                    )
                }
            }
            .accentColor(accentGreen)
            .accessibilityLabel("\(label) equalizer")
            .accessibilityValue("\(Int(value.wrappedValue))")

            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textPrimary)
                .frame(width: 24, alignment: .trailing)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        DisclosureGroup(
            isExpanded: $showSettings,
            content: {
                VStack(spacing: 10) {
                    // Device name
                    HStack {
                        Text("Name")
                            .font(.system(size: 12))
                            .foregroundColor(textSecondary)
                        Spacer()
                        if editingName {
                            HStack(spacing: 4) {
                                TextField("Name", text: $nameField)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundColor(textPrimary)
                                    .frame(width: 120)
                                    .padding(4)
                                    .background(cardColor)
                                    .cornerRadius(4)
                                    .onSubmit {
                                        manager.setDeviceName(nameField)
                                        editingName = false
                                    }
                                    .accessibilityLabel("Device name text field")
                                    .accessibilityIdentifier("device-name-field")
                                Button("Save") {
                                    manager.setDeviceName(nameField)
                                    editingName = false
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(accentGreen)
                                .accessibilityLabel("Save device name")
                                .accessibilityIdentifier("save-device-name")
                            }
                        } else {
                            Button(action: {
                                nameField = manager.deviceName
                                editingName = true
                            }) {
                                Text(manager.deviceName)
                                    .font(.system(size: 12))
                                    .foregroundColor(textPrimary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit device name: \(manager.deviceName)")
                            .accessibilityIdentifier("edit-device-name")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Device name setting")

                    // Multipoint toggle
                    HStack {
                        Text("Multipoint")
                            .font(.system(size: 12))
                            .foregroundColor(textSecondary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { manager.multipointEnabled },
                            set: { manager.setMultipoint($0) }
                        ))
                        .toggleStyle(.switch)
                        .scaleEffect(0.7)
                        .frame(width: 40)
                        .accessibilityLabel("Multipoint toggle, \(manager.multipointEnabled ? "enabled" : "disabled")")
                        .accessibilityIdentifier("multipoint-toggle")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Multipoint setting")

                    // Auto-off timer
                    settingsRow("Auto-off", value: manager.autoOffTimer.isEmpty ? "-" : manager.autoOffTimer)
                        .accessibilityLabel("Auto-off timer: \(manager.autoOffTimer.isEmpty ? "not set" : manager.autoOffTimer)")

                    // CNC Level (custom ANC depth)
                    HStack(spacing: 8) {
                        Text("ANC Depth")
                            .font(.system(size: 12))
                            .foregroundColor(textSecondary)
                            .frame(width: 65, alignment: .leading)

                        Slider(value: $cncSliderValue, in: 0...10, step: 1) { editing in
                            if !editing {
                                manager.setCncLevel(Int(cncSliderValue))
                            }
                        }
                        .accentColor(accentGreen)

                        Text("\(Int(cncSliderValue))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textPrimary)
                            .frame(width: 20, alignment: .trailing)
                    }
                    .accessibilityLabel("ANC depth: \(Int(cncSliderValue))")

                    // Wear detection
                    HStack {
                        Text("Wear Detection")
                            .font(.system(size: 12))
                            .foregroundColor(textSecondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(manager.onHead ? accentGreen : .orange)
                                .frame(width: 6, height: 6)
                            Text(manager.onHead ? "On head" : "Off head")
                                .font(.system(size: 12))
                                .foregroundColor(textPrimary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Wear detection: \(manager.onHead ? "on head" : "off head")")

                }
                .padding(.top, 8)
            },
            label: {
                sectionLabel("SETTINGS")
            }
        )
        .accentColor(textSecondary)
        .accessibilityLabel("Settings section, \(showSettings ? "expanded" : "collapsed")")
        .accessibilityIdentifier("settings-disclosure")
    }

    // MARK: - Info

    private var infoSection: some View {
        DisclosureGroup(
            isExpanded: $showInfo,
            content: {
                VStack(spacing: 8) {
                    infoRow("Firmware", value: manager.firmware)
                        .accessibilityLabel("Firmware: \(manager.firmware.isEmpty ? "unknown" : manager.firmware)")
                    infoRow("Serial", value: manager.serialNumber)
                        .accessibilityLabel("Serial number: \(manager.serialNumber.isEmpty ? "unknown" : manager.serialNumber)")
                    infoRow("Product", value: manager.productName)
                        .accessibilityLabel("Product: \(manager.productName.isEmpty ? "unknown" : manager.productName)")
                    infoRow("Platform", value: manager.platform)
                        .accessibilityLabel("Platform: \(manager.platform.isEmpty ? "unknown" : manager.platform)")
                    infoRow("Codename", value: manager.codename)
                        .accessibilityLabel("Codename: \(manager.codename.isEmpty ? "unknown" : manager.codename)")
                    infoRow("Codec", value: manager.audioCodec)
                        .accessibilityLabel("Audio codec: \(manager.audioCodec.isEmpty ? "unknown" : manager.audioCodec)")
                    infoRow("MAC", value: "E4:58:BC:C0:2F:72")
                        .accessibilityLabel("MAC address: E4:58:BC:C0:2F:72")
                }
                .padding(.top, 8)
            },
            label: {
                sectionLabel("INFO")
            }
        )
        .accentColor(textSecondary)
        .accessibilityLabel("Info section, \(showInfo ? "expanded" : "collapsed")")
        .accessibilityIdentifier("info-disclosure")
    }

    // MARK: - Helpers

    private func syncSliders() {
        volumeSliderValue = Double(manager.volume)
        eqBass = Double(manager.eq.bass)
        eqMid = Double(manager.eq.mid)
        eqTreble = Double(manager.eq.treble)
        cncSliderValue = Double(manager.cncLevel)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(textSecondary)
            .tracking(1)
    }

    private func settingsRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(textPrimary)
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(textSecondary)
            Spacer()
            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
