/// bose-ctl: CLI for Bose QC Ultra headphone control
/// Direct RFCOMM — Mac opens channel 8 independently, no daemon needed.

import Foundation

let bose = BoseRFCOMM()

let MAC_BOSE = "E4:58:BC:C0:2F:72"

// === Blueutil (Mac BT audio profile) ===

@discardableResult
func runBlueutil(_ args: [String]) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/blueutil")
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

// === Phone TCP (Tailscale) ===

let PHONE_IP = "100.97.121.67"
let PHONE_TCP_PORT: UInt16 = 8899

/// Send a command to the phone's BoseService TCP server
@discardableResult
func phoneTcp(_ json: String) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = PHONE_TCP_PORT.bigEndian
    inet_pton(AF_INET, PHONE_IP, &addr.sin_addr)

    // 15-second timeout (EQ SET via GATT takes ~8s)
    var tv = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { return nil }

    let data = json.data(using: .utf8)!
    _ = data.withUnsafeBytes { send(fd, $0.baseAddress!, data.count, 0) }

    var buf = [UInt8](repeating: 0, count: 4096)
    let n = recv(fd, &buf, buf.count, 0)
    guard n > 0 else { return nil }
    return String(bytes: buf[0..<n], encoding: .utf8)
}

/// Tell phone to claim A2DP audio routing
func phoneAudioClaim() {
    if let resp = phoneTcp("{\"cmd\":\"audio_claim\"}") {
        if resp.contains("\"ok\":true") {
            // Success — phone will route audio to Bose
        }
    }
    // Best effort — don't fail the whole command if phone is unreachable
}

// === Helpers ===

func fail(_ message: String) -> Never {
    print("Error: \(message)")
    exit(1)
}

func macForName(_ name: String) -> [UInt8] {
    guard let mac = bose.macForName(name) else {
        fail("unknown device: \(name)")
    }
    return mac
}

func nameForMac(_ mac: [UInt8]) -> String {
    return bose.nameForMac(mac)
}

func isMacDevice(_ mac: [UInt8]) -> Bool {
    return bose.macToString(mac) == "BC:D0:74:11:DB:27"
}

func isPhoneDevice(_ mac: [UInt8]) -> Bool {
    return bose.macToString(mac) == "A8:76:50:D3:B1:1B"
}

// === Commands ===

func cmdStatus() {
    // Single RFCOMM session for all queries
    do {
        try bose.withRFCOMM { channel in
            // Connected devices (ground truth)
            let connResp = bose.sendBMAP(channel, bytes: [0x05, 0x01, OP_GET, 0x00])
            var connectedMacs: [[UInt8]] = []
            if let cr = connResp, cr.count >= 7,
               cr[0] == 0x05, cr[1] == 0x01, cr[2] == OP_RESP {
                let count = Int(cr[6])
                for i in 0..<count {
                    let offset = 7 + (i * 6)
                    guard offset + 6 <= cr.count else { break }
                    connectedMacs.append(Array(cr[offset..<(offset + 6)]))
                }
            }

            // Active device
            var activeDeviceName: String? = nil
            let activeResp = bose.sendBMAP(channel, bytes: [0x04, 0x09, OP_GET, 0x00])
            if let ar = activeResp, ar.count >= 10, ar[2] == OP_RESP {
                let activeMac = Array(ar[4..<10])
                activeDeviceName = nameForMac(activeMac)
            }

            // Connected device names
            let connectedNames = connectedMacs.map { nameForMac($0) }

            // Slots
            let slot1 = connectedNames.count >= 1 ? connectedNames[0] : "—"
            let slot2 = connectedNames.count >= 2 ? connectedNames[1] : "—"

            if let active = activeDeviceName {
                print("Active:   \(active)")
            }
            if !connectedNames.isEmpty {
                print("Connected: \(connectedNames.joined(separator: ", "))")
            }
            print("Slots:    \(slot1) | \(slot2)")

            // Battery
            if let battResp = bose.sendBMAP(channel, bytes: [0x02, 0x02, OP_GET, 0x00]),
               battResp.count >= 5, battResp[2] == OP_RESP {
                let level = min(100, max(0, Int(battResp[4])))
                let charging = battResp.count >= 8 ? battResp[7] != 0 : false
                print("Battery:  \(level)%\(charging ? " ⚡" : "")")
            }

            // ANC
            if let ancResp = bose.sendBMAP(channel, bytes: [0x1F, 0x03, OP_GET, 0x00]),
               ancResp.count >= 5, ancResp[2] == OP_RESP {
                let mode: String
                switch ancResp[4] {
                case 0: mode = "quiet"
                case 1: mode = "aware"
                case 2: mode = "custom1"
                case 3: mode = "custom2"
                default: mode = "unknown(\(ancResp[4]))"
                }
                print("ANC:      \(mode)")
            }

            // Firmware
            if let fwResp = bose.sendBMAP(channel, bytes: [0x00, 0x05, OP_GET, 0x00]),
               fwResp.count >= 5, fwResp[2] == OP_RESP {
                let fwBytes = Array(fwResp[4...])
                if let fw = String(bytes: fwBytes, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")), !fw.isEmpty {
                    print("Firmware: \(fw)")
                }
            }
        }
    } catch {
        fail("headphones not reachable")
    }
}

func cmdBattery() {
    guard let result = bose.getBattery() else {
        fail("headphones not reachable")
    }
    print("\(result.level)%\(result.charging ? " ⚡" : "")")
}

func cmdAnc(_ mode: String?) {
    if let mode = mode {
        if !bose.setAncMode(mode) {
            fail("failed to set ANC mode")
        }
        // Read back to confirm
        if let current = bose.getAncMode() {
            print("ANC: \(current)")
        } else {
            print("ANC: \(mode)")
        }
    } else {
        guard let current = bose.getAncMode() else {
            fail("headphones not reachable")
        }
        print("ANC: \(current)")
    }
}

func cmdDevices() {
    guard let devices = bose.getAllDeviceInfo() else {
        fail("headphones not reachable")
    }
    for d in devices {
        let state = d.info.primary ? "●" : (d.info.connected ? "○" : "·")
        let devName = d.info.name
        print("  \(state) \(d.name)\(devName.isEmpty ? "" : " (\(devName))")")
    }
}

func cmdConnect(_ deviceName: String) {
    let mac = macForName(deviceName)

    // If connecting Mac, blueutil connect first for A2DP
    if isMacDevice(mac) {
        runBlueutil(["--connect", MAC_BOSE])
        Thread.sleep(forTimeInterval: 1.5)
    }

    // BMAP connect — multipoint keeps both devices connected
    if !bose.connectDevice(mac) {
        fail("failed to connect \(deviceName)")
    }

    // If switching to phone, tell phone to connect + claim A2DP
    if isPhoneDevice(mac) {
        phoneAudioClaim()
    }

    print("Switched to \(deviceName)")
}

func cmdDisconnect(_ deviceName: String) {
    let mac = macForName(deviceName)

    if !bose.disconnectDevice(mac) {
        fail("failed to disconnect \(deviceName)")
    }

    // If disconnecting Mac, also disconnect Mac BT stack
    if isMacDevice(mac) {
        runBlueutil(["--disconnect", MAC_BOSE])
    }

    print("Disconnected \(deviceName)")
}

func cmdSwap(_ targetName: String) {
    let targetMac = macForName(targetName)

    // If target is Mac, blueutil connect first so A2DP is ready
    if isMacDevice(targetMac) {
        runBlueutil(["--connect", MAC_BOSE])
        Thread.sleep(forTimeInterval: 1.5)
    }

    // BMAP connect target — multipoint keeps both devices connected,
    // audio routes to whichever got the last connect command.
    // No need to BMAP-disconnect others (kills ACL, disrupts A2DP).
    if !bose.connectDevice(targetMac) {
        fail("failed to swap to \(targetName)")
    }

    // If switching to phone, tell phone to connect + claim A2DP
    if isPhoneDevice(targetMac) {
        phoneAudioClaim()
    }

    print("Swapped to \(targetName)")
}

func cmdVolume(_ arg: String?) {
    if let level = arg.flatMap({ Int($0) }) {
        // SET volume
        guard level >= 0 && level <= 31 else { fail("volume must be 0-31") }
        guard let resp = bose.sendRaw([0x05, 0x05, 0x02, 0x01, UInt8(level)]) else {
            fail("volume set failed")
        }
        if resp.count >= 6 && resp[2] == OP_RESP {
            print("\(resp[5])/\(resp[4])")
        } else {
            print("Set to \(level)")
        }
    } else {
        // GET volume
        guard let resp = bose.sendRaw([0x05, 0x05, 0x01, 0x00]) else {
            fail("volume query failed")
        }
        if resp.count >= 6 && resp[2] == OP_RESP {
            print("\(resp[5])/\(resp[4])")
        }
    }
}

func cmdMultipoint(_ arg: String?) {
    if let toggle = arg {
        let value: UInt8 = (toggle == "on" || toggle == "true" || toggle == "1") ? 0x07 : 0x00
        _ = bose.sendRaw([0x01, 0x0A, 0x02, 0x01, value])
    }
    guard let resp = bose.sendRaw([0x01, 0x0A, 0x01, 0x00]) else {
        fail("multipoint query failed")
    }
    if resp.count >= 5 && resp[2] == OP_RESP {
        let enabled = (resp[4] & 0xFF) != 0
        print(enabled ? "on" : "off")
    }
}

func cmdMedia(_ action: UInt8) {
    _ = bose.sendRaw([0x05, 0x03, 0x05, 0x01, action])
    let names: [UInt8: String] = [0x01: "play", 0x02: "pause", 0x03: "next", 0x04: "prev"]
    print(names[action] ?? "sent")
}

func cmdEq(_ eqArgs: [String]) {
    if eqArgs.isEmpty {
        // GET via phone TCP
        if let resp = phoneTcp("{\"cmd\":\"eq\"}"),
           let data = try? JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any],
           let eq = data["data"] as? [String: Any] {
            let bass = eq["bass"] as? Int ?? 0
            let mid = eq["mid"] as? Int ?? 0
            let treble = eq["treble"] as? Int ?? 0
            print("bass: \(bass)  mid: \(mid)  treble: \(treble)  (range: -10 to +10)")
        } else {
            // Fallback to RFCOMM GET
            guard let resp = bose.sendRaw([0x01, 0x07, 0x01, 0x00]) else {
                fail("EQ query failed")
            }
            if resp.count >= 16 && resp[2] == OP_RESP {
                let bass = Int(Int8(bitPattern: resp[6]))
                let mid = Int(Int8(bitPattern: resp[10]))
                let treble = Int(Int8(bitPattern: resp[14]))
                print("bass: \(bass)  mid: \(mid)  treble: \(treble)  (range: -10 to +10)")
            }
        }
    } else {
        // SET via phone TCP (requires BLE GATT on phone)
        // Parse: bose-ctl eq bass=5 mid=2 treble=-3
        // Or:    bose-ctl eq 5 2 -3
        var json = "{\"cmd\":\"eq\""
        if eqArgs.count == 3, let b = Int(eqArgs[0]), let m = Int(eqArgs[1]), let t = Int(eqArgs[2]) {
            json += ",\"bass\":\(b),\"mid\":\(m),\"treble\":\(t)"
        } else {
            for arg in eqArgs {
                let parts = arg.split(separator: "=")
                guard parts.count == 2, let val = Int(parts[1]) else {
                    fail("Usage: bose-ctl eq bass=5 mid=2 treble=-3  OR  bose-ctl eq 5 2 -3")
                }
                json += ",\"\(parts[0])\":\(val)"
            }
        }
        json += "}"

        if let resp = phoneTcp(json) {
            if resp.contains("\"ok\":true") {
                // Re-read to show new values
                cmdEq([])
            } else {
                print("EQ set failed: \(resp)")
            }
        } else {
            fail("Phone unreachable (EQ SET requires BLE GATT via phone)")
        }
    }
}

func cmdRaw(_ hex: String) {
    // Parse hex string to bytes
    let clean = hex.replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "0x", with: "")
    var bytes: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        guard let next = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) else { break }
        let byteStr = String(clean[i..<next])
        guard let byte = UInt8(byteStr, radix: 16) else {
            fail("invalid hex: \(byteStr)")
        }
        bytes.append(byte)
        i = next
    }

    guard !bytes.isEmpty else { fail("no bytes to send") }

    guard let resp = bose.sendRaw(bytes) else {
        print("No response")
        return
    }

    let hexStr = resp.map { String(format: "%02x", $0) }.joined()
    print("Response (\(resp.count) bytes): \(hexStr)")

    // Try ASCII interpretation
    let asciiBytes = resp.count > 4 ? Array(resp[4...]) : resp
    if let ascii = String(bytes: asciiBytes, encoding: .utf8)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
       !ascii.isEmpty, ascii.allSatisfy({ $0.isASCII && ($0.isPunctuation || $0.isLetter || $0.isNumber || $0 == "." || $0 == "+" || $0 == "-" || $0 == "_") }) {
        print("ASCII: \(ascii)")
    }
}

// === Main ===

@main
struct BoseCtlApp {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("""
            bose-ctl — Bose QC Ultra 2 control (direct RFCOMM)

            Usage:
              bose-ctl status              Connection status, battery, ANC
              bose-ctl connect <device>    Switch audio to device
              bose-ctl disconnect <device> Disconnect device
              bose-ctl swap <device>       Disconnect others, switch to device
              bose-ctl battery             Battery level
              bose-ctl devices             All devices with connection state
              bose-ctl anc [mode]          Get/set ANC (quiet/aware/custom1/custom2)
              bose-ctl raw <hex>           Send raw BMAP bytes

            Devices: \(boseKnownDevices.map { $0.name }.joined(separator: ", "))
            """)
            exit(0)
        }

        let cmd = args[1].lowercased()

        switch cmd {
        case "status", "s":
            cmdStatus()
        case "battery", "b":
            cmdBattery()
        case "anc":
            cmdAnc(args.count >= 3 ? args[2] : nil)
        case "devices":
            cmdDevices()
        case "connect", "c":
            guard args.count >= 3 else { print("Usage: bose-ctl connect <device>"); exit(1) }
            cmdConnect(args[2].lowercased())
        case "disconnect", "d":
            guard args.count >= 3 else { print("Usage: bose-ctl disconnect <device>"); exit(1) }
            cmdDisconnect(args[2].lowercased())
        case "swap":
            guard args.count >= 3 else { print("Usage: bose-ctl swap <device>"); exit(1) }
            cmdSwap(args[2].lowercased())
        case "volume", "vol", "v":
            cmdVolume(args.count >= 3 ? args[2] : nil)
        case "multipoint", "mp":
            cmdMultipoint(args.count >= 3 ? args[2] : nil)
        case "play":
            cmdMedia(0x01)
        case "pause":
            cmdMedia(0x02)
        case "next":
            cmdMedia(0x03)
        case "prev":
            cmdMedia(0x04)
        case "eq":
            cmdEq(args.count >= 3 ? Array(args[2...]) : [])
        case "raw":
            guard args.count >= 3 else { print("Usage: bose-ctl raw <hex>"); exit(1) }
            cmdRaw(args[2])
        default:
            print("Unknown command: \(cmd)")
            exit(1)
        }
    }
}
