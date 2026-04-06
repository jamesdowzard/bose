/// BoseRFCOMM: Direct RFCOMM BMAP protocol module for Bose QC Ultra 2
/// On-demand: open RFCOMM (channel resolved via SDP), send BMAP bytes, read response, close.
/// Both Mac and phone can independently control headphones this way.
///
/// Protocol: BMAP (Bose Music Application Protocol)
/// Format: [block, function, operator, length, ...payload]
/// Operators: GET=0x01, RESP=0x03, ERR=0x04, START=0x05, SET/RESULT=0x06, ACK=0x07

import Foundation
import IOBluetooth
import CoreBluetooth

// MARK: - Constants

let BOSE_MAC = "E4-58-BC-C0-2F-72"  // IOBluetooth uses dash-separated format
let RFCOMM_CHANNEL: BluetoothRFCOMMChannelID = 2  // SPPS De service (BMAP) — resolved via SDP

// BMAP operators
let OP_GET:   UInt8 = 0x01
let OP_RESP:  UInt8 = 0x03
let OP_ERR:   UInt8 = 0x04
let OP_START: UInt8 = 0x05
let OP_SET:   UInt8 = 0x06  // Also RESULT
let OP_SET_GET: UInt8 = 0x02
let OP_ACK:   UInt8 = 0x07

// MARK: - Blueutil Helper

/// Run blueutil CLI (macOS Bluetooth utility). Used for A2DP connect/disconnect
/// which IOBluetooth doesn't expose directly.
@discardableResult
func runBlueutil(_ args: [String], path: String = "/opt/homebrew/bin/blueutil") -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, output)
    } catch {
        return (1, "")
    }
}

// MARK: - Data Types

struct DeviceInfo {
    let mac: [UInt8]
    let name: String
    let connected: Bool
    let primary: Bool
    let boseProduct: Bool

    var macString: String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

enum BoseError: Error, CustomStringConvertible {
    case deviceNotFound
    case connectionFailed(IOReturn)

    case timeout

    var description: String {
        switch self {
        case .deviceNotFound:
            return "Bluetooth device not found: \(BOSE_MAC)"
        case .connectionFailed(let status):
            return "RFCOMM connection failed: \(status)"

        case .timeout:
            return "RFCOMM response timeout"
        }
    }
}

// MARK: - Known Devices

let boseKnownDevices: [(name: String, mac: [UInt8])] = [
    ("phone",  [0xA8, 0x76, 0x50, 0xD3, 0xB1, 0x1B]),
    ("mac",    [0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27]),
    ("ipad",   [0xF4, 0x81, 0xC4, 0xB5, 0xFA, 0xAB]),
    ("iphone", [0xF8, 0x4D, 0x89, 0xC4, 0xB6, 0xED]),
    ("tv",     [0x14, 0xC1, 0x4E, 0xB7, 0xCB, 0x68]),
    ("quest",  [0x78, 0xC4, 0xFA, 0xC8, 0x5C, 0x3D]),
]

// MARK: - RFCOMM Delegate

/// Delegate class that receives RFCOMM data callbacks.
/// Used internally by BoseRFCOMM for the RunLoop-based read pattern.
class RFCOMMDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var responseData = Data()
    var gotResponse = false

    func reset() {
        responseData = Data()
        gotResponse = false
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!, length: Int) {
        responseData.append(Data(bytes: dataPointer, count: length))
        gotResponse = true
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        // Channel closed by remote — nothing to do, withRFCOMM handles cleanup
    }
}

// MARK: - BoseRFCOMM

/// Direct RFCOMM communication with Bose QC Ultra 2 headphones.
///
/// On-demand pattern: each command opens RFCOMM (SDP-resolved channel), sends BMAP bytes,
/// reads the response, then closes. No persistent connection. This allows
/// both Mac and phone to independently control the headphones.
/// Waits for CoreBluetooth central manager to reach poweredOn state.
/// Short-lived CLI processes need this before IOBluetooth RFCOMM calls will succeed.
private class BTReadyWaiter: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private(set) var ready = false

    func waitForReady(timeout: TimeInterval = 5.0) {
        central = CBCentralManager(delegate: self, queue: nil)
        let deadline = Date().addingTimeInterval(timeout)
        while !ready && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            ready = true
        }
    }
}

class BoseRFCOMM {

    private let delegate = RFCOMMDelegate()

    init() {
        // Wait for CoreBluetooth to reach poweredOn state — required for
        // IOBluetooth RFCOMM in short-lived CLI processes. Also do SDP
        // query to warm up the connection so RFCOMM opens immediately.
        let waiter = BTReadyWaiter()
        waiter.waitForReady()

        // SDP query warms the L2CAP connection — without this, the first
        // openRFCOMMChannelSync fails with error 913 on cold processes.
        if let device = IOBluetoothDevice(addressString: BOSE_MAC) {
            device.performSDPQuery(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        }
    }

    // MARK: - Core RFCOMM

    /// Opens RFCOMM channel to headphones, runs body, then closes.
    /// Drains 300ms of initial data (Bose firmware quirk) before calling body.
    @discardableResult
    func withRFCOMM<T>(_ body: (IOBluetoothRFCOMMChannel) throws -> T) throws -> T {
        guard let device = IOBluetoothDevice(addressString: BOSE_MAC) else {
            throw BoseError.deviceNotFound
        }

        var channel: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelSync(
            &channel,
            withChannelID: RFCOMM_CHANNEL,
            delegate: delegate
        )
        guard status == kIOReturnSuccess, let ch = channel else {
            throw BoseError.connectionFailed(status)
        }
        defer { ch.close() }

        // Drain initial data — Bose firmware sends unsolicited bytes on connect
        delegate.reset()
        Thread.sleep(forTimeInterval: 0.3)
        delegate.reset()

        return try body(ch)
    }

    /// Send BMAP bytes on an open channel and wait for response.
    func sendBMAP(_ channel: IOBluetoothRFCOMMChannel,
                  bytes: [UInt8],
                  timeout: TimeInterval = 3.0) -> [UInt8]? {
        delegate.reset()

        var data = Data(bytes)
        let writeResult = channel.writeSync(
            &data,
            length: UInt16(data.count)
        )
        guard writeResult == kIOReturnSuccess else { return nil }

        // RunLoop-based wait for delegate callback
        let deadline = Date().addingTimeInterval(timeout)
        while !delegate.gotResponse && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return delegate.gotResponse ? Array(delegate.responseData) : nil
    }

    // MARK: - BMAP Commands

    /// Get battery level and charging state.
    /// Send: [0x02, 0x02, 0x01, 0x00]
    /// Response byte 4 = level (0-100), byte 7 = charging flag
    func getBattery() -> (level: Int, charging: Bool)? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x02, 0x02, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                let level = min(100, max(0, Int(resp[4])))
                let charging = resp.count >= 8 ? resp[7] != 0 : false
                return (level: level, charging: charging)
            }
        } catch {
            return nil
        }
    }

    /// Get current ANC mode.
    /// Send: [0x1F, 0x03, 0x01, 0x00]
    /// Response byte 4: 0=quiet, 1=aware, 2=custom1, 3=custom2
    func getAncMode() -> String? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x1F, 0x03, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                switch resp[4] {
                case 0: return "quiet"
                case 1: return "aware"
                case 2: return "custom1"
                case 3: return "custom2"
                default: return "unknown(\(resp[4]))"
                }
            }
        } catch {
            return nil
        }
    }

    /// Set ANC mode by name.
    /// Send: [0x1F, 0x03, 0x05, 0x02, {mode_byte}, 0x01]
    func setAncMode(_ mode: String) -> Bool {
        let modeByte: UInt8
        switch mode.lowercased() {
        case "quiet", "q", "0":     modeByte = 0
        case "aware", "a", "1":     modeByte = 1
        case "custom1", "c1", "2":  modeByte = 2
        case "custom2", "c2", "3":  modeByte = 3
        default: return false
        }

        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel,
                    bytes: [0x1F, 0x03, OP_START, 0x02, modeByte, 0x01]) else {
                    return false
                }
                return resp.count >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
            }
        } catch {
            return false
        }
    }

    /// Get the active (audio-routing) device MAC.
    /// Send: [0x04, 0x09, 0x01, 0x00]
    /// Response bytes 4-9 are the 6-byte MAC
    func getActiveDevice() -> [UInt8]? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x04, 0x09, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 10, resp[2] == OP_RESP else { return nil }
                return Array(resp[4..<10])
            }
        } catch {
            return nil
        }
    }

    /// Get list of currently connected device MACs (ground truth).
    /// Send: [0x05, 0x01, 0x01, 0x00]
    /// Response byte 6 = count, then 6-byte MACs
    func getConnectedDevices() -> [[UInt8]] {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x05, 0x01, OP_GET, 0x00]) else {
                    return []
                }
                guard resp.count >= 7,
                      resp[0] == 0x05, resp[1] == 0x01, resp[2] == OP_RESP else {
                    return []
                }
                let count = Int(resp[6])
                var devices: [[UInt8]] = []
                for i in 0..<count {
                    let offset = 7 + (i * 6)
                    guard offset + 6 <= resp.count else { break }
                    devices.append(Array(resp[offset..<(offset + 6)]))
                }
                return devices
            }
        } catch {
            return []
        }
    }

    /// Get detailed info about a specific device.
    /// Send: [0x04, 0x05, 0x01, 0x06] + mac
    /// Response: status byte at offset 10 (bit 0=connected, bit 1=primary, bit 2=bose_product),
    /// name from offset 13
    func getDeviceInfo(_ mac: [UInt8]) -> DeviceInfo? {
        guard mac.count == 6 else { return nil }
        do {
            return try withRFCOMM { channel in
                let cmd: [UInt8] = [0x04, 0x05, OP_GET, 0x06] + mac
                guard let resp = sendBMAP(channel, bytes: cmd, timeout: 2.0) else {
                    return nil
                }
                guard resp.count >= 11, resp[2] == OP_RESP else { return nil }

                let respMac = Array(resp[4..<10])
                let status = Int(resp[10])
                let connected = (status & 0x01) != 0
                let primary = (status & 0x02) != 0
                let boseProduct = (status & 0x04) != 0

                let nameOffset = 13
                var name = ""
                if nameOffset < resp.count {
                    let nameBytes = Array(resp[nameOffset...])
                    if let s = String(bytes: nameBytes, encoding: .utf8) {
                        name = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    }
                }

                return DeviceInfo(
                    mac: respMac,
                    name: name,
                    connected: connected,
                    primary: primary,
                    boseProduct: boseProduct
                )
            }
        } catch {
            return nil
        }
    }

    /// Get info for all known devices, cross-referenced with getConnectedDevices
    /// for ground truth on connection state.
    ///
    /// Opens one RFCOMM session and queries everything in sequence to avoid
    /// multiple connect/disconnect cycles.
    func getAllDeviceInfo() -> [(name: String, info: DeviceInfo)]? {
        do {
            return try withRFCOMM { channel in
                // Ground truth: which devices are actually connected
                let connResp = sendBMAP(channel, bytes: [0x05, 0x01, OP_GET, 0x00])
                var connectedMacs: Set<String> = []
                if let cr = connResp, cr.count >= 7,
                   cr[0] == 0x05, cr[1] == 0x01, cr[2] == OP_RESP {
                    let count = Int(cr[6])
                    for i in 0..<count {
                        let offset = 7 + (i * 6)
                        guard offset + 6 <= cr.count else { break }
                        let mac = Array(cr[offset..<(offset + 6)])
                        connectedMacs.insert(macToString(mac))
                    }
                }

                // Ground truth: active device
                let activeResp = sendBMAP(channel, bytes: [0x04, 0x09, OP_GET, 0x00])
                var activeMac: String? = nil
                if let ar = activeResp, ar.count >= 10, ar[2] == OP_RESP {
                    activeMac = macToString(Array(ar[4..<10]))
                }

                // Query each known device
                var results: [(name: String, info: DeviceInfo)] = []
                for (name, mac) in boseKnownDevices {
                    let cmd: [UInt8] = [0x04, 0x05, OP_GET, 0x06] + mac
                    guard let resp = sendBMAP(channel, bytes: cmd, timeout: 2.0) else { continue }
                    guard resp.count >= 11, resp[2] == OP_RESP else { continue }

                    let respMac = Array(resp[4..<10])
                    let macStr = macToString(mac)

                    let nameOffset = 13
                    var deviceName = ""
                    if nameOffset < resp.count {
                        let nameBytes = Array(resp[nameOffset...])
                        if let s = String(bytes: nameBytes, encoding: .utf8) {
                            deviceName = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                        }
                    }

                    // Override status with ground truth
                    let isConnected = connectedMacs.contains(macStr)
                    let isPrimary = macStr == activeMac

                    let status = Int(resp[10])
                    let boseProduct = (status & 0x04) != 0

                    results.append((name: name, info: DeviceInfo(
                        mac: respMac,
                        name: deviceName,
                        connected: isConnected,
                        primary: isPrimary,
                        boseProduct: boseProduct
                    )))
                }
                return results
            }
        } catch {
            return nil
        }
    }

    /// Connect a device by MAC address.
    /// Send: [0x04, 0x01, 0x05, 0x07, 0x00] + mac (0x00 prefix = connect by MAC)
    /// Accept ACK (0x07) or RESULT (0x06) as success.
    func connectDevice(_ mac: [UInt8]) -> Bool {
        guard mac.count == 6 else { return false }
        do {
            return try withRFCOMM { channel in
                let cmd: [UInt8] = [0x04, 0x01, OP_START, 0x07, 0x00] + mac
                guard let resp = sendBMAP(channel, bytes: cmd, timeout: 5.0) else {
                    return false
                }
                return resp.count >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
            }
        } catch {
            return false
        }
    }

    /// Disconnect a device by MAC address.
    /// Send: [0x04, 0x02, 0x05, 0x06] + mac
    func disconnectDevice(_ mac: [UInt8]) -> Bool {
        guard mac.count == 6 else { return false }
        do {
            return try withRFCOMM { channel in
                let cmd: [UInt8] = [0x04, 0x02, OP_START, 0x06] + mac
                guard let resp = sendBMAP(channel, bytes: cmd, timeout: 3.0) else {
                    return false
                }
                return resp.count >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
            }
        } catch {
            return false
        }
    }

    /// Get firmware version string.
    /// Send: [0x00, 0x05, 0x01, 0x00]
    /// Send a GET query and parse the response as a UTF-8 string (payload from byte 4).
    private func getStringField(block: UInt8, func fn: UInt8, payloadOffset: Int = 4) -> String? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [block, fn, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count > payloadOffset, resp[2] == OP_RESP else { return nil }
                return String(bytes: Array(resp[payloadOffset...]), encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
        } catch {
            return nil
        }
    }

    func getFirmware() -> String? { getStringField(block: 0x00, func: 0x05) }

    // MARK: - Volume & Media

    /// Get volume (max, current).
    /// Send: [0x05, 0x05, 0x01, 0x00]
    /// Response byte 4 = max, byte 5 = current
    func getVolume() -> (max: Int, current: Int)? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x05, 0x05, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 6, resp[2] == OP_RESP else { return nil }
                return (max: Int(resp[4]), current: Int(resp[5]))
            }
        } catch {
            return nil
        }
    }

    /// Set volume level (0-31).
    /// Send: [0x05, 0x05, 0x02, 0x01, {level}]
    func setVolume(_ level: Int) -> Bool {
        guard level >= 0 && level <= 31 else { return false }
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x05, 0x05, OP_SET, 0x01, UInt8(level)]) else {
                    return false
                }
                return resp.count >= 4 && (resp[2] == OP_RESP || resp[2] == OP_ACK)
            }
        } catch {
            return false
        }
    }

    /// Send media control command.
    /// Send: [0x05, 0x03, 0x05, 0x01, {action}]
    /// Actions: 0x01=play, 0x02=pause, 0x03=next, 0x04=prev
    func sendMediaControl(_ action: UInt8) -> Bool {
        do {
            return try withRFCOMM { channel in
                let resp = sendBMAP(channel, bytes: [0x05, 0x03, OP_START, 0x01, action])
                return resp != nil
            }
        } catch {
            return false
        }
    }

    /// Get audio codec info.
    /// Send: [0x05, 0x04, 0x01, 0x00]
    func getAudioCodec() -> String? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x05, 0x04, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                let payload = Array(resp[4...])
                // Try UTF-8 interpretation first
                if let str = String(bytes: payload, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                   !str.isEmpty {
                    return str
                }
                // Fall back to hex representation
                return payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            }
        } catch {
            return nil
        }
    }

    // MARK: - Paired Devices

    /// Get paired devices.
    /// Send: [0x04, 0x04, 0x01, 0x00]
    func getPairedDevices() -> [[UInt8]] {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x04, 0x04, OP_GET, 0x00]) else {
                    return []
                }
                guard resp.count >= 8, resp[2] == OP_RESP else { return [] }
                let plen = Int(resp[3])
                guard plen >= 7, resp.count >= 4 + plen else { return [] }
                var devices: [[UInt8]] = []
                for i in stride(from: 5, to: 4 + plen, by: 6) {
                    if i + 6 <= resp.count {
                        devices.append(Array(resp[i..<i+6]))
                    }
                }
                return devices
            }
        } catch {
            return []
        }
    }

    // MARK: - Device Info Strings

    func getSerialNumber() -> String? { getStringField(block: 0x00, func: 0x07) }
    func getProductName()  -> String? { getStringField(block: 0x00, func: 0x0F) }
    func getPlatform()     -> String? { getStringField(block: 0x12, func: 0x0D) }
    func getCodename()     -> String? { getStringField(block: 0x12, func: 0x0C) }

    // MARK: - Device Settings

    /// Device name has a 0x00 prefix at byte 4, so name starts at byte 5.
    func getDeviceName() -> String? { getStringField(block: 0x01, func: 0x02, payloadOffset: 5) }

    /// Set device name.
    /// Send: [0x01, 0x02, 0x06, len, 0x00, name_bytes...]
    func setDeviceName(_ name: String) -> Bool {
        guard let nameData = name.data(using: .utf8), nameData.count <= 30 else { return false }
        do {
            return try withRFCOMM { channel in
                var cmd: [UInt8] = [0x01, 0x02, OP_SET, UInt8(nameData.count + 1), 0x00]
                cmd.append(contentsOf: Array(nameData))
                guard let resp = sendBMAP(channel, bytes: cmd) else {
                    return false
                }
                return resp.count >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
            }
        } catch {
            return false
        }
    }

    /// Get multipoint enabled state.
    /// Send: [0x01, 0x0A, 0x01, 0x00]
    /// Response byte 4: 0x07=on, 0x00=off
    func getMultipoint() -> Bool? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x01, 0x0A, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                return resp[4] != 0
            }
        } catch {
            return nil
        }
    }

    /// Set multipoint on/off.
    /// Send: [0x01, 0x0A, 0x02, 0x01, {0x07/0x00}]
    func setMultipoint(_ enabled: Bool) -> Bool {
        do {
            return try withRFCOMM { channel in
                let value: UInt8 = enabled ? 0x07 : 0x00
                guard let resp = sendBMAP(channel, bytes: [0x01, 0x0A, OP_SET_GET, 0x01, value]) else {
                    return false
                }
                return resp.count >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
            }
        } catch {
            return false
        }
    }

    /// Get auto-off timer bytes.
    /// Send: [0x01, 0x0B, 0x01, 0x00]
    func getAutoOffTimer() -> [UInt8]? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x01, 0x0B, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                return Array(resp[4...])
            }
        } catch {
            return nil
        }
    }

    /// Get immersion level bytes.
    /// Send: [0x01, 0x09, 0x01, 0x00]
    func getImmersionLevel() -> [UInt8]? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x01, 0x09, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                return Array(resp[4...])
            }
        } catch {
            return nil
        }
    }

    // MARK: - CNC Level (AudioModes SettingsConfig)

    /// Get AudioModes SettingsConfig: cncLevel, autoCNC, spatial, windBlock, ancToggle.
    /// Send: [0x1F, 0x0A, 0x01, 0x00]
    /// Response payload: 5 bytes [cncLevel, autoCNC, spatial, windBlock, ancToggle]
    func getCncLevel() -> Int? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x1F, 0x0A, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                return Int(resp[4])
            }
        } catch {
            return nil
        }
    }

    /// Set CNC level (custom ANC depth). Preserves other SettingsConfig fields.
    /// Send: [0x1F, 0x0A, 0x02, 0x05, {cncLevel}, {autoCNC}, {spatial}, {windBlock}, {ancToggle}]
    func setCncLevel(_ level: Int) -> Bool {
        guard level >= 0 && level <= 10 else { return false }

        do {
            return try withRFCOMM { channel in
                // Read current config first to preserve other fields
                guard let current = sendBMAP(channel, bytes: [0x1F, 0x0A, OP_GET, 0x00]),
                      current.count >= 9, current[2] == OP_RESP else { return false }
                let autoCnc = current[5]
                let spatial = current[6]
                let windBlock = current[7]
                let ancToggle = current[8]

                let cmd: [UInt8] = [0x1F, 0x0A, OP_SET_GET, 0x05,
                    UInt8(level), autoCnc, spatial, windBlock, ancToggle]
                guard let resp = sendBMAP(channel, bytes: cmd) else { return false }
                return resp.count >= 4 && resp[2] == OP_RESP
            }
        } catch {
            return false
        }
    }

    // MARK: - Sensors

    /// Get wear state.
    /// Send: [0x08, 0x07, 0x01, 0x00]
    /// Response byte 4: 0x04 = on head
    func getWearState() -> Bool? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x08, 0x07, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                return resp[4] == 0x04
            }
        } catch {
            return nil
        }
    }

    /// Get EQ settings.
    /// Send: [0x01, 0x07, 0x01, 0x00]
    /// Response: 12 bytes payload, 3x [0xF6, 0x0A, band_id, value]
    func getEQ() -> (bass: Int, mid: Int, treble: Int)? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x01, 0x07, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 16, resp[2] == OP_RESP else { return nil }
                let bass = Int(Int8(bitPattern: resp[6]))
                let mid = Int(Int8(bitPattern: resp[10]))
                let treble = Int(Int8(bitPattern: resp[14]))
                return (bass: bass, mid: mid, treble: treble)
            }
        } catch {
            return nil
        }
    }

    /// Set a single EQ band. Uses SET_GET operator (0x02).
    /// Send: [0x01, 0x07, 0x02, 0x02, {value}, {band}]
    /// band: 0=bass, 1=mid, 2=treble. value: signed byte -10 to +10.
    func setEQBand(_ band: Int, value: Int) -> Bool {
        guard band >= 0 && band <= 2 else { return false }
        guard value >= -10 && value <= 10 else { return false }

        do {
            return try withRFCOMM { channel in
                let cmd: [UInt8] = [0x01, 0x07, OP_SET_GET, 0x02, UInt8(bitPattern: Int8(value)), UInt8(band)]
                guard let resp = sendBMAP(channel, bytes: cmd) else { return false }
                return resp.count >= 4 && resp[2] == OP_RESP
            }
        } catch {
            return false
        }
    }

    /// Set all three EQ bands in a single RFCOMM session.
    func setEQ(bass: Int, mid: Int, treble: Int) -> Bool {
        guard (-10...10).contains(bass), (-10...10).contains(mid), (-10...10).contains(treble) else { return false }

        do {
            return try withRFCOMM { channel in
                for (band, value) in [(0, bass), (1, mid), (2, treble)] {
                    let cmd: [UInt8] = [0x01, 0x07, OP_SET_GET, 0x02, UInt8(bitPattern: Int8(value)), UInt8(band)]
                    let resp = sendBMAP(channel, bytes: cmd)
                    guard resp != nil && resp!.count >= 4 && resp![2] == OP_RESP else { return false }
                }
                return true
            }
        } catch {
            return false
        }
    }

    // MARK: - Bulk State Query

    /// Complete headphone state snapshot, fetched in a single RFCOMM session.
    struct HeadphoneState {
        var batteryLevel: Int = 0
        var batteryCharging: Bool = false
        var ancMode: Int = 0  // 0=quiet, 1=aware, 2=custom1, 3=custom2
        var volume: Int = 0
        var volumeMax: Int = 31
        var connectedDevices: [[UInt8]] = []   // audio-connected (from 05,01)
        var aclConnectedDevices: [[UInt8]] = [] // BT-connected (from per-device 04,05)
        var firmware: String = ""
        var serialNumber: String = ""
        var productName: String = ""
        var platform: String = ""
        var codename: String = ""
        var audioCodec: String = ""
        var deviceName: String = ""
        var multipointEnabled: Bool = false
        var autoOffTimer: [UInt8] = []
        var immersionLevel: [UInt8] = []
        var onHead: Bool = false
        var eq: (bass: Int, mid: Int, treble: Int) = (0, 0, 0)

        var ancModeName: String {
            switch ancMode {
            case 0: return "quiet"
            case 1: return "aware"
            case 2: return "custom1"
            case 3: return "custom2"
            default: return "unknown"
            }
        }
    }

    /// Fetch all state in a single RFCOMM session (minimizes connect/disconnect cycles).
    func getAllState() -> HeadphoneState? {
        do {
            return try withRFCOMM { channel in
                var state = HeadphoneState()

                // Battery
                if let resp = sendBMAP(channel, bytes: [0x02, 0x02, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.batteryLevel = min(100, max(0, Int(resp[4])))
                    state.batteryCharging = resp.count >= 8 ? resp[7] != 0 : false
                }

                // ANC mode
                if let resp = sendBMAP(channel, bytes: [0x1F, 0x03, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.ancMode = Int(resp[4])
                }

                // Volume
                if let resp = sendBMAP(channel, bytes: [0x05, 0x05, OP_GET, 0x00]),
                   resp.count >= 6, resp[2] == OP_RESP {
                    state.volumeMax = Int(resp[4])
                    state.volume = Int(resp[5])
                }

                // Connected devices (ground truth)
                if let resp = sendBMAP(channel, bytes: [0x05, 0x01, OP_GET, 0x00]),
                   resp.count >= 7, resp[0] == 0x05, resp[1] == 0x01, resp[2] == OP_RESP {
                    let count = Int(resp[6])
                    for i in 0..<count {
                        let offset = 7 + (i * 6)
                        guard offset + 6 <= resp.count else { break }
                        state.connectedDevices.append(Array(resp[offset..<(offset + 6)]))
                    }
                }

                // Per-device ACL connection status (04,05 per known device)
                for (_, mac) in boseKnownDevices {
                    let cmd: [UInt8] = [0x04, 0x05, OP_GET, 0x06] + mac
                    if let resp = sendBMAP(channel, bytes: cmd, timeout: 2.0),
                       resp.count >= 11, resp[2] == OP_RESP {
                        let status = Int(resp[10])
                        if (status & 0x01) != 0 {  // bit 0 = ACL connected
                            state.aclConnectedDevices.append(mac)
                        }
                    }
                }

                // Firmware
                if let resp = sendBMAP(channel, bytes: [0x00, 0x05, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.firmware = String(bytes: Array(resp[4...]), encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                }

                // Serial number
                if let resp = sendBMAP(channel, bytes: [0x00, 0x07, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.serialNumber = String(bytes: Array(resp[4...]), encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                }

                // Product name
                if let resp = sendBMAP(channel, bytes: [0x00, 0x0F, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.productName = String(bytes: Array(resp[4...]), encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                }

                // Platform
                if let resp = sendBMAP(channel, bytes: [0x12, 0x0D, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.platform = String(bytes: Array(resp[4...]), encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                }

                // Codename
                if let resp = sendBMAP(channel, bytes: [0x12, 0x0C, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.codename = String(bytes: Array(resp[4...]), encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                }

                // Audio codec
                if let resp = sendBMAP(channel, bytes: [0x05, 0x04, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    let payload = Array(resp[4...])
                    if let str = String(bytes: payload, encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                       !str.isEmpty {
                        state.audioCodec = str
                    } else {
                        state.audioCodec = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    }
                }

                // Device name
                if let resp = sendBMAP(channel, bytes: [0x01, 0x02, OP_GET, 0x00]),
                   resp.count >= 6, resp[2] == OP_RESP {
                    state.deviceName = String(bytes: Array(resp[5...]), encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                }

                // Multipoint
                if let resp = sendBMAP(channel, bytes: [0x01, 0x0A, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.multipointEnabled = resp[4] != 0
                }

                // Auto-off timer
                if let resp = sendBMAP(channel, bytes: [0x01, 0x0B, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.autoOffTimer = Array(resp[4...])
                }

                // Immersion level
                if let resp = sendBMAP(channel, bytes: [0x01, 0x09, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.immersionLevel = Array(resp[4...])
                }

                // Wear state
                if let resp = sendBMAP(channel, bytes: [0x08, 0x07, OP_GET, 0x00]),
                   resp.count >= 5, resp[2] == OP_RESP {
                    state.onHead = resp[4] == 0x04
                }

                // EQ
                if let resp = sendBMAP(channel, bytes: [0x01, 0x07, OP_GET, 0x00]),
                   resp.count >= 16, resp[2] == OP_RESP {
                    state.eq = (
                        bass: Int(Int8(bitPattern: resp[6])),
                        mid: Int(Int8(bitPattern: resp[10])),
                        treble: Int(Int8(bitPattern: resp[14]))
                    )
                }

                return state
            }
        } catch {
            return nil
        }
    }

    // MARK: - Raw

    /// Send arbitrary BMAP bytes and return the raw response.
    func sendRaw(_ bytes: [UInt8]) -> [UInt8]? {
        do {
            return try withRFCOMM { channel in
                return sendBMAP(channel, bytes: bytes)
            }
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Convert 6-byte MAC to colon-separated uppercase hex string.
    func macToString(_ mac: [UInt8]) -> String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Look up a friendly name for a MAC address.
    func nameForMac(_ mac: [UInt8]) -> String {
        for (name, addr) in boseKnownDevices {
            if addr == mac { return name }
        }
        return macToString(mac)
    }

    /// Look up MAC bytes for a friendly device name.
    func macForName(_ name: String) -> [UInt8]? {
        let lower = name.lowercased()
        return boseKnownDevices.first { $0.name == lower }?.mac
    }
}
