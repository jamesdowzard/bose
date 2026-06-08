/// Composites: live-channel orchestration for the three hand-written BMAP commands
/// the generator intentionally skips (marked `composite = true` in bmap.toml):
///   - `connectedDevices` (05,01) — variable-length MAC-list RESPONSE parse (ground truth).
///   - `cncLevel` (1F,0A)         — read-modify-write: read the 5-byte tuple, change
///                                  `level`, preserve autoCNC/spatial/windBlock/ancToggle.
///   - `getAllState`              — one RFCOMM session issuing many generated sub-commands.
///
/// The pure decode logic lives in `Parsers.swift` (Foundation-only, unit-tested).
/// Non-composite sub-command frames come from the generated `BMAP` enum.

import Foundation

extension Transport {

    // Composite GET frames are not emitted by the generator (commands are marked
    // `composite = true`), so the trivial [block, func, GET, 0] query bytes live here.
    private static let connectedDevicesGet: [UInt8] = [0x05, 0x01, 0x01, 0x00]
    private static let cncLevelGet: [UInt8] = [0x1F, 0x0A, 0x01, 0x00]

    /// GET the audio-active device MACs (05,01) — composite ground truth.
    func getConnectedDevices() -> [[UInt8]] {
        guard let r = oneShot(Transport.connectedDevicesGet) else { return [] }
        return parseConnectedDevices(r)
    }

    /// GET the current CNC/ANC-depth level (1F,0A). nil if unreachable/unparsable.
    /// Mirrors Android `Composites.getCncLevel()`.
    func getCncLevel() -> Int? {
        guard let r = oneShot(Transport.cncLevelGet) else { return nil }
        return parseCncLevel(r).map { Int($0.level) }
    }

    /// Read-modify-write the CNC level (1F,0A): preserve the other four fields.
    @discardableResult
    func setCncLevel(_ level: Int) -> Bool {
        session { ch, t in
            guard let cur = t.send(ch, Transport.cncLevelGet), let cfg = parseCncLevel(cur) else { return false }
            guard let resp = t.send(ch, buildCncSet(level: level, preserving: cfg)) else { return false }
            return resp.count >= 4 && resp[2] == OP_RESP_BYTE
        } ?? false
    }

    /// Bulk state in ONE RFCOMM session — issues every GET, parses via `parseAllState`.
    func getAllState() -> HeadphoneState? {
        session { ch, t in
            parseAllState { block, function in t.send(ch, [block, function, 0x01, 0x00], timeout: 2.0) }
        }
    }

    /// Three-state device readout in ONE RFCOMM session:
    ///   `active`    — audio sink (05,01 ground truth)
    ///   `connected` — ACL up (per-device 04,05) but NOT the active sink
    /// Already-active devices skip the per-device probe. Returns nil only if the
    /// session can't open (headphones unreachable). The 04,05 request frame comes
    /// from the generated `BMAP.getDeviceInfo`; only the response decode is hand-written.
    func getDeviceStates(query devices: [[UInt8]]) -> (active: [[UInt8]], connected: [[UInt8]])? {
        session { ch, t in
            // 05,01 is SILENT as the first frame on a fresh channel (same firmware
            // quirk as 08,07 on-head) — it only answers once the session is warm. The
            // bulk `getAllState` path reads it 4th (after battery/anc/volume) and gets
            // the active sink; this dedicated path read it cold and came back empty,
            // which is why `devices` disagreed with `info` (#81). Prime with one cheap
            // GET (battery 02,02 responds even cold) so the active-sink read matches.
            // Single attempt, no retry loop.
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)
            let active = t.send(ch, Transport.connectedDevicesGet).map { parseConnectedDevices($0) } ?? []
            let activeKeys = Set(active.map { macKey($0) })
            var connected: [[UInt8]] = []
            for mac in devices where !activeKeys.contains(macKey(mac)) {
                if let r = t.send(ch, BMAP.getDeviceInfo(mac: mac), timeout: 2.0),
                   parseDeviceInfo(r)?.connected == true {
                    connected.append(mac)
                }
            }
            return (active, connected)
        }
    }

    /// Apply a profile in ONE RFCOMM session. Reads the live CNC config first (only
    /// if the profile sets ancDepth — that's a read-modify-write), then sends every
    /// SET the profile defines. Returns false if the session can't open or the
    /// profile sets nothing.
    @discardableResult
    func applyProfile(_ p: Profile) -> Bool {
        session { ch, t in
            var cnc: CncConfig? = nil
            if p.ancDepth != nil, let cur = t.send(ch, Transport.cncLevelGet) {
                cnc = parseCncLevel(cur)
            }
            let frames = profileFrames(p, currentCnc: cnc)
            guard !frames.isEmpty else { return false }
            var ok = true
            for f in frames where t.send(ch, f) == nil { ok = false }
            return ok
        } ?? false
    }

    /// DEBUG probe: in one warm session, read AudioModes function frames to verify the
    /// 1F,06 (AudioModesModeConfig) reverse-engineering before building the RMW writer.
    /// Reads UserIndices (1F,07), CurrentMode (1F,03), and ModeConfig (1F,06 GET) for
    /// mode indices 0..5. Returns a labelled hex dump. Remove once the fix lands.
    func probeAudioModes() -> [String] {
        session { ch, t in
            var out: [String] = []
            func dump(_ label: String, _ r: [UInt8]?) {
                out.append("\(label): \(r.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "no response")")
            }
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)            // prime warm
            dump("userIndices 1F,07", t.send(ch, [0x1F, 0x07, 0x01, 0x00], timeout: 2.0))
            dump("currentMode 1F,03", t.send(ch, [0x1F, 0x03, 0x01, 0x00], timeout: 2.0))
            for idx in UInt8(0)...UInt8(5) {
                dump("modeConfig 1F,06 idx \(idx)", t.send(ch, [0x1F, 0x06, 0x01, 0x01, idx], timeout: 2.0))
            }
            return out
        } ?? ["session failed"]
    }

    /// SAFETY validation for the 1F,06 write path: GET mode `index`, rebuild the SET
    /// payload UNCHANGED, write it, re-GET, and return (before, after) so the caller
    /// can assert byte-identity. Run on an EMPTY ("None") slot first — if the SET
    /// layout is wrong it scrambles only a throwaway slot, not a real mode.
    func cncRoundTrip(index: UInt8) -> (before: ModeConfig?, after: ModeConfig?) {
        session { ch, t in
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm
            guard let r1 = t.send(ch, [0x1F, 0x06, 0x01, 0x01, index], timeout: 2.0),
                  let before = parseModeConfig(r1) else { return (nil, nil) }
            _ = t.send(ch, buildModeConfigSet(before, newLevel: nil), timeout: 2.0)
            let r2 = t.send(ch, [0x1F, 0x06, 0x01, 0x01, index], timeout: 2.0)
            return (before, r2.flatMap(parseModeConfig))
        } ?? (nil, nil)
    }

    /// Set a mode's CNC level via the 1F,06 read-modify-write, then activate it.
    /// Returns the post-write ModeConfig, or nil. Keeps ANC anchored to the mode.
    func setModeCncLevel(index: UInt8, level: Int, activate: Bool) -> ModeConfig? {
        session { ch, t in
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm
            guard let r1 = t.send(ch, [0x1F, 0x06, 0x01, 0x01, index], timeout: 2.0),
                  let cfg = parseModeConfig(r1) else { return nil }
            _ = t.send(ch, buildModeConfigSet(cfg, newLevel: level), timeout: 2.0)
            if activate { _ = t.send(ch, [0x1F, 0x03, 0x05, 0x02, index, 0x00], timeout: 2.0) }
            let r2 = t.send(ch, [0x1F, 0x06, 0x01, 0x01, index], timeout: 2.0)
            return r2.flatMap(parseModeConfig)
        } ?? nil
    }
}

/// Uppercase-hex MAC key for set membership (keeps this file independent of
/// main.swift's `macString`).
private func macKey(_ mac: [UInt8]) -> String {
    mac.map { String(format: "%02X", $0) }.joined()
}
