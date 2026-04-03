/// BoseRFCOMM: Direct RFCOMM BMAP protocol module for Bose QC Ultra 2
/// On-demand: open channel 8, send BMAP bytes, read response, close.
/// Both Mac and phone can independently control headphones this way.
///
/// Protocol: BMAP (Bose Music Application Protocol)
/// Format: [block, function, operator, length, ...payload]
/// Operators: GET=0x01, RESP=0x03, ERR=0x04, START=0x05, SET/RESULT=0x06, ACK=0x07

import Foundation
import IOBluetooth

// MARK: - Constants

let BOSE_MAC = "E4:58:BC:C0:2F:72"
let RFCOMM_CHANNEL: BluetoothRFCOMMChannelID = 8

// BMAP operators
let OP_GET:   UInt8 = 0x01
let OP_RESP:  UInt8 = 0x03
let OP_ERR:   UInt8 = 0x04
let OP_START: UInt8 = 0x05
let OP_SET:   UInt8 = 0x06  // Also RESULT
let OP_ACK:   UInt8 = 0x07

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
    case bmapVerificationFailed
    case timeout

    var description: String {
        switch self {
        case .deviceNotFound:
            return "Bluetooth device not found: \(BOSE_MAC)"
        case .connectionFailed(let status):
            return "RFCOMM connection failed: \(status)"
        case .bmapVerificationFailed:
            return "BMAP protocol verification failed (firmware query returned unexpected data)"
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
/// On-demand pattern: each command opens RFCOMM channel 8, sends BMAP bytes,
/// reads the response, then closes. No persistent connection. This allows
/// both Mac and phone to independently control the headphones.
class BoseRFCOMM {

    private let delegate = RFCOMMDelegate()

    // MARK: - Core RFCOMM

    /// Opens RFCOMM channel 8 to headphones, runs body, then closes.
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
                return resp.count >= 4 && (resp[2] == OP_ACK || resp[2] == OP_SET)
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
                return resp.count >= 4 && (resp[2] == OP_ACK || resp[2] == OP_SET)
            }
        } catch {
            return false
        }
    }

    /// Switch audio to a device. On QC Ultra 2, CONNECT (0x01) both connects
    /// the device AND makes it the active audio source.
    func switchToDevice(_ mac: [UInt8]) -> Bool {
        return connectDevice(mac)
    }

    /// Get firmware version string.
    /// Send: [0x00, 0x05, 0x01, 0x00]
    func getFirmware() -> String? {
        do {
            return try withRFCOMM { channel in
                guard let resp = sendBMAP(channel, bytes: [0x00, 0x05, OP_GET, 0x00]) else {
                    return nil
                }
                guard resp.count >= 5, resp[2] == OP_RESP else { return nil }
                let fwBytes = Array(resp[4...])
                return String(bytes: fwBytes, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
        } catch {
            return nil
        }
    }

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
