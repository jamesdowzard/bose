/// bose-ctl: Manage Bose QC Ultra connections via RFCOMM protocol
/// Tries bosed daemon (Unix socket) first for instant response (<100ms),
/// falls back to direct RFCOMM if daemon is not running.
/// Protocol: [block, function, operator, length, ...payload]
/// Operators: 0x01=GET, 0x03=RESP, 0x04=ERR, 0x05=START, 0x06=SET, 0x07=ACK

import Foundation
import IOBluetooth

// === Configuration ===
let BOSE_MAC = "E4:58:BC:C0:2F:72"
let RFCOMM_CHANNEL: UInt8 = 2
let DAEMON_SOCKET = "/tmp/bosed.sock"

// Known device names — add yours here
var knownDevices: [String: [UInt8]] = [
    "mac":    [0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27],
    "phone":  [0xA8, 0x76, 0x50, 0xD3, 0xB1, 0x1B],
    "ipad":   [0xF4, 0x81, 0xC4, 0xB5, 0xFA, 0xAB],
    "iphone": [0xF8, 0x4D, 0x89, 0xC4, 0xB6, 0xED],
    "tv":     [0x14, 0xC1, 0x4E, 0xB7, 0xCB, 0x68],  // Watkin Lounge TV (Google/Chromecast)
]

// === Daemon Client ===
/// Try daemon first, return true if command was handled
func tryDaemon(_ cmd: String, _ args: [String]) -> Bool {
    var request: [String: Any]

    switch cmd {
    case "status", "s":
        request = ["cmd": "status"]
    case "connect", "c":
        guard args.count >= 3 else { return false }
        request = ["cmd": "connect", "device": args[2]]
    case "disconnect", "d":
        guard args.count >= 3 else { return false }
        request = ["cmd": "disconnect", "device": args[2]]
    case "swap":
        guard args.count >= 3 else { return false }
        // Swap may take >2s, use longer timeout via raw socket
        request = ["cmd": "swap", "device": args[2]]
    case "raw":
        guard args.count >= 3 else { return false }
        request = ["cmd": "raw", "bytes": args[2]]
    default:
        return false
    }

    // For swap/connect which take longer, we need a longer timeout
    let needsLongTimeout = (cmd == "swap" || cmd == "connect" || cmd == "c")

    guard let response = daemonRequestWithTimeout(request, timeout: needsLongTimeout ? 15 : 5) else {
        return false
    }

    guard let ok = response["ok"] as? Bool else { return false }

    if !ok {
        if let error = response["error"] as? String {
            // "not connected" means daemon is running but RFCOMM isn't established —
            // fall back to direct RFCOMM which can try channel cycling
            if error == "not connected" { return false }
            print("Error: \(error)")
        }
        return true
    }

    guard let data = response["data"] as? [String: Any] else {
        print("OK")
        return true
    }

    // Format output to match original bose-ctl style
    switch cmd {
    case "status", "s":
        if let active = data["active"] as? String, let activeMac = data["active_mac"] as? String {
            print("Active:   \(active) (\(activeMac))")
        }
        if let slots = data["slots"] as? Int {
            print("Slots:    \(slots)/2 connected")
        }
        if let paired = data["paired"] as? [String], let macs = data["paired_macs"] as? [String] {
            print("Paired:   \(paired.count) devices")
            for (i, name) in paired.enumerated() {
                let mac = i < macs.count ? macs[i] : "?"
                print("  \(i+1). \(name) (\(mac))")
            }
        }
        if let fw = data["firmware"] as? String {
            print("Firmware: \(fw)")
        }
    case "connect", "c":
        if let device = data["connected"] as? String {
            print("OK — \(device) connected.")
        }
    case "disconnect", "d":
        if let device = data["disconnected"] as? String {
            print("OK — \(device) disconnected.")
        }
    case "swap":
        if let device = data["swapped"] as? String {
            print("Swapped to \(device)!")
        }
    case "raw":
        if let bytes = data["bytes"] as? String, let length = data["length"] as? Int {
            print("Response (\(length) bytes): \(bytes)")
        }
    default:
        break
    }

    return true
}

/// Send daemon request with configurable timeout
func daemonRequestWithTimeout(_ json: [String: Any], timeout: Int) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        DAEMON_SOCKET.withCString { cstr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                _ = strcpy(dest, cstr)
            }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Foundation.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return nil }

    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    guard let requestData = try? JSONSerialization.data(withJSONObject: json),
          let requestStr = String(data: requestData, encoding: .utf8) else { return nil }

    let sent = requestStr.withCString { ptr in
        write(fd, ptr, requestStr.utf8.count)
    }
    guard sent > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: 8192)
    let bytesRead = read(fd, &buffer, buffer.count)
    guard bytesRead > 0 else { return nil }

    let responseStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
    guard let responseData = responseStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { return nil }

    return parsed
}

// === Direct RFCOMM (fallback) ===
class BoseConnection: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var responses: [Data] = []
    private let semaphore = DispatchSemaphore(value: 0)

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        semaphore.signal()
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int) {
        responses.append(Data(bytes: ptr, count: len))
        semaphore.signal()
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {}

    private func tryChannels(_ device: IOBluetoothDevice) -> Bool {
        let channels: [UInt8] = [2, 14, 22, 25]
        for chId in channels {
            var chRef: IOBluetoothRFCOMMChannel? = nil
            let result = device.openRFCOMMChannelSync(&chRef, withChannelID: chId, delegate: self)
            if result == 0, let ch = chRef, ch.isOpen() {
                channel = ch
                _ = semaphore.wait(timeout: .now() + 1)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                if let r = send([0x00, 0x05, 0x01, 0x00], timeout: 1.5), r.count >= 4, r[0] == 0x00, r[1] == 0x05 {
                    return true
                }
                ch.close()
                channel = nil
            } else {
                chRef?.close()
            }
        }
        return false
    }

    func connect() -> Bool {
        guard let device = IOBluetoothDevice(addressString: BOSE_MAC) else {
            print("Error: Headphones not found. Are they paired?")
            return false
        }
        if !device.isConnected() {
            print("Error: Headphones not connected to Mac.")
            return false
        }
        // Try channels directly first
        if tryChannels(device) { return true }
        // Cycle BT connection — quick disconnect/reconnect frees channels from audioaccessoryd
        device.closeConnection()
        Thread.sleep(forTimeInterval: 2)
        device.openConnection()
        Thread.sleep(forTimeInterval: 3)
        if tryChannels(device) { return true }
        print("Error: No RFCOMM channel available. Try toggling Bluetooth in System Settings.")
        return false
    }

    func send(_ bytes: [UInt8], timeout: TimeInterval = 3) -> Data? {
        responses.removeAll()
        var data = Data(bytes)
        let wr = data.withUnsafeMutableBytes { ptr -> IOReturn in
            channel!.writeSync(ptr.baseAddress!, length: UInt16(bytes.count))
        }
        if wr != 0 { return nil }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            if !responses.isEmpty {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                break
            }
        }
        return responses.first
    }

    func close() { channel?.close() }
}

// === Helpers ===
func macStr(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
}

func nameFor(_ mac: [UInt8]) -> String {
    for (name, addr) in knownDevices where addr == mac { return name }
    return macStr(mac)
}

func parsePaired(_ data: Data) -> [[UInt8]] {
    guard data.count >= 8, data[2] == 0x03 else { return [] }
    let plen = Int(data[3])
    guard plen >= 7, data.count >= 4 + plen else { return [] }
    var devices: [[UInt8]] = []
    for i in stride(from: 5, to: 4 + plen, by: 6) {
        if i + 6 <= data.count { devices.append(Array(data[i..<i+6])) }
    }
    return devices
}

// === Direct RFCOMM Commands ===
func status(_ b: BoseConnection) {
    if let r = b.send([0x04, 0x09, 0x01, 0x00]), r.count >= 10, r[2] == 0x03 {
        print("Active:   \(nameFor(Array(r[4..<10]))) (\(macStr(Array(r[4..<10]))))")
    }
    if let r = b.send([0x05, 0x01, 0x01, 0x00]), r.count >= 7 {
        print("Slots:    \(r[6])/2 connected")
    }
    if let r = b.send([0x04, 0x04, 0x01, 0x00]) {
        let devs = parsePaired(r)
        print("Paired:   \(devs.count) devices")
        for (i, mac) in devs.enumerated() {
            print("  \(i+1). \(nameFor(mac)) (\(macStr(mac)))")
        }
    }
    if let r = b.send([0x00, 0x05, 0x01, 0x00]), r.count >= 5, r[2] == 0x03 {
        let fw = String(data: r[4..<4+Int(r[3])], encoding: .utf8) ?? "?"
        print("Firmware: \(fw)")
    }
}

func connectDevice(_ b: BoseConnection, _ name: String) {
    guard let mac = knownDevices[name.lowercased()] else {
        print("Unknown device '\(name)'. Known: \(knownDevices.keys.sorted().joined(separator: ", "))")
        return
    }
    print("Connecting \(name)...")
    if let r = b.send([0x04, 0x02, 0x05, 0x06] + mac, timeout: 10) {
        if r.count >= 4, r[2] == 0x07 { print("OK — \(name) connected.") }
        else if r.count > 4, r[2] == 0x04, r[4] == 0x0b { print("Error: \(name) not paired. Re-pair from the device.") }
        else if r.count >= 4, r[2] == 0x04 { print("Error: 0x\(String(format: "%02x", r.count > 4 ? r[4] : 0))") }
    } else { print("No response.") }
}

func disconnectDevice(_ b: BoseConnection, _ name: String) {
    guard let mac = knownDevices[name.lowercased()] else {
        print("Unknown device '\(name)'. Known: \(knownDevices.keys.sorted().joined(separator: ", "))")
        return
    }
    if name.lowercased() == "mac" {
        print("Warning: Disconnecting Mac closes this channel. Use blueutil instead:")
        print("  blueutil --disconnect \(BOSE_MAC)")
        return
    }
    print("Disconnecting \(name)...")
    if let r = b.send([0x04, 0x03, 0x05, 0x06] + mac, timeout: 5) {
        if r.count >= 4, r[2] == 0x07 { print("OK — \(name) disconnected.") }
        else { print("Done (device may not have been connected).") }
    }
}

func swap(_ b: BoseConnection, _ name: String) {
    guard let targetMac = knownDevices[name.lowercased()] else {
        print("Unknown device '\(name)'. Known: \(knownDevices.keys.sorted().joined(separator: ", "))")
        return
    }
    let macMac = knownDevices["mac"]!

    guard let r = b.send([0x04, 0x04, 0x01, 0x00]) else {
        print("Error: Could not query devices."); return
    }
    let paired = parsePaired(r)

    // Disconnect any non-Mac, non-target device
    for mac in paired where mac != macMac && mac != targetMac {
        print("Disconnecting \(nameFor(mac))...")
        _ = b.send([0x04, 0x03, 0x05, 0x06] + mac, timeout: 5)
        Thread.sleep(forTimeInterval: 1)
    }

    // Connect target
    print("Connecting \(name)...")
    if let r2 = b.send([0x04, 0x02, 0x05, 0x06] + targetMac, timeout: 10) {
        if r2.count >= 4, r2[2] == 0x07 { print("Swapped to \(name)!") }
        else if r2.count > 4, r2[2] == 0x04, r2[4] == 0x0b { print("Error: \(name) not paired.") }
        else if r2.count >= 4, r2[2] == 0x04 { print("Error: 0x\(String(format: "%02x", r2.count > 4 ? r2[4] : 0))") }
    }
}

// === Main ===
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("""
    bose-ctl — Manage Bose QC Ultra connections

    Usage:
      bose-ctl status              Show connection status
      bose-ctl connect <device>    Connect a paired device
      bose-ctl disconnect <device> Disconnect a device
      bose-ctl swap <device>       Swap 2nd slot to this device
      bose-ctl devices             List known device aliases

    Devices: \(knownDevices.keys.sorted().joined(separator: ", "))
    """)
    exit(0)
}

let cmd = args[1].lowercased()

if cmd == "devices" {
    print("Known devices:")
    for (n, m) in knownDevices.sorted(by: { $0.key < $1.key }) { print("  \(n): \(macStr(m))") }
    exit(0)
}

// Try daemon first (instant, <100ms)
if tryDaemon(cmd, args) {
    exit(0)
}

// Daemon not available — fall back to direct RFCOMM (slow, 5-7s)
let bose = BoseConnection()
guard bose.connect() else { exit(1) }
defer { bose.close() }

switch cmd {
case "status", "s":       status(bose)
case "connect", "c":      guard args.count >= 3 else { print("Usage: bose-ctl connect <device>"); exit(1) }; connectDevice(bose, args[2])
case "disconnect", "d":   guard args.count >= 3 else { print("Usage: bose-ctl disconnect <device>"); exit(1) }; disconnectDevice(bose, args[2])
case "swap":              guard args.count >= 3 else { print("Usage: bose-ctl swap <device>"); exit(1) }; swap(bose, args[2])
case "raw":
    guard args.count >= 3 else { print("Usage: bose-ctl raw <hex,bytes e.g. 04,07,01,00>"); exit(1) }
    let hexBytes = args[2].split(separator: ",").compactMap { UInt8($0, radix: 16) }
    guard !hexBytes.isEmpty else { print("Invalid hex"); exit(1) }
    print("Sending: \(hexBytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
    if let r = bose.send(hexBytes, timeout: 5) {
        print("Response (\(r.count) bytes): \(r.map { String(format: "%02x", $0) }.joined(separator: " "))")
    } else { print("No response.") }
default:                  print("Unknown command: \(cmd)")
}
