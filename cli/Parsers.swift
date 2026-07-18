/// Parsers: pure BMAP response decoders for the composite commands.
///
/// These are deliberately free of IOBluetooth / transport dependencies (Foundation
/// only) so they unit-test WITHOUT hardware — fed representative response byte
/// arrays (see macos/Tests/ParserTests.swift). The live-channel orchestration that
/// uses these parsers lives in `Composites.swift` (an extension over `Transport`).

import Foundation

// MARK: - BMAP response operator (decode side)

let OP_RESP_BYTE: UInt8 = 0x03

// MARK: - Decoded state

/// A full headphone state snapshot (decoded from one bulk session).
struct HeadphoneState {
    var batteryLevel: Int = 0
    var batteryCharging: Bool = false
    var ancMode: Int = 0           // 0=quiet 1=aware 2=immersion 3=cinema 4=custom1 5=custom2
    var volume: Int = 0
    var volumeMax: Int = 31
    var connectedDevices: [[UInt8]] = []   // audio-active (05,01) — ground truth
    var firmware: String = ""
    var serialNumber: String = ""
    var productName: String = ""
    var platform: String = ""
    var codename: String = ""
    var audioCodec: String = ""
    var deviceName: String = ""
    var multipointEnabled: Bool = false
    var autoPlayPause: Bool = false   // 01,18 — pause when removed
    var autoAnswer: Bool = false      // 01,1B — answer call when donned
    var favorites: [Int] = []         // 1F,08 — favourited mode slots
    var autoOffTimer: [UInt8] = []
    var cncLevel: Int = 0
    var eq: (bass: Int, mid: Int, treble: Int) = (0, 0, 0)
}

// MARK: - Pure parsers (unit-testable, no hardware)

/// Parse the connected-devices RESPONSE (05,01). Layout:
///   [0x05, 0x01, RESP, len, ...] with count at byte 6 and 6-byte MACs from byte 7.
/// Returns [] on any malformed/short/non-RESP frame.
func parseConnectedDevices(_ resp: [UInt8]) -> [[UInt8]] {
    guard resp.count >= 7, resp[0] == 0x05, resp[1] == 0x01, resp[2] == OP_RESP_BYTE else { return [] }
    let count = Int(resp[6])
    var devices: [[UInt8]] = []
    for i in 0..<count {
        let offset = 7 + (i * 6)
        guard offset + 6 <= resp.count else { break }
        devices.append(Array(resp[offset..<(offset + 6)]))
    }
    return devices
}

/// The 5-byte AudioModes SettingsConfig tuple (1F,0A RESP): payload from byte 4.
struct CncConfig: Equatable {
    var level: UInt8        // 0-10
    var autoCNC: UInt8
    var spatial: UInt8
    var windBlock: UInt8
    var ancToggle: UInt8
}

/// Multipoint enable from the 01,0A state byte. Bit 0 is the live enable flag; the
/// higher bits are slot/capability bits the firmware retains across toggles, so a
/// disabled-but-paired device reads 0x06, not 0x00 (#83). Mask the enable bit — the
/// old `!= 0` was the bug (0x06 != 0 misread "off" as "on"). Verified live on
/// fw 8.2.20: multipoint on → 0x07, off → 0x06.
func parseMultipointEnabled(_ stateByte: UInt8) -> Bool { (stateByte & 0x01) != 0 }

/// Parse the CNC/ANC-depth RESPONSE (1F,0A). Needs the full 5-byte payload
/// (bytes 4..8). Returns nil on a short/non-RESP frame.
func parseCncLevel(_ resp: [UInt8]) -> CncConfig? {
    guard resp.count >= 9, resp[2] == OP_RESP_BYTE else { return nil }
    return CncConfig(level: resp[4], autoCNC: resp[5], spatial: resp[6],
                     windBlock: resp[7], ancToggle: resp[8])
}

/// One AudioModes mode slot, from the 1F,06 (AudioModesModeConfig) RESPONSE.
/// This is the CORRECT noise-level axis: changing `cncLevel` via a 1F,06 read-modify-
/// write keeps ANC anchored to the mode (unlike the 1F,0A global write that detaches
/// it → 255/off, #83). Level semantics (confirmed live fw 8.2.20): 0 = max
/// cancellation (Quiet), 10 = full transparency (Aware).
struct ModeConfig: Equatable {
    var index: UInt8
    var promptB1: UInt8
    var promptB2: UInt8
    var userConfigurable: Bool  // payload[3] — a user mode slot
    var name: [UInt8]      // 32 bytes, null-padded UTF-8
    var cncMutable: Bool   // payload[41] bit 0 — is the CNC level editable for this mode?
    var spatialMutable: Bool  // payload[41] bit 2 — is the spatial (Immersive Audio) mode editable?
    var cncLevel: UInt8
    var autoCNC: UInt8
    var spatial: UInt8     // 0 = off, 1 = Still (fixed-to-room), 2 = Motion (head-tracking)
    var windBlock: UInt8
    var ancToggle: UInt8

    var displayName: String {
        String(bytes: name.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }
}

/// Parse a 1F,06 AudioModesModeConfig RESPONSE. Response payload (frame[4...]) offsets,
/// confirmed live + against the decompiled AudioModesModeConfigResponse.createFromPacket:
/// [0]=index, [1..2]=prompt, [3]=userConfigurable, [6..37]=32-byte name,
/// [41]=mutability bitfield (bit0 = cncMutable), [42]=cncLevel, [43]=autoCNC,
/// [44]=spatial, [46]=windBlock, [47]=ancToggle. (The RESPONSE layout differs from the
/// SET payload — see buildModeConfigSet.)
func parseModeConfig(_ resp: [UInt8]) -> ModeConfig? {
    guard resp.count >= 4 + 48, resp[0] == 0x1F, resp[1] == 0x06, resp[2] == OP_RESP_BYTE
    else { return nil }
    let p = Array(resp[4...])
    return ModeConfig(
        index: p[0], promptB1: p[1], promptB2: p[2],
        userConfigurable: p[3] == 1,
        name: Array(p[6...37]),
        cncMutable: (p[41] & 0x01) == 1,
        spatialMutable: (p[41] & 0x04) != 0,
        cncLevel: p[42], autoCNC: p[43], spatial: p[44],
        windBlock: p[46], ancToggle: p[47])
}

/// Build a 1F,06 AudioModesModeConfig SET_GET frame from a parsed mode, changing only
/// `cncLevel` and/or the spatial (Immersive Audio) mode, and forcing `ancToggle = 1` (so
/// a level change can't disable ANC). The SET payload layout (from the decompiled app,
/// distinct from the response): [0]=index, [1..2]=prompt, [3..34]=32-byte name,
/// [35]=cncLevel, [36]=autoCNC, [37]=spatial, [38]=windBlock, [39]=ancToggle. Pass
/// `newLevel`/`newSpatial`/`newName = nil` to leave that field unchanged (a no-op
/// round-trip when all are nil). `newSpatial`: 0 = off, 1 = Still, 2 = Motion. `newName`
/// is UTF-8, truncated to 32 bytes and null-padded — used to rename a custom mode slot.
func buildModeConfigSet(_ cfg: ModeConfig, newLevel: Int?, newSpatial: Int? = nil, newName: String? = nil) -> [UInt8] {
    let level = newLevel.map { UInt8(max(0, min(10, $0))) } ?? cfg.cncLevel
    let spatial = newSpatial.map { UInt8(max(0, min(2, $0))) } ?? cfg.spatial
    var name = newName.map { Array($0.utf8.prefix(32)) } ?? Array(cfg.name.prefix(32))
    while name.count < 32 { name.append(0) }
    var payload: [UInt8] = [cfg.index, cfg.promptB1, cfg.promptB2]
    payload += name
    payload += [level, cfg.autoCNC, spatial, cfg.windBlock, 0x01]  // ancToggle forced on
    return [0x1F, 0x06, 0x02, UInt8(payload.count)] + payload
}

/// Parse a 1F,08 AudioModes Favorites RESPONSE into the sorted set of favourited mode
/// slots. Wire format (verified live on verBosita fw 8.2.20 + the decompiled app's
/// AudioModesFavorites packets): payload[0] = slot count, followed by a REVERSED-order
/// bitmask of `ceil(count/8)` bytes — the LOW modes live in the LAST byte. For each
/// favourite mode `d`, bit `(d % 8)` is set in byte index `(maskLen - floor(d/8) - 1)`.
/// Live capture `1f 08 03 03 0b 00 07` -> count 11, modes {0,1,2} (Quiet/Aware/Immersion).
/// Returns nil on a short/non-RESP/wrong-header frame.
func parseFavorites(_ resp: [UInt8]) -> [Int]? {
    guard resp.count >= 5, resp[0] == 0x1F, resp[1] == 0x08, resp[2] == OP_RESP_BYTE else { return nil }
    let payload = Array(resp[4...])
    let count = Int(payload[0])
    let mask = Array(payload.dropFirst())          // ceil(count/8) bytes, reversed order
    var modes: [Int] = []
    for (k, byte) in mask.enumerated() {
        let group = mask.count - 1 - k             // last byte = group 0 (modes 0..7)
        for bit in 0..<8 where (byte >> bit) & 1 == 1 {
            let mode = group * 8 + bit
            if mode < count { modes.append(mode) }
        }
    }
    return modes.sorted()
}

/// Build a 1F,08 Favorites SET_GET frame from the desired favourite mode slots + total
/// slot count. Inverse of parseFavorites; mirrors the app's AudioModesFavoritesSetGetPacket:
/// payload length = ceil(count/8)+1, payload[0] = count, bit (d % 8) of byte
/// (len - floor(d/8) - 1) set per favourite mode d. e.g. modes {0,1,2}, count 11 ->
/// `1F 08 02 03 0b 00 07` (the live no-op-restore frame).
func buildFavoritesSetGet(modes: [Int], slotCount: Int) -> [UInt8] {
    let maskLen = (slotCount + 7) / 8              // ceil(count/8)
    let len = maskLen + 1
    var payload = [UInt8](repeating: 0, count: len)
    payload[0] = UInt8(slotCount & 0xFF)
    for d in modes where d >= 0 && d < slotCount {
        payload[len - (d / 8) - 1] |= UInt8(1 << (d % 8))
    }
    return [0x1F, 0x08, 0x02, UInt8(payload.count)] + payload
}

/// Decoded per-device info (04,05 RESP). `connected` is ACL presence (status
/// bit 0) — reliable for "is this device linked at all", NOT for audio routing
/// (use parseConnectedDevices / 05,01 for the active sink). Mirrors the Android
/// `BoseProtocol.DeviceInfo` decode (status at byte 10, optional name from 13).
struct DeviceInfo: Equatable {
    var status: Int
    var name: String
    var connected: Bool
}

/// Parse a device-info RESPONSE (04,05): status byte at index 10, optional
/// length-prefixed name from index 13. Returns nil on a short/non-RESP frame.
func parseDeviceInfo(_ resp: [UInt8]) -> DeviceInfo? {
    guard resp.count >= 11, resp[2] == OP_RESP_BYTE else { return nil }
    let status = Int(resp[10])
    let connected = (status & 0x01) != 0
    let name = resp.count > 13 ? parseString(resp, from: 13) : ""
    return DeviceInfo(status: status, name: name, connected: connected)
}

/// Decode a UTF-8 string field response from a given payload offset.
func parseString(_ resp: [UInt8], from offset: Int = 4) -> String {
    guard resp.count > offset else { return "" }
    return String(bytes: Array(resp[offset...]), encoding: .utf8)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
}

/// A response provider keyed by the 2-byte (block, function) of the GET frame.
/// Lets `parseAllState` be tested with a stub dictionary and run live by closing
/// over the transport channel.
typealias ResponseProvider = (_ block: UInt8, _ function: UInt8) -> [UInt8]?

/// Assemble a `HeadphoneState` from per-command responses. Pure given `provide`.
/// `provide(block, func)` returns the RESPONSE bytes for that GET (or nil).
func parseAllState(_ provide: ResponseProvider) -> HeadphoneState {
    var s = HeadphoneState()

    func resp(_ b: UInt8, _ f: UInt8) -> [UInt8]? {
        // Require the frame to be the RESPONSE to THIS command: BMAP echoes the
        // queried block/func at r[0],r[1]. Without this, a leftover/late frame from a
        // prior command in the bulk session gets misread as the current field.
        // Matching block/func keeps every field bound to its own response.
        guard let r = provide(b, f), r.count >= 5, r[0] == b, r[1] == f, r[2] == OP_RESP_BYTE else { return nil }
        return r
    }

    if let r = resp(0x02, 0x02) {
        s.batteryLevel = min(100, max(0, Int(r[4])))
        s.batteryCharging = r.count >= 8 ? r[7] != 0 : false
    }
    if let r = resp(0x1F, 0x03) { s.ancMode = Int(r[4]) }
    if let r = resp(0x05, 0x05), r.count >= 6 { s.volumeMax = Int(r[4]); s.volume = Int(r[5]) }

    if let r = provide(0x05, 0x01) { s.connectedDevices = parseConnectedDevices(r) }
    if let r = provide(0x1F, 0x0A), let cfg = parseCncLevel(r) { s.cncLevel = Int(cfg.level) }

    if let r = resp(0x00, 0x05) { s.firmware = parseString(r) }
    if let r = resp(0x00, 0x07) { s.serialNumber = parseString(r) }
    if let r = resp(0x00, 0x0F) { s.productName = parseString(r) }
    if let r = resp(0x12, 0x0D) { s.platform = parseString(r) }
    if let r = resp(0x12, 0x0C) { s.codename = parseString(r) }
    if let r = resp(0x01, 0x02), r.count >= 6 { s.deviceName = parseString(r, from: 5) }

    if let r = resp(0x05, 0x04) {
        let str = parseString(r)
        s.audioCodec = str.isEmpty
            ? Array(r[4...]).map { String(format: "%02X", $0) }.joined(separator: " ")
            : str
    }

    if let r = resp(0x01, 0x0A) { s.multipointEnabled = parseMultipointEnabled(r[4]) }
    if let r = resp(0x01, 0x18), r.count >= 5 { s.autoPlayPause = (r[4] & 0x01) != 0 }
    if let r = resp(0x01, 0x1B), r.count >= 5 { s.autoAnswer = (r[4] & 0x01) != 0 }
    if let r = provide(0x1F, 0x08), let fav = parseFavorites(r) { s.favorites = fav }
    if let r = resp(0x01, 0x0B) { s.autoOffTimer = Array(r[4...]) }
    // No on-head/wear field: the QC Ultra 2 headphones don't expose live worn state.
    // The real wear function is StatusInEar (02,09) — but it's an EARBUDS feature
    // (payload bit0/bit1 = left/right bud) and the headphones answer FuncNotSupp
    // (error 0x04). On-head is handled on-device (sensor → AVRCP pause), never
    // published over BMAP. (The old 08,07 read was a synthetic guess, not the wear fn.)

    if let r = provide(0x01, 0x07), r.count >= 16, r[2] == OP_RESP_BYTE {
        s.eq = (bass: Int(Int8(bitPattern: r[6])),
                mid: Int(Int8(bitPattern: r[10])),
                treble: Int(Int8(bitPattern: r[14])))
    }
    return s
}

// MARK: - BLE advert match (presence)

/// True when a BLE advert belongs to the headphones: exact local-name match
/// ("verBosita" — NB a `bose name` rename must be mirrored here / in devices.toml),
/// or Bose's company ID 0x009E leading the manufacturer data (bytes little-endian:
/// 9E 00). The mfr fallback would also match another powered-on Bose product in
/// range — acceptable for a presence hint, and the name match wins when available.
/// Pure — unit-tested headless; the CoreBluetooth session lives in Presence.swift.
func isBoseAdvert(name: String, mfr: [UInt8]) -> Bool {
    if name == "verBosita" { return true }
    return mfr.count >= 2 && mfr[0] == 0x9E && mfr[1] == 0x00
}
