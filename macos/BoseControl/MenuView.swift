/// MenuView: the full control surface inside the menu-bar popover.
///
/// Surfaces every protocol capability: device switch (with active/connecting state +
/// poll-confirm feedback), ANC mode, CNC/ANC-depth slider, volume, EQ presets +
/// 3-band sliders, multipoint toggle, media transport, per-device disconnect,
/// rename, and an info readout (firmware/serial/codec/battery/auto-off).

import SwiftUI

struct MenuView: View {
    @ObservedObject var manager: BoseManager

    @State private var volumeSlider = 0.0
    @State private var cncSlider = 0.0
    @State private var eqBass = 0.0
    @State private var eqMid = 0.0
    @State private var eqTreble = 0.0
    @State private var renaming = false
    @State private var newName = ""

    private let symbols: [String: String] = [
        "mac": "laptopcomputer", "phone": "iphone", "ipad": "ipad",
        "iphone": "iphone", "tv": "tv", "quest": "visionpro",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            if manager.isConnected {
                devicesSection
                Divider()
                ancSection
                volumeSection
                cncSection
                Divider()
                eqSection
                Divider()
                togglesAndMedia
                Divider()
                infoSection
            } else {
                disconnectedSection
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear(perform: syncSliders)
        .onReceive(manager.objectWillChange) { _ in
            DispatchQueue.main.async { syncSliders() }
        }
    }

    private func syncSliders() {
        volumeSlider = Double(manager.volume)
        cncSlider = Double(manager.cncLevel)
        eqBass = Double(manager.eq.bass)
        eqMid = Double(manager.eq.mid)
        eqTreble = Double(manager.eq.treble)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "headphones").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(manager.deviceName).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: manager.batteryCharging ? "battery.100.bolt" : "battery.75")
                        .font(.system(size: 10))
                    Text("\(manager.batteryLevel)%")
                        .font(.system(size: 11, design: .monospaced))
                    if !manager.isConnected { Text("· offline").font(.system(size: 10)).foregroundColor(.secondary) }
                }.foregroundColor(.secondary)
            }
            Spacer()
            if manager.isRefreshing { ProgressView().scaleEffect(0.5) }
            Button { Task { await manager.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("DEVICES")
            let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(BoseDeviceMap.knownDevices) { dev in
                    deviceButton(dev)
                }
            }
        }
    }

    private func deviceButton(_ dev: BoseDevice) -> some View {
        let state = manager.deviceStates[dev.name] ?? "offline"
        let active = state == "active"
        let connecting = state == "connecting"
        return Button { manager.connectDevice(dev.name) } label: {
            VStack(spacing: 2) {
                if connecting {
                    ProgressView().scaleEffect(0.5).frame(height: 18)
                } else {
                    Image(systemName: symbols[dev.name] ?? "dot.radiowaves.left.and.right")
                        .font(.system(size: 16))
                }
                Text(dev.name.capitalized).font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(active ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(active ? Color.accentColor : .clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Disconnect") { manager.disconnectDevice(dev.name) } }
        .help(connecting ? "Connecting…" : (active ? "Active source" : "Tap to switch"))
    }

    // MARK: ANC / CNC / Volume

    private var ancSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("NOISE CONTROL")
            HStack(spacing: 4) {
                ancButton("Quiet", 0); ancButton("Aware", 1)
                ancButton("C1", 2); ancButton("C2", 3)
            }
        }
    }

    private func ancButton(_ label: String, _ mode: Int) -> some View {
        Button { manager.setAncMode(mode) } label: {
            Text(label).font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(manager.ancMode == mode ? Color.accentColor : Color.gray.opacity(0.12))
                .foregroundColor(manager.ancMode == mode ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { sectionLabel("VOLUME"); Spacer(); Text("\(Int(volumeSlider))").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }
            Slider(value: $volumeSlider, in: 0...Double(manager.volumeMax)) { editing in
                if !editing { manager.setVolume(Int(volumeSlider)) }
            }
        }
    }

    private var cncSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { sectionLabel("ANC DEPTH"); Spacer(); Text("\(Int(cncSlider))").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }
            Slider(value: $cncSlider, in: 0...10, step: 1) { editing in
                if !editing { manager.setCncLevel(Int(cncSlider)) }
            }
        }
    }

    // MARK: EQ

    private struct Preset { let name: String; let b, m, t: Int }
    private let presets = [
        Preset(name: "Flat", b: 0, m: 0, t: 0),
        Preset(name: "Bass+", b: 6, m: 0, t: -2),
        Preset(name: "Treble+", b: -2, m: 0, t: 6),
        Preset(name: "Vocal", b: -2, m: 4, t: 2),
    ]

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("EQUALIZER")
            HStack(spacing: 4) {
                ForEach(presets, id: \.name) { p in
                    let sel = manager.eq.bass == p.b && manager.eq.mid == p.m && manager.eq.treble == p.t
                    Button {
                        eqBass = Double(p.b); eqMid = Double(p.m); eqTreble = Double(p.t)
                        manager.setEQ(bass: p.b, mid: p.m, treble: p.t)
                    } label: {
                        Text(p.name).font(.system(size: 9, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                            .background(sel ? Color.accentColor : Color.gray.opacity(0.12))
                            .foregroundColor(sel ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                }
            }
            eqBand("Bass", $eqBass)
            eqBand("Mid", $eqMid)
            eqBand("Treble", $eqTreble)
        }
    }

    private func eqBand(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 42, alignment: .leading)
            Slider(value: value, in: -10...10, step: 1) { editing in
                if !editing { manager.setEQ(bass: Int(eqBass), mid: Int(eqMid), treble: Int(eqTreble)) }
            }
            Text("\(Int(value.wrappedValue))").font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary).frame(width: 24, alignment: .trailing)
        }
    }

    // MARK: Multipoint + media

    private var togglesAndMedia: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { manager.multipointEnabled },
                                 set: { manager.setMultipoint($0) })) {
                Text("Multipoint (2 devices)").font(.system(size: 12))
            }.toggleStyle(.switch).controlSize(.mini)

            HStack(spacing: 18) {
                mediaButton("backward.fill", 4)
                mediaButton("playpause.fill", 1)  // play; pause is 2 — playpause toggles via play
                mediaButton("forward.fill", 3)
                Spacer()
                Button { manager.sendMediaControl(2) } label: { Image(systemName: "pause.fill") }
                    .buttonStyle(.borderless).help("Pause")
            }
        }
    }

    private func mediaButton(_ symbol: String, _ action: UInt8) -> some View {
        Button { manager.sendMediaControl(action) } label: {
            Image(systemName: symbol).font(.system(size: 14))
        }.buttonStyle(.borderless)
    }

    // MARK: Info + rename

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("INFO")
            infoRow("Firmware", manager.firmware)
            infoRow("Serial", manager.serialNumber)
            infoRow("Codec", manager.audioCodec)
            infoRow("Auto-off", manager.autoOffTimer)
            infoRow("On head", manager.onHead ? "Yes" : "No")

            if renaming {
                HStack {
                    TextField("Name", text: $newName).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button("Save") { manager.setDeviceName(newName); renaming = false }.font(.system(size: 11))
                }
            } else {
                Button { newName = manager.deviceName; renaming = true } label: {
                    Label("Rename…", systemImage: "pencil").font(.system(size: 11))
                }.buttonStyle(.borderless)
            }
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(v.isEmpty ? "—" : v).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
    }

    // MARK: Disconnected + footer

    private var disconnectedSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "headphones.slash").font(.system(size: 28, weight: .thin)).foregroundColor(.secondary)
            Text("Headphones not connected").font(.system(size: 12)).foregroundColor(.secondary)
            Button("Connect to Mac") { manager.connectDevice("mac") }
        }.frame(maxWidth: .infinity).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("⌃⌥⌘B cycles device").font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.font(.system(size: 11))
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
    }
}
