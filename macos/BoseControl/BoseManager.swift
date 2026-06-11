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
    @Published var ancMode: Int = 0          // hardware slot: 0=quiet 1=aware 2=immersion 3=cinema 4=custom1 5=custom2
    @Published var volume: Int = 0
    @Published var volumeMax: Int = 31
    @Published var deviceName: String = "verBosita"
    @Published var firmware: String = ""
    @Published var multipointEnabled: Bool = false
    @Published var eq: (bass: Int, mid: Int, treble: Int) = (0, 0, 0)
    @Published var isRefreshing: Bool = false

    // Active mode's noise level (1F,06): 0 = max cancellation … 10 = transparency.
    // `noiseAdjustable` (the firmware cncMutable bit) gates the slider — only custom
    // modes are tunable; Quiet/Aware/spatial modes are fixed. Writing is via the CLI
    // `anc-level`, which refuses on fixed modes, so the slider can't disable ANC (#83).
    @Published var noiseLevel: Int = 0
    @Published var noiseAdjustable: Bool = false
    @Published var modeName: String = ""

    // Device routing states: "active" / "connected" / "offline"
    @Published var deviceStates: [String: String] = [
        "mac": "offline", "phone": "offline", "ipad": "offline",
        "iphone": "offline", "tv": "offline", "quest": "offline",
    ]

    // MARK: - Pending-write state (drives the "applying / connecting" UI)
    //
    // Writes are optimistic AND confirmed. The catch: a `bose-ctl info` read fired on
    // window-open / focus can still be in flight when the user acts, then land a beat
    // later carrying the PRE-change value and revert the optimistic update — the visible
    // flicker (tap Quiet → snaps back to Aware → settles on Quiet). These flags both
    // surface a spinner and let `apply()` reject a stale snapshot until the change lands.

    /// ANC slot awaiting device confirmation (nil when settled). `ancMode` already shows
    /// the optimistic target; this marks it "applying" and protects it from a stale revert.
    @Published var pendingAncMode: Int? = nil

    /// Device tile awaiting a `connect` result (nil when settled) — renders its spinner.
    @Published var connectingDevice: String? = nil

    /// Last device we successfully told the headphones to make the active sink. The
    /// `info` routing probe reports everything "offline" when off-head/idle (the #81
    /// quirk), which would dark out a tile we just confirmed connected — so we trust the
    /// `connect` result over the probe and keep this tile lit until the probe positively
    /// reports a *different* device as active.
    private var assertedActiveDevice: String? = nil

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
        let snapAnc = (s["ancMode"] as? Int) ?? ancMode
        if let pending = pendingAncMode {
            // A mode change is in flight: ignore a snapshot still showing the old mode
            // (an info read that started before the change landed) so it can't revert the
            // optimistic highlight. Once the snapshot agrees, the change has applied —
            // accept it and clear the pending flag.
            if snapAnc == pending { ancMode = pending; pendingAncMode = nil }
        } else {
            ancMode = snapAnc
        }
        volume = (s["volume"] as? Int) ?? volume
        volumeMax = (s["volumeMax"] as? Int) ?? volumeMax
        multipointEnabled = (s["multipoint"] as? Bool) ?? false
        if let name = s["deviceName"] as? String, !name.isEmpty { deviceName = name }
        if let fw = s["firmware"] as? String { firmware = fw }
        if let e = s["eq"] as? [String: Any] {
            eq = (bass: (e["bass"] as? Int) ?? 0,
                  mid: (e["mid"] as? Int) ?? 0,
                  treble: (e["treble"] as? Int) ?? 0)
        }
        if let d = s["devices"] as? [String: String] {
            for (name, state) in d { deviceStates[name] = state }
            // Off-head/idle, the routing probe reports every device "offline" (#81),
            // which would wrongly dark out a device we just confirmed connected. Trust
            // the connect result: keep the asserted tile lit unless the probe positively
            // reports a *different* device as the active sink (a real, external switch).
            if let asserted = assertedActiveDevice {
                if d.contains(where: { $0.key != asserted && $0.value == "active" }) {
                    assertedActiveDevice = nil
                } else if (deviceStates[asserted] ?? "offline") == "offline" {
                    deviceStates[asserted] = "active"
                }
            }
        }
        noiseLevel = (s["noiseLevel"] as? Int) ?? noiseLevel
        noiseAdjustable = (s["noiseAdjustable"] as? Bool) ?? false
        modeName = (s["modeName"] as? String) ?? modeName
    }

    // MARK: - Write (each: run verb, optimistic local update, then re-read)

    /// Activate an ANC mode by hardware slot index (0-5): 0 quiet, 1 aware,
    /// 2 immersion, 3 cinema (fixed), 4/5 custom (adjustable). Passes the bare
    /// slot to `bose-ctl anc <n>` so app and CLI share one numbering; `ancMode`
    /// (read back from `info`) is the same slot index, so button highlighting matches.
    func setAncMode(_ mode: Int) {
        guard (0...5).contains(mode) else { return }
        ancMode = mode            // optimistic highlight
        pendingAncMode = mode      // mark "applying" + reject any stale revert in apply()
        confirmWrite(["anc", String(mode)],
                     confirm: { ($0["ancMode"] as? Int) == mode },
                     onTimeout: { [weak self] in
                         // Write never confirmed (rare — a genuinely failed set). Drop the
                         // pending guard so the next refresh can show the real mode.
                         if self?.pendingAncMode == mode { self?.pendingAncMode = nil }
                     })
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

    /// Set the active mode's noise level (0 = max cancel … 10 = transparency) via the
    /// CLI `anc-level` (the 1F,06 RMW). No-op unless the active mode is adjustable —
    /// the CLI refuses on fixed modes anyway, so ANC can never be disabled here.
    func setNoiseLevel(_ level: Int) {
        guard noiseAdjustable else { return }
        let clamped = max(0, min(10, level))
        noiseLevel = clamped
        write(["anc-level", String(clamped)])
    }

    /// Tell the headphones to make `name` the active sink. The tile shows a spinner
    /// ("Connecting…") for the duration — `bose-ctl connect` poll-confirms internally
    /// (ACK is never success) and can take up to ~15 s paging a sleeping device — then
    /// settles to active/connected from the CLI's result, which we trust over the flaky
    /// off-head routing probe (see `assertedActiveDevice`).
    func connectDevice(_ name: String) {
        guard connectingDevice == nil else { return }   // ignore taps while one is in flight
        connectingDevice = name
        DispatchQueue.main.async { self.isRefreshing = true }
        queue.async { [weak self] in
            guard let self = self else { return }
            let (code, out) = self.run(["connect", name])
            // The CLI prints "Connected <name>" on success, with "(idle …)" when
            // multipoint kept audio on the previous device (ACL up, not the active sink).
            let ok = code == 0 && out.range(of: "connected", options: .caseInsensitive) != nil
            let idle = out.range(of: "(idle", options: .caseInsensitive) != nil
            let snapshot = Self.parse(self.run(["info", "--json"]).out)
            DispatchQueue.main.async {
                if ok { self.assertedActiveDevice = idle ? nil : name }
                self.apply(snapshot)   // refresh battery/EQ/etc; honours the assertion above
                if ok && idle && (self.deviceStates[name] ?? "offline") == "offline" {
                    self.deviceStates[name] = "connected"
                }
                self.connectingDevice = nil
                self.isRefreshing = false
            }
        }
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

    /// Run a write verb, then read `info` a few times until `confirm` reports the new
    /// value has landed (applying each snapshot so the rest of the UI stays fresh). This
    /// is a BOUNDED, self-terminating post-write settle — it returns the instant the
    /// change confirms (almost always the first read) and nothing reschedules it, so it
    /// is NOT the resident poll that caused the #69-era dropout. It closes the window in
    /// which an already-in-flight refresh could leave the optimistic value reverted.
    /// `onTimeout` runs only if the change never confirms (a failed write) so a pending
    /// spinner can't stick forever.
    private func confirmWrite(_ verb: [String],
                              confirm: @escaping ([String: Any]) -> Bool,
                              attempts: Int = 5, gap: TimeInterval = 0.3,
                              onTimeout: @escaping () -> Void) {
        DispatchQueue.main.async { self.isRefreshing = true }
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = self.run(verb)
            for i in 0..<attempts {
                let parsed = Self.parse(self.run(["info", "--json"]).out)
                let ok = confirm(parsed)
                DispatchQueue.main.async {
                    self.apply(parsed)
                    if ok || i == attempts - 1 { self.isRefreshing = false }
                }
                if ok { return }
                if i < attempts - 1 { Thread.sleep(forTimeInterval: gap) }
            }
            DispatchQueue.main.async { onTimeout() }
        }
    }

    // MARK: - Computed

    var ancModeName: String {
        ["Quiet", "Aware", "Immersion", "Cinema", "Custom 1", "Custom 2"][safe: ancMode] ?? "Unknown"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
