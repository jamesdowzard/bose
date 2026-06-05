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
    var ancMode: Int = 0           // 0=quiet 1=aware 2=custom1 3=custom2
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
    var autoOffTimer: [UInt8] = []
    var cncLevel: Int = 0
    var onHead: Bool = false
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

/// Parse the CNC/ANC-depth RESPONSE (1F,0A). Needs the full 5-byte payload
/// (bytes 4..8). Returns nil on a short/non-RESP frame.
func parseCncLevel(_ resp: [UInt8]) -> CncConfig? {
    guard resp.count >= 9, resp[2] == OP_RESP_BYTE else { return nil }
    return CncConfig(level: resp[4], autoCNC: resp[5], spatial: resp[6],
                     windBlock: resp[7], ancToggle: resp[8])
}

/// Build the CNC SET_GET frame that changes `level` and preserves the rest.
/// `1F,0A,02,05,{level},{autoCNC},{spatial},{windBlock},{ancToggle}`.
func buildCncSet(level: Int, preserving cfg: CncConfig) -> [UInt8] {
    [0x1F, 0x0A, 0x02, 0x05, UInt8(max(0, min(10, level))),
     cfg.autoCNC, cfg.spatial, cfg.windBlock, cfg.ancToggle]
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
        guard let r = provide(b, f), r.count >= 5, r[2] == OP_RESP_BYTE else { return nil }
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

    if let r = resp(0x01, 0x0A) { s.multipointEnabled = r[4] != 0 }
    if let r = resp(0x01, 0x0B) { s.autoOffTimer = Array(r[4...]) }
    if let r = resp(0x08, 0x07) { s.onHead = r[4] == 0x04 }

    if let r = provide(0x01, 0x07), r.count >= 16, r[2] == OP_RESP_BYTE {
        s.eq = (bass: Int(Int8(bitPattern: r[6])),
                mid: Int(Int8(bitPattern: r[10])),
                treble: Int(Int8(bitPattern: r[14])))
    }
    return s
}
