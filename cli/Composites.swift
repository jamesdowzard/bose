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

    /// Bulk state AND per-device idle ACL in ONE RFCOMM session — the read seam for
    /// `info --json`. `parseAllState` warms the channel and lands the active sink in
    /// `state.connectedDevices` (its 4th read, 05,01); the per-device 04,05 idle probes
    /// then run in that SAME warm session. Doing it as a single session (vs `getAllState`
    /// followed by a separate `getDeviceStates`) is why neither the active sink nor the
    /// idle set can be lost to the cold-second-session quirk that dropped every tile to
    /// offline (#132) — and it costs one fewer RFCOMM open/drain/teardown. The headphones
    /// answer 04,05 about a paired device promptly even when that device is offline, so
    /// the probe loop doesn't stall. `idle` = ACL up but NOT the active sink. Returns nil
    /// only if the session can't open (headphones unreachable).
    func getAllStateWithDevices(query devices: [[UInt8]]) -> (state: HeadphoneState, idle: [[UInt8]])? {
        session { ch, t in
            let state = parseAllState { block, function in t.send(ch, [block, function, 0x01, 0x00], timeout: 2.0) }
            let activeKeys = Set(state.connectedDevices.map { macKey($0) })
            var idle: [[UInt8]] = []
            for mac in devices where !activeKeys.contains(macKey(mac)) {
                if let r = t.send(ch, BMAP.getDeviceInfo(mac: mac), timeout: 2.0),
                   parseDeviceInfo(r)?.connected == true {
                    idle.append(mac)
                }
            }
            return (state, idle)
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

    /// Apply a profile in ONE RFCOMM session: send every static SET the profile defines
    /// (mode, volume, multipoint, EQ), then — if it carries a `noiseLevel` — apply that
    /// level to the now-active mode via the 1F,06 RMW. The ANC-mode frame switches the
    /// active mode BEFORE the RMW reads it, so the level lands on the profile's mode. A
    /// named/spatial mode legitimately can't take a level, so a `.fixed` result is a
    /// no-op (not a failure); only an unreachable session — or a profile that sets
    /// nothing — fails the apply.
    @discardableResult
    func applyProfile(_ p: Profile) -> Bool {
        session { ch, t in
            let frames = profileFrames(p, currentCnc: nil)
            guard !frames.isEmpty || p.noiseLevel != nil else { return false }
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm (1F,03/06 need it)
            var ok = true
            for f in frames where t.send(ch, f) == nil { ok = false }
            if let lvl = p.noiseLevel,
               case .unreachable = rmwActiveModeLevel(lvl, send: { t.send(ch, $0, timeout: 2.0) }) {
                ok = false
            }
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

    /// In-session RMW of the active mode's CNC noise level (0 = max cancellation … 10 =
    /// transparency). `send` issues one BMAP frame and returns the RESPONSE bytes — the
    /// CALLER owns the warm session (prime with a 02,02 read first; 1F,03/06 only answer
    /// warm). Resolves the active mode (1F,03), reads its config (1F,06), writes the new
    /// level back, and re-reads. Refuses on a mode whose level is fixed (cncMutable ==
    /// false: Quiet/Aware/spatial), so a level write can never disable ANC (#83). Shared
    /// by `setActiveModeLevel` (the `anc-level` verb) and `applyProfile`.
    private func rmwActiveModeLevel(_ level: Int, send: (_ frame: [UInt8]) -> [UInt8]?) -> AncLevelResult {
        guard let cur = send([0x1F, 0x03, 0x01, 0x00]), cur.count >= 5,
              let r1 = send([0x1F, 0x06, 0x01, 0x01, cur[4]]),
              let cfg = parseModeConfig(r1) else { return .unreachable }
        guard cfg.cncMutable else { return .fixed(name: cfg.displayName) }
        _ = send(buildModeConfigSet(cfg, newLevel: level))
        let after = send([0x1F, 0x06, 0x01, 0x01, cur[4]]).flatMap(parseModeConfig)
        return .ok(name: cfg.displayName, level: Int(after?.cncLevel ?? cfg.cncLevel))
    }

    /// Set the ACTIVE mode's CNC noise level via the 1F,06 RMW — the correct, ANC-anchored
    /// path (#83). Refuses on a fixed-level mode. Returns the device's post-write level.
    func setActiveModeLevel(_ level: Int) -> AncLevelResult {
        session { ch, t in
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm
            return rmwActiveModeLevel(level) { t.send(ch, $0, timeout: 2.0) }
        } ?? .unreachable
    }

    enum SpatialResult { case ok(name: String, spatial: Int), fixed(name: String), unreachable }

    /// In-session RMW of the active mode's Immersive Audio (spatial) mode via the same
    /// 1F,06 path as the noise level (0 = off, 1 = Still, 2 = Motion). The spatial byte is
    /// per-mode and only editable where the firmware sets `spatialMutable` (payload[41]
    /// bit2) — the two custom slots on verBosita; the named modes (Quiet/Aware/Immersion/
    /// Cinema) carry it fixed (Immersion = Motion, Cinema = Still). Refuses on a fixed mode
    /// so the call is a clean no-op rather than a silently-ignored write. The global
    /// AudioManagement function (05,0F) is FuncNotSupp on this firmware — this per-mode RMW
    /// is the only working path.
    private func rmwActiveModeSpatial(_ spatial: Int, send: (_ frame: [UInt8]) -> [UInt8]?) -> SpatialResult {
        guard let cur = send([0x1F, 0x03, 0x01, 0x00]), cur.count >= 5,
              let r1 = send([0x1F, 0x06, 0x01, 0x01, cur[4]]),
              let cfg = parseModeConfig(r1) else { return .unreachable }
        guard cfg.spatialMutable else { return .fixed(name: cfg.displayName) }
        _ = send(buildModeConfigSet(cfg, newLevel: nil, newSpatial: spatial))
        let after = send([0x1F, 0x06, 0x01, 0x01, cur[4]]).flatMap(parseModeConfig)
        return .ok(name: cfg.displayName, spatial: Int(after?.spatial ?? cfg.spatial))
    }

    /// Set the ACTIVE mode's Immersive Audio mode (0 = off, 1 = Still, 2 = Motion) via the
    /// 1F,06 RMW. Refuses on a mode whose spatial is fixed. Returns the post-write value.
    func setActiveModeSpatial(_ spatial: Int) -> SpatialResult {
        session { ch, t in
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm
            return rmwActiveModeSpatial(spatial) { t.send(ch, $0, timeout: 2.0) }
        } ?? .unreachable
    }

    enum NameResult { case ok(name: String), notCustom, unreachable }

    /// Rename the ACTIVE mode via the 1F,06 RMW (writes the 32-byte name field, preserving
    /// level/spatial). Only the user-configurable custom slots can be renamed — the named
    /// presets (Quiet/Aware/Immersion/Cinema) have `userConfigurable == false` and the
    /// firmware ignores a name write, so refuse there. Returns the device's post-write name.
    func setActiveModeName(_ name: String) -> NameResult {
        session { ch, t -> NameResult in
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm
            func send(_ f: [UInt8]) -> [UInt8]? { t.send(ch, f, timeout: 2.0) }
            guard let cur = send([0x1F, 0x03, 0x01, 0x00]), cur.count >= 5,
                  let r1 = send([0x1F, 0x06, 0x01, 0x01, cur[4]]),
                  let cfg = parseModeConfig(r1) else { return .unreachable }
            guard cfg.userConfigurable else { return .notCustom }
            _ = send(buildModeConfigSet(cfg, newLevel: nil, newName: name))
            let after = send([0x1F, 0x06, 0x01, 0x01, cur[4]]).flatMap(parseModeConfig)
            return .ok(name: after?.displayName ?? name)
        } ?? .unreachable
    }

    /// One warm session: the active mode's full config PLUS the display names of the two
    /// custom slots (4, 5), so the app can label the C1/C2 buttons with their stored names.
    /// Folding it into one session (vs a separate read per slot) keeps the app's on-open
    /// read to a single extra RFCOMM open and avoids the cold-start flakiness of stacked
    /// sessions. nil → unreachable.
    func readModeInfo() -> (active: ModeConfig?, customNames: [Int: String])? {
        session { ch, t -> (ModeConfig?, [Int: String]) in
            _ = t.send(ch, [0x02, 0x02, 0x01, 0x00], timeout: 2.0)  // prime warm
            var active: ModeConfig? = nil
            if let cur = t.send(ch, [0x1F, 0x03, 0x01, 0x00], timeout: 2.0), cur.count >= 5 {
                active = t.send(ch, [0x1F, 0x06, 0x01, 0x01, cur[4]], timeout: 2.0).flatMap(parseModeConfig)
            }
            var names: [Int: String] = [:]
            for idx in [4, 5] {
                if let r = t.send(ch, [0x1F, 0x06, 0x01, 0x01, UInt8(idx)], timeout: 2.0),
                   let cfg = parseModeConfig(r) {
                    names[idx] = cfg.displayName
                }
            }
            return (active, names)
        }
    }
}

/// Uppercase-hex MAC key for set membership (keeps this file independent of
/// main.swift's `macString`).
private func macKey(_ mac: [UInt8]) -> String {
    mac.map { String(format: "%02X", $0) }.joined()
}
