/// BoseManager: Observable state for the windowed Bose app.
///
/// This is a THIN FRONT-END over `bose` — exactly like the Raycast commands and
/// the Hammerspoon module. It holds NO RFCOMM channel, imports NO IOBluetooth, and
/// runs NO timer. Every read shells `bose info --json`; every write shells the
/// matching verb. Reads happen only on explicit events (window open, window focus,
/// after a write, the banner's Read-live button) — never on a poll. The v1 BoseManager's 10 s poll
/// timer was the audio-dropout root cause (#69-era); this design makes that class of
/// bug structurally impossible here, and inherits every CLI fix (incl. #83) for free.

import Foundation
import Combine

final class BoseManager: ObservableObject {

    // MARK: - Published State (bound by ContentView)

    @Published var isConnected: Bool = false

    /// Whether THIS Mac currently has a link to the headphones (the `reachable` field
    /// of `info --json`). False while painting a cached snapshot — the CLI's
    /// cached-first read (#148) serves the last-good state instantly instead of
    /// paging headphones the Mac isn't connected to (the probe class behind the
    /// #69-era audio dropouts). Drives the staleness banner; `isConnected` keeps
    /// meaning "we have real headphone state to show".
    @Published var reachable: Bool = true

    /// Age of the painted snapshot in seconds (nil when live). From `ageSeconds`.
    @Published var stateAgeSeconds: Int? = nil

    @Published var batteryLevel: Int = 0
    @Published var batteryCharging: Bool = false
    @Published var ancMode: Int = 0          // hardware slot: 0=quiet 1=aware 2=immersion 3=cinema 4=custom1 5=custom2
    @Published var volume: Int = 0
    @Published var volumeMax: Int = 31
    @Published var deviceName: String = "verBosita"
    @Published var firmware: String = ""
    @Published var multipointEnabled: Bool = false
    @Published var autoPlayPause: Bool = false   // 01,18 — pause when removed
    @Published var autoAnswer: Bool = false      // 01,1B — answer call when donned
    @Published var favorites: [Int] = []         // 1F,08 — favourited mode slots (display-only)
    @Published var eq: (bass: Int, mid: Int, treble: Int) = (0, 0, 0)
    @Published var isRefreshing: Bool = false

    // Active mode's noise level (1F,06): 0 = max cancellation … 10 = transparency.
    // `noiseAdjustable` (the firmware cncMutable bit) gates the slider — only custom
    // modes are tunable; Quiet/Aware/spatial modes are fixed. Writing is via the CLI
    // `anc-level`, which refuses on fixed modes, so the slider can't disable ANC (#83).
    @Published var noiseLevel: Int = 0
    @Published var noiseAdjustable: Bool = false
    @Published var modeName: String = ""

    // Active mode's Immersive Audio (spatial) mode: "off" / "still" / "motion" (1F,06
    // payload[44]). `spatialAdjustable` (the firmware spatialMutable bit, payload[41]
    // bit2) gates the control — only the custom modes are settable; named modes carry it
    // fixed (Immersion = Motion, Cinema = Still). Writing is via the CLI `spatial`, which
    // refuses on fixed modes. The global 05,0F function is FuncNotSupp on this firmware.
    @Published var spatial: String = "off"
    @Published var spatialAdjustable: Bool = false

    // Stored names of the two custom slots (1F,06 name field). Empty when unset ("None") —
    // ContentView falls back to "C1"/"C2". Set via the CLI `mode-name`; persists on-device.
    @Published var custom1Name: String = ""
    @Published var custom2Name: String = ""

    // Device routing states: "active" / "connected" / "offline"
    @Published var deviceStates: [String: String] = [
        "mac": "offline", "phone": "offline", "ipad": "offline",
        "iphone": "offline", "tv": "offline", "appletv": "offline", "quest": "offline",
    ]

    // MARK: - Pending-write state (drives the "applying / connecting" UI)
    //
    // Writes are optimistic AND confirmed. The catch: a `bose info` read fired on
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

    /// Serial queue: one `bose` invocation at a time (RFCOMM is single-session;
    /// serialising here mirrors the CLI's own serial channel discipline).
    private let queue = DispatchQueue(label: "com.jamesdowzard.bose-control.cli")

    /// Resolve the engine: $BOSE_CTL → ~/bin/bose → repo cli/build/bose.
    private static func resolveBinary() -> String {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["BOSE_CTL"], fm.isExecutableFile(atPath: env) {
            return env
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/bin/bose",
            "\(home)/code/personal/bose/cli/build/bose",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "\(home)/bin/bose"
    }

    private lazy var binary: String = Self.resolveBinary()

    // MARK: - Optimistic paint (persisted last-good snapshot)

    /// UserDefaults key for the persisted last-good `info` snapshot.
    private let snapshotKey = "bose.lastSnapshot.v1"

    /// Consecutive failed reads (see `apply`). Tolerates one blip before disconnecting.
    private var consecutiveFailures = 0

    /// Paint the last-good snapshot the moment the app launches, so the window shows
    /// real values instead of the "Not Connected" placeholder during the first ~3s
    /// `info` read. It's overwritten as soon as that live read lands. No-op if nothing
    /// is cached or the cached snapshot was itself disconnected.
    init() {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey),
              let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (s["connected"] as? Bool) == true
        else { return }
        apply(s)
    }

    /// Persist a connected snapshot for the next launch's optimistic paint.
    private func persistSnapshot(_ s: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: s) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }

    // MARK: - Process runner

    /// Run `bose <args>` synchronously (caller is already off the main thread).
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
    ///
    /// Default reads are CACHED-FIRST: with no ACL link the CLI serves the last-good
    /// snapshot instantly (zero radio) instead of paging the headphones — so window
    /// open / app focus can never stall on a multi-second page or glitch audio on
    /// another sink. `forcePage: true` (the staleness banner's Read-live button) deliberately pages for a live read.
    func refreshState(forcePage: Bool = false) {
        DispatchQueue.main.async { self.isRefreshing = true }
        queue.async { [weak self] in
            guard let self = self else { return }
            let (_, out) = self.run(["info", "--json"] + (forcePage ? ["--page"] : []))
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
        // `reachable` absent (pre-#148 output) == the old semantics: a connected
        // snapshot was by definition a live read.
        let reach = (s["reachable"] as? Bool) ?? connected
        guard connected else {
            reachable = false
            stateAgeSeconds = nil
            // One transient unreachable `info` read shouldn't wipe a known-good
            // dashboard to "Not Connected". The CLI does a single RFCOMM attempt per
            // command, so an occasional miss when the link is briefly busy is expected,
            // not a real disconnect — tolerate one blip and only fall back to the
            // disconnected view on a SECOND consecutive failure (or if we've never had a
            // good read this session).
            consecutiveFailures += 1
            if isConnected && consecutiveFailures < 2 { return }
            isConnected = false
            for k in deviceStates.keys { deviceStates[k] = "offline" }
            return
        }
        consecutiveFailures = 0
        isConnected = true
        reachable = reach
        stateAgeSeconds = reach ? nil : (s["ageSeconds"] as? Int)
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
        autoPlayPause = (s["autoPlayPause"] as? Bool) ?? false
        autoAnswer = (s["autoAnswer"] as? Bool) ?? false
        favorites = (s["favorites"] as? [Int]) ?? []
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
        spatial = (s["spatial"] as? String) ?? spatial
        spatialAdjustable = (s["spatialAdjustable"] as? Bool) ?? false
        custom1Name = (s["custom1Name"] as? String) ?? ""
        custom2Name = (s["custom2Name"] as? String) ?? ""
        persistSnapshot(s)
    }

    // MARK: - Write (each: run verb, optimistic local update, then re-read)

    /// Activate an ANC mode by hardware slot index (0-5): 0 quiet, 1 aware,
    /// 2 immersion, 3 cinema (fixed), 4/5 custom (adjustable). Passes the bare
    /// slot to `bose anc <n>` so app and CLI share one numbering; `ancMode`
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

    /// Pause playback when the headphones are removed (01,18, SET_GET).
    func setAutoPlayPause(_ enabled: Bool) {
        autoPlayPause = enabled
        write(["auto-pause", enabled ? "on" : "off"])
    }

    /// Answer an incoming call when the headphones are donned (01,1B, SET_GET).
    func setAutoAnswer(_ enabled: Bool) {
        autoAnswer = enabled
        write(["auto-answer", enabled ? "on" : "off"])
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

    /// Set the active mode's Immersive Audio mode ("off"/"still"/"motion") via the CLI
    /// `spatial` (the 1F,06 RMW). No-op unless the active mode is adjustable — the CLI
    /// refuses on fixed modes anyway. Only the custom modes are settable.
    func setSpatial(_ value: String) {
        guard spatialAdjustable, ["off", "still", "motion"].contains(value) else { return }
        spatial = value
        write(["spatial", value])
    }

    /// Tell the headphones to make `name` the active sink. The tile shows a spinner
    /// ("Connecting…") for the duration — `bose connect` poll-confirms internally
    /// (ACK is never success) and can take up to ~15 s paging a sleeping device — then
    /// settles to active/connected from the CLI's result, which we trust over the flaky
    /// off-head routing probe (see `assertedActiveDevice`).
    func connectDevice(_ name: String) {
        guard connectingDevice == nil else { return }   // ignore taps while one is in flight
        // Skip-if-active: tapping the device that's already the audio sink is a no-op — don't
        // re-run the whole connect sequence (or spin the tile) for a device that's already
        // here. Mirrors Android's BoseService skip-if-active (CLAUDE.md). The CLI connect
        // would settle near-instantly anyway, but this avoids the needless RFCOMM round-trips.
        guard deviceStates[name] != "active" else { return }
        connectingDevice = name
        DispatchQueue.main.async { self.isRefreshing = true }
        queue.async { [weak self] in
            guard let self = self else { return }
            let (code, out) = self.run(["connect", name])
            // The CLI prints "Connected <name>" on success, with "(idle …)" when
            // multipoint kept audio on the previous device (ACL up, not the active sink).
            let ok = code == 0 && out.range(of: "connected", options: .caseInsensitive) != nil
            let idle = out.range(of: "(idle", options: .caseInsensitive) != nil
            // --page: this read follows an explicit connect — it must reflect the
            // device's REAL post-connect state, never the cached-first snapshot.
            let snapshot = Self.parse(self.run(["info", "--json", "--page"]).out)
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

    /// Rename a custom ANC slot (4 = C1, 5 = C2) in place via `mode-name --slot`, WITHOUT
    /// changing the active mode. Optimistically updates the local C1/C2 label, then writes +
    /// refreshes so the button reflects the device's confirmed name. Trims to 30 UTF-8 bytes
    /// (the 1F,06 name-field limit); a blank name is ignored (the CLI treats empty as a read,
    /// so it can't clear a name — there's no on-device "unset" write).
    func renameCustomMode(slot: Int, name: String) {
        guard slot == 4 || slot == 5 else { return }
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.utf8.count > 30 { trimmed = String(trimmed.dropLast()) }
        guard !trimmed.isEmpty else { return }
        if slot == 4 { custom1Name = trimmed } else { custom2Name = trimmed }   // optimistic
        write(["mode-name", "--slot", String(slot), trimmed])
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

    // MARK: - Multipoint priority / pair

    /// Load the saved runtime priority order (`bose priority`) for the reorderable grid.
    /// Returns [] when no override is saved (the app then falls back to the tile default).
    func loadPriorityOrder(_ completion: @escaping ([String]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let out = self.run(["priority"]).out
            var order: [String] = []
            if let r = out.range(of: "priority:") {
                let rest = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.hasPrefix("(") {          // "(default — …)" means no override
                    order = rest.split(separator: " ").map(String.init)
                }
            }
            DispatchQueue.main.async { completion(order) }
        }
    }

    /// Persist the runtime eviction order (index 0 = primary). Writes priority.json only —
    /// no device I/O, so no refresh.
    func setPriority(_ order: [String]) {
        queue.async { [weak self] in _ = self?.run(["priority", "--set"] + order) }
    }

    /// Disconnect a single device (right-click → Disconnect). Refreshes state after.
    func disconnectDevice(_ name: String) {
        write(["disconnect", name])
    }

    /// Apply the multipoint pair now: evict others, connect secondary (held) then primary
    /// (active). Spins the primary tile while it runs (mirrors connectDevice), then refreshes.
    func applyPair(primary: String, secondary: String) {
        guard connectingDevice == nil else { return }
        connectingDevice = primary
        isRefreshing = true
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = self.run(["pair", primary, secondary])
            let snapshot = Self.parse(self.run(["info", "--json", "--page"]).out)   // real post-pair state
            DispatchQueue.main.async {
                self.apply(snapshot)
                self.connectingDevice = nil
                self.isRefreshing = false
            }
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
                // --page: a settle loop reading the cache would "confirm" stale data
                // (or spin to timeout) — post-write reads are always live.
                let parsed = Self.parse(self.run(["info", "--json", "--page"]).out)
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
