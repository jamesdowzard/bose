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
}

/// Uppercase-hex MAC key for set membership (keeps this file independent of
/// main.swift's `macString`).
private func macKey(_ mac: [UInt8]) -> String {
    mac.map { String(format: "%02X", $0) }.joined()
}
