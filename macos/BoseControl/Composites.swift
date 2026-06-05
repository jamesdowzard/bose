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
}
