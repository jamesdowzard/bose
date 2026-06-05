/// BoseManager: observable state for the menu-bar app. EVENT-DRIVEN ONLY.
///
/// CORRECTNESS CONTRACT (the whole reason for the v2 rebuild):
///   1. NO background polling. There is NO `Timer` here. State refreshes ONLY on
///      menu-open (`refresh()`) and on IOBluetooth connect/disconnect notifications.
///      Re-introducing a repeating RFCOMM poll caused the audio dropouts.
///   2. `connectDevice` confirms by polling `getConnectedDevices` until the target
///      MAC appears in the audio-active list (~16s timeout). ACK is NEVER success.
///   3. All RFCOMM access is serialised by `Transport.queue` (one channel per command).
///   4. The app idles silently when the Mac isn't the active source — it only ever
///      touches the link on an explicit user action or a menu-open refresh.
///
/// All command frames come from the generated `BMAP` builders / `Devices.generated`
/// device map. Composite read-modify-write / list parsing lives in `Composites.swift`.

import Foundation
import Combine
import IOBluetooth

@MainActor
final class BoseManager: ObservableObject {

    // MARK: Published state
    @Published var isConnected = false
    @Published var isRefreshing = false
    @Published var batteryLevel = 0
    @Published var batteryCharging = false
    @Published var ancMode = 0
    @Published var volume = 0
    @Published var volumeMax = 31
    @Published var deviceName = Headphone.name
    @Published var firmware = ""
    @Published var serialNumber = ""
    @Published var productName = ""
    @Published var audioCodec = ""
    @Published var multipointEnabled = false
    @Published var autoOffTimer = ""
    @Published var cncLevel = 0
    @Published var onHead = false
    @Published var eq: (bass: Int, mid: Int, treble: Int) = (0, 0, 0)

    /// Per-device control state. "active" = audio routed here, "connecting" = a
    /// connectDevice is in flight + being poll-confirmed, "offline" = not active.
    @Published var deviceStates: [String: String] = {
        var d: [String: String] = [:]
        for dev in BoseDeviceMap.knownDevices { d[dev.name] = "offline" }
        return d
    }()

    private let transport = Transport()
    /// Off-main work queue for blocking RFCOMM calls. Distinct from
    /// `Transport.queue` (the per-command serial lane) so calling a transport
    /// method here never re-enters that queue's `sync` (which would deadlock).
    private let work = DispatchQueue(label: "com.jamesdowzard.bose-control.manager")
    private var connectNotification: IOBluetoothUserNotification?

    init() {
        registerBluetoothNotifications()
    }

    deinit {
        connectNotification?.unregister()
    }

    // MARK: Event-driven triggers (NO Timer)

    /// Register for IOBluetooth ACL connect + per-device disconnect notifications.
    /// These are the ONLY automatic refresh triggers besides menu-open.
    private func registerBluetoothNotifications() {
        // Global connect notification — fires for ANY device connecting; we filter
        // to the headphones inside the handler.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:)))
    }

    @objc private nonisolated func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.addressString?.uppercased() == Headphone.dashMac.uppercased() else { return }
        // Headphones just connected to this Mac — refresh, and arm a disconnect watch.
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        Task { await self.refresh() }
    }

    @objc private nonisolated func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.addressString?.uppercased() == Headphone.dashMac.uppercased() else { return }
        Task { @MainActor in
            self.isConnected = false
            for k in self.deviceStates.keys { self.deviceStates[k] = "offline" }
        }
    }

    // MARK: Refresh (menu-open + BT events only)

    /// Pull a full state snapshot in one RFCOMM session. Only ever called on
    /// menu-open or a BT connect notification — never on a timer.
    func refresh() async {
        isRefreshing = true
        let connected = transport.isHeadphoneConnected()
        guard connected else {
            isConnected = false
            for k in deviceStates.keys { deviceStates[k] = "offline" }
            isRefreshing = false
            return
        }
        let state = await withCheckedContinuation { (cont: CheckedContinuation<HeadphoneState?, Never>) in
            work.async { [transport] in cont.resume(returning: transport.getAllState()) }
        }
        apply(state)
        isRefreshing = false
    }

    private func apply(_ state: HeadphoneState?) {
        guard let s = state else { isConnected = false; return }
        isConnected = true
        batteryLevel = s.batteryLevel
        batteryCharging = s.batteryCharging
        ancMode = s.ancMode
        volume = s.volume
        volumeMax = s.volumeMax
        firmware = s.firmware
        serialNumber = s.serialNumber
        productName = s.productName
        audioCodec = s.audioCodec
        deviceName = s.deviceName.isEmpty ? Headphone.name : s.deviceName
        multipointEnabled = s.multipointEnabled
        cncLevel = s.cncLevel
        onHead = s.onHead
        eq = s.eq

        if !s.autoOffTimer.isEmpty {
            let mins = s.autoOffTimer.count >= 2
                ? Int(s.autoOffTimer[0]) * 256 + Int(s.autoOffTimer[1])
                : Int(s.autoOffTimer[0])
            autoOffTimer = mins == 0 ? "Never" : "\(mins) min"
        }

        // Build device states from the audio-active ground-truth list (05,01).
        let activeMacs = Set(s.connectedDevices.map { macString($0) })
        var newStates: [String: String] = [:]
        for dev in BoseDeviceMap.knownDevices {
            // Preserve an in-flight "connecting" so a refresh mid-connect doesn't flicker.
            if deviceStates[dev.name] == "connecting" && !activeMacs.contains(dev.macString) {
                newStates[dev.name] = "connecting"
            } else {
                newStates[dev.name] = activeMacs.contains(dev.macString) ? "active" : "offline"
            }
        }
        deviceStates = newStates
    }

    private func macString(_ mac: [UInt8]) -> String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Commands (generated builders)

    func setAncMode(_ mode: Int) {
        guard (0...3).contains(mode) else { return }
        runCommand(BMAP.setAncMode(mode: UInt8(mode))) { self.ancMode = mode }
    }

    func setVolume(_ level: Int) {
        let v = max(0, min(volumeMax, level))
        runCommand(BMAP.setVolume(level: UInt8(v))) { self.volume = v }
    }

    func setEQ(bass: Int, mid: Int, treble: Int) {
        // Each band is its own SET_GET; issue all three in one RFCOMM session.
        let bands: [(UInt8, Int8)] = [(0, Int8(clamping: bass)), (1, Int8(clamping: mid)), (2, Int8(clamping: treble))]
        offload { transport in
            let ok: Bool? = transport.session { ch, t in
                for (band, value) in bands { _ = t.send(ch, BMAP.setEqBand(value: value, band: band)) }
                return true
            }
            return ok ?? false
        } onSuccess: { self.eq = (bass: bass, mid: mid, treble: treble) }
    }

    func setMultipoint(_ enabled: Bool) {
        runCommand(BMAP.setMultipoint(state: enabled ? 0x07 : 0x00)) { self.multipointEnabled = enabled }
    }

    func setCncLevel(_ level: Int) {
        let l = max(0, min(10, level))
        offload { $0.setCncLevel(l) } onSuccess: { self.cncLevel = l }
    }

    func sendMediaControl(_ action: UInt8) {
        offload { $0.oneShot(BMAP.mediaControl(action: action)) != nil } onSuccess: {}
    }

    func setDeviceName(_ name: String) {
        guard let body = name.data(using: .utf8), body.count <= 30 else { return }
        // Device-name frame is structural (length-prefixed UTF-8) — the generator
        // can't express a variable-length string payload, so assemble it here:
        // `01,02,06,{len+1},00,{utf8}` (SET).
        var frame: [UInt8] = [0x01, 0x02, 0x06, UInt8(body.count + 1), 0x00]
        frame.append(contentsOf: Array(body))
        runCommand(frame) { self.deviceName = name }
    }

    func disconnectDevice(_ name: String) {
        guard let mac = BoseDeviceMap.mac(name) else { return }
        work.async { [transport] in
            _ = transport.oneShot(BMAP.disconnectDevice(mac: mac))
            Task { @MainActor in await self.refresh() }
        }
    }

    // MARK: connectDevice — poll-confirm (ACK is NOT success)

    /// Switch audio to `name`. Sends connectDevice, then polls getConnectedDevices
    /// until the target MAC is audio-active (timeout ~16s). The device shows
    /// "connecting" throughout, then "active" on success or reverts on failure.
    /// All blocking work runs on the manager work queue (NOT a Timer).
    func connectDevice(_ name: String) {
        guard let dev = BoseDeviceMap.device(name) else { return }
        deviceStates[name] = "connecting"

        work.async { [transport] in
            // For the Mac itself, ensure A2DP first (Samsung/macOS link), like v1.
            if name == "mac" {
                runBlueutil(["--connect", Headphone.mac])
                Thread.sleep(forTimeInterval: 1.5)
            }

            _ = transport.oneShot(BMAP.connectDevice(mac: dev.mac), timeout: 5.0)

            // Poll-confirm: ACK means "received", not "connected". Only the audio-
            // active list is ground truth. ~16s budget (offline devices page slowly).
            let target = dev.macString
            var confirmed = false
            let deadline = Date().addingTimeInterval(16.0)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 1.5)
                let active = transport.getConnectedDevices().map {
                    $0.map { b in String(format: "%02X", b) }.joined(separator: ":")
                }
                if active.contains(target) { confirmed = true; break }
            }

            let didConfirm = confirmed
            Task { @MainActor in
                if didConfirm {
                    self.deviceStates[name] = "active"
                } else if self.deviceStates[name] == "connecting" {
                    self.deviceStates[name] = "offline"  // revert; not optimistic-silent
                }
                await self.refresh()
            }
        }
    }

    // MARK: Helpers

    /// Fire-and-forget a single generated frame on the serial queue; apply
    /// `onSuccess` on the main actor if the device replied.
    private func runCommand(_ frame: [UInt8], onSuccess: @escaping @MainActor () -> Void) {
        offload { $0.oneShot(frame) != nil } onSuccess: { onSuccess() }
    }

    /// Run blocking transport `body` on the manager work queue; if it returns true,
    /// hop to the main actor and run `onSuccess`.
    private func offload(_ body: @escaping (Transport) -> Bool,
                         onSuccess: @escaping @MainActor () -> Void) {
        work.async { [transport] in
            let ok = body(transport)
            if ok { Task { @MainActor in onSuccess() } }
        }
    }

    var ancModeName: String {
        ["Quiet", "Aware", "Custom 1", "Custom 2"][safe: ancMode] ?? "Unknown"
    }

    /// Cycle to the next device in the devices.toml cycle order, relative to the
    /// current audio-active device (global hotkey target).
    func cycleNextDevice() {
        let order = BoseDeviceMap.cycleOrder
        let active = order.firstIndex { deviceStates[$0] == "active" }
        let next = order[((active ?? -1) + 1) % order.count]
        connectDevice(next)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
