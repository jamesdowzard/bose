/// PopoverView: Main SwiftUI interface shown from menu bar click or Option+B.
/// Dark theme, ~320px wide, sections: header, devices, ANC, volume, settings, info.

import SwiftUI

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

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                headerSection
                if manager.isConnected {
                    devicesSection
                    ancSection
                    volumeSection
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
        .onAppear {
            volumeSliderValue = Double(manager.volume)
        }
        .onChange(of: manager.volume) { newValue in
            volumeSliderValue = Double(newValue)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.deviceName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textPrimary)

                if manager.isConnected {
                    HStack(spacing: 6) {
                        batteryView
                        if manager.isRefreshing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        }
                    }
                } else {
                    Text("Disconnected")
                        .font(.system(size: 12))
                        .foregroundColor(textSecondary)
                }
            }

            Spacer()

            if manager.isConnected {
                ancPill
            }
        }
        .padding(.bottom, 4)
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
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 40))
                .foregroundColor(textSecondary)
            Text("Headphones not connected")
                .font(.system(size: 13))
                .foregroundColor(textSecondary)
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
        }
        .padding(.vertical, 20)
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
    }

    private func deviceButton(_ device: DeviceButton) -> some View {
        let state = manager.deviceStates[device.id] ?? "offline"

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
    }

    private func ancButton(_ label: String, mode: Int) -> some View {
        let isSelected = manager.ancMode == mode

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
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 11))
                    .foregroundColor(textSecondary)

                Slider(value: $volumeSliderValue, in: 0...Double(manager.volumeMax), step: 1) { editing in
                    if !editing {
                        manager.setVolume(Int(volumeSliderValue))
                    }
                }
                .accentColor(accentGreen)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 11))
                    .foregroundColor(textSecondary)
            }
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
                                Button("Save") {
                                    manager.setDeviceName(nameField)
                                    editingName = false
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(accentGreen)
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
                        }
                    }

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
                    }

                    // Auto-off timer
                    settingsRow("Auto-off", value: manager.autoOffTimer.isEmpty ? "-" : manager.autoOffTimer)

                    // Immersion level
                    settingsRow("Immersion", value: manager.immersionLevel.isEmpty ? "-" : manager.immersionLevel)

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

                    // EQ
                    HStack {
                        Text("EQ")
                            .font(.system(size: 12))
                            .foregroundColor(textSecondary)
                        Spacer()
                        Text("B:\(manager.eq.bass) M:\(manager.eq.mid) T:\(manager.eq.treble)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textPrimary)
                    }
                }
                .padding(.top, 8)
            },
            label: {
                sectionLabel("SETTINGS")
            }
        )
        .accentColor(textSecondary)
    }

    // MARK: - Info

    private var infoSection: some View {
        DisclosureGroup(
            isExpanded: $showInfo,
            content: {
                VStack(spacing: 8) {
                    infoRow("Firmware", value: manager.firmware)
                    infoRow("Serial", value: manager.serialNumber)
                    infoRow("Product", value: manager.productName)
                    infoRow("Platform", value: manager.platform)
                    infoRow("Codename", value: manager.codename)
                    infoRow("Codec", value: manager.audioCodec)
                    infoRow("MAC", value: "E4:58:BC:C0:2F:72")
                }
                .padding(.top, 8)
            },
            label: {
                sectionLabel("INFO")
            }
        )
        .accentColor(textSecondary)
    }

    // MARK: - Helpers

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
