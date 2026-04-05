/// BoseManager: Observable state manager for Bose QC Ultra 2 headphones.
/// Handles polling, auto-reconnect, and all BMAP command dispatch.

import Foundation
import Combine

class BoseManager: ObservableObject {

    // MARK: - Published State

    @Published var isConnected: Bool = false
    @Published var batteryLevel: Int = 0
    @Published var batteryCharging: Bool = false
    @Published var ancMode: Int = 0  // 0=quiet, 1=aware, 2=custom1, 3=custom2
    @Published var volume: Int = 0
    @Published var volumeMax: Int = 31
    @Published var deviceName: String = "verBosita"
    @Published var firmware: String = ""
    @Published var serialNumber: String = ""
    @Published var productName: String = ""
    @Published var platform: String = ""
    @Published var codename: String = ""
    @Published var audioCodec: String = ""
    @Published var multipointEnabled: Bool = false
    @Published var autoOffTimer: String = ""
    @Published var immersionLevel: String = ""
    @Published var cncLevel: Int = 0
    @Published var onHead: Bool = false
    @Published var eq: (bass: Int, mid: Int, treble: Int) = (0, 0, 0)

    // Device connection states: "active", "connected", "offline"
    @Published var deviceStates: [String: String] = [
        "phone": "offline",
        "mac": "offline",
        "ipad": "offline",
        "iphone": "offline",
        "tv": "offline",
    ]

    @Published var isRefreshing: Bool = false

    /// Callback for AppDelegate to update menu bar display
    var onStateChange: (() -> Void)?

    // MARK: - Private

    private var bose: BoseRFCOMM?
    private var boseReady = false
    private let rfcommQueue = DispatchQueue(label: "com.jamesdowzard.bose-control.rfcomm")
    private var pollTimer: Timer?
    private var reconnectTimer: Timer?
    private var disconnectedAt: Date?
    private let reconnectWindow: TimeInterval = 30.0
    private let reconnectInterval: TimeInterval = 3.0
    private let pollInterval: TimeInterval = 10.0

    private let blueutil = "/opt/homebrew/bin/blueutil"
    private let boseMac = "E4:58:BC:C0:2F:72"

    // MARK: - Polling

    func startPolling() {
        // Init BoseRFCOMM off main thread (BTReadyWaiter + SDP warmup blocks for ~6s)
        rfcommQueue.async { [weak self] in
            guard let self = self else { return }
            self.bose = BoseRFCOMM()
            self.boseReady = true
        }

        // Initial check
        checkConnectionAndRefresh()

        // Poll every 10 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkConnectionAndRefresh()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    // MARK: - Connection Check

    private func checkConnectionAndRefresh() {
        rfcommQueue.async { [weak self] in
            guard let self = self else { return }
            let connected = self.isBluetoothConnected()

            if connected && self.boseReady, let bose = self.bose {
                let state = bose.getAllState()
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.disconnectedAt = nil
                    self.reconnectTimer?.invalidate()
                    self.reconnectTimer = nil
                    self.applyState(state)
                }
            } else {
                DispatchQueue.main.async {
                    let wasConnected = self.isConnected
                    self.isConnected = connected

                    if !connected {
                        if wasConnected && self.disconnectedAt == nil {
                            self.disconnectedAt = Date()
                            self.startReconnectTimer()
                        }
                        for key in self.deviceStates.keys {
                            self.deviceStates[key] = "offline"
                        }
                    }

                    self.onStateChange?()
                }
            }
        }
    }

    // MARK: - Auto-Reconnect

    private func startReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            if let disconnectTime = self.disconnectedAt {
                let elapsed = Date().timeIntervalSince(disconnectTime)
                if elapsed >= self.reconnectWindow {
                    // Window expired — stop trying
                    timer.invalidate()
                    self.reconnectTimer = nil
                    self.disconnectedAt = nil
                    return
                }
            }

            // Try reconnect
            self.rfcommQueue.async {
                self.btConnect()
            }
        }
    }

    // MARK: - State Refresh

    func refreshState() {
        DispatchQueue.main.async { self.isRefreshing = true }
        rfcommQueue.async { [weak self] in
            guard let self = self else { return }

            let connected = self.isBluetoothConnected()
            if connected && self.boseReady {
                // fetchAllState dispatches to rfcommQueue — but we're already on it,
                // so inline the work here to avoid deadlock
                guard let bose = self.bose else { return }
                let state = bose.getAllState()
                DispatchQueue.main.async {
                    self.applyState(state)
                }
            } else {
                DispatchQueue.main.async {
                    self.isConnected = connected
                    if !connected {
                        for key in self.deviceStates.keys {
                            self.deviceStates[key] = "offline"
                        }
                    }
                    self.isRefreshing = false
                    self.onStateChange?()
                }
            }
        }
    }

    /// Called from rfcommQueue — dispatches to rfcommQueue for RFCOMM work.
    private func fetchAllState() {
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            let state = bose.getAllState()
            DispatchQueue.main.async {
                self.applyState(state)
            }
        }
    }

    /// Apply headphone state snapshot to published properties. Must be called on main thread.
    private func applyState(_ state: BoseRFCOMM.HeadphoneState?) {
        guard let bose = self.bose else {
            self.isRefreshing = false
            return
        }

        if let s = state {
            self.batteryLevel = s.batteryLevel
            self.batteryCharging = s.batteryCharging
            self.ancMode = s.ancMode
            self.volume = s.volume
            self.volumeMax = s.volumeMax
            self.firmware = s.firmware
            self.serialNumber = s.serialNumber
            self.productName = s.productName
            self.platform = s.platform
            self.codename = s.codename
            self.audioCodec = s.audioCodec
            self.deviceName = s.deviceName.isEmpty ? "verBosita" : s.deviceName
            self.multipointEnabled = s.multipointEnabled
            self.onHead = s.onHead
            self.eq = s.eq
            self.isConnected = true

            // Parse auto-off timer
            if !s.autoOffTimer.isEmpty {
                let minutes = s.autoOffTimer.count >= 2
                    ? Int(s.autoOffTimer[0]) * 256 + Int(s.autoOffTimer[1])
                    : Int(s.autoOffTimer[0])
                if minutes == 0 {
                    self.autoOffTimer = "Never"
                } else {
                    self.autoOffTimer = "\(minutes) min"
                }
            }

            // Parse immersion level
            if !s.immersionLevel.isEmpty {
                self.immersionLevel = s.immersionLevel
                    .map { String(format: "%02X", $0) }.joined(separator: " ")
            }

            // Build device states: audio-connected = active, ACL-only = connected
            var newStates: [String: String] = [:]
            for key in self.deviceStates.keys {
                newStates[key] = "offline"
            }

            let audioMacs = Set(s.connectedDevices.map { bose.macToString($0) })
            let aclMacs = Set(s.aclConnectedDevices.map { bose.macToString($0) })

            for (name, mac) in boseKnownDevices {
                let macStr = bose.macToString(mac)
                if audioMacs.contains(macStr) {
                    newStates[name] = "active"
                } else if aclMacs.contains(macStr) {
                    newStates[name] = "connected"
                } else {
                    newStates[name] = "offline"
                }
            }
            self.deviceStates = newStates
        } else {
            self.isConnected = false
        }

        self.isRefreshing = false
        self.onStateChange?()
    }

    // MARK: - Commands

    func setAncMode(_ mode: Int) {
        let modeNames = ["quiet", "aware", "custom1", "custom2"]
        guard mode >= 0 && mode < modeNames.count else { return }
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            let success = bose.setAncMode(modeNames[mode])
            if success {
                DispatchQueue.main.async {
                    self.ancMode = mode
                    self.onStateChange?()
                }
            }
        }
    }

    func setVolume(_ level: Int) {
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            let success = bose.setVolume(level)
            if success {
                DispatchQueue.main.async {
                    self.volume = level
                    self.onStateChange?()
                }
            }
        }
    }

    func connectDevice(_ name: String) {
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            guard let mac = bose.macForName(name) else { return }

            // If connecting Mac, blueutil connect first for A2DP
            if name == "mac" {
                self.runBlueutil(["--connect", self.boseMac])
                Thread.sleep(forTimeInterval: 1.5)
            }

            let success = bose.connectDevice(mac)
            if success {
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async {
                    self.refreshState()
                }
            }
        }
    }

    func disconnectDevice(_ name: String) {
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            guard let mac = bose.macForName(name) else { return }

            let success = bose.disconnectDevice(mac)
            if success {
                if name == "mac" {
                    self.runBlueutil(["--disconnect", self.boseMac])
                }
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async {
                    self.refreshState()
                }
            }
        }
    }

    func sendMediaControl(_ action: UInt8) {
        rfcommQueue.async { [weak self] in
            guard let bose = self?.bose else { return }
            _ = bose.sendMediaControl(action)
        }
    }

    func setDeviceName(_ name: String) {
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            let success = bose.setDeviceName(name)
            if success {
                DispatchQueue.main.async {
                    self.deviceName = name
                }
            }
        }
    }

    func setEQ(bass: Int, mid: Int, treble: Int) {
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            let success = bose.setEQ(bass: bass, mid: mid, treble: treble)
            if success {
                DispatchQueue.main.async {
                    self.eq = (bass: bass, mid: mid, treble: treble)
                    self.onStateChange?()
                }
            }
        }
    }

    func setMultipoint(_ enabled: Bool) {
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            let success = bose.setMultipoint(enabled)
            if success {
                DispatchQueue.main.async {
                    self.multipointEnabled = enabled
                }
            }
        }
    }

    func setCncLevel(_ level: Int) {
        rfcommQueue.async { [weak self] in
            guard let self = self, let bose = self.bose else { return }
            let success = bose.setCncLevel(level)
            if success {
                DispatchQueue.main.async {
                    self.cncLevel = level
                    self.onStateChange?()
                }
            }
        }
    }

    // MARK: - Bluetooth Helpers

    private func isBluetoothConnected() -> Bool {
        let (status, output) = runBlueutil(["--is-connected", boseMac])
        return status == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func btConnect() {
        runBlueutil(["--connect", boseMac])
    }

    @discardableResult
    private func runBlueutil(_ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: blueutil)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (proc.terminationStatus, output)
        } catch {
            return (1, "")
        }
    }

    // MARK: - Computed Properties

    var ancModeName: String {
        switch ancMode {
        case 0: return "Quiet"
        case 1: return "Aware"
        case 2: return "Custom 1"
        case 3: return "Custom 2"
        default: return "Unknown"
        }
    }
}
