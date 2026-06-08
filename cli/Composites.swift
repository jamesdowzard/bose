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

    /// Read the ACTIVE mode's full AudioModesModeConfig (1F,06) in one warm session.
    /// Resolves the current mode index (1F,03) first. nil if unreachable.
    func readActiveModeConfig() -> ModeConfig? {
        session { ch, t in
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm
            guard let cur = t.send(ch, [0x1F, 0x03, 0x01, 0x00], timeout: 2.0), cur.count >= 5
            else { return nil }
            return t.send(ch, [0x1F, 0x06, 0x01, 0x01, cur[4]], timeout: 2.0).flatMap(parseModeConfig)
        } ?? nil
    }

    enum AncLevelResult { case ok(name: String, level: Int), fixed(name: String), unreachable }

    /// Set the ACTIVE mode's CNC noise level (0 = max cancellation … 10 = transparency)
    /// via the 1F,06 read-modify-write — the correct, ANC-anchored path (#83). Refuses
    /// on a mode whose level is fixed (cncMutable == false: Quiet/Aware/spatial modes),
    /// so a level write can never disable ANC. Returns the device's post-write level.
    func setActiveModeLevel(_ level: Int) -> AncLevelResult {
        session { ch, t in
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm
            guard let cur = t.send(ch, [0x1F, 0x03, 0x01, 0x00], timeout: 2.0), cur.count >= 5,
                  let r1 = t.send(ch, [0x1F, 0x06, 0x01, 0x01, cur[4]], timeout: 2.0),
                  let cfg = parseModeConfig(r1) else { return .unreachable }
            guard cfg.cncMutable else { return .fixed(name: cfg.displayName) }
            _ = t.send(ch, buildModeConfigSet(cfg, newLevel: level), timeout: 2.0)
            let after = t.send(ch, [0x1F, 0x06, 0x01, 0x01, cur[4]], timeout: 2.0).flatMap(parseModeConfig)
            return .ok(name: cfg.displayName, level: Int(after?.cncLevel ?? cfg.cncLevel))
        } ?? .unreachable
    }
}

/// Uppercase-hex MAC key for set membership (keeps this file independent of
/// main.swift's `macString`).
private func macKey(_ mac: [UInt8]) -> String {
    mac.map { String(format: "%02X", $0) }.joined()
}
