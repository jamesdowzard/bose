/// BoseManager: Observable state for the windowed Bose app.
///
/// This is a THIN FRONT-END over `bose-ctl` — exactly like the Raycast commands and
/// the Hammerspoon module. It holds NO RFCOMM channel, imports NO IOBluetooth, and
/// runs NO timer. Every read shells `bose-ctl info --json`; every write shells the
/// matching verb. Reads happen only on explicit events (window open, window focus,
/// after a write, manual ⌘R) — never on a poll. The v1 BoseManager's 10 s poll
/// timer was the audio-dropout root cause (#69-era); this design makes that class of
/// bug structurally impossible here, and inherits every CLI fix (incl. #83) for free.

import Foundation
import Combine

final class BoseManager: ObservableObject {

    // MARK: - Published State (bound by ContentView)

    @Published var isConnected: Bool = false
    @Published var batteryLevel: Int = 0
    @Published var batteryCharging: Bool = false
    @Published var ancMode: Int = 0          // 0=quiet 1=aware 2=custom1 3=custom2
    @Published var volume: Int = 0
    @Published var volumeMax: Int = 31
    @Published var deviceName: String = "verBosita"
    @Published var firmware: String = ""
    @Published var multipointEnabled: Bool = false
    @Published var cncLevel: Int = 0         // ANC depth 0–10
    @Published var onHead: Bool = false
    @Published var eq: (bass: Int, mid: Int, treble: Int) = (0, 0, 0)
    @Published var isRefreshing: Bool = false

    // Device routing states: "active" / "connected" / "offline"
    @Published var deviceStates: [String: String] = [
        "mac": "offline", "phone": "offline", "ipad": "offline",
        "iphone": "offline", "tv": "offline", "quest": "offline",
    ]

    // MARK: - Private

    /// Serial queue: one `bose-ctl` invocation at a time (RFCOMM is single-session;
    /// serialising here mirrors the CLI's own serial channel discipline).
    private let queue = DispatchQueue(label: "com.jamesdowzard.bose-control.cli")

    /// Resolve the engine: $BOSE_CTL → ~/bin/bose-ctl → repo cli/build/bose-ctl.
    private static func resolveBinary() -> String {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["BOSE_CTL"], fm.isExecutableFile(atPath: env) {
            return env
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/bin/bose-ctl",
            "\(home)/code/personal/bose/cli/build/bose-ctl",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "\(home)/bin/bose-ctl"
    }

    private lazy var binary: String = Self.resolveBinary()

    // MARK: - Process runner

    /// Run `bose-ctl <args>` synchronously (caller is already off the main thread).
    /// Returns (exitCode, stdout). A spawn failure returns (-1, "").
    @discardableResult
    private func run(_ args: [String]) -> (code: Int32, out: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Read

    /// Read full state via `info --json` and publish it. Event-driven only.
    func refreshState() {
        DispatchQueue.main.async { self.isRefreshing = true }
        queue.async { [weak self] in
            guard let self = self else { return }
            let (_, out) = self.run(["info", "--json"])
            let parsed = Self.parse(out)
            DispatchQueue.main.async {
                self.apply(parsed)
                self.isRefreshing = false
            }
        }
    }

    /// Decode the `info --json` payload. Returns nil-equivalent (connected=false) on
    /// any failure so the UI shows the disconnected state rather than stale values.
    private static func parse(_ out: String) -> [String: Any] {
        guard let data = out.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return ["connected": false] }
        return obj
    }

    /// Apply a decoded snapshot to published properties. Must run on the main thread.
    private func apply(_ s: [String: Any]) {
        let connected = (s["connected"] as? Bool) ?? false
        isConnected = connected
        guard connected else {
            for k in deviceStates.keys { deviceStates[k] = "offline" }
            return
        }
        batteryLevel = (s["batteryLevel"] as? Int) ?? batteryLevel
        batteryCharging = (s["batteryCharging"] as? Bool) ?? false
        ancMode = (s["ancMode"] as? Int) ?? ancMode
        cncLevel = (s["ancDepth"] as? Int) ?? cncLevel
        volume = (s["volume"] as? Int) ?? volume
        volumeMax = (s["volumeMax"] as? Int) ?? volumeMax
        multipointEnabled = (s["multipoint"] as? Bool) ?? false
        onHead = (s["onHead"] as? Bool) ?? false
        if let name = s["deviceName"] as? String, !name.isEmpty { deviceName = name }
        if let fw = s["firmware"] as? String { firmware = fw }
        if let e = s["eq"] as? [String: Any] {
            eq = (bass: (e["bass"] as? Int) ?? 0,
                  mid: (e["mid"] as? Int) ?? 0,
                  treble: (e["treble"] as? Int) ?? 0)
        }
        if let d = s["devices"] as? [String: String] {
            for (name, state) in d { deviceStates[name] = state }
        }
    }

    // MARK: - Write (each: run verb, optimistic local update, then re-read)

    func setAncMode(_ mode: Int) {
        let names = ["quiet", "aware", "custom1", "custom2"]
        guard names.indices.contains(mode) else { return }
        ancMode = mode
        write(["anc", names[mode]])
    }

    func setVolume(_ level: Int) {
        let clamped = max(0, min(volumeMax, level))
        volume = clamped
        write(["volume", String(clamped)])
    }

    func setEQ(bass: Int, mid: Int, treble: Int) {
        eq = (bass: bass, mid: mid, treble: treble)
        write(["eq", String(bass), String(mid), String(treble)])
    }

    func setMultipoint(_ enabled: Bool) {
        multipointEnabled = enabled
        write(["multipoint", enabled ? "on" : "off"])
    }

    /// ANC depth (CNC level 0–10). Note: exercises the #83 RMW path on hardware.
    func setCncLevel(_ level: Int) {
        let clamped = max(0, min(10, level))
        cncLevel = clamped
        write(["anc-depth", String(clamped)])
    }

    func connectDevice(_ name: String) {
        write(["connect", name])
    }

    func applyProfile(_ name: String) {
        write(["profile", name])
    }

    /// Run a write verb off the main thread, then refresh to reflect the device's
    /// real post-write state (the optimistic update above is just for snappiness).
    private func write(_ args: [String]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = self.run(args)
            self.refreshState()
        }
    }

    // MARK: - Computed

    var ancModeName: String {
        ["Quiet", "Aware", "Custom 1", "Custom 2"][safe: ancMode] ?? "Unknown"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
