/// StateCache: the timestamped last-good `info --json` snapshot.
///
/// Written on every successful LIVE `info --json` read; served when the Mac has no
/// ACL link to the headphones so the app (and any other front-end) can paint the
/// last-known state INSTANTLY instead of paging the headphones over BT Classic.
/// Paging from a non-slot device is slow (multi-second page + warm-up) and is the
/// interference class behind the #69-era audio dropouts — the cached-first read
/// makes "open the app while the golf plays through the Audikast" a zero-radio act.
///
/// The cache is a *presentation* cache, not a source of truth: every served
/// snapshot is stamped `reachable: false` + `cachedAt`/`ageSeconds`, and the UI
/// renders the staleness honestly. A live read (ACL up, or explicit `--page`)
/// always bypasses and rewrites it.
///
/// Location: `~/.cache/bose/state-<MAC>.json` (same home as the identity memo);
/// `$BOSE_STATE_DIR` overrides for tests (same env the priority tests use).
/// Foundation-only — no IOBluetooth — so it compiles into the headless test binary.

import Foundation

enum StateCache {

    /// Snapshot JSON keys added by the cache layer (kept in one place so the
    /// stamping logic and its tests can't drift from the emitters in main.swift).
    static let reachableKey = "reachable"
    static let cachedAtKey = "cachedAt"
    static let ageSecondsKey = "ageSeconds"

    private static var path: String {
        let dir: String
        if let d = ProcessInfo.processInfo.environment["BOSE_STATE_DIR"], !d.isEmpty {
            dir = d
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.path + "/.cache/bose"
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("state-\(Headphone.dashMac).json")
    }

    /// Persist a successful live snapshot (the exact `info --json` object) with a
    /// wall-clock stamp. Cache-layer keys are stripped first so a re-served cached
    /// object can never be re-persisted as if it were live (belt-and-braces — the
    /// call site only saves live reads anyway).
    static func save(_ snapshot: [String: Any], now: Date = Date()) {
        var clean = snapshot
        clean.removeValue(forKey: reachableKey)
        clean.removeValue(forKey: cachedAtKey)
        clean.removeValue(forKey: ageSecondsKey)
        let wrapped: [String: Any] = ["savedAt": now.timeIntervalSince1970, "snapshot": clean]
        if let data = try? JSONSerialization.data(withJSONObject: wrapped) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Load the raw cached snapshot + its save time. nil when absent/corrupt.
    static func load() -> (snapshot: [String: Any], savedAt: Date)? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = obj["savedAt"] as? Double,
              let snap = obj["snapshot"] as? [String: Any]
        else { return nil }
        return (snap, Date(timeIntervalSince1970: ts))
    }

    /// The cached snapshot stamped for serving to a front-end: `reachable: false`
    /// (the Mac has no link right now) + `cachedAt` (epoch seconds) + `ageSeconds`.
    /// `connected` keeps its cached value — it describes the HEADPHONE state the
    /// snapshot captured, not the Mac's link; `reachable` carries the link truth.
    /// nil when there is no usable cache (caller falls back to a bare
    /// connected:false/reachable:false object).
    static func staleOutput(now: Date = Date()) -> [String: Any]? {
        guard let (snap, savedAt) = load() else { return nil }
        return stamp(snap, savedAt: savedAt, now: now)
    }

    /// Pure stamping transform (unit-tested without touching disk).
    static func stamp(_ snapshot: [String: Any], savedAt: Date, now: Date) -> [String: Any] {
        var out = snapshot
        out[reachableKey] = false
        out[cachedAtKey] = savedAt.timeIntervalSince1970
        out[ageSecondsKey] = max(0, Int(now.timeIntervalSince(savedAt)))
        return out
    }

    // MARK: - BLE correlation log

    /// One JSONL line pairing a BLE advert capture with the last-known battery, for
    /// offline decoding of the advert payload (which byte tracks charge — unproven,
    /// 2026-07-18). Pure — unit-tested; nil when there's no battery to correlate
    /// against (a payload with no reference value teaches nothing).
    static func correlationLine(now: Date, rssi: Int, mfr: [UInt8],
                                cachedBattery: Int?, cacheAge: Int?) -> String? {
        guard let battery = cachedBattery else { return nil }
        var obj: [String: Any] = [
            "ts": Int(now.timeIntervalSince1970),
            "rssi": rssi,
            "mfr": mfr.map { String(format: "%02x", $0) }.joined(),
            "battery": battery,
        ]
        if let age = cacheAge { obj["cacheAgeSeconds"] = age }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Append a correlation line to `ble-correlation-<MAC>.jsonl` (same dir as the
    /// state cache). Battery + age come from the cache; a missing cache is a no-op.
    static func appendCorrelation(rssi: Int, mfr: [UInt8], now: Date = Date()) {
        let cached = load()
        let battery = cached?.snapshot["batteryLevel"] as? Int
        let age = cached.map { max(0, Int(now.timeIntervalSince($0.savedAt))) }
        guard let line = correlationLine(now: now, rssi: rssi, mfr: mfr,
                                         cachedBattery: battery, cacheAge: age) else { return }
        let logPath = (path as NSString).deletingLastPathComponent + "/ble-correlation-\(Headphone.dashMac).jsonl"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            handle.closeFile()
        } else {
            try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: logPath))
        }
    }
}
